import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/app_settings.dart';
import '../services/app_strings.dart';
import '../services/block_api.dart';
import '../services/call_launcher.dart';
import '../services/chat_api.dart';
import '../services/chat_unread.dart';
import '../services/device_id.dart';
import '../services/friendship_api.dart';
import '../services/guest_invite_api.dart';
import '../services/languages.dart';
import '../services/profile_api.dart';
import '../services/supabase_service.dart';
import '../services/token_api.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../translation/realtime_translation_port.dart';
import '../widgets/glass.dart';
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
  Map<String, ChatMessage> _latestByConv = const {};
  Map<String, DateTime> _seenByConv = const {};
  bool _loading = true;
  String? _error;
  Timer? _pollTimer;
  /// UI lock while a guest-invite link is being minted (prevents double-tap).
  bool _creatingInvite = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Rebuild when the local "hide my online status" toggle flips
    // so the green dots on every row vanish (or come back)
    // immediately, without waiting for the 7 s poll.
    AppSettings.hideOnlineLocal.addListener(_onHideOnlineChanged);
    _reload();
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
    _pollTimer?.cancel();
    super.dispose();
  }

  void _onHideOnlineChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reload();
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
          _loading = false;
        });
        return;
      }
      // Fire every independent request in parallel — previously each
      // await sat in front of the next, so the list staggered in over
      // 6-7× the latency of one request. Future.wait collapses them
      // into a single round-trip from the user's point of view.
      final results = await Future.wait([
        FriendshipApi.fetchAcceptedPeers(
          meId: id,
          direction: FriendDirection.followers,
        ),
        FriendshipApi.fetchAcceptedPeers(
          meId: id,
          direction: FriendDirection.following,
        ),
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
      ]);
      final followers = results[0] as List<RemoteProfile>;
      final following = results[1] as List<RemoteProfile>;
      final latest = results[2] as Map<String, ChatMessage>;
      final seen = results[3] as Map<String, DateTime>;
      final cleared = results[4] as Map<String, DateTime>;
      final iBlocked = results[5] as List<RemoteProfile>;
      final blockedMe = results[6] as Set<String>;

      final byId = <String, RemoteProfile>{};
      for (final p in followers) {
        byId[p.id] = p;
      }
      for (final p in following) {
        byId[p.id] = p;
      }
      // Keep conversations alive after the friendship ends. Removing
      // (unfollowing) someone deletes the friendship edge but not the
      // messages, so any peer we have a thread with — even a now-stranger —
      // still earns a row here. Pull the profiles the friends lists missed.
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

      final friends = byId.values.where((p) {
        final clearedAt = cleared[convIdFor(p.id)];
        if (clearedAt == null) return true;
        // Re-surface the conversation once a newer message lands.
        final lm = latest[convIdFor(p.id)];
        return lm != null && lm.createdAt.isAfter(clearedAt);
      }).toList()
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
      if (!mounted) return;
      setState(() {
        _myId = id;
        _friends = friends;
        _latestByConv = latest;
        _seenByConv = seen;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Erreur de chargement : $e';
        _loading = false;
      });
    }
  }

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
      // Snackbar = compact confirmation, reuse the block label.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${peer.displayName} · ${AppStrings.t('block')}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppStrings.t('error_prefix', args: {'msg': '$e'})),
      ));
    }
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
      // Enter the waiting room — the call connects when the guest joins.
      final token = await fetchLiveKitToken(
        roomName: invite.roomName,
        identity: _newCallIdentity(),
        displayName: myName,
        sourceLang: myLang,
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
            mySourceLang: myLang,
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
      backgroundColor: const Color(0xFF0E0E0E),
      body: ColoredBox(
        color: const Color(0xFF0E0E0E),
        child: SafeArea(
          bottom: false,
          // No fixed top bar: the "Messages" title is the first item of the
          // scroll view (see _buildBody), so it scrolls away with the list
          // instead of being a fixed band the conversations tuck under.
          child: _buildBody(),
        ),
      ),
    );
  }

  /// The big "Messages" title — now a normal (scrolling) item, not a fixed
  /// header bar.
  Widget get _titleBar => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(AppStrings.t('messages_title'), style: SCText.h1),
        ),
      );

  Widget _buildBody() {
    if (_loading) {
      // Skeleton list while data lands — keeps the layout in place
      // instead of swapping a centred spinner for a populated list
      // (the old behaviour made rows pop in one by one as each
      // request resolved).
      return Column(
        children: [
          _titleBar,
          Expanded(
            child: _ChatListSkeleton(
              bottomInset: 84 + MediaQuery.paddingOf(context).bottom,
            ),
          ),
        ],
      );
    }
    if (_error != null) {
      return Column(
        children: [
          _titleBar,
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error!,
              style: const TextStyle(
                color: Color(0xFFFFAB91),
                height: 1.35,
                fontSize: 13,
              ),
            ),
          ),
        ],
      );
    }
    if (_friends.isEmpty) {
      return Column(
        children: [_titleBar, const Expanded(child: _NoFriendsEmpty())],
      );
    }
    return RefreshIndicator(
      color: SC.accent,
      backgroundColor: SC.bubbleIn,
      onRefresh: _reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        // Clear the floating nav bar so the invite row stays scrollable.
        padding: EdgeInsets.fromLTRB(
          16, 0, 16,
          84 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          _titleBar,
          // Conversation rows as a flat list (no boxed card) — just a thin
          // hairline divider between them (inset past the avatar).
          Column(
              children: [
                for (final (i, p) in _friends.indexed) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      // Inset past the avatar on the left and stopping before
                      // the time + call/menu cluster on the right, so it sits
                      // only under the text.
                      indent: 70,
                      endIndent: 150,
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  _FriendChatRow(
                    profile: p,
                    lastMessage: _latestByConv[_conversationIdFor(p.id)],
                    isMine: _latestByConv[_conversationIdFor(p.id)]
                            ?.senderId ==
                        _myId,
                    unread: _isUnread(p),
                    onTap: () => _openThread(p),
                    onViewProfile: () => _viewProfile(p),
                    onBlock: () => _blockPeer(p),
                    onReport: () => _reportPeer(p),
                    onDeleteConversation: () => _deleteConversation(p),
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
              ],
            ),
          const SizedBox(height: 18),
          _InviteToCallBar(
            onInviteToCall: _creatingInvite ? null : _shareCallInvite,
            creatingInvite: _creatingInvite,
          ),
        ],
      ),
    );
  }

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
}

class _FriendChatRow extends StatelessWidget {
  const _FriendChatRow({
    required this.profile,
    required this.lastMessage,
    required this.isMine,
    required this.unread,
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

  @override
  Widget build(BuildContext context) {
    final lang = findLanguageByCode(profile.language);
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
    } else if (lang != null) {
      subtitleParts.add(TextSpan(text: '${lang.flag}  ${lang.label}'));
    } else {
      subtitleParts.add(TextSpan(text: AppStrings.t('chat_tap_to_chat')));
    }

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
                    avatarColorHex: profile.avatarColor,
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
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: SCText.name.copyWith(
                      fontWeight:
                          unread ? FontWeight.w800 : FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  RichText(
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
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (unread) ...[
                      Container(
                        width: 7,
                        height: 7,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: const BoxDecoration(
                          color: SC.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
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
              ],
            ),
            const SizedBox(width: 8),
            // Quick audio-call shortcut, then the 3-dots popup (red-only:
            // report / block / delete) on the far right.
            _RowCallButton(onTap: onCall),
            const SizedBox(width: 6),
            _RowMoreMenu(
              onReport: onReport,
              onBlock: onBlock,
              onDeleteConversation: onDeleteConversation,
            ),
          ],
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
    return Material(
      color: SC.glassStrong,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.all(9),
          child: Icon(Icons.phone_rounded, color: SC.accent, size: 18),
        ),
      ),
    );
  }
}

/// Small round "more" (⋮) button at the far-right of every chat-list row.
/// Opens a compact dropdown popup with the destructive (red) actions only:
/// Report / Block / Delete conversation. Call lives on the phone shortcut.
class _RowMoreMenu extends StatelessWidget {
  const _RowMoreMenu({
    required this.onReport,
    required this.onBlock,
    required this.onDeleteConversation,
  });

  final VoidCallback onReport;
  final VoidCallback onBlock;
  final VoidCallback onDeleteConversation;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '',
      color: const Color(0xFF0E0E0E),
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.5),
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: SC.glassBorderStrong),
      ),
      onSelected: (v) {
        switch (v) {
          case 'report':
            onReport();
            break;
          case 'block':
            onBlock();
            break;
          case 'delete':
            onDeleteConversation();
            break;
        }
      },
      itemBuilder: (ctx) => [
        _redItem('report', Icons.flag_outlined, 'report'),
        _redItem('block', Icons.block, 'block'),
        _redItem('delete', Icons.delete_outline, 'delete_conversation'),
      ],
      child: Container(
        padding: const EdgeInsets.all(9),
        decoration: const BoxDecoration(
          color: SC.glassStrong,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.more_vert, color: SC.textPrimary, size: 18),
      ),
    );
  }

  PopupMenuItem<String> _redItem(String value, IconData icon, String key) {
    const red = Color(0xFFE53935);
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, color: red, size: 20),
          const SizedBox(width: 14),
          Text(
            AppStrings.t(key),
            style: SCText.body.copyWith(color: red, fontSize: 15),
          ),
        ],
      ),
    );
  }
}

/// "Invite to a call" row on the Messages page: a full-width green strip,
/// the height of a conversation row, that mints a guest invite link (join
/// a call with no account) and opens the native OS share sheet. Rendered
/// as the last item of the conversation list, just below the discussions.
class _InviteToCallBar extends StatelessWidget {
  const _InviteToCallBar({
    required this.onInviteToCall,
    required this.creatingInvite,
  });

  /// Null while a link is being minted — disables the button.
  final VoidCallback? onInviteToCall;
  final bool creatingInvite;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GlassContainer(
        borderRadius: BorderRadius.circular(22),
        color: SC.glassStrong,
        border: SC.glassBorderStrong,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onInviteToCall,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (creatingInvite)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  else
                    const Icon(Icons.videocam_rounded,
                        color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    creatingInvite
                        ? AppStrings.t('invite_call_creating')
                        : AppStrings.t('invite_to_call'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
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
class _ChatListSkeleton extends StatefulWidget {
  const _ChatListSkeleton({required this.bottomInset});

  final double bottomInset;

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
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16, 0, 16, widget.bottomInset),
      children: [
        GlassContainer(
          borderRadius: BorderRadius.circular(24),
          padding: const EdgeInsets.all(6),
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, _) {
              final t = Curves.easeInOut.transform(_ctrl.value);
              // 0.10 → 0.18 alpha so the shimmer breathes gently
              // without strobing the screen.
              final shimmer =
                  Colors.white.withValues(alpha: 0.10 + 0.08 * t);
              return Column(
                children: [
                  for (var i = 0; i < 5; i++)
                    _SkeletonRow(shimmer: shimmer),
                ],
              );
            },
          ),
        ),
      ],
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
