import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

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
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../theme/whatsapp_call_theme.dart';
import '../translation/realtime_translation_port.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/report_dialog.dart';
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
    _pollTimer?.cancel();
    super.dispose();
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
      final followers = await FriendshipApi.fetchAcceptedPeers(
        meId: id,
        direction: FriendDirection.followers,
      );
      final following = await FriendshipApi.fetchAcceptedPeers(
        meId: id,
        direction: FriendDirection.following,
      );
      final byId = <String, RemoteProfile>{};
      for (final p in followers) {
        byId[p.id] = p;
      }
      for (final p in following) {
        byId[p.id] = p;
      }

      // Fetch the latest message for each conversation involving me — used
      // to render the last-message preview and to sort rows by most-recent
      // activity (WhatsApp style).
      final latest = await ChatApi.fetchLatestPerConversation(id);
      final seen = await ChatUnread.readPerConversationSeen();
      // Drop any conversation where either side has blocked the other —
      // I blocked them (BlockApi.fetchMyBlockedProfiles) or they blocked
      // me (my_blockers RPC). Both directions should make the row
      // disappear from this chat list so the user can't keep messaging
      // into a void.
      final iBlocked = await BlockApi.fetchMyBlockedProfiles(id);
      final blockedByMe = iBlocked.map((p) => p.id).toSet();
      final blockedMe = await BlockApi.fetchMyBlockerIds();
      final hiddenPeers = {...blockedByMe, ...blockedMe};
      byId.removeWhere((k, _) => hiddenPeers.contains(k));

      String convIdFor(String otherId) {
        final ids = [id, otherId]..sort();
        return 'dm-${ids[0]}-${ids[1]}';
      }

      final friends = byId.values.toList()
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WhatsAppCallTheme.bar,
        title: Text(
          AppStrings.t('block_peer_q', args: {'name': peer.displayName}),
          style: const TextStyle(color: WhatsAppCallTheme.strongText),
        ),
        content: Text(
          AppStrings.t('block_peer_body'),
          style: const TextStyle(color: WhatsAppCallTheme.subtleText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppStrings.t('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE53935)),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppStrings.t('block')),
          ),
        ],
      ),
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
      // route — the same profile fields onboarding collects.
      final profile = await UserPrefs.loadProfile();
      final myName = profile?.firstName.trim() ?? '';
      final myLang = profile?.sourceLang.trim() ?? '';
      if (myName.isEmpty || myLang.isEmpty) {
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
      backgroundColor: WhatsAppCallTheme.scaffold,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  AppStrings.t('messages_title'),
                  style: const TextStyle(
                    color: WhatsAppCallTheme.strongText,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
            // The list fills the full height (scrolling behind the
            // floating nav bar). The "Invite to a call" row is the last
            // item of the list — see _buildBody.
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: WhatsAppCallTheme.accent),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _error!,
          style: const TextStyle(color: Color(0xFFFFAB91), height: 1.35, fontSize: 13),
        ),
      );
    }
    if (_friends.isEmpty) {
      return const _NoFriendsEmpty();
    }
    return RefreshIndicator(
      color: WhatsAppCallTheme.accent,
      backgroundColor: WhatsAppCallTheme.bar,
      onRefresh: _reload,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        // Clear the floating nav bar so the invite row (last item) can
        // always be scrolled fully into view.
        padding: EdgeInsets.only(
          bottom: 84 + MediaQuery.paddingOf(context).bottom,
        ),
        // +1 for the "Invite to a call" row, placed right after the last
        // conversation — same in-list position as the discussions.
        itemCount: _friends.length + 1,
        // Brighter separator so rows read distinctly against the dark
        // scaffold (the previous near-black 0xFF1F2C34 was invisible).
        separatorBuilder: (_, _) => const Divider(
          height: 1,
          thickness: 1,
          color: Color(0xFF2F3D45),
          indent: 68,
        ),
        itemBuilder: (ctx, i) {
          // Last item: "Invite to a call", in the list flow just below
          // the last discussion.
          if (i == _friends.length) {
            return _InviteToCallBar(
              onInviteToCall: _creatingInvite ? null : _shareCallInvite,
              creatingInvite: _creatingInvite,
            );
          }
          final p = _friends[i];
          final convId = _conversationIdFor(p.id);
          final last = _latestByConv[convId];
          final lastSeen = _seenByConv[convId];
          // "Unread" = the latest message was sent by the peer and is
          // newer than the last time the user opened this thread (or the
          // user has never opened the thread → all peer messages count).
          final isUnread = last != null &&
              last.senderId != _myId &&
              (lastSeen == null || last.createdAt.isAfter(lastSeen));
          return _FriendChatRow(
            profile: p,
            lastMessage: last,
            isMine: last?.senderId == _myId,
            unread: isUnread,
            onTap: () => _openThread(p),
            onViewProfile: () => _viewProfile(p),
            onBlock: () => _blockPeer(p),
            onReport: () => _reportPeer(p),
            onCall: () => CallLauncher.startCall(
              context,
              peerDeviceId: p.id,
              translation: widget.translation,
            ),
          );
        },
      ),
    );
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
    required this.onCall,
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
  /// Dials this friend — same call path as the chat thread header.
  final VoidCallback onCall;

  /// True when the peer was active in the last 2 minutes and has not
  /// hidden their online status.
  bool get _peerOnline {
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
            color: WhatsAppCallTheme.subtleText,
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

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
        child: Row(
          children: [
            // Avatar = direct shortcut to the peer's profile (Insta-style).
            // A green dot rides the bottom-right corner when the peer is
            // currently online.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onViewProfile,
              child: Stack(
                children: [
                  ProfileAvatar(
                    displayName: profile.displayName,
                    avatarUrl: profile.avatarUrl,
                    avatarColorHex: profile.avatarColor,
                    size: 60,
                  ),
                  if (_peerOnline)
                    Positioned(
                      right: 1,
                      bottom: 1,
                      child: Container(
                        width: 15,
                        height: 15,
                        decoration: BoxDecoration(
                          color: WhatsAppCallTheme.accent,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: WhatsAppCallTheme.scaffold,
                            width: 2.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Name on its own line — no more competing with the time
                  // for horizontal space. Bolder + brighter when unread.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onViewProfile,
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: TextStyle(
                        color: WhatsAppCallTheme.strongText,
                        fontWeight:
                            unread ? FontWeight.w800 : FontWeight.w600,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  RichText(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    text: TextSpan(
                      style: TextStyle(
                        color: unread
                            ? WhatsAppCallTheme.strongText
                            : WhatsAppCallTheme.subtleText,
                        fontSize: 14,
                        fontWeight:
                            unread ? FontWeight.w600 : FontWeight.normal,
                      ),
                      children: subtitleParts,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Trailing column: time at top with its own space, phone +
            // 3-dot menu below. Stops the time from being squeezed
            // between the name ellipsis and the icons.
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (lastMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // The unread dot lives next to the time — never in
                        // the buttons row — so the call + overflow icons
                        // stay pinned at a fixed right-hand position
                        // whether the row is read or unread.
                        if (unread) ...[
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(right: 5),
                            decoration: const BoxDecoration(
                              color: WhatsAppCallTheme.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                        Text(
                          _formatTime(lastMessage!.createdAt),
                          style: TextStyle(
                            color: unread
                                ? WhatsAppCallTheme.accent
                                : WhatsAppCallTheme.subtleText,
                            fontSize: 12,
                            fontWeight: unread
                                ? FontWeight.w700
                                : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Call button — sits just before the overflow menu.
                    // A tap dials the friend directly (LiveKit call +
                    // ring) via the shared CallLauncher.
                    IconButton(
                      onPressed: onCall,
                      tooltip: AppStrings.t('tooltip_call'),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                          width: 34, height: 34),
                      icon: const Icon(Icons.phone,
                          color: Colors.white, size: 20),
                    ),
                    PopupMenuButton<String>(
                      tooltip: AppStrings.t('tooltip_more'),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.more_vert,
                          color: WhatsAppCallTheme.subtleText, size: 20),
                      color: WhatsAppCallTheme.bar,
                      onSelected: (v) {
                        if (v == 'profile') onViewProfile();
                        if (v == 'report') onReport();
                        if (v == 'block') onBlock();
                      },
                      itemBuilder: (ctx) => [
                        PopupMenuItem<String>(
                          value: 'profile',
                          child: Row(
                            children: [
                              const Icon(Icons.person_outline,
                                  size: 18,
                                  color: WhatsAppCallTheme.strongText),
                              const SizedBox(width: 10),
                              Text(AppStrings.t('view_profile'),
                                  style: const TextStyle(
                                      color: WhatsAppCallTheme.strongText)),
                            ],
                          ),
                        ),
                        PopupMenuItem<String>(
                          value: 'report',
                          child: Row(
                            children: [
                              const Icon(Icons.flag_outlined,
                                  size: 18, color: Color(0xFFE53935)),
                              const SizedBox(width: 10),
                              Text(AppStrings.t('report'),
                                  style: const TextStyle(
                                      color: Color(0xFFE53935))),
                            ],
                          ),
                        ),
                        PopupMenuItem<String>(
                          value: 'block',
                          child: Row(
                            children: [
                              const Icon(Icons.block,
                                  size: 18, color: Color(0xFFE53935)),
                              const SizedBox(width: 10),
                              Text(AppStrings.t('block'),
                                  style: const TextStyle(
                                      color: Color(0xFFE53935))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
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
    return Material(
      color: WhatsAppCallTheme.accent,
      child: InkWell(
        onTap: onInviteToCall,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
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
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
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
                color: WhatsAppCallTheme.bar,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.people_outline,
                color: WhatsAppCallTheme.subtleText,
                size: 34,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              AppStrings.t('chat_no_friends_title'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: WhatsAppCallTheme.strongText,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppStrings.t('chat_no_friends_body'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: WhatsAppCallTheme.subtleText,
                  fontSize: 13,
                  height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
