import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/analytics.dart';
import '../services/app_settings.dart';
import '../services/app_strings.dart';
import '../widgets/spoken_language_gate.dart';
import '../services/block_api.dart';
import '../services/call_launcher.dart';
import '../services/chat_api.dart';
import '../services/chat_unread.dart';
import '../services/device_id.dart';
import '../services/match_seen.dart';
import '../services/muted_calls.dart';
import '../services/friendship_api.dart';
import '../services/guest_invite_api.dart';
import '../services/nav_tab.dart';
import '../services/notif_enable_flow.dart';
import '../services/notification_client.dart';
import '../services/profile_api.dart';
import '../services/supabase_service.dart';
import '../services/token_api.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../swayco/realtime_translation_port.dart';
import '../widgets/appear.dart';
import '../widgets/glass.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/report_dialog.dart';
import '../widgets/swayco_dialog.dart';
import 'call_screen.dart';
import 'chat_thread_screen.dart';
import 'profile_screen.dart';

/// WhatsApp-style chat home: lists every accepted friend (union of followers
/// + following). Tapping a row opens the direct-message thread; the trailing
/// video icon launches a call directly with that friend.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    this.translation = const NoOpRealtimeTranslation(),
  });

  final RealtimeTranslationPort translation;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  String _myId = '';
  List<RemoteProfile> _friends = const [];
  /// Matches with no message yet, newest first — the bubble row under the
  /// wordmark. Once a conversation starts they move down into the list.
  List<RemoteProfile> _newMatches = const [];
  /// Matches the user has already laid eyes on — they stay in the rail but
  /// stop counting toward the badge.
  Set<String> _seenMatches = const {};
  /// Fires a few seconds after the rail is on screen: by then the user has
  /// seen the new matches, so the badge clears.
  Timer? _matchSeenTimer;
  Map<String, ChatMessage> _latestByConv = const {};
  Map<String, DateTime> _seenByConv = const {};
  Map<String, int> _unreadCountByConv = const {};
  bool _loading = true;
  String? _error;
  Timer? _pollTimer;
  /// UI lock while a guest-invite link is being minted (prevents double-tap).
  bool _creatingInvite = false;

  /// True when OS notifications are off (never asked or refused). Drives the
  /// recovery banner at the top of the conversation list — the moment where a
  /// missed-message notification matters most. Dismissible per session.
  bool _notifBlocked = false;
  bool _notifBannerDismissed = false;

  Future<void> _checkNotifStatus() async {
    final blocked = (await NotificationClient.notifStatus()) != 'enabled';
    if (!mounted || blocked == _notifBlocked) return;
    setState(() => _notifBlocked = blocked);
  }

  Future<void> _onEnableNotifs() async {
    await NotifEnableFlow.run(context);
    await _checkNotifStatus();
  }

  @override
  void initState() {
    super.initState();
    Analytics.track('screen_view', props: {'screen': 'chat'});
    WidgetsBinding.instance.addObserver(this);
    // Rebuild when the local "hide my online status" toggle flips
    // so the green dots on every row vanish (or come back)
    // immediately, without waiting for the 7 s poll.
    AppSettings.hideOnlineLocal.addListener(_onHideOnlineChanged);
    NavTab.index.addListener(_onNavTabChanged);
    _reload();
    _checkNotifStatus();
    // Web build doesn't always get realtime push reliably — poll the list
    // silently so new messages / new friends appear without pull-to-refresh.
    _pollTimer = WebPoll.every(
      const Duration(seconds: 7),
      () => _reload(silent: true),
    );
    // NOTE: we deliberately do NOT call ChatUnread.markAllSeen() here.
    // ChatScreen lives inside IndexedStack, so initState fires at app
    // launch even when the user is on another tab — calling markAllSeen
    // here would silently wipe the unread badge before the user ever
    // sees it. The badge is cleared in RootShell when the user actually
    // taps the Chat tab destination.
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppSettings.hideOnlineLocal.removeListener(_onHideOnlineChanged);
    NavTab.index.removeListener(_onNavTabChanged);
    _matchSeenTimer?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  void _onHideOnlineChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onNavTabChanged() {
    if (!mounted) return;
    if (NavTab.index.value == NavTab.chat) {
      _scheduleMatchSeen();
    } else {
      _matchSeenTimer?.cancel();
      _matchSeenTimer = null;
    }
  }

  /// The badge is a "you have new matches" nudge, so it dies once the rail has
  /// actually been looked at: three seconds on the Messages tab with unseen
  /// bubbles on screen is enough. The bubbles themselves stay.
  void _scheduleMatchSeen() {
    if (_matchSeenTimer != null) return;
    if (_unseenMatches == 0) return;
    if (NavTab.index.value != NavTab.chat) return;
    _matchSeenTimer = Timer(const Duration(seconds: 3), () async {
      _matchSeenTimer = null;
      if (!mounted) return;
      final ids = _newMatches.map((p) => p.id).toList();
      final seen = await MatchSeen.markSeen(
        ids,
        stillMatched: ids.toSet(),
      );
      if (!mounted) return;
      setState(() => _seenMatches = seen);
    });
  }

  /// Matches in the rail the user hasn't laid eyes on yet — the badge count.
  int get _unseenMatches =>
      _newMatches.where((p) => !_seenMatches.contains(p.id)).length;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reload();
      // Re-check after the user may have toggled notifications in Settings.
      _checkNotifStatus();
    }
  }

  Future<void> _reload({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final id = await DeviceId.getOrCreate();
      if (!isSupabaseReady) {
        if (!mounted) return;
        setState(() {
          _myId = id;
          _friends = const [];
          _newMatches = const [];
          _loading = false;
        });
        return;
      }
      // Fire every independent request in parallel — previously each
      // await sat in front of the next, so the list staggered in over
      // 6-7× the latency of one request. Future.wait collapses them
      // into a single round-trip from the user's point of view.
      final results = await Future.wait([
        FriendshipApi.fetchMatchesNewestFirst(id),
        // Latest message per conversation involving me — used for the
        // "WhatsApp-style" last-message preview and the sort order.
        ChatApi.fetchLatestPerConversation(id),
        ChatUnread.readPerConversationSeen(),
        // Conversations the user deleted from their list (local
        // "delete for me"). A row stays hidden until a message newer
        // than the clear timestamp arrives.
        ChatUnread.clearedConversations(),
        // Either side of a block hides the row in both directions.
        BlockApi.fetchMyBlockedProfiles(id),
        BlockApi.fetchMyBlockerIds(),
        // Recent inbound messages — counted per conversation for the badge.
        ChatApi.fetchInboundForUnread(id),
      ]);
      final matches = results[0] as List<RemoteProfile>;
      final latest = results[1] as Map<String, ChatMessage>;
      final seen = results[2] as Map<String, DateTime>;
      final cleared = results[3] as Map<String, DateTime>;
      final iBlocked = results[4] as List<RemoteProfile>;
      final blockedMe = results[5] as Set<String>;
      final inbound =
          results[6] as List<({String conversationId, DateTime createdAt})>;

      final byId = <String, RemoteProfile>{};
      for (final p in matches) {
        byId[p.id] = p;
      }
      // Keep conversations alive after a match ends: the messages outlive the
      // friendship row, so any peer we have a thread with — even a now-
      // stranger — still earns a row here. Pull the profiles matches missed.
      final convPeerIds = <String>{};
      for (final msg in latest.values) {
        final peer = msg.senderId == id ? msg.recipientId : msg.senderId;
        if (peer.isEmpty || peer == id || byId.containsKey(peer)) continue;
        convPeerIds.add(peer);
      }
      if (convPeerIds.isNotEmpty) {
        for (final p in await ProfileApi.fetchByIds(convPeerIds.toList())) {
          byId[p.id] = p;
        }
      }
      final blockedByMe = iBlocked.map((p) => p.id).toSet();
      final hiddenPeers = {...blockedByMe, ...blockedMe};
      byId.removeWhere((k, _) => hiddenPeers.contains(k));

      String convIdFor(String otherId) {
        final ids = [id, otherId]..sort();
        return 'dm-${ids[0]}-${ids[1]}';
      }

      final visible = byId.values.where((p) {
        final clearedAt = cleared[convIdFor(p.id)];
        if (clearedAt == null) return true;
        // Re-surface the conversation once a newer message lands.
        final lm = latest[convIdFor(p.id)];
        return lm != null && lm.createdAt.isAfter(clearedAt);
      }).toSet();
      // A match with no message yet is a BUBBLE, not a row (Tinder split).
      // `matches` already comes newest-first, so the freshest match leads.
      final newMatches = [
        for (final p in matches)
          if (visible.contains(p) && latest[convIdFor(p.id)] == null) p,
      ];
      final seenMatches = await MatchSeen.load();
      final friends = visible
          .where((p) => latest[convIdFor(p.id)] != null)
          .toList()
        ..sort((a, b) {
          final la = latest[convIdFor(a.id)]?.createdAt;
          final lb = latest[convIdFor(b.id)]?.createdAt;
          if (la == null && lb == null) {
            return a.displayName
                .toLowerCase()
                .compareTo(b.displayName.toLowerCase());
          }
          if (la == null) return 1; // peers without messages sink to the bottom
          if (lb == null) return -1;
          return lb.compareTo(la); // most recent first
        });
      // Per-conversation unread COUNT: inbound messages newer than the last
      // time I opened that thread (never opened → all of them count).
      final unreadCounts = <String, int>{};
      for (final m in inbound) {
        final s = seen[m.conversationId];
        if (s == null || m.createdAt.isAfter(s)) {
          unreadCounts[m.conversationId] =
              (unreadCounts[m.conversationId] ?? 0) + 1;
        }
      }
      if (!mounted) return;
      setState(() {
        _myId = id;
        _friends = friends;
        _newMatches = newMatches;
        _seenMatches = seenMatches;
        _latestByConv = latest;
        _seenByConv = seen;
        _unreadCountByConv = unreadCounts;
        _loading = false;
      });
      // Landed on Messages with fresh matches → start the "seen" countdown.
      _scheduleMatchSeen();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Erreur de chargement : $e';
        _loading = false;
      });
    }
  }

  /// Conversations with at least one unread inbound message — the number in
  /// the "Messages" badge.
  int get _unreadConversations =>
      _friends.where(_isUnread).length;

  String _conversationIdFor(String otherId) {
    final ids = [_myId, otherId]..sort();
    return 'dm-${ids[0]}-${ids[1]}';
  }

  Future<void> _openThread(RemoteProfile peer) async {
    final convId = _conversationIdFor(peer.id);
    final title = peer.displayName.isNotEmpty
        ? peer.displayName
        : (peer.handle.isNotEmpty ? '@${peer.handle}' : 'Ami');
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatThreadScreen(
          conversationId: convId,
          title: title,
          peerDeviceId: peer.id,
          translation: widget.translation,
        ),
      ),
    );
    _reload();
  }

  void _viewProfile(RemoteProfile peer) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ProfileScreen(userId: peer.id),
      ),
    );
  }

  /// Delete a conversation from the chat list — local "delete for me".
  /// The peer's copy is untouched; the row reappears here if they send a
  /// new message later.
  Future<void> _deleteConversation(RemoteProfile peer) async {
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('delete_conversation'),
      body: AppStrings.t('delete_conversation_body'),
      confirmLabel: AppStrings.t('delete'),
    );
    if (ok != true) return;
    await ChatUnread.markConversationCleared(_conversationIdFor(peer.id));
    await _reload();
  }

  Future<void> _reportPeer(RemoteProfile peer) async {
    if (_myId.isEmpty) return;
    await showReportDialog(
      context,
      reporterId: _myId,
      reportedId: peer.id,
      peerName: peer.displayName.isEmpty
          ? AppStrings.t('incoming_someone')
          : peer.displayName,
    );
  }

  Future<void> _blockPeer(RemoteProfile peer) async {
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('block_peer_q', args: {'name': peer.displayName}),
      body: AppStrings.t('block_peer_body'),
      confirmLabel: AppStrings.t('block'),
    );
    if (ok != true || _myId.isEmpty) return;
    try {
      await BlockApi.block(blockerId: _myId, blockedId: peer.id);
      if (!mounted) return;
      // Cyan top toast as a compact confirmation (reuse the block label).
      _showTopToast('${peer.displayName} · ${AppStrings.t('block')}');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppStrings.t('error_prefix', args: {'msg': '$e'})),
      ));
    }
  }

  /// Cyan pill notification at the TOP of the screen that auto-dismisses —
  /// used for the block confirmation instead of the default white bottom
  /// snackbar.
  void _showTopToast(String message) {
    final overlay = Overlay.of(context);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _TopToast(
        message: message,
        onDismissed: () {
          if (entry.mounted) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
  }

  /// Random LiveKit identity for the host joining a guest-invite call.
  String _newCallIdentity() {
    final r = Random();
    return 'u${DateTime.now().millisecondsSinceEpoch}${r.nextInt(999999)}';
  }

  /// Mint a guest-invite link, open the share sheet, then drop the host into
  /// the call's waiting room. Whoever opens the link joins with no account;
  /// the host (the caller) is the one billed for the call.
  Future<void> _shareCallInvite() async {
    if (_creatingInvite) return;
    setState(() => _creatingInvite = true);
    try {
      // The host needs a name + spoken language for the call's translation
      // route — the same profile fields onboarding collects. Resolved via
      // the shared helper so the local→Supabase fallback is identical to a
      // direct peer call (and can't drift out of sync).
      final me = await CallLauncher.resolveMyIdentity();
      final myName = me.name;
      final myLang = me.sourceLang;
      if (!me.isComplete) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.t('invite_call_need_profile'))),
        );
        return;
      }
      final invite = await GuestInviteApi.create();
      if (invite == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.t('invite_call_failed'))),
        );
        return;
      }
      final shareText = AppStrings.t(
        'invite_call_share_text',
        args: {'link': invite.link},
      );
      // Open the OS share sheet so the host can send the link right away.
      if (mounted) {
        final box = context.findRenderObject() as RenderBox?;
        try {
          await SharePlus.instance.share(
            ShareParams(
              text: shareText,
              subject: AppStrings.t('invite_to_call'),
              sharePositionOrigin: box != null
                  ? box.localToGlobal(Offset.zero) & box.size
                  : null,
            ),
          );
        } catch (_) {
          // Sheet dismissed — still enter the waiting room; the host can
          // re-share the link from there.
        }
      }
      // Which language will be spoken, resolved before minting anything: the
      // token carries it into the LiveKit metadata, which is what the peer
      // translates FROM.
      final spokenLang = await resolveSpokenLanguage(preselect: myLang);
      if (!mounted) return;

      // Enter the waiting room — the call connects when the guest joins.
      final token = await fetchLiveKitToken(
        roomName: invite.roomName,
        identity: _newCallIdentity(),
        displayName: myName,
        sourceLang: spokenLang,
        inviteSig: invite.sig,
        inviteExp: invite.exp,
      );
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => CallScreen(
            wsUrl: token.url,
            jwt: token.token,
            roomName: token.roomName,
            displayName: myName,
            mySourceLang: spokenLang,
            translation: widget.translation,
            inviteShareText: shareText,
            isCaller: true,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('invite_call_failed'))),
      );
    } finally {
      if (mounted) setState(() => _creatingInvite = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Classic flat black, matching the conversation thread — no blue mesh.
      backgroundColor: SC.bg,
      body: SafeArea(
        bottom: false,
        // Fixed "Messages" band at the top; the conversation list scrolls
        // underneath it (the band stays pinned, it doesn't scroll away).
        child: Column(
          children: [
            _titleBar,
            // Le liseré qui ferme le header : pleine largeur, bord à bord.
            Divider(
              height: 1,
              thickness: 1,
              color: Colors.white.withValues(alpha: 0.10),
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  /// The band pinned at the top of the page — the same swayco.ai wordmark as
  /// the Discover header (".ai" in cyan), where the "Messages" title used to be.
  Widget get _titleBar => const Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'swayco'),
                TextSpan(
                  text: '.ai',
                  style: TextStyle(color: Color(0xFF22D3EE)),
                ),
              ],
            ),
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
        ),
      );

  Widget _buildBody() {
    if (_loading) {
      // Skeleton list while data lands — keeps the layout in place
      // instead of swapping a centred spinner for a populated list
      // (the old behaviour made rows pop in one by one as each
      // request resolved).
      return const _ChatListSkeleton();
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _error!,
          style: const TextStyle(
            color: Color(0xFFFFAB91),
            height: 1.35,
            fontSize: 13,
          ),
        ),
      );
    }
    if (_friends.isEmpty && _newMatches.isEmpty) {
      return const _NoFriendsEmpty();
    }
    // LAYER STRUCTURE: the mesh fond (built in build()) sits at the back; the
    // panel is the middle layer. It lives INSIDE the page scroll view so the
    // WHOLE panel moves when you scroll. A min-height = the available zone
    // makes it fill and rest flush on the nav at rest, so the nav's concave
    // notches hug its rounded bottom corners (Discover-style); once the rows
    // overflow that height the panel grows and the whole thing scrolls.
    final navBody =
        GlassNavBar.totalReservedHeight + MediaQuery.paddingOf(context).bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fill = constraints.maxHeight - 12 - navBody;
        return RefreshIndicator(
          color: SC.accent,
          backgroundColor: SC.bubbleIn,
          onRefresh: _reload,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(top: 12, bottom: navBody),
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(minHeight: fill > 0 ? fill : 0),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_notifBlocked && !_notifBannerDismissed)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                          child: _NotifBanner(
                            onEnable: _onEnableNotifs,
                            onDismiss: () =>
                                setState(() => _notifBannerDismissed = true),
                          ),
                        ),
                      // "Nouveaux matchs" — the bubble rail, newest first.
                      if (_newMatches.isNotEmpty) ...[
                        _SectionHeader(
                          label: AppStrings.t('new_matches_section'),
                          count: _unseenMatches,
                        ),
                        _MatchBubbleRail(
                          matches: _newMatches,
                          onTap: _openThread,
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (_friends.isNotEmpty)
                        _SectionHeader(
                          label: AppStrings.t('messages_section'),
                          count: _unreadConversations,
                        ),
                      // Conversation rows.
                      for (final (i, p) in _friends.indexed)
                        FadeSlideIn(
                          delay: Duration(milliseconds: i * 55),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (i > 0) _rowDivider,
                              _FriendChatRow(
                                profile: p,
                                lastMessage:
                                    _latestByConv[_conversationIdFor(p.id)],
                                isMine: _latestByConv[_conversationIdFor(p.id)]
                                        ?.senderId ==
                                    _myId,
                                unread: _isUnread(p),
                                unreadCount: _unreadCountFor(p),
                                onTap: () => _openThread(p),
                                onViewProfile: () => _viewProfile(p),
                                onBlock: () => _blockPeer(p),
                                onReport: () => _reportPeer(p),
                                onDeleteConversation: () =>
                                    _deleteConversation(p),
                                onCall: () => CallLauncher.startCall(
                                  context,
                                  peerDeviceId: p.id,
                                  translation: widget.translation,
                                ),
                                onCallVideo: () => CallLauncher.startCall(
                                  context,
                                  peerDeviceId: p.id,
                                  translation: widget.translation,
                                  startWithCamera: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                      _rowDivider,
                      // "Invite to a call" — last section in the panel.
                      _InviteToCallRow(
                        onTap: _creatingInvite ? null : _shareCallInvite,
                        creatingInvite: _creatingInvite,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Hairline divider between sections on the white block — inset past the
  /// avatar on the left, stopping before the time / call cluster on the right.
  static Widget get _rowDivider => Divider(
        height: 1,
        thickness: 1,
        indent: 70,
        endIndent: 24,
        color: Colors.white.withValues(alpha: 0.08),
      );

  /// True when the peer's last message is newer than the last time I
  /// opened the thread (or I've never opened it). Drives the cyan dot.
  bool _isUnread(RemoteProfile p) {
    final convId = _conversationIdFor(p.id);
    final last = _latestByConv[convId];
    final seen = _seenByConv[convId];
    return last != null &&
        last.senderId != _myId &&
        (seen == null || last.createdAt.isAfter(seen));
  }

  /// Number of unread inbound messages in [p]'s conversation (0 = none).
  int _unreadCountFor(RemoteProfile p) =>
      _unreadCountByConv[_conversationIdFor(p.id)] ?? 0;
}

class _FriendChatRow extends StatelessWidget {
  const _FriendChatRow({
    required this.profile,
    required this.lastMessage,
    required this.isMine,
    required this.unread,
    required this.unreadCount,
    required this.onTap,
    required this.onViewProfile,
    required this.onBlock,
    required this.onReport,
    required this.onDeleteConversation,
    required this.onCall,
    required this.onCallVideo,
  });
  final RemoteProfile profile;
  final ChatMessage? lastMessage;
  final bool isMine;
  /// True when the last message is from the peer and hasn't been read
  /// yet — drives the green dot + bold name styling on the row.
  final bool unread;

  /// Number of unread messages in this conversation (0 = none). Drives the
  /// cyan count badge; falls back to a dot when [unread] but the count
  /// window missed it.
  final int unreadCount;
  final VoidCallback onTap;
  final VoidCallback onViewProfile;
  final VoidCallback onBlock;
  final VoidCallback onReport;
  /// Removes this conversation from the chat list (local "delete for me").
  final VoidCallback onDeleteConversation;
  /// Dials this friend (audio) — same call path as the chat thread header.
  final VoidCallback onCall;

  /// Dials this friend with the camera on (video call).
  final VoidCallback onCallVideo;

  /// True when the peer was active in the last 2 minutes, has not
  /// hidden their own online status, AND the local user has not
  /// opted out of presence (reciprocal rule — if I'm hiding I don't
  /// see anyone else's dot either).
  bool get _peerOnline {
    if (AppSettings.hideOnlineLocal.value) return false;
    final ls = profile.lastSeen;
    return !profile.hideOnlineStatus &&
        ls != null &&
        DateTime.now().difference(ls) < const Duration(minutes: 2);
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final isSameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (isSameDay) {
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    final wasYesterday =
        dt.year == yesterday.year && dt.month == yesterday.month && dt.day == yesterday.day;
    if (wasYesterday) return 'hier';
    final daysAgo = now.difference(dt).inDays;
    if (daysAgo < 7) {
      const weekdays = ['lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.', 'dim.'];
      return weekdays[(dt.weekday - 1).clamp(0, 6)];
    }
    final d = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    return '$d/$mo';
  }

  /// Long-press menu (the per-row 3-dots was removed): block / report /
  /// delete the conversation.
  void _showRowActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SC.bubbleIn,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<Set<String>>(
              valueListenable: MutedCalls.ids,
              builder: (_, muted, _) {
                final isMuted = muted.contains(profile.id);
                return ListTile(
                  leading: Icon(
                    isMuted
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_off_outlined,
                    color: SC.textPrimary,
                  ),
                  title: Text(
                    AppStrings.t(
                      isMuted ? 'calls_unmute' : 'calls_mute',
                    ),
                    style: const TextStyle(color: SC.textPrimary),
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    MutedCalls.setMuted(profile.id, !isMuted);
                  },
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.block, color: Color(0xFFE53935)),
              title: Text(
                AppStrings.t('block'),
                style: const TextStyle(color: SC.textPrimary),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                onBlock();
              },
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined, color: SC.textPrimary),
              title: Text(
                AppStrings.t('report'),
                style: const TextStyle(color: SC.textPrimary),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                onReport();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: SC.textPrimary),
              title: Text(
                AppStrings.t('delete_conversation'),
                style: const TextStyle(color: SC.textPrimary),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                onDeleteConversation();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = profile.displayName.isNotEmpty
        ? profile.displayName
        : (profile.handle.isNotEmpty
            ? '@${profile.handle}'
            : AppStrings.t('chat_no_name'));

    final subtitleParts = <InlineSpan>[];
    if (lastMessage != null && lastMessage!.body.isNotEmpty) {
      if (isMine) {
        subtitleParts.add(const TextSpan(
          text: 'Vous : ',
          style: TextStyle(
            color: SC.textMuted,
            fontWeight: FontWeight.w500,
          ),
        ));
      }
      subtitleParts.add(TextSpan(text: lastMessage!.body));
    } else {
      subtitleParts.add(TextSpan(text: AppStrings.t('chat_tap_to_chat')));
    }

    return Material(
      color: unread ? SC.accent.withValues(alpha: 0.07) : Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        onLongPress: () => _showRowActions(context),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            // Avatar — tap goes straight to the peer's profile. The light-
            // green presence dot rides the bottom-right corner when online.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onViewProfile,
              child: Stack(
                children: [
                  ProfileAvatar(
                    displayName: profile.displayName,
                    avatarUrl: profile.avatarUrl,
                    size: 46,
                  ),
                  if (_peerOnline)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: SC.online,
                          shape: BoxShape.circle,
                          border: Border.all(color: SC.bg, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // WhatsApp-style top line: name on the left, date on the
                  // right (small & dim, cyan when unread).
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: SCText.name.copyWith(
                            fontWeight:
                                unread ? FontWeight.w800 : FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        lastMessage != null
                            ? _formatTime(lastMessage!.createdAt)
                            : '',
                        style: SCText.meta.copyWith(
                          color: unread ? SC.accent : SC.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: RichText(
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          text: TextSpan(
                            style: SCText.preview.copyWith(
                              color: unread ? SC.textPrimary : SC.textMuted,
                              fontWeight:
                                  unread ? FontWeight.w600 : FontWeight.w400,
                            ),
                            children: subtitleParts,
                          ),
                        ),
                      ),
                      if (unreadCount > 0) ...[
                        const SizedBox(width: 8),
                        _UnreadBadge(count: unreadCount),
                      ] else if (unread) ...[
                        const SizedBox(width: 8),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: SC.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Quick audio-call shortcut. The 3-dots menu was removed — long-
            // press the row for block / report / delete.
            _RowCallButton(onTap: onCall),
          ],
        ),
        ),
      ),
    );
  }

}

/// Filled cyan pill showing the unread-message count on a chat row (caps at
/// 99+). High-contrast — the primary "new messages" signal on the list.
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: SC.accent,
        borderRadius: BorderRadius.circular(999),
      ),
      alignment: Alignment.center,
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          color: SC.bgDeep,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}

/// Snapchat-style recovery banner: when notifications are off, nudge the user
/// to turn them on right where missed messages hurt. Benefit-framed copy, a
/// one-tap "enable" that runs the priming → OS-prompt / Settings flow, and a
/// dismiss for the session.
class _NotifBanner extends StatelessWidget {
  const _NotifBanner({required this.onEnable, required this.onDismiss});

  final VoidCallback onEnable;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: SC.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: SC.accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.notifications_off_rounded,
              color: SC.accent, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              AppStrings.t('notif_banner_text'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onEnable,
            style: TextButton.styleFrom(
              foregroundColor: SC.accent,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              AppStrings.t('notif_banner_cta'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded,
                color: Colors.white54, size: 18),
          ),
        ],
      ),
    );
  }
}

/// Cyan top-toast that slides down + fades in, holds, then slides up + fades
/// out before removing its own overlay entry via [onDismissed].
class _TopToast extends StatefulWidget {
  const _TopToast({required this.message, required this.onDismissed});

  final String message;
  final VoidCallback onDismissed;

  @override
  State<_TopToast> createState() => _TopToastState();
}

class _TopToastState extends State<_TopToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _t =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    await _c.forward();
    await Future<void>.delayed(const Duration(milliseconds: 1700));
    if (!mounted) return;
    await _c.reverse();
    widget.onDismissed();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 10,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _t,
          builder: (context, child) => Opacity(
            opacity: _t.value.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, (1 - _t.value) * -14),
              child: child,
            ),
          ),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                decoration: BoxDecoration(
                  color: SC.accent,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black45,
                      blurRadius: 14,
                      offset: Offset(0, 5),
                    ),
                  ],
                ),
                child: Text(
                  widget.message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF04141A),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small round audio-call shortcut at the far-right of every chat-list row.
class _RowCallButton extends StatelessWidget {
  const _RowCallButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Real glass circle + spring bounce (like the header / photo buttons),
    // keeping the cyan phone glyph.
    return GlassIconButton(
      icon: Icons.phone_rounded,
      onTap: onTap,
      size: 38,
      iconSize: 18,
      iconColor: SC.accent,
    );
  }
}

/// "Invite to a call" entry — now the first row inside the messages glass
/// card (instead of a separate bar below the list). It mints a guest invite
/// link (join a call with no account) and opens the native OS share sheet.
/// Styled like a conversation row but with a cyan gradient video badge in
/// place of an avatar so it reads as the primary action of the section.
class _InviteToCallRow extends StatelessWidget {
  const _InviteToCallRow({
    required this.onTap,
    required this.creatingInvite,
  });

  /// Null while a link is being minted — disables the row.
  final VoidCallback? onTap;
  final bool creatingInvite;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              // Cyan gradient badge, same 46 px footprint as a row avatar.
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [SC.accent, SC.meshBlue],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: SC.accent.withValues(alpha: 0.35),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: creatingInvite
                    ? const Padding(
                        padding: EdgeInsets.all(13),
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.videocam_rounded,
                        color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  creatingInvite
                      ? AppStrings.t('invite_call_creating')
                      : AppStrings.t('invite_to_call'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SCText.name.copyWith(color: SC.accent),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded,
                  color: SC.textMuted, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

/// Placeholder list shown while the chat-list data is loading. Same
/// glass card + same row geometry as the real list, with each row
/// replaced by shimmering bars. Keeps the page layout stable so the
/// content doesn't pop in / shift when the data lands.
/// A section title on the Messages page — "NOUVEAUX MATCHS" / "MESSAGES" in
/// the cyan accent, with the count in a filled pill next to it (Tinder-style,
/// but cyan on black rather than red on white).
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: SC.accent,
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          if (count > 0) ...[
            const SizedBox(width: 8),
            Container(
              constraints: const BoxConstraints(minWidth: 18),
              height: 18,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 5),
              decoration: const BoxDecoration(
                color: SC.accent,
                shape: BoxShape.circle,
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                  color: Color(0xFF0E0E0E),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The horizontal rail of match bubbles: one circle per match you haven't
/// written to yet, newest first, name underneath. Tapping one opens the
/// conversation — which is exactly what moves it out of the rail.
class _MatchBubbleRail extends StatelessWidget {
  const _MatchBubbleRail({required this.matches, required this.onTap});

  final List<RemoteProfile> matches;
  final void Function(RemoteProfile) onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 100,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: matches.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (ctx, i) => _MatchBubble(
          profile: matches[i],
          onTap: () => onTap(matches[i]),
        ),
      ),
    );
  }
}

class _MatchBubble extends StatelessWidget {
  const _MatchBubble({required this.profile, required this.onTap});

  final RemoteProfile profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = profile.displayName.trim().isNotEmpty
        ? profile.displayName
        : (profile.handle.isNotEmpty
              ? '@${profile.handle}'
              : AppStrings.t('chat_no_name'));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProfileAvatar(
              displayName: profile.displayName,
              avatarUrl: profile.avatarUrl,
              size: 66,
            ),
            const SizedBox(height: 6),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: SC.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatListSkeleton extends StatefulWidget {
  const _ChatListSkeleton();

  @override
  State<_ChatListSkeleton> createState() => _ChatListSkeletonState();
}

class _ChatListSkeletonState extends State<_ChatListSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Same panel (fills + hugs the nav at rest) as the loaded list, with
    // shimmering placeholder rows so the layout doesn't shift when data lands.
    final navBody = GlassNavBar.height + MediaQuery.paddingOf(context).bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fill = constraints.maxHeight - 12 - navBody;
        return ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.only(top: 12, bottom: navBody),
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: fill > 0 ? fill : 0),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: AnimatedBuilder(
                  animation: _ctrl,
                  builder: (_, _) {
                    final t = Curves.easeInOut.transform(_ctrl.value);
                    // 0.10 → 0.18 alpha so the shimmer breathes gently.
                    final shimmer =
                        Colors.white.withValues(alpha: 0.10 + 0.08 * t);
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < 5; i++)
                          _SkeletonRow(shimmer: shimmer),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow({required this.shimmer});

  final Color shimmer;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          // Avatar placeholder — same 46 px circle the real row uses.
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: shimmer,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 120,
                  height: 14,
                  decoration: BoxDecoration(
                    color: shimmer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: 180,
                  height: 10,
                  decoration: BoxDecoration(
                    color: shimmer,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Timestamp bar.
          Container(
            width: 28,
            height: 10,
            decoration: BoxDecoration(
              color: shimmer,
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          const SizedBox(width: 8),
          // Phone-button placeholder.
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: shimmer,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}

class _NoFriendsEmpty extends StatelessWidget {
  const _NoFriendsEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: SC.bubbleIn,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.people_outline,
                color: SC.textMuted,
                size: 34,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              AppStrings.t('chat_no_friends_title'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SC.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppStrings.t('chat_no_friends_body'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: SC.textMuted,
                  fontSize: 13,
                  height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
