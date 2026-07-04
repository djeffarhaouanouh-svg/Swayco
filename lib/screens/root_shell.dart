import 'dart:async';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/app_strings.dart';
import '../services/call_alert.dart';
import '../services/call_launcher.dart';
import '../services/chat_unread.dart';
import '../services/device_id.dart';
import '../services/friend_request_unread.dart';
import '../services/app_navigator.dart';
import '../services/call_audio.dart';
import '../services/incoming_call_api.dart';
import '../services/ios_callkit.dart';
import '../services/local_notifications.dart';
import '../services/nav_tab.dart';
import '../services/notification_router.dart';
import '../services/profile_api.dart';
import '../services/received_activity_unread.dart';
import '../services/supabase_service.dart';
import '../services/token_api.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../translation/realtime_translation_port.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/missions_ring.dart';
import '../widgets/profile_avatar.dart';
import 'call_screen.dart';
import 'chat_screen.dart';
import 'discover_screen.dart';
import 'friend_requests_screen.dart';
import 'profile_screen.dart';

/// Hosts the tab pages and the full-width glass bottom-nav (flush to the
/// screen bottom) with a sliding pill that animates between selected tabs.
class RootShell extends StatefulWidget {
  const RootShell({super.key, required this.translation});

  final RealtimeTranslationPort translation;

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  // Tab order: Chat (0), Discover (1), Profile (2). Discover is the
  // default landing tab. The selected index lives in the shared
  // [NavTab] notifier so screens pushed on top of the shell can drive it.

  RealtimeChannel? _callsChannel;
  bool _ringingDialogOpen = false;
  Timer? _callPollTimer;
  String _myCalleeId = '';

  /// Call ids that have already triggered the modal — keeps the realtime
  /// channel and the polling backup from racing into two dialogs for the
  /// same ring. Cleared lazily; bounded by call rate so it won't blow up.
  final Set<String> _handledCallIds = {};

  /// Guards the one-shot coach-mark dialogs from overlapping each other.
  bool _tipBusy = false;

  /// Drives the horizontal swipe between tabs (Snapchat-style). Kept in sync
  /// with [NavTab.index]: nav-bar taps / routing animate it, swipes update
  /// [NavTab.index] via [PageView.onPageChanged].
  late final PageController _pageController =
      PageController(initialPage: NavTab.index.value);

  /// Select a tab: update the shared index and clear the matching badges.
  /// Shared by nav-bar taps and swipe (onPageChanged).
  void _selectTab(int i) {
    NavTab.select(i);
    if (i == NavTab.chat) ChatUnread.markAllSeen();
    if (i == NavTab.demandes) ReceivedActivityUnread.markSeen();
  }

  @override
  void initState() {
    super.initState();
    _subscribeIncomingCalls();
    // Route taps on push notifications (live-call invite, message, …).
    NotificationRouter.pending.addListener(_onNotificationIntent);
    // Show the first-visit hint when the user opens their Profile tab.
    NavTab.index.addListener(_onNavTabChanged);
    // A cold launch from a notification tap may have set an intent
    // before this shell mounted — handle it once after the first frame.
    // The same frame is a safe point to fire the post-onboarding nudge.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onNotificationIntent();
      _maybeShowOnboardingTips();
      // Warm the call "connecting" logo into the image cache at app start so
      // it shows instantly when a call begins (it was decoding on first
      // display, leaving a visible blank beat on the connecting screen).
      if (mounted) {
        precacheImage(const AssetImage('assets/notif-android.png'), context);
      }
    });
  }

  /// Sends the shell to the screen a tapped notification points at.
  void _onNotificationIntent() {
    final intent = NotificationRouter.pending.value;
    if (intent == null || !mounted) return;
    switch (intent.type) {
      case 'message':
        NavTab.select(NavTab.chat);
        ChatUnread.markAllSeen();
      case 'online_broadcast':
        // "5 Japonaises en ligne" pull notification → open Discover so they
        // can browse / call whoever is online right now.
        NavTab.select(NavTab.discover);
      // 'incoming_call' needs no routing — the ring modal is shown by
      // the realtime subscription / poll whatever tab is open.
      // 'live_call' was the broadcast notification from the deleted
      // Random-call lobby; ignored if it still lands from a stale
      // push payload.
    }
    NotificationRouter.consume();
  }

  Future<void> _subscribeIncomingCalls() async {
    if (!isSupabaseReady) return;
    final myId = await DeviceId.getOrCreate();
    if (!mounted || myId.isEmpty) return;
    _myCalleeId = myId;
    // iOS only: wire CallKit so an incoming call rings full-screen via a
    // VoIP push even when the app is killed. Accept → join the room;
    // decline → tell the caller (same path as the in-app dialog).
    unawaited(IosCallKit.start(
      userId: myId,
      onAccept: _onCallKitAccept,
      onDecline: _onCallKitDecline,
    ));
    // Kick the pending-requests watcher so the Demandes nav badge stays
    // live without waiting for the user to open the tab.
    unawaited(FriendRequestUnread.start(myId));
    // Same for received likes / photo-reactions — they also badge Demandes.
    unawaited(ReceivedActivityUnread.start(myId));
    _callsChannel = IncomingCallApi.subscribe(
      calleeId: myId,
      onCall: _handleIncomingCall,
    );
    // Web realtime occasionally misses INSERT events (websocket drop,
    // tab throttling). Poll every 3s as a safety net so a missed
    // notification is at most ~3s late.
    _callPollTimer = WebPoll.every(const Duration(seconds: 3), () async {
      if (!mounted || _ringingDialogOpen) return;
      final pending = await IncomingCallApi.fetchPending(_myCalleeId);
      if (!mounted) return;
      for (final call in pending) {
        if (_handledCallIds.contains(call.id)) continue;
        _handleIncomingCall(call);
        // The dialog can only handle one ring at a time. Bail out and
        // let the next poll pick up any remaining ones once it closes.
        break;
      }
    });
  }

  Future<void> _handleIncomingCall(IncomingCall call) async {
    // On iOS the incoming call is owned by CallKit (native full-screen via
    // VoIP push). Running the in-app dialog in parallel races it: when the
    // user answers in CallKit, this dialog's auto-decline timer fires and
    // broadcasts a spurious "declined", which makes the caller leave and the
    // just-joined call drop. So skip the dialog entirely on iOS.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) return;
    if (!mounted || _ringingDialogOpen) return;
    if (_handledCallIds.contains(call.id)) return;
    _handledCallIds.add(call.id);
    // Ignore a stale ring. If the row is older than the caller's ring window
    // it's a missed/abandoned call (e.g. a web caller closed the tab without
    // stamping ended_at) — don't pop the answer UI for it when the callee
    // opens / foregrounds the app long after.
    if (DateTime.now().difference(call.createdAt) >
        const Duration(seconds: 45)) {
      return;
    }
    // The app is now in the foreground handling the call via the in-app
    // dialog — silence the full-screen background ringer if it fired.
    unawaited(LocalNotifications.cancelIncomingCall());
    final caller = isSupabaseReady
        ? await ProfileApi.fetchById(call.callerId)
        : null;
    if (!mounted) return;
    _ringingDialogOpen = true;
    final callerName = caller?.displayName.isNotEmpty == true
        ? caller!.displayName
        : AppStrings.t('incoming_someone');
    // Web only: vibrate + flash the tab title until the user answers /
    // dismisses. No-op on native (handled by the OS already).
    CallAlert.start(callerName: callerName);
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _IncomingCallDialog(
        callerName: callerName,
        callerAvatarUrl: caller?.avatarUrl,
        callerAvatarColor: caller?.avatarColor,
      ),
    );
    CallAlert.stop();
    _ringingDialogOpen = false;
    // Either side of the answer collapses the row so the caller knows.
    await IncomingCallApi.cancel(callId: call.id);
    // Declined (tapped "Refuser" or the ring auto-dismissed): tell the
    // caller so their waiting screen closes instead of ringing forever.
    if (accepted != true) {
      await IncomingCallApi.broadcastDecline(callId: call.id);
    }
    if (!mounted) return;
    if (accepted == true) {
      await _joinCallRoom(call);
    }
  }

  Future<void> _joinCallRoom(IncomingCall call) async {
    try {
      // Resolve my name + spoken language the SAME robust way the caller does
      // (local prefs → Supabase fallback). The old raw profile fetch could
      // mint a token with an empty sourceLang, leaving the OTHER side unable
      // to translate me — half of the "translation only reaches one person".
      final me = await CallLauncher.resolveMyIdentity();
      final token = await fetchLiveKitToken(
        roomName: call.roomName,
        identity: 'u${DateTime.now().millisecondsSinceEpoch}',
        displayName: me.name,
        sourceLang: me.sourceLang,
      );
      // Navigate via the global navigator key, not `context`: on an iOS
      // CallKit accept this runs from a native event while the app may still
      // be backgrounded — or cold-launching from a killed state, where the
      // widget tree (and the navigator) isn't built yet. Previously we dropped
      // the push when the navigator wasn't ready, which is exactly the
      // "answered but never landed on the call screen" bug — so wait up to
      // ~6s for it to appear instead of giving up.
      NavigatorState? nav;
      for (var i = 0; i < 40; i++) {
        nav = rootNavigatorKey.currentState;
        if (nav != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (nav == null) return;
      await nav.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => CallScreen(
            wsUrl: token.url,
            jwt: token.token,
            roomName: token.roomName,
            displayName: me.name,
            mySourceLang: me.sourceLang,
            translation: widget.translation,
            // For the "call ended" summary card (peer PDP + flag).
            peerId: call.callerId,
          ),
        ),
      );
    } catch (e) {
      final ctx = rootNavigatorKey.currentContext;
      if (ctx == null) return;
      // ctx is fetched fresh here (not captured across the await), so it's safe.
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(AppStrings.t('cant_join_call', args: {'msg': '$e'})),
        ),
      );
    }
  }

  /// iOS CallKit "Accept": the user answered from the native full-screen
  /// call UI (possibly straight from a killed app). The accept event only
  /// carries the call id, so we read the row back for the room name, join
  /// it, and dismiss the CallKit entry so it doesn't linger behind our own
  /// in-call screen.
  Future<void> _onCallKitAccept(String callId) async {
    if (callId.isEmpty) return;
    // Don't let the realtime poll re-open the in-app dialog for the same
    // call we're already answering.
    _handledCallIds.add(callId);
    // Prefer the room straight from the CallKit payload (no DB / auth
    // dependency); fall back to the incoming_calls row only if it's missing.
    final extra = await IosCallKit.extraFor(callId);
    var roomName = (extra['roomName'] ?? '').toString();
    var callerId = (extra['callerId'] ?? '').toString();
    if (roomName.isEmpty) {
      final call = await IncomingCallApi.fetchById(callId);
      if (call != null) {
        roomName = call.roomName;
        callerId = call.callerId;
      }
    }
    if (roomName.isEmpty) {
      unawaited(IosCallKit.endCall(callId));
      return;
    }
    // Mark the CallKit call connected (do NOT end it yet) so iOS keeps the
    // audio session alive for LiveKit — otherwise there's no sound. Our own
    // call screen shows under CallKit's banner.
    await IosCallKit.setConnected(callId);
    await _joinCallRoom(IncomingCall(
      id: callId,
      callerId: callerId,
      calleeId: _myCalleeId,
      roomName: roomName,
      createdAt: DateTime.now(),
    ));
    // The call screen has been closed (hung up) — now tear down CallKit.
    unawaited(IosCallKit.endCall(callId));
  }

  /// iOS CallKit "Decline" (or the ring timing out): close the row and tell
  /// the caller so their waiting screen stops ringing.
  Future<void> _onCallKitDecline(String callId) async {
    if (callId.isEmpty) return;
    _handledCallIds.add(callId);
    await IncomingCallApi.broadcastDecline(callId: callId);
    await IncomingCallApi.cancel(callId: callId);
    unawaited(IosCallKit.endCall(callId));
  }

  @override
  void dispose() {
    _callPollTimer?.cancel();
    _pageController.dispose();
    NotificationRouter.pending.removeListener(_onNotificationIntent);
    NavTab.index.removeListener(_onNavTabChanged);
    final ch = _callsChannel;
    if (ch != null) {
      unawaited(Supabase.instance.client.removeChannel(ch));
    }
    super.dispose();
  }

  void _onNavTabChanged() {
    final i = NavTab.index.value;
    // Keep the swipeable pager in sync with programmatic tab changes
    // (nav-bar taps, notification routing, pop-to-tab). Guarded so the
    // round-trip from a swipe (onPageChanged → NavTab.select → here) doesn't
    // re-animate to the page we're already on.
    if (_pageController.hasClients && _pageController.page?.round() != i) {
      _pageController.animateToPage(
        i,
        duration: const Duration(milliseconds: 190),
        curve: Curves.easeOutCubic,
      );
    }
    if (i == NavTab.profile) _maybeShowProfileTip();
  }

  /// Whether the signed-in user already uploaded a Discover photo — when
  /// they have, the "add a photo" nudges are pointless and skipped.
  Future<bool> _hasDiscoverPhoto() async {
    if (!isSupabaseReady) return false;
    try {
      final uid = await DeviceId.getOrCreate();
      final me = await ProfileApi.fetchById(uid);
      return (me?.discoverPhotoUrl ?? '').isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Post-onboarding nudge to add a Discover photo (why, then where).
  /// The "seen" flag is persisted UP FRONT, before any dialog is shown —
  /// otherwise reloading the page mid-popup leaves the flag unset and the
  /// nudge replays on every load. Skipped entirely if a photo is set.
  Future<void> _maybeShowOnboardingTips() async {
    if (_tipBusy || !mounted) return;
    if (await UserPrefs.isOnboardingTipsSeen() || !mounted) return;
    await UserPrefs.markOnboardingTipsSeen();
    if (!mounted) return;
    if (await _hasDiscoverPhoto() || !mounted) return;
    _tipBusy = true;
    await _showTip(
      icon: Icons.add_a_photo_rounded,
      title: AppStrings.t('tip_photo_title'),
      body: AppStrings.t('tip_photo_body'),
      buttonLabel: AppStrings.t('tip_next'),
    );
    if (mounted) {
      await _showTip(
        icon: Icons.person_rounded,
        title: AppStrings.t('tip_photo_where_title'),
        body: AppStrings.t('tip_photo_where_body'),
        buttonLabel: AppStrings.t('tip_got_it'),
      );
    }
    _tipBusy = false;
  }

  /// Photo-nudge on the Profile tab. Shows on EVERY navigation into
  /// the Profile tab — and stops showing entirely once the user has
  /// actually uploaded a Discover photo. (The legacy one-shot
  /// `isProfileTipSeen` flag is no longer read; the discover-photo
  /// presence is the source of truth.) Re-fires only on tab-change
  /// events (NavTab.index listener), so a user who stays on the
  /// profile tab does not get the dialog re-shown.
  Future<void> _maybeShowProfileTip() async {
    if (_tipBusy || !mounted) return;
    if (NavTab.index.value != NavTab.profile) return;
    if (await _hasDiscoverPhoto() || !mounted) return;
    if (NavTab.index.value != NavTab.profile) return;
    _tipBusy = true;
    // Preload the illustration before showing the dialog so the image
    // is in the cache when _TipDialog mounts — no flash of an empty
    // square / popping pixels. Best-effort: a decode error still lets
    // the dialog open with the icon fallback.
    const asset = AssetImage('assets/add-picture.png');
    try {
      await precacheImage(asset, context);
    } catch (_) {}
    if (!mounted) {
      _tipBusy = false;
      return;
    }
    if (NavTab.index.value != NavTab.profile) {
      _tipBusy = false;
      return;
    }
    await _showTip(
      icon: Icons.add_a_photo_rounded,
      title: AppStrings.t('tip_profile_here_title'),
      body: AppStrings.t('tip_profile_here_body'),
      buttonLabel: AppStrings.t('tip_got_it'),
      imageAsset: 'assets/add-picture.png',
    );
    _tipBusy = false;
  }

  Future<void> _showTip({
    required IconData icon,
    required String title,
    required String body,
    required String buttonLabel,
    String? imageAsset,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TipDialog(
        icon: icon,
        title: title,
        body: body,
        buttonLabel: buttonLabel,
        imageAsset: imageAsset,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SC.bg,
      extendBody: true,
      body: ValueListenableBuilder<int>(
        valueListenable: NavTab.index,
        builder: (context, index, _) => ValueListenableBuilder<int>(
          valueListenable: ChatUnread.count,
          builder: (context, unread, _) => ValueListenableBuilder<int>(
            valueListenable: FriendRequestUnread.count,
            builder: (context, pending, _) => ValueListenableBuilder<int>(
              valueListenable: ReceivedActivityUnread.count,
              builder: (context, activity, _) {
                final pages = <Widget>[
                  ChatScreen(translation: widget.translation),
                  const DiscoverScreen(),
                  const FriendRequestsScreen(),
                  const ProfileScreen(),
                ];
                return Stack(
                  children: [
                    // Swipe horizontally between tabs (Snapchat-style). Each
                    // page is kept alive so its state (scroll position, the
                    // Discover deck, subscriptions) survives a swipe away,
                    // exactly like the old IndexedStack.
                    PageView(
                      controller: _pageController,
                      onPageChanged: _selectTab,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        for (final p in pages) _KeepAlivePage(child: p),
                      ],
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: MediaQuery.paddingOf(context).bottom +
                          GlassNavBar.floatBottom,
                      // Rebuild on every pager tick so the highlight pill
                      // glides with the swipe instead of snapping at the end.
                      child: AnimatedBuilder(
                        animation: _pageController,
                        builder: (context, _) {
                          final frac = _pageController.hasClients
                              ? (_pageController.page ?? index.toDouble())
                              : index.toDouble();
                          return GlassNavBar(
                            selected: index,
                            selectedFraction: frac,
                            unreadChat: unread,
                            unreadRequests: pending + activity,
                            onSelect: _selectTab,
                          );
                        },
                      ),
                    ),
                    // Game-style mission celebration, drawn above every tab.
                    const Positioned.fill(child: MissionCelebrationOverlay()),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}


/// Keeps a tab page alive while it's swiped off-screen in the [PageView],
/// so its state (scroll, subscriptions, the Discover deck position) is
/// preserved — matching the old IndexedStack behaviour.
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});
  final Widget child;
  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// Modal shown to the callee when a peer rings them. Pops `true` on
/// "Accepter", `false` on "Refuser".
class _IncomingCallDialog extends StatefulWidget {
  const _IncomingCallDialog({
    required this.callerName,
    required this.callerAvatarUrl,
    required this.callerAvatarColor,
  });

  final String callerName;
  final String? callerAvatarUrl;
  final String? callerAvatarColor;

  @override
  State<_IncomingCallDialog> createState() => _IncomingCallDialogState();
}

class _IncomingCallDialogState extends State<_IncomingCallDialog> {
  static const _timeout = Duration(seconds: 30);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Auto-decline if the user doesn't answer in time so the call doesn't
    // ring forever after the caller has already given up.
    _timer = Timer(_timeout, () {
      if (mounted) Navigator.of(context).pop(false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: SC.bubbleIn,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Tappable hero zone — clicking anywhere on the avatar / name /
          // label accepts the call directly, same effect as the green
          // button. Keeps the explicit Accept / Decline buttons below
          // for users who want to refuse.
          InkWell(
            onTap: () {
              armCallAudio();
              armSpeechSynthesis();
              Navigator.of(context).pop(true);
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ProfileAvatar(
                    displayName: widget.callerName,
                    avatarUrl: widget.callerAvatarUrl,
                    avatarColorHex: widget.callerAvatarColor,
                    size: 88,
                    fontSize: 36,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    widget.callerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: SC.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    AppStrings.t('incoming_call_label'),
                    style: const TextStyle(color: SC.textMuted, fontSize: 14),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _RoundActionButton(
                  icon: Icons.call_end,
                  label: AppStrings.t('decline'),
                  color: const Color(0xFFE53935),
                  onTap: () => Navigator.of(context).pop(false),
                ),
                _RoundActionButton(
                  icon: Icons.call,
                  label: AppStrings.t('accept'),
                  color: SC.accent,
                  onTap: () {
              armCallAudio();
              armSpeechSynthesis();
              Navigator.of(context).pop(true);
            },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundActionButton extends StatelessWidget {
  const _RoundActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 64,
              height: 64,
              child: Icon(icon, color: Colors.white, size: 28),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            color: SC.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

/// Friendly one-shot coach-mark. Styled on the app's near-black scaffold
/// colour with white copy; dismissed only by its button.
class _TipDialog extends StatelessWidget {
  const _TipDialog({
    required this.icon,
    required this.title,
    required this.body,
    required this.buttonLabel,
    this.imageAsset,
  });

  final IconData icon;
  final String title;
  final String body;
  final String buttonLabel;

  /// Optional illustration asset shown in place of the round [icon].
  /// Used by the "add your photo" tip to replace the camera bubble with
  /// a richer drawing while keeping every other tip on the icon layout.
  final String? imageAsset;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      // Near-black surface (the original WhatsApp-scaffold tone) —
      // the navy SC.bg the rest of the app uses bled the popup into
      // the mesh background. Kept hardcoded so a future Midnight
      // tweak doesn't accidentally lift this surface again.
      backgroundColor: const Color(0xFF0A0A0A),
      insetPadding: const EdgeInsets.symmetric(horizontal: 36),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (imageAsset != null)
              // The source PNG ships with a black square framing the
              // illustration — crop into the artwork (BoxFit.cover) so
              // the popup shows just the picture, not the bleed.
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset(
                  imageAsset!,
                  width: 180,
                  height: 180,
                  fit: BoxFit.cover,
                ),
              )
            else
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: SC.accent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: SC.accent, size: 28),
              ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14.5,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: SC.accent,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(buttonLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
