import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/analytics.dart';
import '../services/app_settings.dart';
import '../services/app_strings.dart';
import '../services/block_api.dart';
import '../services/call_launcher.dart';
import '../services/chat_api.dart';
import '../services/chat_unread.dart';
import '../services/device_id.dart';
import '../services/languages.dart';
import '../services/peer_local_time.dart';
import '../services/profile_api.dart';
import '../services/supabase_service.dart';
import '../services/translation_api.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../swayco/realtime_translation_port.dart';
import '../widgets/gif_picker_sheet.dart';
import '../widgets/glass.dart';
import '../widgets/glass_panel.dart';
import '../widgets/pressable.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/report_dialog.dart';
import '../widgets/swayco_dialog.dart';
import '../widgets/swayco_logo.dart';
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

class _ChatThreadScreenState extends State<ChatThreadScreen>
    with SingleTickerProviderStateMixin {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  /// Plays a one-shot white shimmer sweep across the whole chat whenever the
  /// translate toggle is flipped from off → on. Idle the rest of the time so
  /// the overlay paints nothing.
  late final AnimationController _activationWave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 750),
  );

  StreamSubscription<List<ChatMessage>>? _sub;
  Timer? _pollTimer;

  /// La présence du pair n'a pas de canal Realtime : sans ce battement, la
  /// pastille verte de l'en-tête reste celle de l'ouverture du fil.
  Timer? _presenceTimer;

  /// Ticks every minute so the peer's local-time bubble stays current
  /// without the user reopening the thread.
  Timer? _clockTimer;
  List<ChatMessage> _messages = const [];
  String _myId = '';
  String _myName = '';
  String _myLang = '';
  String _myGender = '';

  RemoteProfile? _peer;
  bool _sending = false;
  String? _error;

  /// When true, replace each foreign-language message body with its
  /// translation into [_myLang]. Translations are cached by message id so we
  /// only hit the live engine once per message.
  // Auto-translate is ON by default for every conversation — foreign messages
  // get translated into the reader's language without them flipping a switch.
  bool _autoTranslate = true;
  final Map<String, String> _translations = {};
  final Set<String> _translatingIds = {};

  /// Cached "have I blocked this peer" flag — refreshed on bootstrap and
  /// after every block / unblock toggle. Drives the menu label.
  bool _peerBlocked = false;

  /// Cached "has this peer blocked ME" flag. When true the composer and the
  /// call button are disabled — messages / calls would go into a black hole.
  bool _peerBlockedMe = false;

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

  /// Efface la conversation de MA liste et me ramène en arrière — le même
  /// geste que l'appui long sur la ligne dans les messages, offert ici parce
  /// que c'est de cet écran qu'on ne peut plus rien faire d'autre.
  Future<void> _deleteConversation() async {
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('delete_conversation'),
      body: AppStrings.t('delete_conversation_body'),
      confirmLabel: AppStrings.t('delete'),
      destructive: true,
    );
    if (ok != true) return;
    await ChatUnread.markConversationCleared(widget.conversationId);
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  Future<void> _toggleBlockPeer() async {
    if (_myId.isEmpty || widget.peerDeviceId.isEmpty) return;
    final wasBlocked = _peerBlocked;
    final peerName = _peer?.displayName.isNotEmpty == true
        ? _peer!.displayName
        : widget.title;
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t(
        wasBlocked ? 'unblock_peer_q' : 'block_peer_q',
        args: {'name': peerName},
      ),
      body: AppStrings.t(wasBlocked ? 'unblock_peer_body' : 'block_peer_body'),
      confirmLabel: AppStrings.t(wasBlocked ? 'unblock' : 'block'),
      destructive: !wasBlocked,
    );
    if (ok != true) return;
    try {
      if (wasBlocked) {
        await BlockApi.unblock(
          blockerId: _myId,
          blockedId: widget.peerDeviceId,
        );
      } else {
        await BlockApi.block(blockerId: _myId, blockedId: widget.peerDeviceId);
      }
      if (!mounted) return;
      setState(() => _peerBlocked = !wasBlocked);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  /// Local time at the peer's place, derived from the free-text city they
  /// filled into their profile (country as a fallback). Null when no city is
  /// set or the place isn't in our timezone table — the header line then hides.
  PeerLocalTime? get _peerClock {
    final p = _peer;
    if (p == null || p.city.trim().isEmpty) return null;
    return resolvePeerLocalTime(city: p.city, country: p.country);
  }

  /// Toggle the auto-translate state. On turn-on, kick translation for all
  /// visible foreign-language messages.
  void _toggleAutoTranslate() {
    setState(() => _autoTranslate = !_autoTranslate);
    if (_autoTranslate) {
      _activationWave.forward(from: 0);
      _ensureTranslationsForCurrent();
    }
  }

  /// For every message in [_messages] whose language differs from mine and
  /// is not yet cached or in flight, fetch the translation and rebuild.
  void _ensureTranslationsForCurrent() {
    if (_myLang.isEmpty) return;
    for (final m in _messages) {
      _maybeFetchTranslation(m);
    }
  }

  /// Build the conversation history that gets shipped alongside the
  /// message being translated. Limited to the 10 messages immediately
  /// *before* the one we're translating so the model can resolve
  /// pronouns / references / in-conversation glossary without seeing
  /// the answer it's about to produce.
  List<TranslationHistoryItem> _historyBefore(String messageId) {
    final idx = _messages.indexWhere((x) => x.id == messageId);
    if (idx <= 0) return const [];
    final start = idx - 10 < 0 ? 0 : idx - 10;
    final slice = _messages.sublist(start, idx);
    return [
      for (final h in slice)
        TranslationHistoryItem(
          author: h.senderId == _myId ? 'peer' : 'me',
          text: h.body,
        ),
    ];
    // Note on the author labels: from the *backend's* point of view the
    // "sender" is whoever wrote the message being translated (the peer,
    // since we only translate foreign messages) and the "reader" is the
    // local user. So a history message from `_myId` is from the reader's
    // perspective — labelled "me" — and a peer message is "peer".
  }

  TranslationContext _buildContext() {
    // From the translator's point of view the *sender* is the peer (we
    // only translate foreign messages) and the *reader* is the local
    // user. So author* fields = peer profile, peer* fields = me.
    final peerGender = (_peer?.gender ?? '').isEmpty ? null : _peer!.gender;
    return TranslationContext(
      authorName: _peer?.displayName,
      authorGender: peerGender,
      authorLang: (_peer?.language ?? '').isEmpty ? null : _peer!.language,
      peerName: _myName.isEmpty ? null : _myName,
      peerGender: _myGender.isEmpty ? null : _myGender,
      peerLang: _myLang.isEmpty ? null : _myLang,
    );
  }

  void _maybeFetchTranslation(ChatMessage m) {
    if (!_autoTranslate || _myLang.isEmpty) return;
    final id = m.id;
    if (id.isEmpty) return;
    final lang = _messageLang(m);
    if (lang == _myLang) return; // already in my language
    if (_translations.containsKey(id) || _translatingIds.contains(id)) return;
    _translatingIds.add(id);
    final history = _historyBefore(id);
    final ctx = _buildContext();
    () async {
      try {
        final out = await fetchTextTranslation(
          text: m.body,
          to: _myLang,
          from: lang.isEmpty ? null : lang,
          history: history,
          context: ctx,
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

  /// Best-effort message language: prefer the explicit `language` column
  /// (set by ChatApi.sendMessage and by the voice-message STT pipeline),
  /// then fall back to the sender's profile language.
  String _messageLang(ChatMessage m) {
    if (m.language.isNotEmpty) return m.language;
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
    // Load my own remote profile so we can read my subscription_tier
    // — UserPrefs only carries the locally-typed name + language and
    // intentionally doesn't track billing state. Failure is fine: we
    // just leave the tier at 'free' and the bubble hides the CTA.
    RemoteProfile? mine;
    if (isSupabaseReady && id.isNotEmpty) {
      try {
        mine = await ProfileApi.fetchById(id);
      } catch (_) {}
    }
    final blocked = isSupabaseReady && id.isNotEmpty
        ? await BlockApi.isBlocked(blockerId: id, otherId: widget.peerDeviceId)
        : false;
    // Has the peer blocked ME? Disables the composer + call button below.
    var blockedMe = false;
    if (isSupabaseReady && id.isNotEmpty) {
      try {
        blockedMe = (await BlockApi.fetchMyBlockerIds()).contains(
          widget.peerDeviceId,
        );
      } catch (_) {}
    }
    // Opening this thread = peer's messages here are now "seen". Clears
    // the per-row dot on the chat list for this conversation.
    unawaited(ChatUnread.markConversationSeen(widget.conversationId));
    if (!mounted) return;
    setState(() {
      _myId = id;
      _myName = profile?.firstName.trim() ?? '';
      // Prefer the locally-stored spoken language, but fall back to the
      // Supabase profile when local prefs are empty — otherwise a
      // returning user on a freshly-installed app has an empty _myLang,
      // which makes _maybeFetchTranslation bail out and the translate
      // toggle silently does nothing (works on web only because the
      // browser session still holds the onboarding prefs).
      _myLang = (profile?.sourceLang.trim().isNotEmpty ?? false)
          ? profile!.sourceLang.trim()
          : (mine?.language.trim() ?? '');
      _myGender = (profile?.gender.trim().isNotEmpty ?? false)
          ? profile!.gender.trim()
          : (mine?.gender.trim() ?? '');
      _peer = peer;
      _peerBlocked = blocked;
      _peerBlockedMe = blockedMe;
    });

    if (!isSupabaseReady) {
      setState(
        () => _error =
            'Supabase non configuré — les messages ne sont pas disponibles.',
      );
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

    // La présence du pair, rafraîchie sur toutes les plateformes (sur le web
    // aussi : le poll ci-dessous ne relit que les messages).
    _presenceTimer = AppPoll.every(const Duration(seconds: 30), () async {
      if (!mounted || !isSupabaseReady || widget.peerDeviceId.isEmpty) return;
      try {
        final fresh = await ProfileApi.fetchById(widget.peerDeviceId);
        if (!mounted || fresh == null) return;
        setState(() => _peer = fresh);
      } catch (_) {
        // Confort d'affichage : un échec réseau ne casse rien.
      }
    });

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
    _presenceTimer?.cancel();
    _clockTimer?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _activationWave.dispose();
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
        recipientLang: _peer?.language ?? '',
      );
      Analytics.track(
        'message_sent',
        props: {'source': 'chat', 'type': 'text'},
      );
      _inputCtrl.clear();
    } catch (e) {
      setState(() => _error = 'Envoi échoué: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Pick an image from the gallery and send it as an image message.
  Future<void> _sendImage() async {
    if (_myId.isEmpty || _sending) return;
    if (!isSupabaseReady) {
      setState(() => _error = 'Supabase non configuré.');
      return;
    }
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 85,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final isPng = file.name.toLowerCase().endsWith('.png');
    setState(() => _sending = true);
    try {
      await ChatApi.sendImage(
        conversationId: widget.conversationId,
        senderId: _myId,
        senderName: _myName.isEmpty ? 'Moi' : _myName,
        recipientId: widget.peerDeviceId,
        bytes: bytes,
        contentType: isPng ? 'image/png' : 'image/jpeg',
        recipientLang: _peer?.language ?? '',
      );
      Analytics.track(
        'message_sent',
        props: {'source': 'chat', 'type': 'image'},
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Envoi image échoué: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Lance l'appel. [withCamera] distingue les deux boutons de l'en-tête :
  /// le téléphone appelle caméra coupée, la caméra ouvre le mode visio.
  void _startCall({required bool withCamera}) {
    if (_peerBlockedMe) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('chat_blocked_by_peer'))),
      );
      return;
    }
    CallLauncher.startCall(
      context,
      peerDeviceId: widget.peerDeviceId,
      translation: widget.translation,
      startWithCamera: withCamera,
    );
  }

  /// Choisit un GIF dans le catalogue Giphy et l'envoie. Rien n'est uploadé :
  /// le message porte l'URL Giphy, comme une image distante.
  Future<void> _sendGif() async {
    if (_myId.isEmpty || _sending) return;
    if (!isSupabaseReady) {
      setState(() => _error = 'Supabase non configuré.');
      return;
    }
    final gif = await showGifPicker(context);
    if (gif == null || !mounted) return;
    setState(() => _sending = true);
    try {
      await ChatApi.sendGif(
        conversationId: widget.conversationId,
        senderId: _myId,
        senderName: _myName.isEmpty ? 'Moi' : _myName,
        recipientId: widget.peerDeviceId,
        gifUrl: gif.sendUrl,
        recipientLang: _peer?.language ?? '',
      );
      Analytics.track(
        'message_sent',
        props: {'source': 'chat', 'type': 'gif'},
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Envoi GIF échoué: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final peerClock = _peerClock;
    return Scaffold(
      backgroundColor: SC.bg,
      body: GestureDetector(
        // Swipe right anywhere to leave the conversation (back).
        onHorizontalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) Navigator.of(context).maybePop();
        },
        child: Stack(
          children: [
            ColoredBox(
              color: SC.bg,
              child: SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    _ThreadHeader(
                      title: widget.title,
                      peer: _peer,
                      clock: peerClock,
                      place: _peer?.city ?? '',
                      blockedByPeer: _peerBlockedMe,
                      onCall: () => _startCall(withCamera: false),
                      onVideoCall: () => _startCall(withCamera: true),
                      onViewProfile: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              ProfileScreen(userId: widget.peerDeviceId),
                        ),
                      ),
                      peerBlocked: _peerBlocked,
                      onToggleBlock: _toggleBlockPeer,
                      onReport: _reportPeer,
                    ),
                    if (_error != null) _ErrorBanner(message: _error!),
                    // Pure-black background ONLY behind the messages zone — the
                    // header and composer keep the lighter 0E0E0E surface.
                    // Tapping anywhere in the area dismisses the keyboard;
                    // translucent so the list still scrolls and taps register.
                    Expanded(
                      child: ColoredBox(
                        color: const Color(0xFF000000),
                        child: Stack(
                          children: [
                            GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onTap: () => FocusScope.of(context).unfocus(),
                              child: _buildMessageList(),
                            ),
                            // Top fade — messages dissolve into black under the
                            // header (floating, not empty).
                            const Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: IgnorePointer(
                                child: SizedBox(
                                  // Taller + lower-opacity peak so the top fades
                                  // gently (floating, not a hard black bar) —
                                  // same soft feel as the footer fade below.
                                  height: 88,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Color(0x99000000),
                                          Color(0x00000000),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // Bottom fade — messages dissolve into black under
                            // the floating composer.
                            const Positioned(
                              bottom: 0,
                              left: 0,
                              right: 0,
                              child: IgnorePointer(
                                child: SizedBox(
                                  height: 160,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Color(0x00000000),
                                          Color(0x99000000),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Floating glass composer OVER the messages — no dark footer behind
            // it, so the glass refracts the conversation.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _peerBlockedMe
                  ? _BlockedComposerNotice(
                      name: _peer?.displayName.isNotEmpty == true
                          ? _peer!.displayName
                          : widget.title,
                      onReport: _reportPeer,
                      onDelete: _deleteConversation,
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Composer(
                          controller: _inputCtrl,
                          sending: _sending,
                          onSend: _send,
                          onSendImage: _sendImage,
                          onSendGif: _sendGif,
                          autoTranslate: _autoTranslate,
                          onToggleTranslate: _toggleAutoTranslate,
                          myLang: _myLang,
                        ),
                      ],
                    ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: _ActivationWaveOverlay(animation: _activationWave),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Long-press one of my own messages → confirm, then delete it (an
  /// "unsend" — the row is removed for both sides). Removed optimistically;
  /// the realtime stream confirms it.
  Future<void> _deleteMessage(ChatMessage m) async {
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('delete_message'),
      body: AppStrings.t('delete_message_body'),
      confirmLabel: AppStrings.t('delete'),
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget _buildMessageList() {
    if (_messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            AppStrings.t('no_messages'),
            style: const TextStyle(color: SC.textMuted, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    // Flat list of day separators + bubbles. A separator opens every calendar
    // day so a long thread reads as "MERCREDI / JEUDI / …" instead of one
    // unbroken scroll of timestamps.
    final items = <_ThreadListItem>[];
    DateTime? lastDay;
    for (final m in _messages) {
      final day = DateTime(m.createdAt.year, m.createdAt.month, m.createdAt.day);
      if (lastDay == null || day != lastDay) {
        items.add(_ThreadListItem.day(day));
        lastDay = day;
      }
      items.add(_ThreadListItem.message(m));
    }

    // Local TTS is local — no cloud cost, available to all tiers.
    return ListView.builder(
      controller: _scrollCtrl,
      // Bottom room so the last message clears the floating composer.
      padding: EdgeInsets.fromLTRB(
        12,
        12,
        12,
        96 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final item = items[i];
        if (item.isDay) {
          return _DaySeparator(day: item.day!);
        }
        final m = item.message!;
        final mine = m.senderId == _myId;
        return _MessageBubble(
          message: m,
          mine: mine,
          displayBody: _displayBodyFor(m),
          translating: _translatingIds.contains(m.id),
          myLang: _myLang,
          // Long-press to delete — only my own messages.
          onLongPressDelete: mine ? () => _deleteMessage(m) : null,
        );
      },
    );
  }
}

/// One row of the thread list: either a day label or a message bubble.
class _ThreadListItem {
  const _ThreadListItem._({this.day, this.message});

  factory _ThreadListItem.day(DateTime day) => _ThreadListItem._(day: day);
  factory _ThreadListItem.message(ChatMessage m) =>
      _ThreadListItem._(message: m);

  final DateTime? day;
  final ChatMessage? message;

  bool get isDay => day != null;
}

/// Hairline — JOUR — hairline. Marks the start of a calendar day in the
/// thread, matching the Messages list's mono section-label feel.
class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.day});

  final DateTime day;

  static const _hairline = Color(0x22FFFFFF);
  static const _label = TextStyle(
    fontFamily: 'monospace',
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.2,
    color: Color(0x66FFFFFF),
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
      child: Row(
        children: [
          const Expanded(child: Divider(height: 1, thickness: 1, color: _hairline)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_labelFor(day).toUpperCase(), style: _label),
          ),
          const Expanded(child: Divider(height: 1, thickness: 1, color: _hairline)),
        ],
      ),
    );
  }

  /// Today / yesterday when recent; full weekday within the last week;
  /// otherwise a short numeric date so old threads stay scannable.
  static String _labelFor(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    if (day == today) return AppStrings.t('chat_day_today');
    if (day == yesterday) return AppStrings.t('chat_day_yesterday');
    final daysAgo = today.difference(day).inDays;
    if (daysAgo >= 0 && daysAgo < 7) {
      const keys = [
        'weekday_mon',
        'weekday_tue',
        'weekday_wed',
        'weekday_thu',
        'weekday_fri',
        'weekday_sat',
        'weekday_sun',
      ];
      return AppStrings.t(keys[(day.weekday - 1).clamp(0, 6)]);
    }
    final d = day.day.toString().padLeft(2, '0');
    final mo = day.month.toString().padLeft(2, '0');
    return '$d/$mo/${day.year}';
  }
}

class _ThreadHeader extends StatelessWidget {
  const _ThreadHeader({
    required this.title,
    required this.peer,
    required this.onCall,
    required this.onVideoCall,
    required this.onViewProfile,
    this.clock,
    this.place = '',
    this.peerBlocked = false,
    this.blockedByPeer = false,
    this.onToggleBlock,
    this.onReport,
  });
  final String title;
  final RemoteProfile? peer;

  /// Local time at the peer's place — rendered as an orange line under the
  /// first name (not a floating pill over the messages).
  final PeerLocalTime? clock;

  /// City label shown next to the clock (empty = time alone).
  final String place;

  /// True when the peer has blocked ME — greys out the call button.
  final bool blockedByPeer;

  /// Téléphone : appel normal, caméra coupée des deux côtés.
  final VoidCallback onCall;

  /// Caméra : mode visio, la mienne s'allume dès l'entrée en appel.
  final VoidCallback onVideoCall;

  final VoidCallback onViewProfile;

  // Block / report are no longer surfaced in the header (the ⋮ menu was
  // removed in favour of the phone + camera buttons) — they remain reachable
  // from the peer's profile. Kept as optional params so the wiring survives.
  final bool peerBlocked;
  final VoidCallback? onToggleBlock;
  final VoidCallback? onReport;

  /// True when the peer was active in the last 2 minutes, hasn't
  /// hidden their online state, AND the local user hasn't opted out
  /// of presence (reciprocal rule).
  bool get _peerOnline {
    if (AppSettings.hideOnlineLocal.value) return false;
    final p = peer;
    if (p == null) return false;
    final ls = p.lastSeen;
    return !p.hideOnlineStatus &&
        ls != null &&
        DateTime.now().difference(ls) < const Duration(minutes: 2);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // No frosted block behind the header any more — only the round glass
      // buttons keep their glass. The row sits transparently over the chat.
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
      child: Padding(
        // Transparent header — only the round glass buttons carry the glass.
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          children: [
            GlassIconButton(
              icon: Icons.arrow_back_rounded,
              size: 40,
              iconSize: 20,
              // Bigger, marked grow-then-settle pop on tap (like the nav bar).
              popScale: 1.25,
              onTap: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 8),
            // PDP bubble + online dot — tap opens the peer's profile.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onViewProfile,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  ProfileAvatar(
                    displayName: title,
                    avatarUrl: peer?.avatarUrl,
                    size: 36,
                  ),
                  if (_peerOnline)
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: SC.online,
                          shape: BoxShape.circle,
                          border: Border.all(color: SC.bgDeep, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Middle zone: peer name + local-time left, brand mark centred.
            // The yellow clock used to paint over the brand — the left column
            // is hard-capped before the logo so the city ellipsizes instead.
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  final nameStyle = SCText.h3.copyWith(
                    fontSize: 15,
                    color: Colors.white.withValues(alpha: 0.9),
                  );
                  const logoW = 22.0;
                  // Leave ≥12px air before the centred brand.
                  const gap = 12.0;
                  final logoLeft = c.maxWidth / 2 - logoW / 2;
                  final leftMax = (logoLeft - gap).clamp(48.0, c.maxWidth);
                  // Only drop the mark if the middle strip is too narrow to fit
                  // both a usable left column and the logo.
                  final showLogo = leftMax + gap + logoW <= c.maxWidth;
                  // Local copy so the null check promotes (field `clock` cannot).
                  final peerClock = clock;
                  return Stack(
                    clipBehavior: Clip.hardEdge,
                    alignment: Alignment.center,
                    children: [
                      if (showLogo)
                        const Center(
                          child: SwaycoLogo(height: 22),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onViewProfile,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: showLogo ? leftMax : c.maxWidth,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: nameStyle,
                                ),
                                if (peerClock != null)
                                  _PeerClockLine(
                                    clock: peerClock,
                                    place: place,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            // Deux boutons d'appel : la caméra démarre le mode visio, le
            // téléphone un appel normal (caméras coupées) — c'est lui qui est
            // au bord, le plus près du pouce.
            //
            // Bloqué par le pair, ils cessent d'être des boutons : plus de
            // verre, plus de rebond, plus rien à toucher — il ne reste que les
            // deux icônes en creux. Un bouton grisé se presse quand même ;
            // une icône nue, non. Ce qu'on peut encore faire est en bas.
            if (blockedByPeer)
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _DeadCallIcon(icon: Icons.videocam_rounded),
                  SizedBox(width: 8),
                  _DeadCallIcon(icon: Icons.phone_rounded),
                ],
              )
            else
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassIconButton(
                    icon: Icons.videocam_rounded,
                    size: 40,
                    iconSize: 20,
                    // Marked pop on tap (matches the back button / nav bar).
                    popScale: 1.25,
                    onTap: onVideoCall,
                  ),
                  const SizedBox(width: 8),
                  GlassIconButton(
                    icon: Icons.phone_rounded,
                    size: 40,
                    iconSize: 20,
                    popScale: 1.25,
                    onTap: onCall,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// L'icône d'appel quand elle n'appelle plus : même gabarit que le bouton en
/// verre qu'elle remplace, pour que l'en-tête ne bouge pas d'un pixel — mais
/// sans fond, sans bord et sans geste. Elle dit ce qui existait ici, pas ce
/// qu'on peut faire.
class _DeadCallIcon extends StatelessWidget {
  const _DeadCallIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: Icon(icon, size: 20, color: Colors.white.withValues(alpha: 0.32)),
    );
  }
}

/// Orange subtitle under the peer's first name: local time, sun/moon, city.
/// Plain text — no pill / glass island over the conversation.
class _PeerClockLine extends StatelessWidget {
  const _PeerClockLine({required this.clock, required this.place});

  final PeerLocalTime clock;

  /// The peer's city (their country when no city is set); empty = time alone.
  final String place;

  static const _orange = Color(0xFFFFB74D);

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(
      color: _orange,
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      height: 1.15,
    );
    final city = place.trim();

    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Row(
        // Fill the constrained parent so [Expanded] can ellipsize the city
        // instead of painting past swaycø in the header Stack.
        children: [
          Text(
            clock.hhmm,
            style: textStyle.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            clock.isDay ? Icons.wb_sunny_rounded : Icons.nightlight_round,
            size: 12,
            color: _orange,
          ),
          if (city.isNotEmpty) ...[
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                city.toUpperCase(),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: textStyle.copyWith(letterSpacing: 0.3),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.mine,
    required this.displayBody,
    required this.translating,
    required this.myLang,
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

  /// BCP-47 primary subtag of the local user's language.
  final String myLang;

  @override
  Widget build(BuildContext context) {
    final align = mine ? Alignment.centerRight : Alignment.centerLeft;
    // Dark text on the light bubbles (dark-teal on sent, near-black on
    // received).
    final bubbleText = mine ? SC.msgOutText : SC.msgInText;
    final radius = BorderRadius.only(
      topLeft: Radius.circular(mine ? 18 : 8),
      topRight: Radius.circular(mine ? 8 : 18),
      bottomLeft: const Radius.circular(18),
      bottomRight: const Radius.circular(18),
    );

    final time =
        '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')}';

    // Text-only bubbles hug their content so a short "👋" or "Coucou !" no
    // longer stretches the full width; media bubbles keep their own width.
    var hugContent =
        !message.isImage && !message.hasDiscoverPhoto;

    // Une image ou un GIF envoyé seul se montre NU : pas de bulle, pas de
    // cadre, pas de fond. L'image est déjà un objet à elle seule — l'enfermer
    // dans un rectangle coloré ne fait que l'entourer de bord perdu. Il ne
    // reste que l'heure, posée dessous.
    final bareMedia = message.isImage && displayBody.trim().isEmpty;
    // Sans bulle, la colonne doit épouser l'image. Sinon l'heure, qui est un
    // Align, s'étire sur toute la largeur offerte (78 % de l'écran) et emporte
    // la colonne avec elle : l'image se retrouvait calée à gauche d'un bloc
    // trois fois plus large qu'elle, donc « au milieu » de l'écran.
    if (bareMedia) hugContent = true;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!mine && message.senderName.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              message.senderName,
              style: const TextStyle(
                color: SC.accent,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        // Discover reaction / intro: a small Snapchat-style thumbnail
        // of the photo it was about, with the message stuck below it.
        if (message.hasDiscoverPhoto)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: GestureDetector(
              onTap: () => _openFullImage(context, message.discoverPhoto),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: 150,
                    maxWidth: 120,
                  ),
                  child: Image.network(
                    message.discoverPhoto,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox(
                      height: 100,
                      width: 100,
                      child: Center(
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: SC.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        // Image messages: show the photo (tap to view full-screen).
        if (message.isImage)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: GestureDetector(
              onTap: () => _openFullImage(context, message.imageUrl),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: Image.network(
                    message.imageUrl,
                    fit: BoxFit.cover,
                    loadingBuilder: (ctx, child, progress) => progress == null
                        ? child
                        : const SizedBox(
                            height: 160,
                            width: 200,
                            child: Center(
                              child: CircularProgressIndicator(
                                color: SC.accent,
                                strokeWidth: 2,
                              ),
                            ),
                          ),
                    errorBuilder: (_, _, _) => const SizedBox(
                      height: 120,
                      width: 200,
                      child: Center(
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: SC.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        // When [displayBody] is empty, drop the Text node entirely so
        // the bubble shows no phantom line.
        if (displayBody.isNotEmpty)
          Text(
            displayBody,
            style: TextStyle(
              color: translating
                  ? bubbleText.withValues(alpha: 0.55)
                  : bubbleText,
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
              // Sans bulle, l'heure se pose sur le fond noir de la page : le
              // gris des bulles y serait illisible.
              color: bareMedia
                  ? SC.textMuted
                  : bubbleText.withValues(alpha: 0.5),
              fontSize: 10,
            ),
          ),
        ),
      ],
    );

    return Align(
      alignment: align,
      child: GestureDetector(
        // Long-press one of my own bubbles → offer to delete it.
        onLongPress: onLongPressDelete,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: bareMedia
              ? EdgeInsets.zero
              : const EdgeInsets.fromLTRB(14, 10, 14, 8),
          constraints: BoxConstraints(
            // Floor so a tiny "👋" / "Coucou !" / "hello" still reads as a
            // proper bubble instead of a cramped little square. Une image nue
            // n'a pas de plancher : elle fait sa taille.
            minWidth: bareMedia ? 0 : 110,
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          decoration: bareMedia
              ? null
              : BoxDecoration(
                  // Light "card" bubbles on the black message area: received =
                  // neutral grey, sent = pale cyan with a cyan border.
                  color: mine ? SC.msgOutBg : SC.msgInBg,
                  borderRadius: radius,
                  border: Border.all(
                    color: mine ? SC.msgOutBorder : SC.msgInBorder,
                  ),
                ),
          child: hugContent ? IntrinsicWidth(child: content) : content,
        ),
      ),
    );
  }

  /// Full-screen image viewer — tap anywhere or pinch to zoom; tap to close.
  void _openFullImage(BuildContext context, String url) {
    // Reuse the profile photo overlay (rounded corners, ✕, pinch-zoom, fade,
    // tap-to-dismiss). viewerMode hides the "set as Discover" button and a
    // single-photo list means no side arrows.
    showPhotoViewer(context, photos: [url], index: 0, viewerMode: true);
  }
}

/// Le panneau qui prend la place du composer quand le pair m'a bloqué.
///
/// Il ne se contente plus d'annoncer la mauvaise nouvelle : puisque écrire et
/// appeler sont devenus impossibles, il porte les deux seules choses qui
/// restent — signaler la personne, ou supprimer la conversation. C'est là que
/// le pouce arrive, à la place exacte où il allait écrire.
class _BlockedComposerNotice extends StatelessWidget {
  const _BlockedComposerNotice({
    required this.name,
    required this.onReport,
    required this.onDelete,
  });

  /// Prénom du pair — le titre le nomme, sinon on ne sait pas qui a bloqué qui.
  final String name;
  final VoidCallback onReport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final firstName = name.trim().split(RegExp(r'\s+')).first;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        4,
        12,
        12 + MediaQuery.paddingOf(context).bottom * 0.4,
      ),
      child: GlassPanel(
        borderRadius: 22,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              AppStrings.t('chat_blocked_title', args: {'name': firstName}),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SC.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              AppStrings.t('chat_blocked_body'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SC.textMuted,
                fontSize: 13,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _BlockedAction(
                  label: AppStrings.t('report'),
                  onTap: onReport,
                ),
                const SizedBox(width: 10),
                _BlockedAction(
                  label: AppStrings.t('delete'),
                  onTap: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Une des deux touches du panneau de blocage : une pilule sobre, bordée, sans
/// couleur d'alerte — ni l'une ni l'autre n'est le geste qu'on attend de
/// quelqu'un, et rien ne doit pousser à en choisir une.
class _BlockedAction extends StatelessWidget {
  const _BlockedAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      bounce: true,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: SC.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onSendImage,
    required this.onSendGif,
    required this.autoTranslate,
    required this.onToggleTranslate,
    required this.myLang,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  /// The local user's spoken-language code (e.g. `fr`). Drives the composer
  /// placeholder — "Écrivez en Français" instead of a generic "Message".
  final String myLang;

  /// Pick + send an image. Wired to the image button on the left.
  final Future<void> Function() onSendImage;

  /// Ouvre le catalogue Giphy et envoie le GIF choisi.
  final Future<void> Function() onSendGif;
  final bool autoTranslate;
  final VoidCallback onToggleTranslate;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  /// True while the input field has any text — in that case we render
  /// the send button (instead of the mic) so the gesture matches the
  /// user's clear intent.
  bool _hasText = false;

  /// Typewriter reveal of the placeholder when the chat opens — the hint
  /// fills in one character at a time ("W", "Wr", "Wri"…).
  String _typedHint = '';
  Timer? _hintTimer;

  /// Gate: only type the placeholder once the page-open transition has
  /// finished, so the animation plays on a settled (visible) screen instead
  /// of during the slide-in + initial message load (where it isn't seen).
  bool _hintReady = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    _hasText = widget.controller.text.trim().isNotEmpty;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _startHintWhenSettled(),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _hintTimer?.cancel();
    super.dispose();
  }

  void _onTextChanged() {
    final has = widget.controller.text.trim().isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  @override
  void didUpdateWidget(_Composer old) {
    super.didUpdateWidget(old);
    // The spoken language loads a beat after the screen opens; retype the
    // placeholder once it resolves ("Message" → "Write in English") — but
    // only after the open transition, so the retype stays visible.
    if (_hintReady && old.myLang != widget.myLang) _animateHint();
  }

  /// Wait for the route's open transition to finish, then start typing.
  /// Runs immediately when there's no transition still in flight.
  void _startHintWhenSettled() {
    if (!mounted) return;
    final anim = ModalRoute.of(context)?.animation;
    if (anim != null && anim.status != AnimationStatus.completed) {
      void onStatus(AnimationStatus s) {
        if (s == AnimationStatus.completed || s == AnimationStatus.dismissed) {
          anim.removeStatusListener(onStatus);
          if (!mounted) return;
          _hintReady = true;
          _animateHint();
        }
      }

      anim.addStatusListener(onStatus);
    } else {
      _hintReady = true;
      _animateHint();
    }
  }

  /// Reveal [_composerHint] one character at a time. Cheap setState loop on a
  /// ~75 ms tick — quick enough to feel snappy, slow enough to read.
  void _animateHint() {
    _hintTimer?.cancel();
    final full = _composerHint;
    if (!mounted) return;
    setState(() => _typedHint = '');
    var shown = 0;
    _hintTimer = Timer.periodic(const Duration(milliseconds: 75), (t) {
      if (!mounted || shown >= full.length) {
        t.cancel();
        return;
      }
      shown++;
      setState(() => _typedHint = full.substring(0, shown));
    });
  }

  @override
  Widget build(BuildContext context) => _buildIdleBar();

  /// Placeholder shown in the empty input. Adapts to the user's spoken
  /// language — "Écrivez en Français" for a French user — falling back to the
  /// plain "Message" when their language is unknown.
  String get _composerHint {
    final lang = findLanguageByCode(widget.myLang);
    if (lang == null) return AppStrings.t('composer_message_hint');
    return AppStrings.t(
      'composer_message_hint_lang',
      args: {'lang': lang.label},
    );
  }

  Widget _buildIdleBar() {
    // Lowered: use only part of the bottom safe-area inset so the bar sits a
    // bit closer to the screen edge.
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        4,
        8,
        // Nudged up very slightly (was 6) so the floating bar + photo button
        // sit a touch higher off the bottom edge.
        12 + MediaQuery.paddingOf(context).bottom * 0.4,
      ),
      child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: GlassPanel(
                borderRadius: 26,
                padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 140),
                        child: TextField(
                          controller: widget.controller,
                          enabled: !widget.sending,
                          minLines: 1,
                          maxLines: 6,
                          textCapitalization: TextCapitalization.sentences,
                          cursorColor: SC.accent,
                          style: const TextStyle(color: SC.textPrimary),
                          decoration: InputDecoration(
                            hintText: _typedHint,
                            hintStyle: const TextStyle(color: SC.textMuted),
                            // Keep the placeholder on ONE line — on the native
                            // build the wider font wrapped "Écrivez en Français"
                            // onto a second line and made the whole bar tall.
                            hintMaxLines: 1,
                            filled: false,
                            contentPadding: const EdgeInsets.fromLTRB(
                              4,
                              8,
                              12,
                              8,
                            ),
                            // Only the translate toggle on the left — the photo
                            // button now sits OUTSIDE the bar (right).
                            prefixIcon: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(width: 8),
                                _ComposerTranslateToggle(
                                  active: widget.autoTranslate,
                                  onTap: widget.onToggleTranslate,
                                ),
                              ],
                            ),
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 0,
                              minHeight: 38,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                          ),
                          onSubmitted: (_) => widget.onSend(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Le bouton rond : envoyer quand il y a du texte, sinon
                    // ouvrir les GIF. Il a remplacé le micro — le chat
                    // n'enregistre plus de vocaux.
                    _CircleActionButton(
                      icon: _hasText ? Icons.send : Icons.gif_box_rounded,
                      busy: widget.sending,
                      onTap: widget.sending
                          ? null
                          : (_hasText ? widget.onSend : widget.onSendGif),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            // Photo (add image) button — OUTSIDE the glass bar, so it gets its
            // own glass circle + spring bounce (like the header buttons).
            GlassIconButton(
              icon: Icons.add_photo_alternate_outlined,
              onTap: widget.sending ? null : widget.onSendImage,
              size: 46,
              iconSize: 24,
            ),
          ],
        ),
      );
  }

}

class _CircleActionButton extends StatelessWidget {
  const _CircleActionButton({
    required this.icon,
    required this.busy,
    required this.onTap,
  });
  final IconData icon;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [SC.accent, SC.accentDeep],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: SC.accent.withValues(alpha: 0.45),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: busy
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(icon, color: Colors.white, size: 22),
          ),
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
              color: active ? SC.accent : SC.textMuted,
            ),
            const SizedBox(width: 8),
            // Sliding pill — bigger so it reads as a real toggle.
            Container(
              width: 42,
              height: 22,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: active
                    ? SC.online.withValues(alpha: 0.55)
                    : SC.glassStrong,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: SC.glassBorder),
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                alignment: active
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active
                        ? SC.online
                        : Colors.white.withValues(alpha: 0.40),
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: SC.online.withValues(alpha: 0.55),
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

/// Full-screen white shimmer that sweeps from left to right when the
/// translate toggle is activated. Driven by a one-shot AnimationController
/// kept on [_ChatThreadScreenState]; idle the rest of the time so it paints
/// nothing and stays free.
class _ActivationWaveOverlay extends StatelessWidget {
  const _ActivationWaveOverlay({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (_, child) {
        final t = animation.value;
        if (t == 0 || t == 1) return const SizedBox.shrink();
        // Slide a soft white gradient from off-screen-bottom (+1.2) to
        // off-screen-top (-1.2), expressed as a fractional offset of the
        // overlay's own height.
        final dy = 1.2 - 2.4 * t;
        // Quick fade-in / fade-out so the band never appears or disappears
        // abruptly at the edges of the sweep.
        final fade = (t < 0.15) ? t / 0.15 : (t > 0.85 ? (1 - t) / 0.15 : 1.0);
        return ClipRect(
          child: FractionalTranslation(
            translation: Offset(0, dy),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
                  colors: [
                    Colors.white.withValues(alpha: 0),
                    Colors.white.withValues(alpha: 0.10 * fade),
                    Colors.white.withValues(alpha: 0.28 * fade),
                    Colors.white.withValues(alpha: 0.10 * fade),
                    Colors.white.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        );
      },
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
      color: Color(0xFFE53935).withValues(alpha: 0.18),
      child: Text(
        message,
        style: const TextStyle(
          color: Color(0xFFFFAB91),
          fontSize: 12,
          height: 1.35,
        ),
      ),
    );
  }
}
