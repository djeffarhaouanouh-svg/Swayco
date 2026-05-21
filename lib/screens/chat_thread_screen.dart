import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/block_api.dart';
import '../services/call_launcher.dart';
import '../services/chat_api.dart';
import '../services/chat_unread.dart';
import '../services/device_id.dart';
import '../services/profile_api.dart';
import '../services/supabase_service.dart';
import '../services/translation_api.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../theme/whatsapp_call_theme.dart';
import '../translation/realtime_translation_port.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/report_dialog.dart';
import 'profile_screen.dart';

/// One-to-one chat thread for [conversationId]. Title is the human-friendly
/// name shown in the header. The header phone icon dials the peer directly
/// via CallLauncher.
class ChatThreadScreen extends StatefulWidget {
  const ChatThreadScreen({
    super.key,
    required this.conversationId,
    required this.title,
    required this.peerDeviceId,
    this.translation = const NoOpRealtimeTranslation(),
  });

  final String conversationId;
  final String title;

  /// The other party's device id — sent with every message as `recipient`
  /// so the deployed messages schema (DM-style, NOT-NULL recipient column)
  /// accepts inserts. Also used as the peer for the call shortcut.
  final String peerDeviceId;

  final RealtimeTranslationPort translation;

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  StreamSubscription<List<ChatMessage>>? _sub;
  Timer? _pollTimer;
  List<ChatMessage> _messages = const [];
  String _myId = '';
  String _myName = '';
  String _myLang = '';
  RemoteProfile? _peer;
  bool _sending = false;
  String? _error;

  /// When true, replace each foreign-language message body with its
  /// translation into [_myLang]. Translations are cached by message id so we
  /// only hit OpenAI once per message.
  bool _autoTranslate = false;
  final Map<String, String> _translations = {};
  final Set<String> _translatingIds = {};

  /// Cached "have I blocked this peer" flag — refreshed on bootstrap and
  /// after every block / unblock toggle. Drives the menu label.
  bool _peerBlocked = false;

  Future<void> _reportPeer() async {
    if (_myId.isEmpty || widget.peerDeviceId.isEmpty) return;
    final peerName = _peer?.displayName.isNotEmpty == true
        ? _peer!.displayName
        : widget.title;
    await showReportDialog(
      context,
      reporterId: _myId,
      reportedId: widget.peerDeviceId,
      peerName: peerName,
    );
  }

  Future<void> _toggleBlockPeer() async {
    if (_myId.isEmpty || widget.peerDeviceId.isEmpty) return;
    final wasBlocked = _peerBlocked;
    final peerName = _peer?.displayName.isNotEmpty == true
        ? _peer!.displayName
        : widget.title;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WhatsAppCallTheme.bar,
        title: Text(
          AppStrings.t(
            wasBlocked ? 'unblock_peer_q' : 'block_peer_q',
            args: {'name': peerName},
          ),
          style: const TextStyle(color: WhatsAppCallTheme.strongText),
        ),
        content: Text(
          AppStrings.t(
              wasBlocked ? 'unblock_peer_body' : 'block_peer_body'),
          style: const TextStyle(color: WhatsAppCallTheme.subtleText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppStrings.t('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: wasBlocked
                  ? WhatsAppCallTheme.accent
                  : const Color(0xFFE53935),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppStrings.t(wasBlocked ? 'unblock' : 'block')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (wasBlocked) {
        await BlockApi.unblock(
            blockerId: _myId, blockedId: widget.peerDeviceId);
      } else {
        await BlockApi.block(
            blockerId: _myId, blockedId: widget.peerDeviceId);
      }
      if (!mounted) return;
      setState(() => _peerBlocked = !wasBlocked);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// Toggle the auto-translate state. On turn-on, kick translation for all
  /// visible foreign-language messages.
  void _toggleAutoTranslate() {
    setState(() => _autoTranslate = !_autoTranslate);
    if (_autoTranslate) _ensureTranslationsForCurrent();
  }

  /// For every message in [_messages] whose language differs from mine and
  /// is not yet cached or in flight, fetch the translation and rebuild.
  void _ensureTranslationsForCurrent() {
    if (_myLang.isEmpty) return;
    for (final m in _messages) {
      _maybeFetchTranslation(m);
    }
  }

  void _maybeFetchTranslation(ChatMessage m) {
    if (!_autoTranslate || _myLang.isEmpty) return;
    final id = m.id;
    if (id.isEmpty) return;
    final lang = _messageLang(m);
    if (lang == _myLang) return; // already in my language
    if (_translations.containsKey(id) || _translatingIds.contains(id)) return;
    _translatingIds.add(id);
    () async {
      try {
        final out = await fetchTextTranslation(
          text: m.body,
          to: _myLang,
          from: lang.isEmpty ? null : lang,
        );
        if (!mounted) return;
        setState(() {
          _translations[id] = out;
          _translatingIds.remove(id);
        });
      } catch (_) {
        if (mounted) {
          setState(() => _translatingIds.remove(id));
        }
      }
    }();
  }

  /// Best-effort message language: prefer the explicit column we send when
  /// inserting; fall back to the sender's profile language ("their lang")
  /// if needed. Empty if unknown.
  String _messageLang(ChatMessage m) {
    // ChatMessage doesn't expose the language column today; use the peer's
    // language when the sender is the peer, else my language.
    if (m.senderId == _myId) return _myLang;
    return _peer?.language.trim() ?? '';
  }

  String _displayBodyFor(ChatMessage m) {
    if (!_autoTranslate) return m.body;
    final translated = _translations[m.id];
    if (translated != null && translated.isNotEmpty) return translated;
    return m.body;
  }

  Future<void> _bootstrap() async {
    final id = await DeviceId.getOrCreate();
    final profile = await UserPrefs.loadProfile();
    final peer = isSupabaseReady
        ? await ProfileApi.fetchById(widget.peerDeviceId)
        : null;
    final blocked = isSupabaseReady && id.isNotEmpty
        ? await BlockApi.isBlocked(
            blockerId: id, otherId: widget.peerDeviceId,
          )
        : false;
    // Opening this thread = peer's messages here are now "seen". Clears
    // the per-row dot on the chat list for this conversation.
    unawaited(ChatUnread.markConversationSeen(widget.conversationId));
    if (!mounted) return;
    setState(() {
      _myId = id;
      _myName = profile?.firstName.trim() ?? '';
      _myLang = profile?.sourceLang.trim() ?? '';
      _peer = peer;
      _peerBlocked = blocked;
    });

    if (!isSupabaseReady) {
      setState(() => _error = 'Supabase non configuré — les messages ne sont pas disponibles.');
      return;
    }
    _sub = ChatApi.subscribeMessages(widget.conversationId).listen(
      (rows) {
        if (!mounted) return;
        setState(() => _messages = rows);
        // If auto-translate is on, kick translations for the new arrivals.
        if (_autoTranslate) {
          for (final m in rows) {
            _maybeFetchTranslation(m);
          }
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      },
      onError: (e) {
        if (!mounted) return;
        setState(() => _error = 'Connexion temps réel perdue: $e');
      },
    );

    // Web build: even with the realtime subscription above, websockets
    // sometimes drop. Poll the last 200 messages every 5s as a safety
    // net so new arrivals always surface quickly.
    _pollTimer = WebPoll.every(const Duration(seconds: 5), () async {
      try {
        final rows = await ChatApi.fetchMessages(widget.conversationId);
        if (!mounted) return;
        // Only repaint when there's actually a new tail message — keeps
        // the chat from rebuilding constantly while the user is typing.
        final last = _messages.isEmpty ? null : _messages.last.id;
        final freshLast = rows.isEmpty ? null : rows.last.id;
        if (last == freshLast && rows.length == _messages.length) return;
        setState(() => _messages = rows);
        if (_autoTranslate) {
          for (final m in rows) {
            _maybeFetchTranslation(m);
          }
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      } catch (_) {
        // Swallow — the realtime sub is the primary path; polling errors
        // shouldn't surface to the user.
      }
    });
  }

  void _scrollToBottom() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      _scrollCtrl.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pollTimer?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _inputCtrl.text.trim();
    if (body.isEmpty || _sending) return;
    if (_myId.isEmpty) return;
    if (!isSupabaseReady) {
      setState(() => _error = 'Supabase non configuré.');
      return;
    }
    setState(() => _sending = true);
    try {
      await ChatApi.sendMessage(
        conversationId: widget.conversationId,
        senderId: _myId,
        senderName: _myName.isEmpty ? 'Moi' : _myName,
        recipientId: widget.peerDeviceId,
        body: body,
        language: _myLang,
      );
      _inputCtrl.clear();
    } catch (e) {
      setState(() => _error = 'Envoi échoué: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WhatsAppCallTheme.scaffold,
      appBar: _ThreadHeader(
        title: widget.title,
        peer: _peer,
        onCall: () => CallLauncher.startCall(
          context,
          peerDeviceId: widget.peerDeviceId,
          translation: widget.translation,
        ),
        onViewProfile: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ProfileScreen(userId: widget.peerDeviceId),
          ),
        ),
        peerBlocked: _peerBlocked,
        onToggleBlock: _toggleBlockPeer,
        onReport: _reportPeer,
      ),
      body: Column(
        children: [
          if (_error != null) _ErrorBanner(message: _error!),
          Expanded(child: _buildMessageList()),
          _Composer(
            controller: _inputCtrl,
            sending: _sending,
            onSend: _send,
            autoTranslate: _autoTranslate,
            onToggleTranslate: _toggleAutoTranslate,
          ),
        ],
      ),
    );
  }

  /// Long-press one of my own messages → confirm, then delete it (an
  /// "unsend" — the row is removed for both sides). Removed optimistically;
  /// the realtime stream confirms it.
  Future<void> _deleteMessage(ChatMessage m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WhatsAppCallTheme.bar,
        title: Text(
          AppStrings.t('delete_message'),
          style: const TextStyle(color: WhatsAppCallTheme.strongText),
        ),
        content: Text(
          AppStrings.t('delete_message_body'),
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
            child: Text(AppStrings.t('delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ChatApi.deleteMessage(m.id);
      if (!mounted) return;
      setState(() {
        _messages = _messages.where((x) => x.id != m.id).toList();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget _buildMessageList() {
    if (_messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            AppStrings.t('no_messages'),
            style: const TextStyle(
              color: WhatsAppCallTheme.subtleText,
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    // Top-anchored layout: first (oldest) message at the top, list grows
    // downward, empty space at the bottom when the conversation is short.
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: _messages.length,
      itemBuilder: (ctx, i) {
        final m = _messages[i];
        final mine = m.senderId == _myId;
        return _MessageBubble(
          message: m,
          mine: mine,
          displayBody: _displayBodyFor(m),
          translating: _translatingIds.contains(m.id),
          // Long-press to delete — only my own messages.
          onLongPressDelete: mine ? () => _deleteMessage(m) : null,
        );
      },
    );
  }
}

class _ThreadHeader extends StatelessWidget implements PreferredSizeWidget {
  const _ThreadHeader({
    required this.title,
    required this.peer,
    required this.onCall,
    required this.onViewProfile,
    required this.peerBlocked,
    required this.onToggleBlock,
    required this.onReport,
  });
  final String title;
  final RemoteProfile? peer;
  final VoidCallback onCall;
  final VoidCallback onViewProfile;
  final bool peerBlocked;
  final VoidCallback onToggleBlock;
  final VoidCallback onReport;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      titleSpacing: 0,
      title: InkWell(
        onTap: onViewProfile,
        child: Row(
          children: [
            ProfileAvatar(
              displayName: title,
              avatarUrl: peer?.avatarUrl,
              avatarColorHex: peer?.avatarColor,
              size: 36,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          tooltip: AppStrings.t('tooltip_call'),
          onPressed: onCall,
          icon: const Icon(Icons.phone),
        ),
        PopupMenuButton<String>(
          tooltip: AppStrings.t('tooltip_more'),
          icon: const Icon(Icons.more_vert),
          color: WhatsAppCallTheme.bar,
          onSelected: (value) {
            if (value == 'report') onReport();
            if (value == 'block') onToggleBlock();
          },
          itemBuilder: (ctx) => [
            PopupMenuItem<String>(
              value: 'report',
              child: Row(
                children: [
                  const Icon(Icons.flag_outlined,
                      size: 18, color: Color(0xFFE53935)),
                  const SizedBox(width: 10),
                  Text(
                    AppStrings.t('report'),
                    style: const TextStyle(color: Color(0xFFE53935)),
                  ),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'block',
              child: Row(
                children: [
                  Icon(
                    peerBlocked ? Icons.lock_open : Icons.block,
                    size: 18,
                    color: peerBlocked
                        ? WhatsAppCallTheme.accent
                        : const Color(0xFFE53935),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    AppStrings.t(peerBlocked ? 'unblock' : 'block'),
                    style: TextStyle(
                      color: peerBlocked
                          ? WhatsAppCallTheme.accent
                          : const Color(0xFFE53935),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.mine,
    required this.displayBody,
    required this.translating,
    this.onLongPressDelete,
  });
  final ChatMessage message;
  final bool mine;
  /// Long-press handler — non-null only for the user's own messages.
  final VoidCallback? onLongPressDelete;
  /// Body text actually rendered — may be the translated version when the
  /// thread-level auto-translate toggle is on.
  final String displayBody;
  /// Show a subtle indicator while the translation is being fetched.
  final bool translating;

  @override
  Widget build(BuildContext context) {
    final bg = mine ? WhatsAppCallTheme.accentMuted : WhatsAppCallTheme.bubbleIncoming;
    final align = mine ? Alignment.centerRight : Alignment.centerLeft;
    final radius = mine
        ? const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(4),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(14),
          );

    final time =
        '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')}';

    return Align(
      alignment: align,
      child: GestureDetector(
        // Long-press one of my own bubbles → offer to delete it.
        onLongPress: onLongPressDelete,
        child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(color: bg, borderRadius: radius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mine && message.senderName.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  message.senderName,
                  style: const TextStyle(
                    color: WhatsAppCallTheme.accent,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
            Text(
              displayBody,
              style: TextStyle(
                color: translating
                    ? WhatsAppCallTheme.strongText.withValues(alpha: 0.55)
                    : WhatsAppCallTheme.strongText,
                fontSize: 15,
                height: 1.3,
                fontStyle: translating ? FontStyle.italic : FontStyle.normal,
              ),
            ),
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.bottomRight,
              child: Text(
                time,
                style: TextStyle(
                  color: WhatsAppCallTheme.strongText.withValues(alpha: 0.55),
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.autoTranslate,
    required this.onToggleTranslate,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final bool autoTranslate;
  final VoidCallback onToggleTranslate;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        color: WhatsAppCallTheme.bar,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 140),
                child: TextField(
                  controller: controller,
                  enabled: !sending,
                  minLines: 1,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  style: const TextStyle(color: WhatsAppCallTheme.strongText),
                  decoration: InputDecoration(
                    hintText: AppStrings.t('composer_message_hint'),
                    hintStyle: const TextStyle(color: WhatsAppCallTheme.subtleText),
                    filled: true,
                    fillColor: WhatsAppCallTheme.surface,
                    contentPadding: const EdgeInsets.fromLTRB(2, 10, 14, 10),
                    // Translate switch lives inline at the left of the field
                    // — icon + sliding pill, tap-to-toggle. Pushes the
                    // "Message" hint to the right.
                    prefixIcon: _ComposerTranslateToggle(
                      active: autoTranslate,
                      onTap: onToggleTranslate,
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 96, minHeight: 40,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => onSend(),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Material(
              color: WhatsAppCallTheme.accent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: sending ? null : onSend,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: sending
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send, color: Colors.white, size: 22),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline translate switch shown as a TextField prefix in the chat composer.
/// Icon + sliding pill ball — tap anywhere on it flips _autoTranslate.
class _ComposerTranslateToggle extends StatelessWidget {
  const _ComposerTranslateToggle({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(left: 10, right: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.translate,
              size: 24,
              color: active
                  ? WhatsAppCallTheme.accent
                  : WhatsAppCallTheme.subtleText,
            ),
            const SizedBox(width: 8),
            // Sliding pill — bigger so it reads as a real toggle.
            Container(
              width: 42, height: 22,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: active
                    ? WhatsAppCallTheme.accent.withValues(alpha: 0.45)
                    : const Color(0xFF2A3942),
                borderRadius: BorderRadius.circular(999),
                border:
                    Border.all(color: Colors.white.withValues(alpha: 0.10)),
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                alignment:
                    active ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 16, height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active
                        ? WhatsAppCallTheme.accent
                        : Colors.white.withValues(alpha: 0.40),
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: WhatsAppCallTheme.accent
                                  .withValues(alpha: 0.55),
                              blurRadius: 8,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      color: WhatsAppCallTheme.danger.withValues(alpha: 0.18),
      child: Text(
        message,
        style: const TextStyle(color: Color(0xFFFFAB91), fontSize: 12, height: 1.35),
      ),
    );
  }
}
