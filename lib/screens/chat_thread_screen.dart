import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

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
import '../services/voice_message_api.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../translation/realtime_translation_port.dart';
import '../widgets/glass.dart';
import '../widgets/glass_panel.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/report_dialog.dart';
import '../widgets/swayco_dialog.dart';
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

  /// Ticks every minute so the peer's local-time bubble stays current
  /// without the user reopening the thread.
  Timer? _clockTimer;
  List<ChatMessage> _messages = const [];
  String _myId = '';
  String _myName = '';
  String _myLang = '';
  String _myGender = '';

  /// `'free' | 'plus' | 'pro' | 'ultra'` — read from my own
  /// Supabase profile during [_bootstrap]. Gates the /voice/dub CTA
  /// rendered on incoming voice messages.
  String _myTier = 'free';
  RemoteProfile? _peer;
  bool _sending = false;
  String? _error;

  /// When true, replace each foreign-language message body with its
  /// translation into [_myLang]. Translations are cached by message id so we
  /// only hit OpenAI once per message.
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
  /// set or the place isn't in our timezone table — the bubble then hides.
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
      _myTier = mine?.subscriptionTier ?? 'free';
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

  /// Upload a recorded voice message via the backend STT pipeline. The
  /// backend persists the audio, transcribes it and inserts the row;
  /// the realtime stream will surface the new message to both sides so
  /// we don't have to optimistically inject it here.
  Future<void> _sendVoice({
    required Uint8List bytes,
    required String mimeType,
    required int durationMs,
  }) async {
    if (_myId.isEmpty || _sending) return;
    if (!isSupabaseReady) {
      setState(() => _error = 'Supabase non configuré.');
      return;
    }
    setState(() => _sending = true);
    try {
      await uploadVoiceMessage(
        audioBytes: bytes,
        mimeType: mimeType,
        durationMs: durationMs,
        conversationId: widget.conversationId,
        recipientId: widget.peerDeviceId,
        senderName: _myName.isEmpty ? 'Moi' : _myName,
        hintLanguage: _myLang.isEmpty ? null : _myLang,
      );
      Analytics.track(
        'message_sent',
        props: {'source': 'chat', 'type': 'voice'},
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Envoi vocal échoué: $e');
      }
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

  @override
  Widget build(BuildContext context) {
    final peerClock = _peerClock;
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      body: GestureDetector(
        // Swipe right anywhere to leave the conversation (back).
        onHorizontalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) Navigator.of(context).maybePop();
        },
        child: Stack(
          children: [
            ColoredBox(
              color: const Color(0xFF0E0E0E),
              child: SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    _ThreadHeader(
                      title: widget.title,
                      peer: _peer,
                      blockedByPeer: _peerBlockedMe,
                      onCall: _peerBlockedMe
                          ? () => ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  AppStrings.t('chat_blocked_by_peer'),
                                ),
                              ),
                            )
                          : () => CallLauncher.startCall(
                              context,
                              peerDeviceId: widget.peerDeviceId,
                              translation: widget.translation,
                              startWithCamera: true,
                            ),
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
                              child: _buildMessageList(
                                hasClockChip: peerClock != null,
                              ),
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
                            // Floating "local time at the peer's place" bubble.
                            // Centred under the swayco.ai logo, not the screen:
                            // the header's logo sits in an Expanded offset by
                            // the back+avatar cluster on the left (18 padding +
                            // 40 + 8 + 36 + 10 = 112) and the call button on the
                            // right (18 padding + 40 = 58). Matching those insets
                            // here puts the bubble's centre on the logo's centre.
                            if (peerClock != null)
                              Positioned(
                                top: 8,
                                left: 112,
                                right: 58,
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: _PeerClockChip(
                                    clock: peerClock,
                                    name: widget.title,
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
                  ? const _BlockedComposerNotice()
                  : _Composer(
                      controller: _inputCtrl,
                      sending: _sending,
                      onSend: _send,
                      onSendVoice: _sendVoice,
                      onSendImage: _sendImage,
                      autoTranslate: _autoTranslate,
                      onToggleTranslate: _toggleAutoTranslate,
                      myLang: _myLang,
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

  Widget _buildMessageList({bool hasClockChip = false}) {
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
    // Top-anchored layout: first (oldest) message at the top, list grows
    // downward, empty space at the bottom when the conversation is short.
    final canDub = _myTier == 'plus' || _myTier == 'pro' || _myTier == 'ultra';
    return ListView.builder(
      controller: _scrollCtrl,
      // Extra top room when the floating local-time bubble is shown so the
      // first message never hides behind it.
      // Bottom room so the last message clears the floating composer.
      padding: EdgeInsets.fromLTRB(
        12,
        hasClockChip ? 46 : 12,
        12,
        96 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: _messages.length,
      itemBuilder: (ctx, i) {
        final m = _messages[i];
        final mine = m.senderId == _myId;
        return _MessageBubble(
          message: m,
          mine: mine,
          displayBody: _displayBodyFor(m),
          translating: _translatingIds.contains(m.id),
          canDubAudio: canDub,
          myLang: _myLang,
          // Long-press to delete — only my own messages.
          onLongPressDelete: mine ? () => _deleteMessage(m) : null,
        );
      },
    );
  }
}

class _ThreadHeader extends StatelessWidget {
  const _ThreadHeader({
    required this.title,
    required this.peer,
    required this.onCall,
    required this.onViewProfile,
    this.peerBlocked = false,
    this.blockedByPeer = false,
    this.onToggleBlock,
    this.onReport,
  });
  final String title;
  final RemoteProfile? peer;

  /// True when the peer has blocked ME — greys out the call button.
  final bool blockedByPeer;

  /// Call button — starts a video call (camera on).
  final VoidCallback onCall;
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
                    avatarColorHex: peer?.avatarColor,
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
            // Middle zone: the swayco.ai logo CENTRED between the PDP and the
            // call button (its own, larger size), with the peer name small and
            // left-aligned, nudged up. The logo is dropped for a long name so
            // the two never collide.
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  final nameStyle = SCText.h3.copyWith(
                    fontSize: 15,
                    color: Colors.white.withValues(alpha: 0.9),
                  );
                  const logoStyle = TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  );
                  final scaler = MediaQuery.textScalerOf(context);
                  double widthOf(String t, TextStyle s) => (TextPainter(
                    text: TextSpan(text: t, style: s),
                    maxLines: 1,
                    textScaler: scaler,
                    textDirection: TextDirection.ltr,
                  )..layout()).width;
                  final nameW = widthOf(title, nameStyle);
                  final logoW = widthOf('swayco.ai', logoStyle);
                  // Logo is centred over [0, c.maxWidth]; the name is left-
                  // aligned [0, nameW]. Show the logo ONLY if the name's right
                  // edge clears the logo's left edge with a 14px gap — measured,
                  // so it never collides regardless of the name.
                  final showLogo = nameW <= c.maxWidth / 2 - logoW / 2 - 14;
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onViewProfile,
                          child: Transform.translate(
                            offset: const Offset(0, -3),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: c.maxWidth),
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: nameStyle,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (showLogo)
                        const Center(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: 'swayco'),
                                TextSpan(
                                  text: '.ai',
                                  style: TextStyle(color: SC.accent),
                                ),
                              ],
                            ),
                            maxLines: 1,
                            style: logoStyle,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            // Single call button — a tap starts a video call (camera on).
            // Greyed when the peer has blocked me (the call can't connect).
            Opacity(
              opacity: blockedByPeer ? 0.4 : 1.0,
              child: GlassIconButton(
                icon: Icons.phone_rounded,
                size: 40,
                iconSize: 20,
                // Marked pop on tap (matches the back button / nav bar).
                popScale: 1.25,
                onTap: onCall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small floating bubble under the header showing the peer's local time, with
/// a white sun (day) / moon (night) icon. Orange-tinted, darker border.
class _PeerClockChip extends StatefulWidget {
  const _PeerClockChip({required this.clock, required this.name});

  final PeerLocalTime clock;
  final String name;

  @override
  State<_PeerClockChip> createState() => _PeerClockChipState();
}

class _PeerClockChipState extends State<_PeerClockChip> {
  // Held down → the pill stretches open to spell out whose local time it is;
  // released → it snaps back to just the time + sun/moon.
  bool _open = false;
  void _set(bool v) {
    if (mounted && _open != v) setState(() => _open = v);
  }

  @override
  Widget build(BuildContext context) {
    // Frosted-glass orange pill — translucent so the chat behind shows through.
    const shadows = [
      Shadow(color: Color(0x66000000), blurRadius: 2, offset: Offset(0, 1)),
    ];
    const textStyle = TextStyle(
      color: Colors.white,
      fontSize: 13,
      fontWeight: FontWeight.w700,
      shadows: shadows,
    );
    final firstName = widget.name.trim().split(RegExp(r'\s+')).first;

    final timeRow = Row(
      key: const ValueKey('time'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.clock.hhmm,
          style: textStyle.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 6),
        Icon(
          widget.clock.isDay ? Icons.wb_sunny_rounded : Icons.nightlight_round,
          size: 14,
          color: Colors.white,
          shadows: shadows,
        ),
      ],
    );
    final phrase = Text(
      AppStrings.t(
        'peer_clock_phrase',
        args: {'time': widget.clock.hhmm, 'name': firstName},
      ),
      key: const ValueKey('phrase'),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.fade,
      style: textStyle,
    );

    return GestureDetector(
      // A real press-and-hold (~0.5s) opens it — a brush/tap does nothing.
      // Stays open while held; snaps shut the instant the finger lifts.
      onLongPressStart: (_) => _set(true),
      onLongPressEnd: (_) => _set(false),
      onLongPressCancel: () => _set(false),
      child: GlassPanel(
        borderRadius: 999,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        color: const Color(0x55FFA726), // light orange — recording tint
        // Stretch open/closed; the text cross-fades inside.
        child: AnimatedSize(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutBack,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _open ? phrase : timeRow,
          ),
        ),
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
    required this.canDubAudio,
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

  /// True when the local user's tier unlocks /voice/dub. Plus / Pro /
  /// Ultra → true; Free → false. Server-side gating is the final word,
  /// so this only drives whether we render the CTA at all.
  final bool canDubAudio;

  /// BCP-47 primary subtag of the local user's language — the
  /// translation target for any incoming foreign voice message.
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
    final hugContent =
        !message.isImage && !message.hasDiscoverPhoto && !message.isVoice;

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
        // Voice messages render an inline mini-player above the body.
        // The body itself stays so the transcript / translation is
        // always visible underneath the audio control.
        if (message.isVoice)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _VoicePlayer(
              audioUrl: message.audioUrl,
              durationMs: message.audioDurationMs,
            ),
          ),
        // For voice messages the transcription / translation is only
        // for the recipient — the sender already knows what they said,
        // so we hide the text under their own voice bubble (the player
        // alone is enough). Non-voice messages always show their body.
        // When [displayBody] is empty (raw STT returned nothing), drop
        // the Text node entirely so the bubble shows no phantom line.
        if (displayBody.isNotEmpty && !(message.isVoice && mine))
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
        // "🔊 Écouter la traduction" CTA. Only shown for incoming
        // foreign voice messages when the local user is on a paid
        // tier and we already have a translated body to dub.
        if (message.isVoice &&
            !mine &&
            canDubAudio &&
            !translating &&
            displayBody.isNotEmpty &&
            displayBody != message.body &&
            myLang.isNotEmpty)
          _DubButton(
            key: ValueKey('dub-${message.id}-$myLang'),
            messageId: message.id,
            targetLang: myLang,
            translatedText: displayBody,
          ),
        const SizedBox(height: 2),
        Align(
          alignment: Alignment.bottomRight,
          child: Text(
            time,
            style: TextStyle(
              color: bubbleText.withValues(alpha: 0.5),
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
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          constraints: BoxConstraints(
            // Floor so a tiny "👋" / "Coucou !" / "hello" still reads as a
            // proper bubble instead of a cramped little square.
            minWidth: 110,
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          decoration: BoxDecoration(
            // Light "card" bubbles on the black message area: received =
            // neutral grey, sent = pale cyan with a cyan border.
            color: mine ? SC.msgOutBg : SC.msgInBg,
            borderRadius: radius,
            border: Border.all(color: mine ? SC.msgOutBorder : SC.msgInBorder),
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

/// Inline audio player for a single voice message. Each bubble owns its
/// own [AudioPlayer] so two messages can play concurrently if the user
/// somehow taps two — but in practice we let any other instance keep
/// running; there is no global "single player" coordinator yet.
class _VoicePlayer extends StatefulWidget {
  const _VoicePlayer({required this.audioUrl, required this.durationMs});
  final String audioUrl;
  final int durationMs;

  @override
  State<_VoicePlayer> createState() => _VoicePlayerState();
}

/// Companion "🔊 Écouter la traduction" CTA shown under the original
/// voice bubble when:
///   1. auto-translate is on,
///   2. the message body is in a different language than mine, AND
///   3. the local user is on a paid tier with [voiceDub != 'none']
///      (the backend re-checks — this is a UX hint, not a security
///      gate).
/// On first tap we POST /voice/dub with the already-translated text;
/// the backend renders + caches the mp3 and the player widget below
/// fades in to play it.
class _DubButton extends StatefulWidget {
  const _DubButton({
    super.key,
    required this.messageId,
    required this.targetLang,
    required this.translatedText,
  });
  final String messageId;
  final String targetLang;
  final String translatedText;

  @override
  State<_DubButton> createState() => _DubButtonState();
}

class _DubButtonState extends State<_DubButton> {
  bool _loading = false;
  String? _dubUrl;
  String? _error;

  Future<void> _generate() async {
    if (_loading || _dubUrl != null) return;
    if (widget.translatedText.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final out = await fetchVoiceDub(
        messageId: widget.messageId,
        targetLang: widget.targetLang,
        text: widget.translatedText,
      );
      if (!mounted) return;
      setState(() => _dubUrl = out.audioUrl);
    } on VoiceDubException catch (e) {
      if (!mounted) return;
      String msg;
      switch (e.code) {
        case VoiceDubError.upgradeRequired:
          msg = AppStrings.t('voice_dub_upgrade');
          break;
        case VoiceDubError.quotaExceeded:
          msg = AppStrings.t('voice_dub_quota');
          break;
        case VoiceDubError.other:
          msg = AppStrings.t('voice_dub_failed');
          break;
      }
      setState(() => _error = msg);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {
      if (!mounted) return;
      final msg = AppStrings.t('voice_dub_failed');
      setState(() => _error = msg);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_dubUrl != null) {
      // Once we have a URL, replace the CTA with a full mini-player so
      // the user can scrub / replay the translated audio just like the
      // original recording above.
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: _VoicePlayer(audioUrl: _dubUrl!, durationMs: 0),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        onTap: _loading ? null : _generate,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: SC.accent,
                  ),
                )
              else
                const Icon(
                  Icons.volume_up_outlined,
                  size: 16,
                  color: SC.accent,
                ),
              const SizedBox(width: 6),
              Text(
                _error ?? AppStrings.t('voice_dub_listen'),
                style: const TextStyle(
                  color: SC.accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VoicePlayerState extends State<_VoicePlayer> {
  late final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _posSub;
  Duration _position = Duration.zero;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      setState(() => _playing = s == PlayerState.playing);
      if (s == PlayerState.completed) {
        setState(() => _position = Duration.zero);
      }
    });
    _posSub = _player.onPositionChanged.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _posSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    try {
      if (_playing) {
        await _player.pause();
      } else {
        await _player.play(UrlSource(widget.audioUrl));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Lecture impossible: $e')));
    }
  }

  String _fmt(Duration d) {
    final secs = d.inSeconds;
    final m = (secs ~/ 60).toString().padLeft(1, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final total = Duration(milliseconds: widget.durationMs);
    final progress = total.inMilliseconds <= 0
        ? 0.0
        : (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final remaining = total - _position;
    final label = _playing
        ? _fmt(_position)
        : _fmt(total > Duration.zero ? total : remaining);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: SC.accent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                _playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 140,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: SC.textPrimary.withValues(alpha: 0.18),
              valueColor: const AlwaysStoppedAnimation<Color>(SC.accent),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            color: SC.msgInText.withValues(alpha: 0.75),
            fontSize: 12,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// Maximum recording length. Aligned with the DB CHECK constraint on
/// `messages.audio_duration_ms` (120000 ms) but capped lower in the UI
/// so users see a clear ceiling. Mirrors WhatsApp's UX.
const Duration _kMaxVoiceMessage = Duration(seconds: 60);

/// Replaces the composer when the peer has blocked me — a flat, disabled
/// notice bar so it's obvious messages can't be sent (they'd go nowhere).
class _BlockedComposerNotice extends StatelessWidget {
  const _BlockedComposerNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF0E0E0E),
      padding: EdgeInsets.fromLTRB(
        16,
        14,
        16,
        // Match the idle bar's slight upward nudge (was 14).
        20 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.block, size: 18, color: SC.textMuted),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              AppStrings.t('chat_blocked_by_peer'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: SC.textMuted, fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onSendVoice,
    required this.onSendImage,
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

  /// Hand the parent the raw recording so it can run the backend upload.
  final Future<void> Function({
    required Uint8List bytes,
    required String mimeType,
    required int durationMs,
  })
  onSendVoice;

  /// Pick + send an image. Wired to the image button on the left.
  final Future<void> Function() onSendImage;
  final bool autoTranslate;
  final VoidCallback onToggleTranslate;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final AudioRecorder _recorder = AudioRecorder();

  /// True while the recorder is active. The composer collapses into a
  /// "recording UI" with timer + cancel/send buttons during this state.
  bool _recording = false;

  /// True while the input field has any text — in that case we render
  /// the send button (instead of the mic) so the gesture matches the
  /// user's clear intent.
  bool _hasText = false;
  DateTime? _recordStart;
  Timer? _tick;
  Duration _elapsed = Duration.zero;

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
    _tick?.cancel();
    _hintTimer?.cancel();
    // Best-effort: drop any in-flight recording when the chat is closed.
    unawaited(() async {
      try {
        if (await _recorder.isRecording()) await _recorder.cancel();
      } catch (_) {}
      await _recorder.dispose();
    }());
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

  /// Resolved path passed to `record.start`. Native gets a real file in
  /// the temp directory; on web the package ignores the path and writes
  /// to a Blob URL we read back via `_recorder.stop()`.
  Future<String> _recordingPath() async {
    if (kIsWeb) return ''; // ignored by the web backend
    final dir = await getTemporaryDirectory();
    final name = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    return '${dir.path}/$name';
  }

  Future<void> _startRecording() async {
    if (_recording || widget.sending) return;
    try {
      if (!await _recorder.hasPermission()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.t('voice_mic_denied'))),
        );
        return;
      }
      final path = await _recordingPath();
      // AAC-LC inside an MP4 container = .m4a — natively decodable by
      // iOS / Android / Chrome / Safari. On web the package transparently
      // falls back to the closest available codec (WebM/Opus on Chrome).
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      _recordStart = DateTime.now();
      _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted || _recordStart == null) return;
        final el = DateTime.now().difference(_recordStart!);
        // Hard stop at the cap so an idle user can't blow past the DB
        // constraint or rack up STT bills accidentally.
        if (el >= _kMaxVoiceMessage) {
          unawaited(_stopAndSend());
          return;
        }
        setState(() => _elapsed = el);
      });
      setState(() {
        _recording = true;
        _elapsed = Duration.zero;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur micro: $e')));
    }
  }

  Future<void> _cancelRecording() async {
    if (!_recording) return;
    _tick?.cancel();
    try {
      await _recorder.cancel();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _recording = false;
        _elapsed = Duration.zero;
        _recordStart = null;
      });
    }
  }

  Future<void> _stopAndSend() async {
    if (!_recording) return;
    _tick?.cancel();
    final ms = _elapsed.inMilliseconds;
    String? out;
    try {
      out = await _recorder.stop();
    } catch (_) {
      out = null;
    }
    if (!mounted) return;
    setState(() {
      _recording = false;
      _elapsed = Duration.zero;
      _recordStart = null;
    });
    if (out == null || ms <= 500) {
      // Sub-half-second recording is almost certainly a misfire — skip.
      return;
    }
    Uint8List bytes;
    try {
      if (kIsWeb) {
        // On web, `stop()` returns a blob: URL; fetch it to read bytes.
        final res = await http.get(Uri.parse(out));
        bytes = res.bodyBytes;
      } else {
        bytes = await File(out).readAsBytes();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Lecture audio échouée: $e')));
      }
      return;
    }
    if (bytes.isEmpty) return;
    // Best-guess mime: native = m4a, web = webm.
    final mime = kIsWeb ? 'audio/webm' : 'audio/m4a';
    await widget.onSendVoice(bytes: bytes, mimeType: mime, durationMs: ms);
  }

  @override
  Widget build(BuildContext context) {
    if (_recording) return _buildRecordingBar();
    return _buildIdleBar();
  }

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
                    _CircleActionButton(
                      icon: _hasText ? Icons.send : Icons.mic,
                      busy: widget.sending,
                      onTap: widget.sending
                          ? null
                          : (_hasText ? widget.onSend : _startRecording),
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

  Widget _buildRecordingBar() {
    final secs = _elapsed.inSeconds;
    final m = (secs ~/ 60).toString().padLeft(1, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: GlassPanel(
          borderRadius: 28,
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
          child: Row(
            children: [
              // Cancel — drops the recording without sending.
              Material(
                color: Colors.transparent,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _cancelRecording,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(
                      Icons.delete_outline,
                      color: Color(0xFFE57373),
                      size: 26,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Color(0xFFE53935),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '$m:$s',
                      style: const TextStyle(
                        color: SC.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        AppStrings.t('voice_recording_hint'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: SC.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _CircleActionButton(
                icon: Icons.send,
                busy: false,
                onTap: _stopAndSend,
              ),
            ],
          ),
        ),
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
