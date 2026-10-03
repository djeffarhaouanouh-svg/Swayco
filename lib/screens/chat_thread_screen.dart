import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/analytics.dart';
import '../services/app_strings.dart';
import '../services/block_api.dart';
import '../services/call_launcher.dart';
import '../services/chat_api.dart';
import '../services/chat_reads.dart';
import '../services/chat_unread.dart';
import '../services/message_reactions.dart';
import '../services/device_id.dart';
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/open_thread.dart';
import '../services/peer_local_time.dart';
import '../services/profile_api.dart';
import '../services/presence_service.dart';
import '../services/supabase_service.dart';
import '../services/translation_api.dart';
import '../services/translation_cache.dart';
import '../services/typing_signal.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../swayco/realtime_translation_port.dart';
import '../widgets/gif_picker_sheet.dart';
import '../widgets/glass_panel.dart';
import '../widgets/liquid_glass_button.dart';
import '../widgets/popup_kit.dart';
import '../widgets/pressable.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/report_dialog.dart';
import '../widgets/swayco_animations.dart';
import '../widgets/swayco_dialog.dart';
import 'profile_screen.dart';

/// One-to-one chat thread for [conversationId]. Title is the human-friendly
/// name shown in the header. The header phone icon dials the peer directly
/// via CallLauncher.
/// Fond de la conversation 1b (handoff) — un cran au-dessus du noir pur.
/// Suit le thème : #0A0F1C en sombre, blanc en clair.
Color get _kThreadBg => SC.bg;

/// Opacité du fond DERRIÈRE le header et le composer. Constante sur toute
/// leur hauteur : un dégradé qui baissait déjà derrière le prénom laissait
/// une bulle cyan transparaître en vert sale sous le texte.
const double _kChromeSolid = 0.92;

/// Hauteur du fondu qui prolonge le header (vers le bas) et le composer
/// (vers le haut) : c'est LÀ que les messages transparaissent.
const double _kChromeFade = 40;

/// Le fond du header / du footer : [solid] px à [_kChromeSolid] (là où il y a
/// du contenu), puis [_kChromeFade] px de fondu jusqu'à transparent, en
/// courbe douce — un fondu linéaire court faisait une marche visible.
LinearGradient _chromeGradient({required double solid, required bool top}) {
  final f = solid / (solid + _kChromeFade);
  final tail = 1 - f;
  final c = _kThreadBg;
  return LinearGradient(
    begin: top ? Alignment.topCenter : Alignment.bottomCenter,
    end: top ? Alignment.bottomCenter : Alignment.topCenter,
    stops: [0, f, f + tail * 0.25, f + tail * 0.5, f + tail * 0.75, 1],
    colors: [
      c.withValues(alpha: _kChromeSolid),
      c.withValues(alpha: _kChromeSolid),
      c.withValues(alpha: _kChromeSolid * 0.78),
      c.withValues(alpha: _kChromeSolid * 0.45),
      c.withValues(alpha: _kChromeSolid * 0.15),
      c.withValues(alpha: 0),
    ],
  );
}

/// Bulle reçue (8c) : gris ardoise, liseré blanc 12 % posé dans la bulle.
const Color _kBubbleIn = Color(0xFF2F333B);

/// Bulle envoyée : le cyan d'avant la 8c, gardé ici alors que [SC.accent]
/// est passé au jaune.
const Color _kBubbleMine = Color(0xFF22D3EE);

/// « traduit · voir l'original » (1b : text-muted).
const Color _kMetaMuted = Color(0xFF77777D);

/// Route for a conversation: slides in from the LEFT (toward the right) and,
/// on close, goes back out to the left — the way the closing swipe goes.
Route<void> chatThreadRoute({required WidgetBuilder builder}) {
  return PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (context, _, _) => builder(context),
    transitionsBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween<Offset>(begin: const Offset(-1, 0), end: Offset.zero)
          .animate(
        CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      ),
      child: child,
    ),
  );
}

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
  StreamSubscription<List<MessageReaction>>? _reactionSub;
  Timer? _pollTimer;

  /// Reactions in this thread, keyed by message id. Rebuilt from the
  /// realtime stream (and the web poll) so both sides see a 👍 land live.
  Map<String, List<MessageReaction>> _reactionsByMessage = const {};

  /// La présence du pair n'a pas de canal Realtime : sans ce battement, la
  /// pastille verte de l'en-tête reste celle de l'ouverture du fil.
  Timer? _presenceTimer;

  /// Ticks every minute so the peer's local-time bubble stays current
  /// without the user reopening the thread.
  Timer? _clockTimer;
  List<ChatMessage> _messages = const [];

  /// First snapshot received: only then does an empty list mean "you've never
  /// written to each other" (the empty-thread screen), not "still loading".
  bool _messagesLoaded = false;
  final EntranceTracker _entrance = EntranceTracker();

  /// Typing indicator: I announce when my composer is open; the peer's
  /// "writing…" bubble shows while [_peerTyping].
  TypingSignal? _typing;
  bool _peerTyping = false;
  String _myId = '';
  String _myName = '';
  String _myLang = '';
  String _myGender = '';

  RemoteProfile? _peer;
  bool _sending = false;
  String? _error;

  /// Jusqu'où le pair a lu. Null tant qu'il n'a jamais ouvert le fil — ou tant
  /// que la migration 0054 n'est pas passée, auquel cas aucun « Lu » ne
  /// s'affiche et rien d'autre ne change.
  DateTime? _peerLastRead;
  StreamSubscription<DateTime?>? _peerReadSub;

  /// Publie MA lecture pour que le pair voie son « Lu ». Séparé de
  /// [ChatUnread.markConversationSeen], qui ne sort jamais du téléphone.
  void _publishRead() {
    if (_myId.isEmpty) return;
    unawaited(ChatReads.markRead(
      conversationId: widget.conversationId,
      meId: _myId,
    ));
  }

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
      ).showSnackBar(SnackBar(
          content: Text(AppStrings.t('error_prefix', args: {'msg': '$e'}))));
    }
  }

  @override
  void initState() {
    super.initState();
    // So the in-app "new message" banner (MessageBanner) can suppress
    // itself for this exact conversation — a message that's already
    // appearing live in the list below doesn't need a banner on top of it.
    OpenThread.conversationId.value = widget.conversationId;
    _bootstrap();
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    // A picker pinned to a bubble would float in the wrong place once the
    // list moves — drop it the moment the user scrolls.
    _scrollCtrl.addListener(_MessageBubble.dismissActivePicker);
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

  /// Smart replies for the last peer message: fetched once per message,
  /// dropped as soon as I (or nobody) spoke last.
  List<String> _suggestions = const [];
  String _suggestionsForId = '';

  void _refreshSuggestions() {
    if (_myLang.isEmpty) return;
    // Conversation vide : des phrases d'accroche pour écrire le premier.
    if (_messages.isEmpty) {
      if (!_messagesLoaded || _suggestionsForId == '_opener') return;
      _suggestionsForId = '_opener';
      () async {
        final out = await fetchReplySuggestions(
          lang: _myLang,
          history: const [],
          name: _peer?.displayName ?? '',
        );
        if (!mounted || _suggestionsForId != '_opener') return;
        setState(() => _suggestions = out);
      }();
      return;
    }
    final last = _messages.last;
    if (last.senderId == _myId || last.id.isEmpty) {
      if (_suggestions.isNotEmpty || _suggestionsForId.isNotEmpty) {
        setState(() {
          _suggestions = const [];
          _suggestionsForId = '';
        });
      }
      return;
    }
    // Photos and GIFs carry nothing to answer in words.
    if (last.isImage || last.body.trim().isEmpty) return;
    if (last.id == _suggestionsForId) return;
    _suggestionsForId = last.id;
    final start = _messages.length > 8 ? _messages.length - 8 : 0;
    final history = [
      for (final m in _messages.sublist(start))
        if (m.body.trim().isNotEmpty && !m.isImage)
          TranslationHistoryItem(
            author: m.senderId == _myId ? 'me' : 'peer',
            text: _displayBodyFor(m),
          ),
    ];
    final forId = last.id;
    () async {
      final out = await fetchReplySuggestions(
        lang: _myLang,
        history: history,
        name: _peer?.displayName ?? '',
      );
      // A newer message may have landed while the model was thinking.
      if (!mounted || _suggestionsForId != forId) return;
      setState(() => _suggestions = out);
    }();
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
        // Gardée sur l'appareil : un message ne se réécrit pas, donc le
        // retraduire à chaque ouverture du fil ne fait que repayer la même
        // phrase et la faire clignoter le temps qu'elle revienne.
        //
        // Seulement si le moteur a VRAIMENT traduit : en cas d'échec,
        // fetchTextTranslation rend le texte d'entrée tel quel, et graver ça
        // figerait un message non traduit pour toujours.
        if (out.isNotEmpty && out != m.body) {
          unawaited(TranslationCache.put(
            convId: widget.conversationId,
            lang: _myLang,
            messageId: id,
            translated: out,
          ));
        }
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
    // Et la moitié PARTAGÉE : le pair doit voir son « Lu ». `id` plutôt que
    // [_myId], qui n'est posé que par le setState juste en dessous.
    unawaited(ChatReads.markRead(
      conversationId: widget.conversationId,
      meId: id,
    ));
    if (!mounted) return;
    // « … en train d'écrire » dans les deux sens, tant que le fil est ouvert.
    _typing = TypingSignal(
      conversationId: widget.conversationId,
      myId: id,
      onPeerTyping: (typing) {
        if (mounted) setState(() => _peerTyping = typing);
      },
    )..start();
    setState(() {
      _myId = id;
      _myName = profile?.firstName.trim() ?? '';
      // La langue du COMPTE — celle de l'interface — et pas la langue parlée
      // des préférences locales.
      //
      // Les deux se confondent le plus souvent, mais pas toujours : la langue
      // parlée est celle qu'on a choisie pour être TRANSCRIT en appel, et rien
      // n'oblige quelqu'un dont l'app est en français à parler français. Cette
      // personne-là recevait ses messages traduits vers sa langue parlée, dans
      // une app entièrement en français. Ce qu'on lit doit arriver dans la
      // langue où on lit tout le reste.
      //
      // Le profil DISTANT d'abord : c'est lui qui fait foi pour la langue de
      // compte, un compte étant partagé entre appareils. [AppStrings] ensuite,
      // qui porte la même valeur une fois synchronisée et couvre la lecture
      // distante ratée. La préférence locale en tout dernier, pour ne jamais
      // rendre une chaîne vide — vide, la traduction se tait sans rien dire.
      _myLang = (mine?.language.trim().isNotEmpty ?? false)
          ? mine!.language.trim()
          : (AppStrings.currentBcp47.value.trim().isNotEmpty
              ? AppStrings.currentBcp47.value.trim()
              : (profile?.sourceLang.trim() ?? ''));
      _myGender = (profile?.gender.trim().isNotEmpty ?? false)
          ? profile!.gender.trim()
          : (mine?.gender.trim() ?? '');
      _peer = peer;
      _peerBlocked = blocked;
      _peerBlockedMe = blockedMe;
    });
    // Les messages ont pu arriver avant ma langue : les propositions suivent.
    _refreshSuggestions();

    // Les traductions déjà obtenues, relues du disque AVANT que les messages
    // arrivent : sans ça, le fil s'affiche dans la langue de l'autre puis
    // bascule bulle après bulle, et chaque bascule est une requête payée pour
    // une phrase qu'on avait déjà traduite.
    if (_myLang.isNotEmpty) {
      final cached =
          await TranslationCache.load(widget.conversationId, _myLang);
      if (!mounted) return;
      if (cached.isNotEmpty) {
        setState(() => _translations.addAll(cached));
      }
    }

    if (!isSupabaseReady) {
      setState(
        () => _error =
            'Supabase non configuré — les messages ne sont pas disponibles.',
      );
      return;
    }
    _reactionSub = MessageReactions.subscribeForConversation(
      widget.conversationId,
    ).listen((rows) {
      if (!mounted) return;
      setState(() => _reactionsByMessage = reactionsByMessage(rows));
    });
    // First paint shouldn't wait on the realtime hello — same snapshot the
    // stream will confirm a moment later.
    unawaited(MessageReactions.fetchForConversation(widget.conversationId)
        .then((rows) {
      if (!mounted || rows.isEmpty) return;
      setState(() => _reactionsByMessage = reactionsByMessage(rows));
    }));

    _sub = ChatApi.subscribeMessages(widget.conversationId).listen(
      (rows) {
        if (!mounted) return;
        setState(() {
          _messages = rows;
          _messagesLoaded = true;
          // The realtime channel retries with its own backoff — a delivery
          // reaching here means it recovered, so the "connexion perdue"
          // banner (never cleared before) would otherwise sit there forever.
          _error = null;
        });
        // Lu, puisque le fil est SOUS LES YEUX. Le point de lecture n'était
        // posé qu'à l'ouverture : un message reçu pendant qu'on lisait
        // rallumait le badge de la barre de nav derrière l'écran ouvert, et il
        // fallait ressortir puis revenir pour l'éteindre.
        unawaited(ChatUnread.markConversationSeen(widget.conversationId));
        _publishRead();
        // If auto-translate is on, kick translations for the new arrivals.
        if (_autoTranslate) {
          for (final m in rows) {
            _maybeFetchTranslation(m);
          }
        }
        _refreshSuggestions();
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      },
      onError: (e) {
        if (!mounted) return;
        // Not the raw exception: a Supabase RealtimeSubscribeException's
        // toString() is meaningless to a user ("channelError, details:
        // null") and untranslated. The channel retries on its own; this is
        // purely a "hang tight" notice, cleared above once it reconnects.
        setState(() => _error = AppStrings.t('chat_realtime_lost'));
      },
    );

    // Jusqu'où le pair a lu, en direct : le « Lu » doit apparaître au moment
    // où il ouvre le fil, pas au prochain rechargement.
    _peerReadSub = ChatReads.watchPeerLastRead(
      conversationId: widget.conversationId,
      peerId: widget.peerDeviceId,
    ).listen((at) {
      if (!mounted || at == null) return;
      // Jamais en arrière : un flux peut rejouer une ligne plus ancienne, et
      // un accusé qui recule ferait sauter le « Lu » d'un message à l'autre.
      final cur = _peerLastRead;
      if (cur != null && !at.isAfter(cur)) return;
      setState(() => _peerLastRead = at);
    });

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
        final reacts = await MessageReactions.fetchForConversation(
          widget.conversationId,
        );
        if (!mounted) return;
        final nextReactions = reactionsByMessage(reacts);
        // Only repaint when there's actually a new tail message — keeps
        // the chat from rebuilding constantly while the user is typing.
        final last = _messages.isEmpty ? null : _messages.last.id;
        final freshLast = rows.isEmpty ? null : rows.last.id;
        if (last == freshLast && rows.length == _messages.length) {
          setState(() {
            _reactionsByMessage = nextReactions;
            _messagesLoaded = true;
          });
          return;
        }
        setState(() {
          _messages = rows;
          _messagesLoaded = true;
          _reactionsByMessage = nextReactions;
        });
        if (_autoTranslate) {
          for (final m in rows) {
            _maybeFetchTranslation(m);
          }
        }
        _refreshSuggestions();
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      } catch (_) {
        // Swallow — the realtime sub is the primary path; polling errors
        // shouldn't surface to the user.
      }
    });
  }

  // reverse: true means offset 0 IS the newest message — exact, never an
  // estimate, so there's nothing to guess at on first layout.
  void _scrollToBottom() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    // Only clear if it's still pointing at THIS thread — a second thread
    // opened on top (push another conversation while this one is still in
    // the stack underneath) would otherwise have its own value wiped out
    // by this screen's dispose running after it.
    if (OpenThread.conversationId.value == widget.conversationId) {
      OpenThread.conversationId.value = '';
    }
    _scrollCtrl.removeListener(_MessageBubble.dismissActivePicker);
    _MessageBubble.dismissActivePicker();
    _sub?.cancel();
    _reactionSub?.cancel();
    _peerReadSub?.cancel();
    _typing?.dispose();
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
    final XFile? file;
    final Uint8List bytes;
    try {
      final picker = ImagePicker();
      file = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (file == null) return;
      bytes = await file.readAsBytes();
    } catch (e) {
      if (mounted) setState(() => _error = "Accès à la galerie refusé ou indisponible: $e");
      return;
    }
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
    final safeTop = MediaQuery.paddingOf(context).top;
    // Conversation 1b : la liste occupe TOUT l'écran ; header et footer sont
    // des calques posés dessus, fondus dans le fond (façon Insta / Telegram).
    // La liste leur réserve juste la place de ne pas cacher un message au
    // repos — au défilement, les messages passent dessous et s'y dissolvent.
    // (La pastille « ES → FR » de la maquette a été retirée à la demande.)
    final headerH = safeTop +
        _ThreadHeader.height +
        _TranslatePill.blockHeight +
        (_error != null ? 40 : 0);
    // Hauteur du composer (champ ~50 + 4 dessus + 12 dessous + une part de
    // la safe area, cf. _buildIdleBar) : le fond y reste constant.
    final footerSolid = 70 + MediaQuery.paddingOf(context).bottom * 0.4;
    return Scaffold(
      backgroundColor: _kThreadBg,
      // canPop:false coupe le glissement retour d'iOS (bord gauche → droite) :
      // ici on ne quitte qu'en balayant vers la gauche. Flèche, maybePop et
      // retour Android passent par onPopInvokedWithResult, qui ferme la page.
      body: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) Navigator.of(context).pop();
        },
        child: GestureDetector(
          // Balayer vers la GAUCHE, n'importe où, quitte la conversation.
          onHorizontalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) < -300) Navigator.of(context).maybePop();
          },
          child: Stack(
            children: [
              // ── La liste, plein écran ─────────────────────────────────────
              // Un tap n'importe où ferme le clavier ; translucide pour que la
              // liste défile et que les bulles reçoivent leurs taps.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    FocusScope.of(context).unfocus();
                    _MessageBubble.dismissActivePicker();
                  },
                  child: _buildMessageList(topInset: headerH + 8),
                ),
              ),
              // ── Header : fond constant derrière le prénom et les boutons, puis
              //    un fondu doux de 40 px sous lui. Les boutons sont en verre. ──
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                // Le fond (et son fondu) garde la hauteur d'avant la 8c : la
                // pastille Traduction se pose DANS le fondu, elle n'allonge pas
                // la zone opaque.
                child: Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: headerH - _TranslatePill.blockHeight + _kChromeFade,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: _chromeGradient(
                            solid: headerH - _TranslatePill.blockHeight,
                            top: true,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                    padding: EdgeInsets.only(top: safeTop, bottom: _kChromeFade),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
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
                        // Le réglage de traduction : sous l'en-tête, plus dans
                        // la barre d'écriture (maquette 8c).
                        _TranslatePill(
                          active: _autoTranslate,
                          fromLang: _peer?.language ?? '',
                          toLang: _myLang,
                          onTap: _toggleAutoTranslate,
                        ),
                        if (_error != null) _ErrorBanner(message: _error!),
                      ],
                    ),
                  ),
                  ],
                ),
              ),
              // ── Footer : même fond, inversé — constant derrière le composer,
              //    puis 40 px de fondu doux au-dessus. ─────────────────────────
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    height: _kChromeFade + footerSolid,
                    decoration: BoxDecoration(
                      gradient: _chromeGradient(solid: footerSolid, top: false),
                    ),
                  ),
                ),
              ),
              // Composer en verre posé SUR la conversation.
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
                          // Les propositions, juste au-dessus du champ : seulement
                          // tant que je n'ai rien commencé à écrire.
                          if (_suggestions.isNotEmpty)
                            ValueListenableBuilder<TextEditingValue>(
                              valueListenable: _inputCtrl,
                              builder: (_, v, _) => v.text.trim().isEmpty
                                  ? _SuggestionChips(
                                      suggestions: _suggestions,
                                      onPick: (s) {
                                        _inputCtrl.value = TextEditingValue(
                                          text: s,
                                          selection: TextSelection.collapsed(
                                            offset: s.length,
                                          ),
                                        );
                                      },
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          _Composer(
                            controller: _inputCtrl,
                            sending: _sending,
                            onSend: _send,
                            onSendImage: _sendImage,
                            onSendGif: _sendGif,
                            autoTranslate: _autoTranslate,
                            onTypingChanged: (t) => _typing?.setTyping(t),
                            myLang: _myLang,
                            peerLang: _peer?.language ?? '',
                            peerFirstName: (_peer?.displayName.isNotEmpty == true
                                    ? _peer!.displayName
                                    : widget.title)
                                .trim()
                                .split(RegExp(r'\s+'))
                                .first,
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
    _MessageBubble.dismissActivePicker();
    try {
      await ChatApi.deleteMessage(m.id);
      if (!mounted) return;
      setState(() {
        _messages = _messages.where((x) => x.id != m.id).toList();
        final next = Map<String, List<MessageReaction>>.from(
          _reactionsByMessage,
        );
        next.remove(m.id);
        _reactionsByMessage = next;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Apply [emoji] to [m]. Same emoji again removes it. Optimistic so the
  /// chip lands before the round-trip; the realtime stream is the source
  /// of truth afterwards.
  Future<void> _react(ChatMessage m, String emoji) async {
    if (_myId.isEmpty || m.id.isEmpty) return;
    String? current;
    final existing = _reactionsByMessage[m.id];
    if (existing != null) {
      for (final r in existing) {
        if (r.userId == _myId) {
          current = r.emoji;
          break;
        }
      }
    }
    final next = nextReactionEmoji(current: current, tapped: emoji);
    setState(() {
      final list = [
        ...?_reactionsByMessage[m.id]?.where((r) => r.userId != _myId),
      ];
      if (next != null) {
        list.add(MessageReaction(
          id: 'local-${m.id}-$_myId',
          messageId: m.id,
          conversationId: m.conversationId,
          userId: _myId,
          userName: _myName,
          messageAuthorId: m.senderId,
          emoji: next,
          createdAt: DateTime.now(),
        ));
      }
      _reactionsByMessage = {
        ..._reactionsByMessage,
        m.id: list,
      };
    });
    try {
      await MessageReactions.set(
        messageId: m.id,
        conversationId: m.conversationId.isNotEmpty
            ? m.conversationId
            : widget.conversationId,
        userId: _myId,
        userName: _myName.isEmpty ? 'Moi' : _myName,
        messageAuthorId: m.senderId,
        emoji: emoji,
        currentEmoji: current,
        authorLang: m.senderId == _myId ? _myLang : (_peer?.language ?? ''),
      );
    } catch (e) {
      debugPrint('react failed: $e');
      final rows = await MessageReactions.fetchForConversation(
        widget.conversationId,
      );
      if (!mounted) return;
      setState(() => _reactionsByMessage = reactionsByMessage(rows));
    }
  }

  Widget _buildMessageList({required double topInset}) {
    if (_messages.isEmpty) {
      // Still loading: nothing rather than a "no messages" flash.
      if (!_messagesLoaded) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.only(
          top: topInset,
          bottom: 96 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Stack(
          children: [
            Align(
              // Remonté : photo et phrase au tiers haut, plus au centre.
              alignment: const Alignment(0, -0.55),
              child: SingleChildScrollView(
                child: _EmptyThread(
                  peerName: widget.title,
                  photoUrl: (_peer?.avatarUrl.isNotEmpty ?? false)
                      ? _peer!.avatarUrl
                      : (_peer?.fallbackPhotoUrl ?? ''),
                  peerLang: _peer?.language ?? '',
                  myLang: _myLang,
                ),
              ),
            ),
            if (_peerTyping)
              const Positioned(left: 12, bottom: 0, child: _TypingBubble()),
          ],
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
    // Les messages déjà là à l'ouverture ne s'animent pas (une seule fois).
    if (_messagesLoaded) {
      _entrance.prime([for (final m in _messages) m.id]);
    }

    // Le DERNIER de mes messages que le pair a ouvert : c'est sous celui-là,
    // et lui seul, que « Lu » se pose. Un accusé par bulle ferait une colonne
    // de « Lu » qui ne dit rien de plus — ce qu'on veut savoir, c'est jusqu'où
    // il est allé.
    final readAt = _peerLastRead;
    String? lastReadMineId;
    if (readAt != null) {
      for (final m in _messages) {
        if (m.senderId != _myId) continue;
        if (m.createdAt.isAfter(readAt)) continue;
        lastReadMineId = m.id;
      }
    }

    // La barre de réactions rapides (😂 ❤️ 🔥 👍 +) ne se pose que sous le
    // DERNIER message du pair, et seulement s'il est le dernier du fil et que
    // je n'y ai pas encore réagi : c'est une invitation à répondre, pas un
    // décor à répéter sous chaque bulle.
    String? quickReactId;
    if (_messages.isNotEmpty && _messages.last.senderId != _myId) {
      final last = _messages.last;
      final reacted = (_reactionsByMessage[last.id] ?? const [])
          .any((r) => r.userId == _myId);
      if (!reacted && last.id.isNotEmpty) quickReactId = last.id;
    }

    // Local TTS is local — no cloud cost, available to all tiers.
    //
    // reverse: true — the list's resting position (scroll offset 0) IS the
    // newest message, by construction, with no estimation or post-layout
    // scroll needed. A non-reversed list had to guess maxScrollExtent to
    // jump there instead, and that guess is an *extrapolation* from
    // whichever few items a lazy sliver has actually built (bubbles vary a
    // lot in height — text vs. image) — wrong on a long history, and no
    // more accurate on a later frame since nothing between has actually
    // been measured. `items` stays built oldest→newest exactly as before;
    // only the read direction is inverted here, at the last possible step.
    return ListView.builder(
      controller: _scrollCtrl,
      reverse: true,
      // Haut : la place du header en calque. Bas : celle du composer.
      padding: EdgeInsets.fromLTRB(
        12,
        topInset,
        12,
        // +48 quand la rangée de propositions (44) est posée au-dessus du
        // champ : sans ça les réactions rapides du dernier message viennent
        // se coller contre elles.
        96 +
            (_suggestions.isNotEmpty ? 48 : 0) +
            MediaQuery.paddingOf(context).bottom,
      ),
      // The peer's "writing…" bubble is the newest row: index 0 of the
      // reversed list, under their last message.
      itemCount: items.length + (_peerTyping ? 1 : 0),
      itemBuilder: (ctx, index) {
        if (_peerTyping && index == 0) {
          return const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(top: 6, bottom: 4),
              child: _TypingBubble(),
            ),
          );
        }
        final i = _peerTyping ? index - 1 : index;
        final item = items[items.length - 1 - i];
        if (item.isDay) {
          return _DaySeparator(day: item.day!);
        }
        final m = item.message!;
        final mine = m.senderId == _myId;
        final display = _displayBodyFor(m);
        final bubble = _MessageBubble(
          message: m,
          mine: mine,
          displayBody: display,
          // Reçu ET réellement réécrit par la traduction : la bulle le dit
          // (« traduit · voir l'original ») et peut montrer l'original.
          translated: !mine &&
              display.trim().isNotEmpty &&
              display.trim() != m.body.trim(),
          showQuickReactions: m.id == quickReactId,
          translating: _translatingIds.contains(m.id),
          reactions: _reactionsByMessage[m.id] ?? const [],
          myId: _myId,
          onReact: (emoji) => _react(m, emoji),
          onLongPressDelete: mine ? () => _deleteMessage(m) : null,
          // « 14:35 · lu » sous le dernier de mes messages que le pair a lus.
          read: m.id == lastReadMineId,
        );
        return MessageEntrance(
          key: ValueKey(m.id),
          mine: mine,
          animate: _entrance.take(m.id),
          child: bubble,
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

  static const _hairline = Color(0x1AFFFFFF);
  static const _label = TextStyle(
    fontFamily: 'monospace',
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 1,
    color: Color(0x73F5F7FF),
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
    final p = peer;
    return p != null && isPeerOnline(p);
  }

  /// Hauteur du header sous la safe area (boutons 44 + 8 dessus/dessous).
  static const double height = 60;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Padding(
        // Header transparent (1b) : seuls les boutons ronds portent le verre.
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            // Apple Liquid Glass (natif iOS 26+, verre flouté ailleurs) sur
            // les trois boutons de l'en-tête.
            LiquidGlassButton(
              icon: Icons.arrow_back_rounded,
              sfSymbol: 'arrow.left',
              size: 44,
              iconSize: 20,
              semanticLabel: MaterialLocalizations.of(context).backButtonTooltip,
              onTap: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 10),
            // PDP (sans contour) + point en ligne — tap = profil du pair.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onViewProfile,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  ProfileAvatar(
                    displayName: title,
                    avatarUrl: peer?.avatarUrl,
                    fallbackUrl: peer?.fallbackPhotoUrl,
                    size: 44,
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
            // Middle zone: peer name + local-time, left-aligned. Le swaycø
            // centré a été retiré — la bande d'en-tête ne porte plus que le
            // pair. Plus de logo à contourner, donc plus de largeur bornée :
            // le nom et la ville disposent de toute la bande jusqu'aux boutons
            // d'appel et n'ellipsent que s'ils la remplissent vraiment.
            Expanded(
              child: Builder(
                builder: (context) {
                  // Ombre de texte : le prénom reste lisible quand les
                  // messages passent sous le header transparent.
                  final nameStyle = popupDisplay(
                    fontSize: 16,
                    letterSpacing: -0.3,
                    color: SC.fg,
                  ).copyWith(
                    shadows: const [
                      Shadow(color: Color(0x99000000), blurRadius: 8),
                    ],
                  );
                  // Local copy so the null check promotes (field `clock` cannot).
                  final peerClock = clock;
                  // Country flag once the peer's country is known (the spoken
                  // language doesn't always match the country); language
                  // flag otherwise.
                  final flag = countryFlagFor(peer?.country ?? '') ??
                      (peer?.language.trim().isNotEmpty ?? false
                          ? findLanguageByCode(peer!.language)?.flag
                          : null) ??
                      '';
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onViewProfile,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: nameStyle,
                              ),
                            ),
                            if (flag.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Text(flag, style: const TextStyle(fontSize: 15)),
                            ],
                          ],
                        ),
                        if (peerClock != null)
                          _PeerClockLine(
                            clock: peerClock,
                            place: place,
                          ),
                      ],
                    ),
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
            // Ordre de la maquette 1b : téléphone, puis caméra au bord.
            if (blockedByPeer)
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _DeadCallIcon(icon: Icons.phone_rounded),
                  SizedBox(width: 8),
                  _DeadCallIcon(icon: Icons.videocam_rounded),
                ],
              )
            else
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LiquidGlassButton(
                    icon: Icons.phone_rounded,
                    sfSymbol: 'phone.fill',
                    size: 44,
                    iconSize: 19,
                    semanticLabel: 'Call',
                    onTap: onCall,
                  ),
                  const SizedBox(width: 8),
                  LiquidGlassButton(
                    icon: Icons.videocam_rounded,
                    sfSymbol: 'video.fill',
                    size: 44,
                    iconSize: 19,
                    semanticLabel: 'Video call',
                    onTap: onVideoCall,
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
      width: 44,
      height: 44,
      child: Icon(icon, size: 21, color: SC.fg.withValues(alpha: 0.32)),
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

  static const _orange = Color(0xFFFF9F43);

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(
      color: _orange,
      fontSize: 12,
      fontWeight: FontWeight.w700,
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

class _MessageBubble extends StatefulWidget {
  const _MessageBubble({
    required this.message,
    required this.mine,
    required this.displayBody,
    required this.translating,
    required this.reactions,
    required this.myId,
    required this.onReact,
    this.onLongPressDelete,
    this.translated = false,
    this.showQuickReactions = false,
    this.read = false,
  });
  final ChatMessage message;
  final bool mine;

  /// Mine and the last one the peer has read: « 14:35 · lu » under it.
  final bool read;

  /// Reçu et réécrit par la traduction auto : la bulle affiche « traduit ·
  /// voir l'original » et peut basculer sur le texte d'origine.
  final bool translated;

  /// La barre 😂 ❤️ 🔥 👍 + sous la bulle (dernier message du pair seulement).
  final bool showQuickReactions;

  /// Long-press handler — non-null only for the user's own messages.
  final VoidCallback? onLongPressDelete;

  /// Body text actually rendered — may be the translated version when the
  /// thread-level auto-translate toggle is on.
  final String displayBody;

  /// Show a subtle indicator while the translation is being fetched.
  final bool translating;

  final List<MessageReaction> reactions;
  final String myId;
  final ValueChanged<String> onReact;

  /// The picker currently on screen — at most one, dismissed on scroll /
  /// tap-away / leaving the thread.
  static OverlayEntry? _activePicker;

  static void dismissActivePicker() {
    _activePicker?.remove();
    _activePicker = null;
  }

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  String? _burstEmoji;

  /// « voir l'original » touché : cette bulle montre le texte tel qu'écrit.
  bool _showOriginal = false;

  ChatMessage get message => widget.message;
  bool get mine => widget.mine;
  String get displayBody => widget.translated && _showOriginal
      ? widget.message.body
      : widget.displayBody;
  bool get translating => widget.translating;
  VoidCallback? get onLongPressDelete => widget.onLongPressDelete;

  String? get _myEmoji {
    for (final r in widget.reactions) {
      if (r.userId == widget.myId) return r.emoji;
    }
    return null;
  }

  void _thumbsUp() {
    HapticFeedback.lightImpact();
    setState(() => _burstEmoji = kThumbsUpEmoji);
    widget.onReact(kThumbsUpEmoji);
  }

  void _openPicker() {
    HapticFeedback.mediumImpact();
    _MessageBubble.dismissActivePicker();
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    final size = box.size;
    final pickerWidth = onLongPressDelete == null ? 236.0 : 286.0;
    final screen = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    var left = origin.dx + size.width / 2 - pickerWidth / 2;
    left = left.clamp(12.0, screen.width - pickerWidth - 12);
    var top = origin.dy - 58;
    if (top < pad.top + 8) top = origin.dy + size.height + 8;

    final selected = _myEmoji;
    final entry = OverlayEntry(
      builder: (ctx) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _MessageBubble.dismissActivePicker,
              ),
            ),
            Positioned(
              top: top,
              left: left,
              child: _ReactionPicker(
                selected: selected,
                onPick: (emoji) {
                  _MessageBubble.dismissActivePicker();
                  HapticFeedback.lightImpact();
                  if (mounted) setState(() => _burstEmoji = emoji);
                  widget.onReact(emoji);
                },
                onDelete: onLongPressDelete == null
                    ? null
                    : () {
                        _MessageBubble.dismissActivePicker();
                        onLongPressDelete!();
                      },
              ),
            ),
          ],
        );
      },
    );
    _MessageBubble._activePicker = entry;
    Overlay.of(context).insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    final align = mine ? Alignment.centerRight : Alignment.centerLeft;
    // Envoyé = cyan plein, texte encre ; reçu = gris ardoise liseré, texte
    // blanc. Le petit coin (6) pointe vers l'auteur (maquette 8c).
    final bubbleText = mine ? SC.onAccent : Colors.white;
    final radius = mine
        ? const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomLeft: Radius.circular(20),
            bottomRight: Radius.circular(6),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomLeft: Radius.circular(6),
            bottomRight: Radius.circular(20),
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
        // Le prénom de l'autre n'est plus affiché dans les bulles : il est
        // déjà dans l'en-tête de la conversation.
        // Discover reaction / intro: a small Snapchat-style thumbnail
        // of the photo it was about, with the message stuck below it.
        if (message.hasDiscoverPhoto)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: GestureDetector(
              onTap: () => _openFullImage(context, message.discoverPhoto),
              onDoubleTap: _thumbsUp,
              onLongPress: _openPicker,
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
                    errorBuilder: (_, _, _) => SizedBox(
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
              onDoubleTap: _thumbsUp,
              onLongPress: _openPicker,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: Image.network(
                    message.imageUrl,
                    fit: BoxFit.cover,
                    loadingBuilder: (ctx, child, progress) => progress == null
                        ? child
                        : SizedBox(
                            height: 160,
                            width: 200,
                            child: Center(
                              child: CircularProgressIndicator(
                                color: SC.accentFg,
                                strokeWidth: 2,
                              ),
                            ),
                          ),
                    errorBuilder: (_, _, _) => SizedBox(
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
          _LinkifiedText(
            text: displayBody,
            style: TextStyle(
              color: translating
                  ? bubbleText.withValues(alpha: 0.55)
                  : bubbleText,
              fontSize: 15,
              height: 1.4,
              fontStyle: translating ? FontStyle.italic : FontStyle.normal,
            ),
          ),
      ],
    );

    // Sous la bulle (8c) : « traduit · voir l'original · 14:32 » pour un
    // message reçu traduit, « 14:35 · lu » pour le dernier des miens lu,
    // l'heure seule sinon. Le lien bascule la bulle entre la traduction et
    // le texte tel qu'il a été écrit.
    final metaColor = SC.textPrimary.withValues(alpha: 0.5);
    final meta = Padding(
      padding: EdgeInsets.only(
        top: 4,
        left: mine ? 0 : 6,
        right: mine ? 6 : 0,
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: metaColor, fontSize: 11.5),
        child: widget.translated
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${AppStrings.t('msg_translated')} · '),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        setState(() => _showOriginal = !_showOriginal),
                    child: Text(
                      AppStrings.t(
                        _showOriginal
                            ? 'msg_see_translation'
                            : 'msg_see_original',
                      ),
                      style: TextStyle(
                        decoration: TextDecoration.underline,
                        decorationColor: metaColor,
                      ),
                    ),
                  ),
                  Text(' · $time'),
                ],
              )
            : Text(
                widget.read
                    ? '$time · ${AppStrings.t('chat_read').toLowerCase()}'
                    : time,
              ),
      ),
    );

    final chips = reactionChipEmojis(widget.reactions);

    final bubbleStack = Padding(
        // La puce de réaction déborde SOUS la bulle (1b) : on lui garde la
        // place en bas, plus en haut.
        padding: EdgeInsets.only(top: 4, bottom: chips.isNotEmpty ? 16 : 4),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: _thumbsUp,
              onLongPress: _openPicker,
              child: Container(
                padding: bareMedia
                    ? EdgeInsets.zero
                    : const EdgeInsets.fromLTRB(15, 11, 15, 11),
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
                        color: mine ? _kBubbleMine : _kBubbleIn,
                        borderRadius: radius,
                        border: mine
                            ? null
                            : Border.all(
                                color: SC.stroke.withValues(alpha: 0.12),
                              ),
                      ),
                child: hugContent ? IntrinsicWidth(child: content) : content,
              ),
            ),
            if (chips.isNotEmpty)
              Positioned(
                // À cheval sur le bord BAS de la bulle, côté début (1b).
                bottom: -14,
                left: 10,
                child: _ReactionChip(
                  // New key each time the reaction set changes → the pop
                  // animation replays on every add/change, not just once.
                  key: ValueKey(chips.join()),
                  emojis: chips,
                  count: widget.reactions.length,
                  onTap: () {
                    final mineEmoji = _myEmoji;
                    widget.onReact(mineEmoji ?? chips.first);
                  },
                ),
              ),
            if (_burstEmoji != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: _EmojiBurst(
                    key: ValueKey(_burstEmoji),
                    emoji: _burstEmoji!,
                    onDone: () {
                      if (mounted) setState(() => _burstEmoji = null);
                    },
                  ),
                ),
              ),
          ],
        ),
      );

    return Align(
      alignment: align,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          bubbleStack,
          meta,
          if (widget.showQuickReactions)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 6),
              child: _QuickReactionBar(
                onPick: (emoji) {
                  HapticFeedback.lightImpact();
                  setState(() => _burstEmoji = emoji);
                  widget.onReact(emoji);
                },
                onMore: _openPicker,
              ),
            ),
        ],
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

/// White pill of quick-react emojis, matching the iOS reaction strip.
class _ReactionPicker extends StatelessWidget {
  const _ReactionPicker({
    required this.selected,
    required this.onPick,
    this.onDelete,
  });

  final String? selected;
  final ValueChanged<String> onPick;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xF2FFFFFF),
      elevation: 10,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(28),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final emoji in kQuickReactionEmojis)
              Pressable(
                onTap: () => onPick(emoji),
                scale: 0.88,
                child: Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: selected == emoji
                      ? BoxDecoration(
                          color: const Color(0x22000000),
                          borderRadius: BorderRadius.circular(21),
                        )
                      : null,
                  child: Text(emoji, style: const TextStyle(fontSize: 26)),
                ),
              ),
            if (onDelete != null) ...[
              Container(
                width: 1,
                height: 22,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: const Color(0x22000000),
              ),
              Pressable(
                onTap: onDelete,
                child: const SizedBox(
                  width: 42,
                  height: 42,
                  child: Icon(
                    Icons.delete_outline_rounded,
                    color: Color(0xFF3A3A3C),
                    size: 22,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Instagram/WhatsApp-style tapback sitting astride the bubble's top-right
/// corner. Pops in with a small overshoot — [key] should change whenever the
/// reaction set changes so the animation replays instead of only playing once.
class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    super.key,
    required this.emojis,
    required this.count,
    required this.onTap,
  });

  final List<String> emojis;

  /// Nombre de réactions — « 🔥 1 » (1b).
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 340),
      curve: Curves.elasticOut,
      builder: (context, t, child) =>
          Transform.scale(scale: t, alignment: Alignment.center, child: child),
      child: Material(
        color: const Color(0xFF1C1C1E),
        elevation: 3,
        shadowColor: Colors.black54,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.fromLTRB(7, 3, 7, 3),
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0x33FFFFFF)),
            ),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: emojis.join()),
                  if (count > 0)
                    TextSpan(
                      text: ' $count',
                      style: TextStyle(
                        color: SC.fg,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
              style: const TextStyle(fontSize: 14, height: 1.15),
            ),
          ),
        ),
      ),
    );
  }
}

/// 😂 ❤️ 🔥 👍 + sous le dernier message du pair (1b) : un tap réagit, le +
/// ouvre le sélecteur complet (le même qu'un appui long sur la bulle).
class _QuickReactionBar extends StatelessWidget {
  const _QuickReactionBar({required this.onPick, required this.onMore});

  final ValueChanged<String> onPick;
  final VoidCallback onMore;

  static const _emojis = ['😂', '❤️', '🔥', '👍'];

  /// One glass pill, 36×30 (8c).
  static Widget _pill(Widget child) => Container(
        width: 36,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: SC.fill.withValues(alpha: 0.08), boxShadow: SC.lift,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: SC.stroke.withValues(alpha: 0.14)),
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final e in _emojis) ...[
            Pressable(
              onTap: () => onPick(e),
              scale: 0.85,
              child: _pill(Text(e, style: const TextStyle(fontSize: 15))),
            ),
            const SizedBox(width: 6),
          ],
          Pressable(
            onTap: onMore,
            scale: 0.85,
            child: _pill(
              const Icon(
                Icons.add_reaction_outlined,
                size: 16,
                color: _kMetaMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A handful of the chosen emoji rising and fading — the double-tap burst.
class _EmojiBurst extends StatefulWidget {
  const _EmojiBurst({super.key, required this.emoji, required this.onDone});

  final String emoji;
  final VoidCallback onDone;

  @override
  State<_EmojiBurst> createState() => _EmojiBurstState();
}

class _EmojiBurstState extends State<_EmojiBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  )..forward().whenComplete(widget.onDone);

  static const _dx = <double>[-18, 4, 16, -8, 22];
  static const _delay = <double>[0.0, 0.08, 0.04, 0.14, 0.1];

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Stack(
          children: [
            for (var i = 0; i < _dx.length; i++)
              Positioned.fill(
                child: Align(
                  alignment: Alignment.center,
                  child: Opacity(
                    opacity: (1 - _c.value).clamp(0.0, 1.0),
                    child: Transform.translate(
                      offset: Offset(
                        _dx[i] * _c.value,
                        -86 *
                            Curves.easeOut.transform(
                              (((_c.value - _delay[i]) /
                                          (1 - _delay[i]))
                                      .clamp(0.0, 1.0))
                                  .toDouble(),
                            ),
                      ),
                      child: Text(
                        widget.emoji,
                        style: TextStyle(fontSize: 18 + i.toDouble()),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Renders [text] in [style], with any http(s)/www URL substring underlined
/// and tappable (opens externally via url_launcher). A StatefulWidget rather
/// than an inline TextSpan builder because each link needs its own
/// TapGestureRecognizer, and those must be disposed explicitly — a bare
/// `TapGestureRecognizer()` created straight in a build method leaks.
class _LinkifiedText extends StatefulWidget {
  const _LinkifiedText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<_LinkifiedText> {
  static final _urlRegex = RegExp(
    r'(https?://[^\s]+|www\.[^\s]+)',
    caseSensitive: false,
  );

  final List<TapGestureRecognizer> _recognizers = [];

  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  Future<void> _open(String rawUrl) async {
    final withScheme = rawUrl.startsWith('http') ? rawUrl : 'https://$rawUrl';
    final uri = Uri.tryParse(withScheme);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    _clearRecognizers();
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _urlRegex.allMatches(widget.text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: widget.text.substring(last, m.start)));
      }
      // Trailing punctuation ('.', ',', ')', '!', '?') usually closes the
      // sentence rather than belonging to the URL — keep it out of the link.
      var url = m.group(0)!;
      var trail = '';
      while (url.isNotEmpty && '.,!?)'.contains(url[url.length - 1])) {
        trail = url[url.length - 1] + trail;
        url = url.substring(0, url.length - 1);
      }
      final recognizer = TapGestureRecognizer()..onTap = () => _open(url);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: url,
          recognizer: recognizer,
          style: widget.style.copyWith(
            decoration: TextDecoration.underline,
            decorationColor: widget.style.color,
          ),
        ),
      );
      if (trail.isNotEmpty) spans.add(TextSpan(text: trail));
      last = m.end;
    }
    if (last < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(last)));
    }
    return Text.rich(TextSpan(style: widget.style, children: spans));
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
              style: TextStyle(
                color: SC.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              AppStrings.t('chat_blocked_body'),
              textAlign: TextAlign.center,
              style: TextStyle(
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
          color: SC.fill.withValues(alpha: 0.08), boxShadow: SC.lift,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: SC.stroke.withValues(alpha: 0.16)),
        ),
        child: Text(
          label,
          style: TextStyle(
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
    required this.myLang,
    this.onTypingChanged,
    this.peerLang = '',
    this.peerFirstName = '',
  });

  /// The field just opened (`true`) or closed (`false`) — drives the
  /// "writing…" bubble on the peer's side.
  final ValueChanged<bool>? onTypingChanged;

  /// Langue et prénom du pair — pour « Écris en français, Lucía lit en
  /// espagnol » quand la traduction auto relie deux langues différentes.
  final String peerLang;
  final String peerFirstName;

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

  /// Drives the placeholder only — the switch itself is [_TranslatePill].
  final bool autoTranslate;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer>
    with SingleTickerProviderStateMixin {
  /// Opacité du texte d'aide : 1 = visible, 0 = effacé. S'efface vite quand
  /// on touche le champ, revient en fondu quand on le quitte — plus d'aller-
  /// retour brutal.
  late final AnimationController _hintFade = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 300),
    reverseDuration: const Duration(milliseconds: 150),
  )..addListener(() => setState(() {}));

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

  /// Focus du champ : dès qu'on tape dessus, le texte d'aide s'efface.
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  void _onFocusChanged() {
    if (_focus.hasFocus == _focused) return;
    _focused = _focus.hasFocus;
    widget.onTypingChanged?.call(_focused);
    if (_focused) {
      _hintFade.reverse();
    } else {
      _hintFade.forward();
    }
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    _focus.addListener(_onFocusChanged);
    _hasText = widget.controller.text.trim().isNotEmpty;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _startHintWhenSettled(),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _focus
      ..removeListener(_onFocusChanged)
      ..dispose();
    _hintFade.dispose();
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
    // only after the open transition, so the retype stays visible. Same when
    // the peer's language lands or the translate toggle flips.
    // Retaper seulement si le TEXTE à taper change vraiment (langue du pair
    // arrivée, toggle basculé) — pas à chaque reconstruction du parent.
    if (_hintReady && !_waitingForLangs && _composerHint != _typingFor) {
      _animateHint();
    }
  }

  /// Ce que la machine à écrire tape (ou a fini de taper).
  String? _typingFor;

  /// Vrai tant qu'on attend que les langues arrivent avant de taper.
  bool _waitingForLangs = false;

  /// Tape le texte d'aide une fois qu'il est DÉFINITIF : ma langue et celle
  /// du pair arrivent un instant après l'ouverture, et taper « Écrivez en
  /// Français » pour le remplacer aussitôt par « Écris en français, Lucía
  /// lit en espagnol » cassait l'animation. On patiente 1,2 s au plus.
  void _typeWhenLangsKnown([int waitedMs = 0]) {
    if (!mounted) return;
    final known = widget.myLang.isNotEmpty && widget.peerLang.isNotEmpty;
    if (!known && waitedMs < 1200) {
      _waitingForLangs = true;
      Timer(const Duration(milliseconds: 150),
          () => _typeWhenLangsKnown(waitedMs + 150));
      return;
    }
    _waitingForLangs = false;
    _animateHint();
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
          _typeWhenLangsKnown();
        }
      }

      anim.addStatusListener(onStatus);
    } else {
      _hintReady = true;
      _typeWhenLangsKnown();
    }
  }

  /// Reveal [_composerHint] one character at a time. Cheap setState loop on a
  /// ~75 ms tick — quick enough to feel snappy, slow enough to read.
  void _animateHint() {
    _hintTimer?.cancel();
    final full = _composerHint;
    if (!mounted) return;
    _typingFor = full;
    setState(() => _typedHint = '');
    var shown = 0;
    // Même durée que l'animation d'origine (~1,5 s pour « Écrivez en
    // Français ») quelle que soit la longueur : la phrase longue ne traîne
    // pas 3 s, une courte garde son rythme de 75 ms.
    final tick = (1500 / full.length.clamp(1, 1000)).round().clamp(28, 75);
    _hintTimer = Timer.periodic(Duration(milliseconds: tick), (t) {
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
    final me = widget.myLang.trim().split('-').first;
    final peer = widget.peerLang.trim().split('-').first;
    if (widget.autoTranslate &&
        me.isNotEmpty &&
        peer.isNotEmpty &&
        me != peer &&
        widget.peerFirstName.isNotEmpty) {
      return AppStrings.t(
        'composer_hint_cross',
        args: {
          'me': _langName(me),
          'peer': _langName(peer),
          'name': widget.peerFirstName,
        },
      );
    }
    final lang = findLanguageByCode(widget.myLang);
    if (lang == null) return AppStrings.t('composer_message_hint');
    return AppStrings.t(
      'composer_message_hint_lang',
      args: {'lang': lang.label},
    );
  }

  /// Nom de la langue [code] dans la langue de l'interface (« espagnol »).
  /// En minuscule là où les noms de langue en prennent une (fr, es, it, pt,
  /// nl) — « Écris en français », pas « en Français ».
  static String _langName(String code) {
    final name = AppStrings.t('lang_name_$code');
    if (name == 'lang_name_$code') {
      return findLanguageByCode(code)?.label ?? code.toUpperCase();
    }
    const lower = {'fr', 'es', 'it', 'pt', 'nl'};
    return lower.contains(AppStrings.currentBcp47.value)
        ? name.toLowerCase()
        : name;
  }

  Widget _buildIdleBar() {
    // Lowered: use only part of the bottom safe-area inset so the bar sits a
    // bit closer to the screen edge.
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        4,
        12,
        // Nudged up very slightly (was 6) so the floating bar + photo button
        // sit a touch higher off the bottom edge.
        12 + MediaQuery.paddingOf(context).bottom * 0.4,
      ),
      child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: GlassPanel(
                borderRadius: 27,
                padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      // Hauteur FIXE : un long message défile dans le champ au
                      // lieu de l'agrandir.
                      child: SizedBox(
                        height: 50,
                        child: TextField(
                          controller: widget.controller,
                          focusNode: _focus,
                          enabled: !widget.sending,
                          expands: true,
                          minLines: null,
                          maxLines: null,
                          textAlignVertical: TextAlignVertical.center,
                          textCapitalization: TextCapitalization.sentences,
                          cursorColor: SC.accentFg,
                          style: TextStyle(color: SC.textPrimary),
                          decoration: InputDecoration(
                            // Effacé dès que le champ a le focus.
                            // S'efface / revient en fondu avec le focus.
                            hintText: _hintFade.value == 0 ? null : _typedHint,
                            hintStyle: TextStyle(
                              color: SC.fg.withValues(
                                alpha: 0.55 *
                                    Curves.easeOut.transform(_hintFade.value),
                              ),
                              fontSize: 14,
                              height: 1.25,
                            ),
                            // Deux lignes au plus : « Écris en français, Lucía
                            // lit en espagnol » tient sur deux (maquette 1b).
                            hintMaxLines: 2,
                            filled: false,
                            contentPadding: const EdgeInsets.fromLTRB(
                              4,
                              6,
                              8,
                              6,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                          ),
                          onSubmitted: (_) => widget.onSend(),
                        ),
                      ),
                    ),
                    // La photo, à droite DANS le champ — la place de l'emoji
                    // de la maquette 1b (le chat n'a pas de sélecteur
                    // d'emoji ; il a l'envoi de photo).
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.sending ? null : widget.onSendImage,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        child: Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 23,
                          color: SC.fg.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Le rond jaune (8c) : « GIF » quand le champ est vide, l'envoi
            // dès qu'il y a du texte.
            _CircleActionButton(
              send: _hasText,
              busy: widget.sending,
              onTap: widget.sending
                  ? null
                  : (_hasText ? widget.onSend : widget.onSendGif),
            ),
          ],
        ),
      );
  }

}

class _CircleActionButton extends StatelessWidget {
  const _CircleActionButton({
    required this.send,
    required this.busy,
    required this.onTap,
  });

  /// Text typed → the send arrow; empty field → « GIF ».
  final bool send;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // Le rond d'origine : jaune plein 46, icône GIF (flèche d'envoi dès
    // qu'il y a du texte).
    return Material(
      color: SC.accent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 46,
          height: 46,
          child: Center(
            child: busy
                ? SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: SC.onAccent,
                    ),
                  )
                // Champ vide : le mot « GIF » ; dès qu'il y a du texte : la flèche
                // d'envoi (fondu entre les deux).
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutBack,
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: anim,
                      child: FadeTransition(opacity: anim, child: child),
                    ),
                    child: send
                        ? Icon(
                            Icons.send_rounded,
                            key: const ValueKey('send'),
                            color: SC.onAccent,
                            size: 22,
                          )
                        : Text(
                            'GIF',
                            key: const ValueKey('gif'),
                            style: popupDisplay(
                              fontSize: 14,
                              letterSpacing: 0.2,
                              color: SC.onAccent,
                            ),
                          ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// The translation switch, under the header (8c): « 文A Traduction JA → FR ⬤ ».
/// On = brand gradient, yellow icon and track; off = faint glass.
class _TranslatePill extends StatelessWidget {
  const _TranslatePill({
    required this.active,
    required this.fromLang,
    required this.toLang,
    required this.onTap,
  });

  final bool active;

  /// Peer's language → mine: what the switch translates (« JA → FR »).
  final String fromLang;
  final String toLang;
  final VoidCallback onTap;

  /// 6 above + 36: the room the header reserves for it.
  static const double blockHeight = 42;

  @override
  Widget build(BuildContext context) {
    final from = fromLang.trim().split('-').first.toUpperCase();
    final to = toLang.trim().split('-').first.toUpperCase();
    final pair = from.isNotEmpty && to.isNotEmpty && from != to
        ? '$from → $to'
        : '';
    // Actif : texte blanc sur le dégradé bleu ; inactif : encre (clair) ou blanc 60 %.
    final fg = active ? Colors.white : SC.fgA(0.6);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 36,
            padding: const EdgeInsets.fromLTRB(14, 0, 6, 0),
            decoration: BoxDecoration(
              gradient: active ? SC.brandGradient : null,
              color: active ? null : SC.fg.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: SC.stroke.withValues(alpha: active ? 0.3 : 0.2),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.translate_rounded,
                  size: 18,
                  color: active
                      ? SC.accent
                      : SC.fg.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 9),
                Text(
                  AppStrings.t('call_lang_translation'),
                  style: TextStyle(
                    color: fg,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (pair.isNotEmpty) ...[
                  const SizedBox(width: 9),
                  Text(
                    pair,
                    style: TextStyle(
                      color: fg,
                      fontFamily: 'monospace',
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                const SizedBox(width: 9),
                // The switch: 38×24 track, 18 knob.
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 38,
                  height: 24,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: active
                        ? SC.accent
                        : SC.fg.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: AnimatedAlign(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    alignment:
                        active ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: active ? SC.onAccent : SC.fg,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// « Hello » in each language — the two floating pills of the empty thread.
const Map<String, String> _kHello = {
  'fr': 'Salut',
  'en': 'Hello',
  'es': 'Hola',
  'de': 'Hallo',
  'it': 'Ciao',
  'pt': 'Olá',
  'nl': 'Hoi',
  'ar': 'مرحبا',
  'ru': 'Привет',
  'zh': '你好',
  'ja': 'こんにちは',
  'ko': '안녕하세요',
  'pl': 'Cześć',
  'tr': 'Merhaba',
  'uk': 'Привіт',
  'hi': 'नमस्ते',
};

/// A second way to say hello, for when both sides speak the same language.
const Map<String, String> _kHi = {
  'fr': 'Bonjour',
  'en': 'Hi',
  'es': 'Buenas',
  'de': 'Guten Tag',
  'it': 'Buongiorno',
  'pt': 'Oi',
  'nl': 'Goedendag',
  'ar': 'أهلاً',
  'ru': 'Здравствуй',
  'zh': '您好',
  'ja': 'どうも',
  'ko': '안녕',
  'pl': 'Dzień dobry',
  'tr': 'Selam',
  'uk': 'Вітаю',
  'hi': 'नमस्कार',
};

String _hi(String lang) =>
    _kHi[lang.trim().split('-').first.toLowerCase()] ?? 'Hi';

/// Never written to each other yet (8c, 3b): the peer's photo with three
/// blue waves rippling out, « hello » in their language (yellow) and in
/// mine (glass), and an invitation to write first.
class _EmptyThread extends StatefulWidget {
  const _EmptyThread({
    required this.peerName,
    required this.photoUrl,
    required this.peerLang,
    required this.myLang,
  });

  final String peerName;
  final String photoUrl;
  final String peerLang;
  final String myLang;

  @override
  State<_EmptyThread> createState() => _EmptyThreadState();
}

class _EmptyThreadState extends State<_EmptyThread>
    with SingleTickerProviderStateMixin {
  late final AnimationController _waves = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void dispose() {
    _waves.dispose();
    super.dispose();
  }

  static String _hello(String lang) =>
      _kHello[lang.trim().split('-').first.toLowerCase()] ?? '';

  @override
  Widget build(BuildContext context) {
    final theirs = _hello(widget.peerLang);
    var mine = _hello(widget.myLang);
    // Même langue des deux côtés : la 2e pastille dit « bonjour » autrement.
    if (mine == theirs) mine = _hi(widget.myLang);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 300,
          height: 300,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Three waves, a third of a cycle apart.
              AnimatedBuilder(
                animation: _waves,
                builder: (_, _) => Stack(
                  alignment: Alignment.center,
                  children: [
                    for (var i = 0; i < 3; i++)
                      Builder(
                        builder: (_) {
                          final p = (_waves.value + i / 3) % 1;
                          final eased = Curves.easeOut.transform(p);
                          return Opacity(
                            opacity: (1 - eased) * 0.8,
                            child: Transform.scale(
                              scale: 0.6 + eased,
                              child: Container(
                                width: 150,
                                height: 150,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: SC.brandBlue,
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
              Container(
                width: 132,
                height: 132,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF222222),
                  border: Border.all(color: SC.brandBlue, width: 3),
                ),
                clipBehavior: Clip.antiAlias,
                child: widget.photoUrl.isNotEmpty
                    ? Image.network(
                        widget.photoUrl,
                        fit: BoxFit.cover,
                        alignment: const Alignment(0, -0.44),
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      )
                    : Center(
                        child: ProfileAvatar(
                          displayName: widget.peerName,
                          avatarUrl: null,
                          size: 126,
                          fontSize: 48,
                        ),
                      ),
              ),
              if (theirs.isNotEmpty)
                Positioned(
                  left: 32,
                  top: 76,
                  child: Transform.rotate(
                    angle: -8 * math.pi / 180,
                    child: _HelloPill(text: theirs, yellow: true),
                  ),
                ),
              if (mine.isNotEmpty)
                Positioned(
                  right: 26,
                  bottom: 70,
                  child: Transform.rotate(
                    angle: 6 * math.pi / 180,
                    child: _HelloPill(text: mine, yellow: false),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Text(
            AppStrings.t('no_messages'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: SC.textPrimary.withValues(alpha: 0.7),
              fontSize: 15,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

/// Suggested replies in a row above the composer: glass pills, scrolling
/// sideways when they don't fit. A tap drops the text into the field — it is
/// never sent without the user's own tap on send.
class _SuggestionChips extends StatelessWidget {
  const _SuggestionChips({required this.suggestions, required this.onPick});

  final List<String> suggestions;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: suggestions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) => Pressable(
          onTap: () => onPick(suggestions[i]),
          scale: 0.95,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: SC.fill.withValues(alpha: 0.08), boxShadow: SC.lift,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: SC.stroke.withValues(alpha: 0.18)),
            ),
            child: Text(
              suggestions[i],
              maxLines: 1,
              style: TextStyle(
                color: SC.fg,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The peer is writing — iMessage's bubble: a received-style bubble with
/// three dots rising and brightening one after the other. Pops in.
class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Transform.scale(
        scale: t,
        alignment: Alignment.bottomLeft,
        child: Opacity(opacity: t.clamp(0, 1), child: child),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _kBubbleIn,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomLeft: Radius.circular(6),
            bottomRight: Radius.circular(20),
          ),
          border: Border.all(color: SC.stroke.withValues(alpha: 0.12)),
        ),
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 5),
                Builder(
                  builder: (_) {
                    // Each dot peaks a third of a beat after the previous.
                    final p = (_c.value - i * 0.18) % 1;
                    final wave = p < 0.5 ? math.sin(p * 2 * math.pi) : 0.0;
                    return Transform.translate(
                      offset: Offset(0, -3 * wave),
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white
                              .withValues(alpha: 0.35 + 0.45 * wave),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HelloPill extends StatelessWidget {
  const _HelloPill({required this.text, required this.yellow});

  final String text;
  final bool yellow;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: yellow ? SC.accent : SC.fg.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: yellow
            ? null
            : Border.all(color: SC.stroke.withValues(alpha: 0.3)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: yellow ? SC.onAccent : SC.fg,
          fontSize: 13,
          fontWeight: yellow ? FontWeight.w800 : FontWeight.w700,
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
                    // Reflet : invisible en clair (blanc sur blanc).
                    Colors.white.withValues(alpha: 0.10 * fade * (SC.light ? 0 : 1)),
                    Colors.white.withValues(alpha: 0.28 * fade * (SC.light ? 0 : 1)),
                    Colors.white.withValues(alpha: 0.10 * fade * (SC.light ? 0 : 1)),
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
