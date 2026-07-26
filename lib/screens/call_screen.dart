import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:audioplayers/audioplayers.dart';
import 'package:country_flags/country_flags.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show RealtimeChannel, Supabase;

import '../services/analytics.dart';
import '../services/app_strings.dart';
import '../services/audio_controller.dart';
import '../services/auth_service.dart';
import '../services/call_audio.dart';
import '../services/call_alert.dart';
import '../services/incoming_call_api.dart';
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/permission_priming.dart';
import '../services/profile_api.dart';
import '../swayco/speech/speech_service.dart';
import '../swayco/wire_compat.dart';
import '../services/debug_overlay.dart';
import '../services/usage_tracker.dart';
import '../services/user_prefs.dart';
import '../theme/swayco_theme.dart';
import '../swayco/realtime_translation_port.dart';
import '../swayco/translation_route.dart';
import '../widgets/pressable.dart';
import '../widgets/profile_avatar.dart';
import 'paywall_screen.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.wsUrl,
    required this.jwt,
    required this.roomName,
    required this.displayName,
    required this.mySourceLang,
    required this.translation,
    this.inviteShareText,
    this.isCaller = false,
    this.outgoingCallId,
    this.startWithCamera = false,
    this.peerId,
  });

  final String wsUrl;
  final String jwt;
  final String roomName;
  final String displayName;
  /// The local user's spoken language (BCP-47). The remote participant's
  /// language is read live from their LiveKit metadata.
  final String mySourceLang;
  final RealtimeTranslationPort translation;
  /// When set, the empty-room "waiting" placeholder shows a button that
  /// re-opens the share sheet with this text â€” used by the host of a
  /// guest-invite call so they can resend the link while waiting.
  final String? inviteShareText;

  /// True when the local user initiated this call (dialled out, created
  /// the room or the guest-invite link). Drives the "caller pays"
  /// billing rule: a paying subscriber on the receiving end of a call
  /// is never debited — the cost is borne by whoever started the
  /// session, or by the free side if it's a free-vs-paying mix. Free
  /// users are always debited regardless of which side they are on, so
  /// this flag only affects paying users.
  final bool isCaller;

  /// Caller-only: the `incoming_calls` row id of the ring we sent. When
  /// set, the waiting screen listens for the callee declining and closes
  /// itself instead of ringing into an empty room. Null for the callee
  /// and for guest/live calls that have no ring row.
  final String? outgoingCallId;

  /// Start the call with the local camera ON (a "video" call). When false
  /// the call starts audio-only — the camera stays off and isn't even
  /// requested until the user taps the in-call camera toggle.
  final bool startWithCamera;

  /// Device id of the person on the other end (caller for the callee, callee
  /// for the caller). Used purely to fetch their profile for the "call ended"
  /// summary card (PDP + flag). Null for guest/live calls with no known peer.
  final String? peerId;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Room? _room;
  String? _connectError;
  bool _connecting = true;

  /// Keep the connecting splash on screen for at least this long — LiveKit
  /// often connects in well under a second, so the splash used to flash by
  /// before the caller could read it. Flips true after the timer below.
  bool _minSplashDone = false;
  Timer? _splashTimer;

  /// Once a connected call ends, we swap to a black "call ended" summary card
  /// (peer PDP + flag + duration) instead of popping straight back. These hold
  /// the data that card needs.
  bool _ended = false;
  RemoteProfile? _peerProfile;
  Duration? _finalDuration;

  /// Wraps the shareable part of the summary card so it can be captured to a
  /// PNG and shared ("partager la page").
  final GlobalKey _shareCardKey = GlobalKey();
  /// The blue control rail is folded away behind the chevron until the user
  /// asks for it — the video stays clean. Hang up is never hidden.
  bool _controlsOpen = false;
  /// Ce qui est DIT, transcrit — chaque device dans sa langue. Les lignes ne
  /// vivent que le temps de l'appel (rien n'est persisté).
  final List<_SpokenTurn> _turns = [];

  /// La zone est dépliée : on voit les 4 derniers tours, on peut remonter.
  bool _turnsOpen = false;

  /// Un tour vient d'arriver : le dock s'ouvre en grand pour le montrer, puis
  /// se referme tout seul. Le chevron et le raccrochage s'effacent le temps que
  /// la phrase tienne à l'écran, et la pastille glisse à leur place.
  bool _messageOpen = false;
  Timer? _messageTimer;

  /// Combien de temps la phrase reste dépliée une fois affichée.
  static const Duration _kMessageHold = Duration(milliseconds: 1500);

  /// Plus personne ne parle : le dock s'efface presque entièrement et il ne
  /// reste que la pastille, comme la pilule de Gemini qui se replie en pastille.
  /// Un tap n'importe où dessus le ramène.
  bool _dockDimmed = false;
  Timer? _dockIdleTimer;

  /// Le silence au bout duquel le dock disparaît.
  static const Duration _kDockIdle = Duration(seconds: 4);

  /// Quelque chose vient de se passer (une voix, une phrase, un tap) : le dock
  /// se rallume et repart pour [_kDockIdle] de sursis.
  void _wakeDock() {
    _dockIdleTimer?.cancel();
    _dockIdleTimer = Timer(_kDockIdle, () {
      if (!mounted || _dockDimmed) return;
      // Un panneau ouvert, la légende dépliée : on ne s'efface pas sous les
      // doigts de quelqu'un qui est en train de s'en servir.
      if (_turnsOpen || _controlsOpen) return;
      setState(() => _dockDimmed = true);
    });
    if (_dockDimmed && mounted) setState(() => _dockDimmed = false);
  }

  /// Une phrase vient de s'afficher : on la garde en grand [_kMessageHold],
  /// puis le dock se resserre. Une phrase qui en chasse une autre relance le
  /// compte à rebours plutôt que de le laisser expirer au milieu.
  void _flashMessage() {
    _messageTimer?.cancel();
    if (!_messageOpen) setState(() => _messageOpen = true);
    _messageTimer = Timer(_kMessageHold, () {
      if (!mounted) return;
      setState(() => _messageOpen = false);
    });
  }

  /// Niveau de voix courant (0..1), toutes voix humaines confondues : le max
  /// des [Participant.audioLevel] que LiveKit publie à chaque changement de
  /// locuteur actif. C'est ce qui fait *légèrement* bouger la pastille de
  /// traduction — la TTS, elle, la fait bouger fort ([ttsSpeaking]).
  final ValueNotifier<double> _voiceLevel = ValueNotifier<double>(0);

  void _addTurn(_SpokenTurn turn) {
    if (!mounted || turn.text.trim().isEmpty) return;
    _wakeDock();
    _flashMessage();
    setState(() {
      _turns.add(turn);
      // Un appel long ne doit pas garder la conversation entière en mémoire.
      if (_turns.length > 60) _turns.removeRange(0, _turns.length - 60);
    });
  }

  /// Mon micro vient de produire une phrase : elle s'affiche chez moi dans ma
  /// langue (le pair, lui, reçoit sa traduction par le canal de données).
  void _onMyTranscript() {
    final line = widget.translation.localTranscript?.value;
    if (line == null) return;
    _addTurn(_SpokenTurn(
      mine: true,
      text: line.text,
      delivered: line.delivered,
    ));
  }

  bool _micOn = true;
  late bool _camOn = widget.startWithCamera;
  /// When true, the local self-view fills the screen and the remote feed
  /// lives in the small PiP. Tap either to swap back.
  bool _selfMain = false;
  EventsListener<RoomEvent>? _roomEvents;

  static const String _captionTopic = 'swayco-chat';

  /// Data-channel key carrying "the language I want to hear you in". Sent by the
  /// LISTENER, acted on by the SPEAKER — translation runs on the speaker's side.
  static const String _kListenLangKey = 'listenLang';

  /// Data-channel key carrying "translation is on/off". Shared state: either side
  /// can cut it, and both pipelines stop — see [_toggleTranslation].
  static const String _kTranslationOnKey = 'xlateOn';
  final AudioPlayer _ttsPlayer = AudioPlayer();
  final FlutterTts _deviceTts = FlutterTts();
  String _deviceTtsLang = '';

  /// True exactly while a translation is being SPOKEN, whichever engine speaks
  /// it — the premium voice or the device (`flutter_tts`) one.
  ///
  /// This is NOT [isTranslationPlaying]: that flag is an 800 ms anti-echo gate
  /// that self-clears on a timer whether the voice is still talking or not, and
  /// the mic gate is built on it. This one tracks real playback, from the
  /// engines' own start/complete events, and drives nothing on the audio path —
  /// so wiring it cannot wedge the mic the way a completion-event gate does.
  final ValueNotifier<bool> ttsSpeaking = ValueNotifier<bool>(false);

  /// Ties [ttsSpeaking] to the device engine's own events. `flutter_tts` had no
  /// handlers at all, so nothing knew when an OS voice started or stopped — and
  /// since the in-call language button now speaks through it, that was every
  /// utterance in a language other than the account one.
  void _wireDeviceTtsSignal() {
    _deviceTts.setStartHandler(() => ttsSpeaking.value = true);
    _deviceTts.setCompletionHandler(() => ttsSpeaking.value = false);
    _deviceTts.setCancelHandler(() => ttsSpeaking.value = false);
    _deviceTts.setErrorHandler((_) => ttsSpeaking.value = false);
    // Make speak() resolve when the sentence has FINISHED, not when it starts.
    // Without it the queue below cannot know when to start the next one.
    unawaited(_deviceTts.awaitSpeakCompletion(true));
  }

  /// Translations are SPOKEN one after another, never on top of each other.
  ///
  /// Every speak used to be preceded by `_deviceTts.stop()`, to clear whatever
  /// was queued. When the peer sent two translations a few seconds apart — which
  /// they do, one per phrase — the second one cut the first off mid-sentence. The
  /// user heard "Merci, il est tôt ici donc…" and then silence: nothing was lost
  /// in transit, the player killed it.
  Future<void> _ttsQueue = Future.value();

  /// Bumped by "cut translation" and by leaving the call. An utterance whose
  /// generation is stale is dropped instead of spoken — otherwise the queue would
  /// keep reciting sentences the user has just asked to stop hearing.
  int _ttsGeneration = 0;

  /// Speak [text] after everything already queued. Never interrupts.
  Future<void> _enqueueSpeak(String text, String lang) {
    final generation = _ttsGeneration;
    _ttsQueue = _ttsQueue.then((_) async {
      if (!mounted || generation != _ttsGeneration) return;
      await _speakOne(text, lang);
    }).catchError((Object e) {
      DebugOverlay.log('tts queue error: $e');
    });
    return _ttsQueue;
  }

  /// Kill-switch for the premium on-device (gender-matched) voice. Left as a
  /// switch so a build can force the OS voice for a clean audio test.
  static const bool _kPremiumVoiceEnabled = true;

  /// One utterance, start to finish. The timeout is the queue's safety net:
  /// flutter_tts can return without ever playing (a missing voice, a browser that
  /// suspended speechSynthesis), and then the completion event never comes — which
  /// would wedge every translation behind it for the rest of the call.
  Future<void> _speakOne(String text, String lang) async {
    // Premium on-device voice, but ONLY for the one language whose bundle is
    // already installed — the account language, downloaded at boot. A language
    // picked mid-call is never loaded (a live call can't wait on a 110 MB
    // download), so it falls straight through to the OS voice below. That is the
    // whole "one downloadable language, everything else flutter_tts" rule.
    // Match the voice to the SPEAKER (the peer): a woman's line comes out in a
    // woman's voice. The gender rides on the peer's profile, already loaded for
    // the call — no need to send it over the wire. A language with no gender
    // pair, or an unknown gender, just uses whatever voice is loaded.
    final peerGender = _peerProfile?.gender ?? '';
    if (_kPremiumVoiceEnabled &&
        !kIsWeb &&
        SpeechService.instance.isLoadedFor(lang, gender: peerGender)) {
      await _speakPremium(text, lang);
      return;
    }
    final tag = _voiceTagFor(lang);
    DebugOverlay.log('speak lang=$lang (voice $tag) text="$text"');
    markTranslationPlaying(textLength: text.length);
    try {
      if (tag.isNotEmpty && tag != _deviceTtsLang) {
        try {
          await _deviceTts.setLanguage(tag);
          _deviceTtsLang = tag;
        } catch (_) {}
      }
      await _applyTranslatedVolumeToDeviceTts();
      // Mobile Chrome auto-pauses speechSynthesis after a stretch of inactivity;
      // speak() then plays nothing and fires no event.
      resumeSpeechSynthesisIfPaused();
      await _deviceTts.speak(text).timeout(const Duration(seconds: 20));
      DebugOverlay.log('speak done');
    } catch (e) {
      DebugOverlay.log('speak FAILED: $e');
    } finally {
      markTranslationDone();
    }
  }

  /// Speak with the installed premium on-device voice.
  ///
  /// [speak] returns at playback *start*, and swallows its own errors — a
  /// missing model just returns without playing and fires no completion. So the
  /// gate and [ttsSpeaking] are never left waiting on an event that may not
  /// come: the completion stream only *shortens* the gate's own safety timer,
  /// it is never the sole signal. Subscribe before speaking — a short clip can
  /// finish before the await returns.
  Future<void> _speakPremium(String text, String lang) async {
    final speech = SpeechService.instance;
    DebugOverlay.log('speak lang=$lang (premium voice) text="$text"');
    try {
      final done = speech.onPlaybackComplete.first;
      markTranslationPlaying(textLength: text.length);
      ttsSpeaking.value = true;
      unawaited(done
          .timeout(const Duration(seconds: 15))
          .then((_) => markTranslationDone())
          .catchError((_) {/* the gate's safety timer reopens the mic */})
          .whenComplete(() => ttsSpeaking.value = false));
      await speech.speak(text: text, languageCode: lang);
      DebugOverlay.log('speak done (premium)');
    } catch (e) {
      ttsSpeaking.value = false;
      markTranslationDone();
      DebugOverlay.log('premium speak FAILED: $e');
    }
  }

  /// Drop everything still waiting to be spoken, and silence what is playing.
  /// Used by "cut translation" and on leaving the call — the only two places a
  /// translation is genuinely no longer wanted.
  void _cancelQueuedSpeech() {
    _ttsGeneration++;
    unawaited(_deviceTts.stop());
    if (!kIsWeb) unawaited(SpeechService.instance.stop());
    ttsSpeaking.value = false;
    markTranslationDone();
  }

  /// Base code → the FULL tag the OS actually knows (`ja` → `ja-JP`).
  ///
  /// iOS resolves a voice with `AVSpeechSynthesisVoice(language:)`, which wants
  /// the region: hand it a bare `ja` and it finds nothing, returns nil, and the
  /// system quietly falls back to its default voice — so the Japanese translation
  /// was being read out in French. Speak through the tag the device gave us, not
  /// the base code we derived from it.
  Map<String, String> _deviceVoiceTags = const {};

  /// Ask the OS which languages it can speak. `getLanguages` returns BCP-47 tags
  /// (`fr-FR`, `en-US`, …); the picker works in base codes.
  Future<void> _loadDeviceVoiceLangs() async {
    try {
      final raw = await _deviceTts.getLanguages;
      if (raw is! List) return;
      final tags = <String, String>{};
      for (final t in raw) {
        if (t == null) continue;
        final full = t.toString().trim();
        if (full.isEmpty) continue;
        final base = full.toLowerCase().split(RegExp(r'[-_]')).first;
        if (base.isEmpty) continue;
        // First one wins: getLanguages lists the device's own preferred order.
        tags.putIfAbsent(base, () => full);
      }
      if (!mounted || tags.isEmpty) return;
      DebugOverlay.log('device voices: ${tags.length} langs');
      setState(() => _deviceVoiceTags = tags);
    } catch (e) {
      debugPrint('[speech] getLanguages failed: $e');
    }
  }

  /// The tag to hand flutter_tts for [lang] — the device's own (`ja-JP`) when we
  /// know it, the bare code otherwise (the probe may not have answered yet).
  String _voiceTagFor(String lang) {
    final base = lang.toLowerCase().split(RegExp(r'[-_]')).first;
    return _deviceVoiceTags[base] ?? lang;
  }

  /// Whether WE want to hear the peer translated. Toggle via
  /// [_toggleTranslation]; purely our own ear — the peer keeps hearing us
  /// translated unless they cut it on their side.
  bool _translationEnabled = true;

  /// Whether the PEER wants to hear us translated. False once they cut it on
  /// their side, and then our pipeline stops — we are the one who translates our
  /// voice into their language. Assumed true until they say otherwise (a peer on
  /// an older build never sends the key).
  bool _peerWantsTranslation = true;

  /// The target BCP-47 the translation pipeline is currently attached with, so
  /// we only re-attach when it actually changes.
  String _attachedTargetLang = '';

  /// Same, for the source: a source-only change leaves the target untouched, so
  /// without this the re-attach would be short-circuited and the input language
  /// button would do nothing.
  String _attachedSourceLang = '';

  /// The language this phone TRANSCRIBES its own mic in. Starts at the account
  /// language and is changeable mid-call via the input language button.
  ///
  /// Unlike [_myOutputLang] this is a purely local concern — the peer never
  /// needs to know it, because we ship them translated text, not audio. What it
  /// costs is a pipeline restart: `attachToRoom` tears the mic streamer down and
  /// the on-device engine reloads with the new `language:` (no download — the
  /// universal model covers every language in [supportedLanguages]).
  late String _mySourceLang = widget.mySourceLang;

  /// Ce qu'affiche la zone de légende tant que personne n'a parlé : « Parle
  /// japonais » — la langue que CE téléphone s'est engagé à parler pour cet
  /// appel. C'est le seul endroit où elle a besoin d'être rappelée, et il tombe
  /// pile là où les phrases vont apparaître.
  String get _speakLangHint {
    final base = _mySourceLang.split('-').first.toLowerCase();
    if (base.isEmpty) return '';
    final named = AppStrings.t('lang_name_$base');
    // Pas de nom traduit pour cette langue : son nom natif fait l'affaire.
    final name = named.startsWith('lang_name_')
        ? (findLanguageByCode(base)?.label ?? '')
        : named;
    if (name.isEmpty) return '';
    // Ces langues-là écrivent les noms de langue en minuscule ; les autres
    // (anglais, allemand, néerlandais…) les capitalisent.
    const lowercasesLangNames = {'fr', 'es', 'it', 'pt'};
    final shown = lowercasesLangNames.contains(AppStrings.currentBcp47.value)
        ? name[0].toLowerCase() + name.substring(1)
        : name;
    return AppStrings.t('call_captions_hint', args: {'lang': shown});
  }


  /// The language the local user currently *hears* the remote translated into.
  /// Starts at the user's own language; changeable mid-call via the language
  /// button.
  ///
  /// Translation happens on the SPEAKER's side — this phone transcribes its own
  /// mic, translates into the language the *peer* wants, and ships the text over
  /// the data channel for the peer to speak. So changing this does nothing
  /// locally: it is broadcast to the peer ([_kListenLangKey]), and it is THEIR
  /// pipeline that starts translating into it. The only local effect is which
  /// voice speaks the text they send back.
  late String _myOutputLang = widget.mySourceLang;

  /// The language the REMOTE user wants to hear us in — i.e. our translation
  /// target. Defaults to their account language (read from their LiveKit
  /// metadata) and is overridden the moment they tap their own language button.
  String _peerListenLang = '';

  /// The output language we last announced to the peer, so a re-announce on
  /// their (re)connect doesn't republish on every metadata event.
  String _announcedOutputLang = '';
  bool _refreshingTranslation = false;
  /// Set when an event arrives while a refresh is in flight; we re-run once
  /// the in-flight call completes so the latest state is reflected.
  bool _refreshPending = false;

  late final AudioController _audio = AudioController(translation: widget.translation);
  bool _lastTranslationSpeaking = false;
  /// Accumulates real translation-live time (runs only while the live engine
  /// pipeline is live). Reported as `translation_ms` on the call_ended
  /// analytics event so the admin can cost the live engine against actual
  /// translation time rather than whole-call time.
  final Stopwatch _translationLive = Stopwatch();
  /// Set to true the first time any RemoteParticipant joins the room.
  /// Used by the ParticipantDisconnectedEvent handler to distinguish
  /// "caller waiting alone before pickup" (empty + !_hadRemote â†’ keep
  /// the room open) from "peer just left a 1:1 call" (empty +
  /// _hadRemote â†’ auto-hangup so we don't burn credits on a ghost room).
  bool _hadRemote = false;

  /// Caller-only: realtime channel that listens for the callee declining
  /// our ring so the waiting screen can close. Null for the callee and
  /// for calls with no ring row. Removed on teardown.
  RealtimeChannel? _declineChannel;
  /// Guards [_onDeclinedByCallee] / [_onRingTimeout] so we pop / snackbar at
  /// most once.
  bool _declinedHandled = false;

  /// Caller-only ring timeout. The decline signal is a best-effort realtime
  /// broadcast — the web build frequently misses it, and a powered-off callee
  /// can't send it at all — so without this the caller could ring into an
  /// empty room forever. Armed only for direct friend rings (an
  /// [outgoingCallId]); guest-invite waits have no timeout.
  Timer? _ringTimeout;

  /// When the LiveKit room finished connecting â€” null until then. Used
  /// to emit the analytics `call_ended` duration from [dispose] (which
  /// always runs, whatever the exit path: hang-up, peer-left, back nav).
  DateTime? _connectedAt;

  /// Guard against showing the invite-friends popup twice in the same
  /// call session — fires once on the credits-exhaustion edge AND once
  /// at init time when credits were already 0 at call start (the
  /// notifier was already `true` from a previous call, so addListener
  /// won't re-fire on the second set-to-true).
  bool _inviteDialogShown = false;

  /// `guest` / `live` / `friend`, inferred from the room-name prefix the
  /// backend mints. Tags every call analytics event.
  String get _callKind {
    final n = widget.roomName;
    if (n.startsWith('guest-')) return 'guest';
    if (n.startsWith('live-')) return 'live';
    return 'friend';
  }

  void _onTranslationStateChanged() {
    _syncTranslationSpeaking();
    _syncUsageMeter();
  }

  /// Silence the peer's real voice for exactly the window a translation is
  /// audible, from EITHER source.
  ///
  /// [RealtimeTranslationPort.translationSpeaking] only ever covers the cloud
  /// mp3 player, so on the local-TTS path — the default on mobile — nothing was
  /// ducking anything: the peer kept talking underneath their own translation
  /// and the two voices piled up. [ttsSpeaking] is the missing half.
  ///
  /// Nothing upstream is touched: the peer keeps speaking, keeps transcribing
  /// and keeps sending; we only stop *playing* their voice out of this speaker,
  /// and our own mic goes on capturing.
  void _syncTranslationSpeaking() {
    final speaking = ttsSpeaking.value || widget.translation.translationSpeaking;
    if (speaking == _lastTranslationSpeaking) return;
    _lastTranslationSpeaking = speaking;
    _audio.onTranslationSpeaking(speaking);
  }

  /// Translation credits should only burn while the live pipeline is
  /// actually live â€” not for the whole call. Pause the meter while
  /// waiting for the peer / connecting / idle, resume it once the live engine is
  /// connected and translating.
  void _syncUsageMeter() {
    final live = widget.translation.translationFeedbackPhase ==
        TranslationFeedbackPhase.live;
    // The stopwatch tracks real translation time for the cost analytics â€”
    // kept running even when UsageTracker is disabled (test mode).
    if (live) {
      _translationLive.start();
    } else {
      _translationLive.stop();
    }
    if (UsageTracker.isDisabled) return;
    if (live) {
      UsageTracker.resume();
    } else {
      UsageTracker.pause();
    }
  }

  void _onRoomChanged() {
    if (mounted) setState(() {});
  }

  /// Parse `participant.metadata` (set as JSON in the JWT) and return the
  /// remote's `sourceLang` if present. Returns empty string on any failure.
  String _remoteLangFromMetadata(Participant p) {
    final raw = p.metadata?.trim() ?? '';
    if (raw.isEmpty) return '';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final v = decoded['sourceLang'];
        if (v is String) return v.trim();
      }
    } catch (e) {
      debugPrint('CallScreen: failed to parse remote metadata: $e');
    }
    return '';
  }

  /// Returns the first remote participant whose metadata carries a sourceLang.
  String _discoverRemoteLang(Room room) {
    for (final p in room.remoteParticipants.values) {
      final lang = _remoteLangFromMetadata(p);
      if (lang.isNotEmpty) return lang;
    }
    return '';
  }

  /// Re-attach the translation pipeline whenever the remote's language
  /// becomes known or changes. With an empty remote language the route is
  /// not configured and the pipeline stays idle. Serialized so concurrent
  /// participant / metadata events do not race the pipeline's own teardown.
  Future<void> _refreshTranslationBinding(Room room) async {
    if (_refreshingTranslation) {
      _refreshPending = true;
      return;
    }
    _refreshingTranslation = true;
    try {
      do {
        _refreshPending = false;
        // We translate for the PEER, so the target is what the peer asked to
        // hear ([_peerListenLang], set by their language button) and otherwise
        // their account language from metadata.
        final target = _peerListenLang.isNotEmpty
            ? _peerListenLang
            : _discoverRemoteLang(room);
        // A metadata update can momentarily report no language for a peer that
        // is still in the room (observed: `attach src=en tgt=`). Re-attaching on
        // that gives an unconfigured route, which tears the pipeline down and
        // never brings it back. Keep the last known language instead.
        if (target.isEmpty &&
            _attachedTargetLang.isNotEmpty &&
            room.remoteParticipants.isNotEmpty) {
          DebugOverlay.log(
              'translation: ignoring empty remote lang, keeping $_attachedTargetLang');
          continue;
        }
        // The peer may have joined after we picked a language — re-announce so
        // they translate into it rather than into our account language.
        _announceOutputLang(room);
        if (target == _attachedTargetLang &&
            _mySourceLang == _attachedSourceLang) {
          continue;
        }
        _attachedTargetLang = target;
        _attachedSourceLang = _mySourceLang;
        final route = TranslationRoute(
          // Our mic, our real spoken language — never the language we listen in.
          sourceBcp47: _mySourceLang,
          targetBcp47: target,
        );
        await widget.translation.attachToRoom(room, route: route);
        // Pre-warm the TTS engine: setLanguage loads the voice, then a
        // zero-volume silent speak forces the browser to initialise the
        // synthesis pipeline so the first real translation plays instantly.
        if (_myOutputLang.isNotEmpty && kIsWeb) {
          unawaited(() async {
            try {
              await _deviceTts.setLanguage(_voiceTagFor(_myOutputLang));
              await _deviceTts.setVolume(0.0);
              await _deviceTts.speak(' ');
              await _deviceTts.stop();
              await _deviceTts.setVolume(1.0);
            } catch (_) {}
          }());
        } else if (_myOutputLang.isNotEmpty) {
          unawaited(_deviceTts.setLanguage(_voiceTagFor(_myOutputLang)).catchError((_) {}));
        }
      } while (_refreshPending && mounted);
    } finally {
      _refreshingTranslation = false;
    }
  }

  /// Poll-rebind translation until the remote's spoken language is known.
  /// Covers the second-joiner case: a peer already in the room when we connect
  /// emits no ParticipantConnectedEvent, and their JWT metadata (which carries
  /// their language) can hydrate a beat after connect — so the first bind ran
  /// blind (remote lang unknown) and nothing retried. That's the "only one
  /// side hears the translation" bug.
  Future<void> _rebindUntilRemoteLangKnown(Room room) async {
    for (var i = 0; i < 12; i++) {
      if (!mounted) return;
      if (_discoverRemoteLang(room).isNotEmpty) {
        await _refreshTranslationBinding(room);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  @override
  void initState() {
    super.initState();
    widget.translation.localTranscript?.addListener(_onMyTranscript);
    Analytics.track('screen_view', props: {'screen': 'live'});
    _start();
    // Hold the connecting splash for a minimum of 5s so it is actually
    // readable even when the room connects almost instantly.
    _splashTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _minSplashDone = true);
    });
    unawaited(_loadPeerProfile());
    _wireDeviceTtsSignal();
    ttsSpeaking.addListener(_syncTranslationSpeaking);
    unawaited(_loadDeviceVoiceLangs());
    unawaited(_initUsageTracking());
    _wakeDock();
    UsageTracker.creditsExhausted.addListener(_onCreditsExhausted);
    // Caller waiting for pickup: listen for the callee declining so we
    // can close this screen instead of ringing into an empty room.
    final callId = widget.outgoingCallId;
    if (widget.isCaller && callId != null && callId.isNotEmpty) {
      _declineChannel = IncomingCallApi.subscribeDecline(
        callId: callId,
        onDeclined: _onDeclinedByCallee,
      );
      // Safety net for the lost-broadcast / powered-off-callee cases above:
      // leave the waiting room after the ring window if nobody joined.
      _ringTimeout = Timer(const Duration(seconds: 25), _onRingTimeout);
    }
  }

  /// Ring window elapsed with no one joining — the callee declined (and the
  /// broadcast was lost), their phone was off, or they simply didn't answer.
  /// Same teardown as a decline, with a "no answer" message.
  void _onRingTimeout() {
    if (_declinedHandled || _hadRemote || !mounted) return;
    _declinedHandled = true;
    CallAlert.stop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.t('call_no_answer'))),
    );
    unawaited(_hangUp());
  }

  /// Best-effort fetch of the peer's profile (PDP + language) for the
  /// "call ended" summary card. Silent on any failure — the card just falls
  /// back to an initial-letter avatar and no flag.
  Future<void> _loadPeerProfile() async {
    final id = widget.peerId;
    if (id == null || id.isEmpty) return;
    try {
      final p = await ProfileApi.fetchById(id);
      if (mounted && p != null) {
        setState(() => _peerProfile = p);
        // Same gender, second use: the translator needs it to agree on the
        // person we are talking TO. Japanese marks no gender, so "あなたは新しい
        // 方ですか" is otherwise rendered "tu es nouveau/nouvelle ici ?" — and the
        // TTS reads the slash out loud.
        widget.translation.peerGender = p.gender;
        // Both halves of my language's voice were fetched at boot; now that the
        // peer's gender is known, configure the matching one so the very first
        // translation already speaks in the right voice. From disk — no
        // download, and it no-ops when the gender is already the loaded one.
        if (!kIsWeb && _myOutputLang.isNotEmpty && p.gender.isNotEmpty) {
          unawaited(SpeechService.instance.ensureLanguageInstalled(
            _myOutputLang,
            gender: p.gender,
          ));
        }
      }
    } catch (_) {
      // Offline / not found — summary degrades gracefully.
    }
  }

  /// The callee declined our ring. As long as they haven't actually
  /// joined yet ([_hadRemote] still false), stop waiting: silence the
  /// dial tone, tell the user, and close the call screen.
  void _onDeclinedByCallee() {
    if (_declinedHandled || _hadRemote || !mounted) return;
    _declinedHandled = true;
    CallAlert.stop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.t('call_declined'))),
    );
    unawaited(_hangUp());
  }

  /// Pull the user's current credit balance and start the call timer. The
  /// call itself runs regardless â€” we just decide whether translation is
  /// allowed on top.
  Future<void> _initUsageTracking() async {
    final uid = AuthService.currentUserId;
    if (uid.isEmpty) return;
    final p = await ProfileApi.fetchById(uid);
    if (!mounted || p == null) return;
    // "Caller pays" rule: a paying subscriber who is not the caller of
    // this session is never debited. Their abonnement covers it. Free
    // users fall through and are always debited (free vs free → both
    // sides pay; free vs paying → only the free side pays).
    if (p.isPro && !widget.isCaller) {
      debugPrint(
        '[usage] paying callee — skipping tracker '
        '(tier=${p.subscriptionTier})',
      );
      return;
    }
    UsageTracker.start(userId: uid, initialCredits: p.creditsSeconds);
    if (UsageTracker.isDisabled) return;
    // Don't bill the whole call â€” only while translation is live. Set the
    // meter to whatever the pipeline's state is right now.
    _syncUsageMeter();
    if (p.creditsSeconds <= 0) {
      // Already empty before the call started â€” kill translation now,
      // and surface the invite-friends popup directly (the
      // `creditsExhausted` listener won't fire because the notifier
      // was already `true` from a prior session, so no value change).
      await widget.translation.detach();
      if (mounted && !_inviteDialogShown) {
        unawaited(_showOutOfCreditsDialog());
      }
    }
  }

  /// Triggered when credits hit 0 mid-call. We detach the translation
  /// pipeline so the live session stops billing, but leave the LiveKit
  /// connection alone so people can keep talking (untranslated). Then
  /// surface the "Invite 3 amis = +30 min" dialog so the user has a
  /// concrete way to earn more time without forcing them to upgrade.
  void _onCreditsExhausted() {
    if (!UsageTracker.creditsExhausted.value) return;
    unawaited(widget.translation.detach());
    if (!mounted) return;
    if (_inviteDialogShown) return;
    unawaited(_showOutOfCreditsDialog());
  }

  /// Modal shown when the user is out of translation credits: a quick
  /// "Oups… plus de crédits" with a Recharger button that opens the paywall.
  Future<void> _showOutOfCreditsDialog() async {
    _inviteDialogShown = true;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        // Match the _TipDialog surface (root_shell.dart) — SC.bg would
        // bleed the popup into the mesh background, so we anchor to the
        // same near-black the post-onboarding tips use.
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
              Container(
                width: 88,
                height: 88,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: SC.accent.withValues(alpha: 0.15),
                ),
                child: const Icon(
                  Icons.bolt_rounded,
                  color: SC.accent,
                  size: 44,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                AppStrings.t('out_of_credits_title'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                AppStrings.t('out_of_credits_body'),
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
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    unawaited(showPaywallSheet(context));
                  },
                  child: Text(AppStrings.t('out_of_credits_cta')),
                ),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(
                  AppStrings.t('invite_bonus_later'),
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _start() async {
    // Pre-permission priming: the mic is essential to a call, so we never
    // fire the OS prompt cold. Explain why first; if the user declines the
    // rationale we abort without burning the one-shot iOS prompt.
    if (!(await Permission.microphone.status).isGranted) {
      if (!mounted) return;
      final ok = await PermissionPriming.show(
        context,
        icon: Icons.mic_rounded,
        title: AppStrings.t('mic_prime_title'),
        body: AppStrings.t('mic_prime_body'),
        confirmLabel: AppStrings.t('mic_prime_enable'),
      );
      if (!ok) {
        if (mounted) {
          setState(() {
            _connecting = false;
            _connectError = AppStrings.t('call_perm_required');
          });
        }
        return;
      }
    }
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      setState(() {
        _connecting = false;
        _connectError = AppStrings.t('call_perm_required');
      });
      return;
    }
    // Camera permission is only needed for a video call. Audio calls never
    // touch the camera (it can still be turned on later from the in-call
    // toggle, which requests permission then).
    if (widget.startWithCamera) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        setState(() {
          _connecting = false;
          _connectError = AppStrings.t('call_perm_required');
        });
        return;
      }
    }

    // Android 12+ requires BLUETOOTH_CONNECT at runtime before in-call
    // audio can be routed to a Bluetooth headset. Ask once here, but
    // never block the call on it â€” a refused grant just keeps audio on
    // the speaker/earpiece. No-op on iOS / web (the OS auto-routes).
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await Permission.bluetoothConnect.request();
    }

    final room = Room();
    try {
      await room.connect(widget.wsUrl, widget.jwt);
      // For the callee, the caller is already in the room at connect
      // time â†’ ParticipantConnectedEvent never fires for them and our
      // `_hadRemote` flag would otherwise stay false, defeating the
      // "auto-hangup when peer leaves" logic. Seed the flag from the
      // initial participant snapshot.
      if (room.remoteParticipants.isNotEmpty) {
        _hadRemote = true;
      }
      await room.localParticipant?.setCameraEnabled(widget.startWithCamera);
      // EC + NS on, AGC OFF. Rationale: the translation pipeline plays
      // a second audio stream on the speakers that the browser's EC
      // doesn't fully account for, so any captured leak goes back into
      // LiveKit. AGC then amplifies that leak each loop and the
      // feedback runs away to infinity. Without AGC the captured leak
      // stays below its source and decays naturally.
      await room.localParticipant?.setMicrophoneEnabled(
        true,
        audioCaptureOptions: const AudioCaptureOptions(
          echoCancellation: true,
          // Noise suppression OFF, and the reason is not the noise: livekit
          // sends `voiceIsolation` as a COPY of this flag
          // ({'voiceIsolation': noiseSuppression} in AudioCaptureOptions), so
          // leaving it on silently ran Apple's Voice Isolation over every
          // captured word. That is what the peer heard as a hollow, reverberant
          // "in a room" voice: the algorithm rebuilds the speech instead of
          // carrying it. There is no way to keep one and drop the other through
          // this API. Echo cancellation is untouched.
          noiseSuppression: false,
          // AGC back ON — this is what makes a call sound "flat and settled"
          // rather than swelling and dipping: it levels every word, and it is
          // the single biggest difference between our audio and a normal phone
          // app's.
          //
          // It was turned off for a reason that no longer exists. AGC's job is
          // to pull quiet things up, and what used to be quiet on this mic was
          // the leak from the SECOND capture — so AGC amplified it until the
          // audio ran away. That second capture is gone (the STT now reads
          // WebRTC's own), and with a single clean capture there is no leak left
          // to amplify.
          //
          // KNOWN RISK, on the record: an earlier build with AGC on produced
          // crackling at idle. It is on its own here, so if that returns it is
          // unambiguously this line — flip it back to false.
          autoGainControl: true,
        ),
      );
      // First attach with whatever remote-lang we already know (often nothing
      // yet). Refreshed dynamically as participants join / metadata arrives.
      await _refreshTranslationBinding(room);
      room.addListener(_onRoomChanged);
      _roomEvents = room.createListener()
        ..on<TrackSubscribedEvent>((_) {
          // The peer's audio (and the participant metadata carrying their
          // language) is now here — (re)bind translation in case the remote
          // language wasn't known at connect time.
          unawaited(_refreshTranslationBinding(room));
          if (mounted) setState(() {});
        })
        ..on<TrackUnsubscribedEvent>((_) {
          if (mounted) setState(() {});
        })
        ..on<LocalTrackPublishedEvent>((_) {
          if (mounted) setState(() {});
        })
        // Turning a camera on/off mutes/unmutes its track. Rebuild so the
        // camera-off tile replaces the frozen last frame (and vice versa).
        ..on<TrackMutedEvent>((_) {
          if (mounted) setState(() {});
        })
        ..on<TrackUnmutedEvent>((_) {
          if (mounted) setState(() {});
        })
        // Qui parle, et à quel volume — la liste arrive triée, le plus fort en
        // tête. Sert uniquement à animer la pastille de traduction : aucune
        // décision audio ne s'appuie dessus.
        ..on<ActiveSpeakersChangedEvent>((e) {
          final loudest = e.speakers.isEmpty ? 0.0 : e.speakers.first.audioLevel;
          _voiceLevel.value = loudest.clamp(0.0, 1.0);
          if (loudest > 0.06) _wakeDock();
        })
        // In-call typed-chat messages from the peer.
        ..on<DataReceivedEvent>(_onCaptionData)
        ..on<ParticipantConnectedEvent>((_) {
          // First remote joining = call answered â†’ silence the caller's
          // dial tone (no-op on native via the stub).
          CallAlert.stop();
          _hadRemote = true;
          unawaited(_refreshTranslationBinding(room));
          if (mounted) setState(() {});
        })
        ..on<ParticipantDisconnectedEvent>((_) {
          unawaited(_refreshTranslationBinding(room));
          if (mounted) setState(() {});
          // 1:1 calls only â€” if we had a peer and they just left,
          // there's no reason to keep the room (or our credit meter)
          // running. Auto-hangup so the caller doesn't burn minutes
          // sitting alone in an empty room.
          if (_hadRemote && room.remoteParticipants.isEmpty && mounted) {
            unawaited(_hangUp());
          }
        })
        ..on<ParticipantMetadataUpdatedEvent>((_) {
          unawaited(_refreshTranslationBinding(room));
          if (mounted) setState(() {});
        });
      // A participant may have joined in the window between connect() and
      // this listener being attached â€” very likely in live calls where
      // both peers join at once, and the slow translation setup above
      // widens the window. That ParticipantConnectedEvent would be missed,
      // leaving _hadRemote false and defeating the auto-hangup when the
      // peer later leaves. Re-seed from the current snapshot so both sides
      // are sent back to the live screen when either one ends the call.
      if (room.remoteParticipants.isNotEmpty) {
        _hadRemote = true;
        // Peer was already here when we joined → no ParticipantConnectedEvent
        // fires for us, so keep re-binding until their language is known.
        unawaited(_rebindUntilRemoteLangKnown(room));
      }
      await _audio.bind(room);
      // Call audio starts on the EARPIECE (AudioController's default), like an
      // ordinary phone call; the loudspeaker is one tap away in the rail. A
      // plugged-in headset overrides both, at the OS level.
      widget.translation.translationListenable?.addListener(_onTranslationStateChanged);
      // Reset the global mic-mute flag — it persists across re-attaches.
      setSendMuted(false);
      if (mounted) {
        setState(() {
          _room = room;
          _connecting = false;
          _micOn = true;
          _camOn = widget.startWithCamera;
        });
      }
      _connectedAt = DateTime.now();
      Analytics.track(
        'call_started',
        roomName: widget.roomName,
        langFrom: _mySourceLang,
        langTo: _attachedTargetLang,
        props: {'kind': _callKind},
      );
    } catch (e) {
      await room.disconnect();
      Analytics.track(
        'call_failed',
        roomName: widget.roomName,
        props: {'kind': _callKind, 'message': e.toString()},
      );
      if (mounted) {
        setState(() {
          _connecting = false;
          _connectError = e.toString();
        });
      }
    }
  }

  RemoteParticipant? _primaryRemote(Room room) {
    final it = room.remoteParticipants.values.iterator;
    if (!it.moveNext()) return null;
    return it.current;
  }

  /// Whether the peer has muted their mic. Their mute disables the LiveKit audio
  /// track, which reaches us as a muted publication (and a `TrackMutedEvent`
  /// that already rebuilds this screen). Camera tracks are ignored — only the
  /// mic counts as "muted".
  bool _peerMicMuted(Room room) {
    final peer = _primaryRemote(room);
    if (peer == null) return false;
    for (final pub in peer.audioTrackPublications) {
      if (pub.muted) return true;
    }
    return false;
  }

  String _remoteDisplayName(RemoteParticipant? p) {
    if (p == null) return '';
    final n = p.name.trim();
    if (n.isNotEmpty) return n;
    final id = p.identity;
    if (id.length > 14) return '${id.substring(0, 14)}â€¦';
    return id;
  }

  /// Whether we should draw the small PiP at all. We always show it as
  /// long as a participant exists on the side that PiP would represent,
  /// even when their camera is off â€” the cell falls back to an avatar
  /// placeholder so the layout doesn't collapse mid-call.
  bool _pipFeedAvailable({
    VideoTrack? local,
    VideoTrack? remote,
    bool hasRemote = false,
  }) {
    if (_selfMain) return hasRemote;
    return true; // local participant always exists when call is up
  }

  VideoTrack? _remoteVideo(Room room) {
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        // A muted publication means the participant turned their camera
        // off â€” LiveKit mutes the track instead of unpublishing it. Treat
        // it as "no video" so the camera-off tile shows instead of a
        // frozen / black VideoTrackRenderer.
        if (pub.muted) continue;
        final t = pub.track;
        if (t != null) return t;
      }
    }
    return null;
  }

  VideoTrack? _localVideo(Room room) {
    final lp = room.localParticipant;
    if (lp == null) return null;
    for (final pub in lp.videoTrackPublications) {
      if (pub.muted) continue;
      final t = pub.track;
      if (t != null) return t;
    }
    return null;
  }

  Future<void> _toggleMic() async {
    final room = _room;
    if (room == null) return;
    final next = !_micOn;
    await room.localParticipant?.setMicrophoneEnabled(next);
    setSendMuted(!next);
    if (next) {
      // Unmuting: immediately clear the TTS gate so SEND resumes at once.
      // Without this, a TTS that started while the mic was muted would keep
      // blocking SEND until its timer fires (up to 15 s).
      markTranslationDone();
    }
    if (mounted) setState(() => _micOn = next);
  }

  /// Data channel packet from the peer: local-TTS native or streamed web path,
  /// plus the peer's listening-language announcements.
  void _onCaptionData(DataReceivedEvent e) {
    if (e.topic != _captionTopic) return;
    try {
      final m = jsonDecode(utf8.decode(e.data)) as Map<String, dynamic>;
      // The peer tapped their language button: they want to hear us in this
      // language from now on, so it becomes our translation target. A peer on an
      // older build never sends this and keeps being served their account
      // language from metadata.
      final listen = m[_kListenLangKey]?.toString() ?? '';
      if (listen.isNotEmpty) {
        DebugOverlay.log('peer listens in $listen');
        if (listen != _peerListenLang) {
          _peerListenLang = listen;
          final room = _room;
          if (room != null) unawaited(_refreshTranslationBinding(room));
        }
        return;
      }
      // The peer cut (or restored) translation on THEIR side: stop translating
      // for them. Our own ear is not affected.
      final xlateOn = m[_kTranslationOnKey];
      if (xlateOn is bool) {
        DebugOverlay.log('peer wants translation: $xlateOn');
        unawaited(_applyPeerWantsTranslation(xlateOn));
        return;
      }
      // Translation is off: a packet still in flight from a peer on an older
      // build must not speak over the conversation.
      if (!_translationEnabled) return;
      if (m[kLocalTtsFlag] == true || m[kLegacyLocalTtsFlag] == true) {
        final trans = m['trans']?.toString() ?? '';
        final lang = m['lang']?.toString() ?? '';
        DebugOverlay.log('caption localTts trans="$trans" lang=$lang web=$kIsWeb');
        // Their ORIGINAL rides along next to the translation and was, until now,
        // dropped on the floor. Keep it: our own next sentence is translated in
        // its own request, so without this it has no idea what it replies to —
        // and reusing their exact wording keeps terms consistent both ways.
        widget.translation.notePeerUtterance(m['orig']?.toString() ?? '');
        _addTurn(_SpokenTurn(mine: false, text: trans));
        if (trans.isNotEmpty) {
          if (kIsWeb) {
            unawaited(_speakDeviceTts(trans, lang));
          } else {
            unawaited(_playWithLocalTts(trans, lang));
          }
        }
        return;
      }
      if (m['voiceOnly'] == true) {
        _addTurn(_SpokenTurn(mine: false, text: m['trans']?.toString() ?? ''));
        final audioB64 = m['audio']?.toString() ?? '';
        DebugOverlay.log('caption voiceOnly audio=${audioB64.length}b web=$kIsWeb');
        // On web: play via <audio> element so browser AEC can cancel the echo.
        // On native: audioplayers handles it.
        if (audioB64.isNotEmpty) unawaited(_playTranslatedAudio(audioB64));
        return;
      }
    } catch (_) {}
  }

  /// Cut translation FOR ME — the peer is free to keep hearing theirs.
  ///
  /// Each side owns its own ear. But translation runs on the SPEAKER's side, so
  /// "I don't want to hear translations" is not something we can honour alone:
  /// it is a request to the peer to stop translating *for us*. Same shape as the
  /// language button — sent by the listener, acted on by the speaker.
  ///
  /// Our own pipeline keeps running: we go on translating our voice for the
  /// peer, who still hears us translated unless THEY cut it on their side.
  Future<void> _toggleTranslation() async {
    final want = !_translationEnabled;
    final room = _room;
    if (room == null) return;
    setState(() => _translationEnabled = want);

    unawaited(room.localParticipant
        ?.publishData(
          Uint8List.fromList(
            utf8.encode(jsonEncode({_kTranslationOnKey: want})),
          ),
          reliable: true,
          topic: _captionTopic,
        )
        .catchError((_) {}));

    if (!want) {
      // Whatever the voice is mid-sentence on is no longer wanted, and neither is
      // anything queued behind it. The peer's ducked voice comes straight back up.
      _cancelQueuedSpeech();
    }
  }

  /// The peer asked us to stop (or resume) translating for them: it is OUR
  /// pipeline that has to stop, since we are the one who translates our own
  /// voice into their language. What we hear is untouched.
  Future<void> _applyPeerWantsTranslation(bool wants) async {
    if (wants == _peerWantsTranslation) return;
    _peerWantsTranslation = wants;
    final room = _room;
    if (room == null) return;
    if (wants) {
      // _attachedTargetLang still holds the route we tore down; clear it or the
      // "nothing changed" early-out would skip the re-attach entirely.
      _attachedTargetLang = '';
      await _refreshTranslationBinding(room);
    } else {
      await widget.translation.detach();
    }
  }

  /// Play base64 mp3 (cloud TTS) forwarded by the sender over the data channel.
  Future<void> _playTranslatedAudio(String audioB64) async {
    try {
      final bytes = base64Decode(audioB64);
      if (bytes.isEmpty || !mounted) return;
      // On web, play through the gesture-unlocked element (WebKit autoplay).
      if (kIsWeb) {
        final ok = await playTranslatedMp3(bytes);
        debugPrint('[sway-rt] web play ok=$ok ${bytes.length}b');
        if (ok) return;
      }
      await _ttsPlayer.stop();
      await _ttsPlayer.play(BytesSource(bytes));
      debugPrint('[sway-rt] played cloud audio ${bytes.length}b');
    } catch (e) {
      debugPrint('[sway-rt] play cloud audio FAILED: $e');
    }
  }

  /// Speak [text] with the device's own OS voice (`flutter_tts`).
  ///
  /// The premium on-device voice, when one is loaded for this language; downloaded
  /// per language (~60–110 MB a bundle) and kept in sync with a catalogue. That
  /// whole machinery is gone: the phone already ships dozens of languages, they
  /// need no download, and they start speaking instantly. `ttsSpeaking` is now
  /// driven entirely by flutter_tts's own start/completion handlers.
  ///
  /// flutter_tts's speak() can return without playing (missing voice), so no
  /// completion event is ever guaranteed — the mic gate's own safety timer is
  /// what reopens the mic, never an awaited event.
  Future<void> _playWithLocalTts(String text, String lang) =>
      _enqueueSpeak(text, lang);

  /// The "translated voice volume" slider used to reach only the audioplayers
  /// element that plays a cloud mp3 — a path neither the device voice nor the
  /// old on-device one ever took, so the slider silently did nothing. Now that every
  /// translation is spoken by flutter_tts, the volume has to be handed to it,
  /// before each utterance (the engine forgets it across a stop()).
  Future<void> _applyTranslatedVolumeToDeviceTts() async {
    final v = _audio.translatedVolume.clamp(0.0, 1.0);
    // Logged because this setting is persisted: a slider left at zero during an
    // earlier call silences every translation in every call after it, and until
    // this volume was actually wired to the engine, a stored zero was harmless —
    // so a zero can be sitting in prefs from before it meant anything.
    if (v < 0.05) {
      DebugOverlay.log('translated volume is ${v.toStringAsFixed(2)} — '
          'the voice will be inaudible (check the in-call volume slider)');
    }
    try {
      await _deviceTts.setVolume(v);
    } catch (_) {}
  }

  Future<void> _speakDeviceTts(String text, String lang) =>
      _enqueueSpeak(text, lang);

  /// Loudspeaker ⇄ earpiece. Calls start on the earpiece (see AudioController's
  /// default): against the ear the loudspeaker cannot reach the mic, so the
  /// feedback loop that makes a call howl has no path to close. A plugged-in
  /// headset still wins over both — `_applySpeaker` refuses to override the OS.
  Future<void> _toggleSpeaker() async {
    await _audio.setSpeakerOn(!_audio.speakerOn);
    if (mounted) setState(() {});
  }

  Future<void> _toggleCam() async {
    final room = _room;
    if (room == null) return;
    final next = !_camOn;
    // Audio calls don't request camera permission upfront, so the first
    // time the user turns the camera on we ask for it here.
    if (next) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppStrings.t('call_perm_required'))),
          );
        }
        return;
      }
    }
    await room.localParticipant?.setCameraEnabled(next);
    if (mounted) setState(() => _camOn = next);
  }

  /// Re-open the OS share sheet with the guest-invite link. Only reachable
  /// from the waiting-room placeholder when [CallScreen.inviteShareText] is
  /// set (host side of a guest-invite call).
  Future<void> _shareInviteLink() async {
    final text = widget.inviteShareText;
    if (text == null) return;
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: text,
          sharePositionOrigin: box != null
              ? box.localToGlobal(Offset.zero) & box.size
              : null,
        ),
      );
    } catch (_) {
      // Sheet dismissed or sharing unavailable â€” nothing to do.
    }
  }

  void _openAudioSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0E0E0E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => _AudioSettingsSheet(controller: _audio),
    );
  }

  /// Les deux langues de l'appel, dans un seul panneau : à gauche celle que je
  /// parle, à droite celle que j'entends. Une roue par question, un drapeau à
  /// la fois — rien à lire, on fait défiler jusqu'au bon.
  void _openLanguagePairSheet() {
    // Out of credits → translation is off; tapping the languages opens the
    // recharge paywall instead of the picker.
    if (!UsageTracker.isDisabled && UsageTracker.creditsExhausted.value) {
      unawaited(_showOutOfCreditsDialog());
      return;
    }
    // Le panneau n'a pas de bouton de validation : on note ce que les roues
    // désignent, et on applique quand il se referme — peu importe comment il a
    // été refermé. Appliquer à chaque cran relancerait le recogniser, ou
    // annoncerait une langue au pair, pour des langues qu'on ne fait que
    // survoler.
    var spoken = _mySourceLang;
    var heard = _myOutputLang;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0E0E0E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => _LanguagePairSheet(
        spokenCode: _mySourceLang,
        heardCode: _myOutputLang,
        onChanged: (s, h) {
          spoken = s;
          heard = h;
        },
      ),
    ).whenComplete(() {
      if (!mounted) return;
      // Deux chemins bien distincts : la langue parlée relance notre
      // recogniser, celle qu'on entend est annoncée au pair.
      if (_baseLang(spoken) != _baseLang(_mySourceLang)) {
        unawaited(_changeSpokenLanguage(spoken));
      }
      if (_baseLang(heard) != _baseLang(_myOutputLang)) {
        unawaited(_changeOutputLanguage(heard));
      }
    });
  }

  /// Les deux panneaux de l'appel d'un coup — le son à gauche, les langues à
  /// droite. C'est l'appui long sur la pastille qui l'ouvre : le geste rapide
  /// reste réservé à couper la traduction.
  void _openCallSettingsSheet() {
    var spoken = _mySourceLang;
    var heard = _myOutputLang;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0E0E0E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => _CallSettingsSheet(
        controller: _audio,
        spokenCode: _mySourceLang,
        heardCode: _myOutputLang,
        onLanguagesChanged: (sp, hd) {
          spoken = sp;
          heard = hd;
        },
      ),
    ).whenComplete(() {
      if (!mounted) return;
      if (_baseLang(spoken) != _baseLang(_mySourceLang)) {
        unawaited(_changeSpokenLanguage(spoken));
      }
      if (_baseLang(heard) != _baseLang(_myOutputLang)) {
        unawaited(_changeOutputLanguage(heard));
      }
    });
  }

  /// `fr-FR` et `fr` sont la même langue : comparer les tags bruts ferait
  /// repartir le pipeline pour rien.
  static String _baseLang(String code) =>
      code.split('-').first.toLowerCase();

  /// Change la langue que mon micro est censé entendre. Purement local : le
  /// pair reçoit du texte déjà traduit, il n'a rien à savoir. Ce que ça coûte,
  /// c'est un redémarrage du pipeline — [_refreshTranslationBinding] compare à
  /// [_attachedSourceLang] et relance le recogniser sur la nouvelle langue.
  Future<void> _changeSpokenLanguage(String code) async {
    if (code.isEmpty || code == _mySourceLang) return;
    setState(() => _mySourceLang = code);

    // Le prochain appel repart sur ce choix, comme après le gate d'entrée —
    // sans toucher au «ne plus me demander» déjà exprimé.
    final saved = await UserPrefs.loadCallSpokenLang();
    await UserPrefs.saveCallSpokenLang(code, dontAsk: saved.dontAsk);

    final room = _room;
    if (room != null) await _refreshTranslationBinding(room);
  }

  /// Change the language the local user hears the remote translated into.
  ///
  /// Our own pipeline is untouched — we keep transcribing our mic in our real
  /// spoken language and translating for the peer. What changes is on THEIR
  /// phone: [_announceOutputLang] tells them to translate into [code], and their
  /// [_onCaptionData] re-binds their route to it. All we do locally is point the
  /// device voice at the new language — nothing is downloaded: the language is
  /// picked mid-call, so it has to speak now, not after a 60 MB bundle lands.
  Future<void> _changeOutputLanguage(String code) async {
    if (code.isEmpty || code == _myOutputLang) return;
    setState(() => _myOutputLang = code);

    final room = _room;
    if (room != null) _announceOutputLang(room);

    _deviceTtsLang = code;
    unawaited(_deviceTts.setLanguage(code).catchError((_) {}));
  }


  /// Tell the peer which language to translate into for us.
  ///
  /// Idempotent: only publishes when the announced value actually changed, so
  /// the re-announce on every participant/metadata event costs nothing.
  void _announceOutputLang(Room room) {
    if (_myOutputLang.isEmpty || _myOutputLang == _announcedOutputLang) return;
    if (room.remoteParticipants.isEmpty) return;
    _announcedOutputLang = _myOutputLang;
    DebugOverlay.log('announce listenLang=$_myOutputLang');
    unawaited(room.localParticipant
        ?.publishData(
          Uint8List.fromList(
            utf8.encode(jsonEncode({_kListenLangKey: _myOutputLang})),
          ),
          reliable: true,
          topic: _captionTopic,
        )
        .catchError((_) {}));
  }

  Future<void> _hangUp() async {
    // Caller giving up before the callee ever joined: tell their device to
    // stop ringing NOW (symmetric to the callee's decline broadcast), else
    // their phone rings on until a local ~30 s timeout. Covers manual
    // hang-up while waiting, ring-timeout, and the already-declined case
    // (harmless there — the callee is already gone).
    final outId = widget.outgoingCallId;
    if (widget.isCaller && !_hadRemote && outId != null && outId.isNotEmpty) {
      unawaited(IncomingCallApi.broadcastCancel(callId: outId));
      // App-killed filet: a VoIP "cancel" push so the callee's CallKit ring
      // stops even when their app isn't running to hear the realtime cancel.
      final callee = widget.peerId ?? '';
      if (callee.isNotEmpty) {
        unawaited(
          IncomingCallApi.notifyCancel(calleeId: callee, callId: outId),
        );
      }
    }
    // Bounded: on iOS a WebRTC/CallKit teardown can hang (same class of
    // unbounded-await bug already fixed on the join path) — without a
    // timeout here, the user gets stuck on a spinner and has to force-quit
    // the app to get back in. Best-effort cleanup; the UI always recovers.
    try {
      await widget.translation.detach().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[hangup] translation.detach timed out/failed: $e');
    }
    try {
      await _roomEvents?.dispose().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[hangup] roomEvents.dispose timed out/failed: $e');
    }
    _roomEvents = null;
    final r = _room;
    _room = null;
    if (r != null) {
      r.removeListener(_onRoomChanged);
      try {
        await r.disconnect().timeout(const Duration(seconds: 5));
      } catch (e) {
        debugPrint('[hangup] room.disconnect timed out/failed: $e');
      }
      try {
        await r.dispose().timeout(const Duration(seconds: 5));
      } catch (e) {
        debugPrint('[hangup] room.dispose timed out/failed: $e');
      }
    }
    // If the call actually connected, show the black "call ended" summary
    // (PDP + flag + minutes + share) instead of popping straight back. A call
    // that never connected (declined / unanswered) just closes.
    final startedAt = _connectedAt;
    if (startedAt != null && mounted) {
      _finalDuration = DateTime.now().difference(startedAt);
      unawaited(UsageTracker.stop());
      setState(() => _ended = true);
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  String _formatCallDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    if (m <= 0) return '$s s';
    return '$m min ${s.toString().padLeft(2, '0')} s';
  }

  /// Share the user's referral link — invite friends, both earn free live
  /// minutes. Mirrors the profile's invite-a-friend section. Best-effort.
  Future<void> _shareReferral() async {
    try {
      final uid = AuthService.currentUserId;
      final code =
          uid.isEmpty ? '' : (await ProfileApi.fetchById(uid))?.referralCode ?? '';
      final link = code.isEmpty
          ? 'https://www.swayco.fr'
          : 'https://www.swayco.fr/?ref=$code';
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          text: AppStrings.t('invite_share_text', args: {'link': link}),
          subject: AppStrings.t('invite_friend'),
          sharePositionOrigin: box != null
              ? box.localToGlobal(Offset.zero) & box.size
              : null,
        ),
      );
    } catch (_) {
      // Sheet dismissed / sharing unavailable — nothing to do.
    }
  }

  /// Black "call ended" card: the peer's PDP + flag, the minutes spent, a
  /// share button bottom-right and the swayco logo dead-centre at the bottom.
  Widget _buildEndedSummary(BuildContext context) {
    final profile = _peerProfile;
    final name = (profile?.displayName.trim().isNotEmpty ?? false)
        ? profile!.displayName.trim()
        : AppStrings.t('profile_anonymous');
    final firstName = name.split(RegExp(r'\s+')).first;
    final lang = profile?.language.trim() ?? '';
    // Country flag once the peer has set a location (the spoken language
    // doesn't always match the country); language flag otherwise.
    final flagEmoji = ((profile?.city.trim().isNotEmpty ?? false)
            ? countryFlagFor(profile?.country ?? '')
            : null) ??
        (lang.isEmpty ? null : findLanguageByCode(lang)?.flag) ??
        '';
    final dur = _finalDuration ?? Duration.zero;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      body: SafeArea(
        child: Stack(
          children: [
            // The shareable card (everything captured into the PNG).
            Positioned.fill(
              child: RepaintBoundary(
                key: _shareCardKey,
                child: Container(
                  color: const Color(0xFF0E0E0E),
                  child: Stack(
                    children: [
                      // Brand wordmark — top-centre, like the in-call screen.
                      const Positioned(
                        top: 12,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: 'swayco'),
                                // ".ai" in cyan accent.
                                TextSpan(
                                  text: '.ai',
                                  style: TextStyle(color: SC.accent),
                                ),
                              ],
                            ),
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 25,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                              shadows: [
                                Shadow(color: Colors.black54, blurRadius: 8),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // Peer PDP + first name + call duration, grouped in the
                      // upper area (the duration sits right under the name and
                      // is the biggest figure on the card).
                      Align(
                        alignment: const Alignment(0, -0.42),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ProfileAvatar(
                              displayName: name,
                              avatarUrl: profile?.avatarUrl,
                              size: 132,
                            ),
                            const SizedBox(height: 20),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      firstName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 24,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  if (flagEmoji.isNotEmpty) ...[
                                    const SizedBox(width: 12),
                                    Text(flagEmoji,
                                        style: const TextStyle(fontSize: 30)),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 26),
                            // Call duration — enlarged, just under the name.
                            const Icon(Icons.schedule_rounded,
                                color: SC.accent, size: 30),
                            const SizedBox(height: 8),
                            Text(
                              _formatCallDuration(dur),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 34,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Close — top-left, kept OUT of the captured card.
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 26),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            // Invite friends → both earn free live minutes (referral link).
            // Full-width cyan -> blue gradient CTA pinned to the bottom.
            Positioned(
              left: 20,
              right: 20,
              bottom: 28,
              child: Pressable(
                bounce: true,
                onTap: _shareReferral,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: const LinearGradient(
                      colors: [SC.accent, SC.meshBlue],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: SC.accent.withValues(alpha: 0.35),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.group_add_rounded,
                            color: Colors.white, size: 20),
                        const SizedBox(width: 10),
                        Text(
                          AppStrings.t('invite_bonus_share_cta'),
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
          ],
        ),
      ),
    );
  }

  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SC.bubbleIn,
        title: Text(AppStrings.t('call_leave_q'),
            style: const TextStyle(color: SC.textPrimary)),
        content: Text(
          AppStrings.t('call_leave_body'),
          style: const TextStyle(color: SC.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.t('call_stay')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE53935)),
            child: Text(AppStrings.t('call_leave')),
          ),
        ],
      ),
    );
    if (leave == true && mounted) await _hangUp();
  }

  @override
  void dispose() {
    widget.translation.localTranscript?.removeListener(_onMyTranscript);
    _splashTimer?.cancel();
    _ringTimeout?.cancel();
    // call_ended is emitted here, not in _hangUp(), because dispose()
    // runs on every exit path (hang-up, peer-left auto-hangup, system
    // back) â€” so the call is counted exactly once with its duration.
    final startedAt = _connectedAt;
    if (startedAt != null) {
      // Prefer the duration captured when the call ended — otherwise time
      // spent reading the summary card would inflate the analytics figure.
      final durMs = (_finalDuration ?? DateTime.now().difference(startedAt))
          .inMilliseconds;
      Analytics.track(
        'call_ended',
        roomName: widget.roomName,
        langFrom: _mySourceLang,
        langTo: _attachedTargetLang,
        props: {
          'kind': _callKind,
          'duration_ms': durMs,
          // Real translation-live time â€” drives the live engine cost
          // estimate in the admin dashboard.
          'translation_ms': _translationLive.elapsed.inMilliseconds,
        },
      );
    }
    widget.translation.translationListenable?.removeListener(_onTranslationStateChanged);
    _audio.dispose();
    unawaited(_ttsPlayer.dispose());
    _cancelQueuedSpeech();
    ttsSpeaking.removeListener(_syncTranslationSpeaking);
    ttsSpeaking.dispose();
    _voiceLevel.dispose();
    _messageTimer?.cancel();
    _dockIdleTimer?.cancel();
    UsageTracker.creditsExhausted.removeListener(_onCreditsExhausted);
    final declineCh = _declineChannel;
    _declineChannel = null;
    if (declineCh != null) {
      unawaited(Supabase.instance.client.removeChannel(declineCh));
    }
    // Flush whatever seconds were used since the last tick before tearing
    // everything down. Fire-and-forget â€” disposing a State must be sync.
    unawaited(UsageTracker.stop());
    final ev = _roomEvents;
    _roomEvents = null;
    if (ev != null) unawaited(ev.dispose());
    final r = _room;
    _room = null;
    if (r != null) {
      r.removeListener(_onRoomChanged);
      unawaited(() async {
        await widget.translation.detach();
        await r.disconnect();
        await r.dispose();
      }());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ended) return _buildEndedSummary(context);

    if (_connectError != null) {
      return Scaffold(
        backgroundColor: SC.bg,
        appBar: AppBar(
          backgroundColor: SC.bg,
          foregroundColor: SC.textPrimary,
          title: Text(AppStrings.t('call_could_not_join')),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 48, color: const Color(0xFFE53935).withValues(alpha: 0.9)),
                const SizedBox(height: 16),
                Text(
                  _connectError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: SC.textMuted, height: 1.4),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(AppStrings.t('call_go_back')),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_connecting || _room == null || !_minSplashDone) {
      // Splash-style connecting state. Showing the room name + a bare
      // spinner during LiveKit's handshake felt clinical and gave the
      // caller no signal about the credit deduction â€” switch to the
      // app's splash image with a single one-liner hint clarifying
      // that only the caller's monthly credits are debited (the peer
      // listens free). Keeps the spinner so the user still has motion
      // feedback that something is happening. Held for >= 5s (see
      // _minSplashDone) and on the app's black, to match the logo.
      return Scaffold(
        backgroundColor: const Color(0xFF000000),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
            child: Column(
              children: [
                // Logo, then the spinner + hint kept close just beneath it
                // (centred together as a tight group, not spread apart).
                const Spacer(flex: 5),
                Image.asset(
                  'assets/notif-android.png',
                  width: 210,
                  height: 210,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 22),
                const SizedBox(
                  height: 28,
                  width: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: SC.accent,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  AppStrings.t('call_connecting_caller_pays'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: SC.textMuted,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const Spacer(flex: 6),
              ],
            ),
          ),
        ),
      );
    }

    final room = _room!;
    final remote = _remoteVideo(room);
    final local = _localVideo(room);
    final remoteCount = room.remoteParticipants.length;
    final peer = _primaryRemote(room);
    final peerName = _remoteDisplayName(peer);
    final peerFirstName =
        peerName.isEmpty ? null : peerName.split(' ').first;
    final localFirstName = widget.displayName.trim().isEmpty
        ? null
        : widget.displayName.trim().split(' ').first;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _confirmLeave();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.black,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        child: Scaffold(
          backgroundColor: Colors.black,
          // Don't shrink the video when the keyboard opens — keep it full
          // screen; only the chat composer lifts above the keyboard (it adds
          // viewInsets.bottom itself).
          resizeToAvoidBottomInset: false,
          body: Builder(
            builder: (context) {
              // Pin the bottom safe-area inset so it stays CONSTANT when the
              // keyboard opens — otherwise MediaQuery.padding.bottom collapses
              // to 0, the right-side control rail's SafeArea shrinks, and the
              // buttons jump down. The composer reads viewInsets directly, so
              // it still lifts above the keyboard.
              final mq = MediaQuery.of(context);
              return MediaQuery(
                data: mq.copyWith(
                  padding: mq.padding.copyWith(bottom: mq.viewPadding.bottom),
                ),
                child: SafeArea(
                  child: Stack(
                    fit: StackFit.expand,
              children: [
                // Main view priority:
                //   1. Remote video, if the remote has a published camera.
                //   2. "Camera off" placeholder for the remote (their tile
                //      stays visible, audio keeps flowing).
                //   3. Self-main local video when explicitly swapped.
                //   4. Local "camera off" placeholder when self-main + cam off.
                //   5. Empty-room placeholder if no remote yet.
                if (_selfMain && local != null && _camOn)
                  GestureDetector(
                    onTap: remoteCount > 0
                        ? () => setState(() => _selfMain = false)
                        : null,
                    child: VideoTrackRenderer(
                      local,
                      fit: VideoViewFit.cover,
                      mirrorMode: VideoViewMirrorMode.mirror,
                    ),
                  )
                else if (_selfMain && remoteCount > 0)
                  // Self-main but local cam off â†’ still let the user tap to
                  // swap back to the remote. Show the local user's first
                  // name as placeholder.
                  GestureDetector(
                    onTap: () => setState(() => _selfMain = false),
                    child: _CameraOffTile(
                      label: localFirstName,
                      muted: !_micOn,
                    ),
                  )
                else if (remote != null)
                  VideoTrackRenderer(
                    remote,
                    fit: VideoViewFit.cover,
                    mirrorMode: VideoViewMirrorMode.off,
                  )
                else if (remoteCount > 0)
                  // Remote is connected but has their camera off â€” keep the
                  // tile visible, the call (audio + translation) is still up.
                  _CameraOffTile(
                    label: peerFirstName,
                    muted: _peerMicMuted(room),
                  )
                else
                  Container(
                    color: SC.bubbleIn,
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person, size: 80, color: Colors.white.withValues(alpha: 0.28)),
                        const SizedBox(height: 14),
                        Text(
                          AppStrings.t('call_waiting_title'),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.78),
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          AppStrings.t('call_waiting_body'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 13,
                          ),
                        ),
                        if (widget.inviteShareText != null) ...[
                          const SizedBox(height: 22),
                          FilledButton.icon(
                            onPressed: _shareInviteLink,
                            icon: const Icon(Icons.ios_share_rounded, size: 18),
                            label: Text(AppStrings.t('call_share_invite')),
                          ),
                        ],
                      ],
                    ),
                  ),
                // PiP: shows whichever feed is NOT the main one. Tap to
                // swap. Always rendered when the corresponding party
                // exists, even if their camera is off â€” falls back to a
                // tiny "camera off" tile so the layout doesn't pop.
                if (_pipFeedAvailable(
                    local: local, remote: remote, hasRemote: remoteCount > 0))
                  Positioned(
                    top: MediaQuery.paddingOf(context).top + 52,
                    right: 12,
                    width: 118,
                    height: 176,
                    child: GestureDetector(
                      onTap: () => setState(() => _selfMain = !_selfMain),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white30, width: 1.5),
                            color: Colors.black,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.45),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: () {
                            // PiP shows the "not main" side.
                            if (_selfMain) {
                              // Main = local, PiP = remote.
                              if (remote != null) {
                                return VideoTrackRenderer(
                                  remote,
                                  fit: VideoViewFit.cover,
                                  mirrorMode: VideoViewMirrorMode.off,
                                );
                              }
                              return _CameraOffTile(
                                compact: true,
                                label: peerFirstName,
                                muted: _peerMicMuted(room),
                              );
                            }
                            // Main = remote, PiP = local.
                            if (local != null && _camOn) {
                              return VideoTrackRenderer(
                                local,
                                fit: VideoViewFit.cover,
                                mirrorMode: VideoViewMirrorMode.mirror,
                              );
                            }
                            return _CameraOffTile(
                              compact: true,
                              label: localFirstName,
                              muted: !_micOn,
                            );
                          }(),
                        ),
                      ),
                    ),
                  ),
                if (widget.translation.translationListenable != null)
                  ListenableBuilder(
                    listenable: widget.translation.translationListenable!,
                    builder: (context, _) {
                      final overlay = widget.translation.buildTranslationAudioOverlay();
                      return overlay ?? const SizedBox.shrink();
                    },
                  ),
                // Le dock : une barre de verre posée en bas, dans laquelle tout
                // vit. De gauche à droite : la zone de légende (un tap déplie
                // ce qui se dit), la pastille de traduction, raccrocher, puis
                // le chevron qui déplie les réglages. Ce qui se déplie —
                // légende et réglages — pousse vers le HAUT, au-dessus de la
                // barre, qui elle ne bouge jamais.
                Positioned(
                  key: const ValueKey('call_controls'),
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 1. La légende, dépliée depuis la zone de gauche.
                          AnimatedSize(
                            duration: const Duration(milliseconds: 240),
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.bottomCenter,
                            child: (_turnsOpen && _turns.isNotEmpty)
                                ? Padding(
                                    padding: const EdgeInsets.only(
                                      left: 4,
                                      right: 40,
                                      bottom: 10,
                                    ),
                                    child: _SpokenTurnsPanel(
                                      turns: _turns,
                                      myName: widget.displayName,
                                      myAvatarUrl: '',
                                      peerName:
                                          _peerProfile?.displayName ?? '',
                                      peerAvatarUrl:
                                          _peerProfile?.avatarUrl ?? '',
                                      onToggle: () => setState(
                                        () => _turnsOpen = false,
                                      ),
                                    ),
                                  )
                                : const SizedBox(width: double.infinity),
                          ),
                          // 2. Les réglages, dépliés par le chevron.
                          AnimatedSize(
                            duration: const Duration(milliseconds: 240),
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.bottomCenter,
                            child: !_controlsOpen
                                ? const SizedBox(width: double.infinity)
                                : Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: Wrap(
                                      alignment: WrapAlignment.center,
                                      spacing: 12,
                                      runSpacing: 10,
                                      children: [
                                        // Muet = engagé : le bouton se remplit.
                                        _RoundCallButton(
                                          icon: _micOn
                                              ? Icons.mic_rounded
                                              : Icons.mic_off_rounded,
                                          label: _micOn
                                              ? AppStrings.t('call_mute')
                                              : AppStrings.t('call_unmute'),
                                          active: !_micOn,
                                          onTap: _toggleMic,
                                        ),
                                        _RoundCallButton(
                                          icon: _audio.speakerOn
                                              ? Icons.volume_up_rounded
                                              : Icons.phone_in_talk_rounded,
                                          label: AppStrings.t(_audio.speakerOn
                                              ? 'call_earpiece'
                                              : 'call_speaker'),
                                          active: _audio.speakerOn,
                                          onTap: _toggleSpeaker,
                                        ),
                                        // Live keeps the camera on — no toggle.
                                        if (_callKind != 'live')
                                          _RoundCallButton(
                                            icon: _camOn
                                                ? Icons.videocam_rounded
                                                : Icons.videocam_off_rounded,
                                            label: _camOn
                                                ? AppStrings.t('call_video')
                                                : AppStrings.t(
                                                    'call_video_off'),
                                            active: !_camOn,
                                            onTap: _toggleCam,
                                          ),
                                        // La langue dans laquelle j'entends
                                        // l'appel. Le panneau, lui, porte les
                                        // deux — celle que je parle aussi.
                                        _LanguageButton(
                                          country: findLanguageByCode(
                                                _myOutputLang,
                                              )?.countryCode ??
                                              '',
                                          onTap: _openLanguagePairSheet,
                                        ),
                                        // Il ouvre un panneau, il ne bascule
                                        // rien : jamais d'état blanc, et le
                                        // même verre que les autres.
                                        _RoundCallButton(
                                          icon: Icons.tune_rounded,
                                          label: AppStrings.t('call_audio'),
                                          onTap: _openAudioSheet,
                                        ),
                                      ],
                                    ),
                                  ),
                          ),
                          // 3. La barre elle-même.
                          _CallDock(
                            preview: _turns.isEmpty ? '' : _turns.last.text,
                            previewMine:
                                _turns.isNotEmpty && _turns.last.mine,
                            hint: _speakLangHint,
                            turnsOpen: _turnsOpen,
                            hasTurns: _turns.isNotEmpty,
                            myName: widget.displayName,
                            peerName: _peerProfile?.displayName ?? '',
                            peerAvatarUrl: _peerProfile?.avatarUrl ?? '',
                            translationOn: _translationEnabled,
                            ttsSpeaking: ttsSpeaking,
                            voiceLevel: _voiceLevel,
                            controlsOpen: _controlsOpen,
                            messageOpen: _messageOpen,
                            dimmed: _dockDimmed,
                            onWake: _wakeDock,
                            onToggleTurns: () {
                              _wakeDock();
                              setState(() => _turnsOpen = !_turnsOpen);
                            },
                            onToggleTranslation: _toggleTranslation,
                            onOrbLongPress: _openCallSettingsSheet,
                            onHangUp: _hangUp,
                            onToggleControls: () {
                              _wakeDock();
                              setState(
                                () => _controlsOpen = !_controlsOpen,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Brand watermark — top-centre, always on top of whatever
                // call layout is showing (full-screen, PiP, split…).
                Align(
                  alignment: Alignment.topCenter,
                  child: IgnorePointer(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Opacity(
                            opacity: 0.7,
                            child: Text.rich(
                              const TextSpan(
                                children: [
                                  TextSpan(text: 'swayco'),
                                  TextSpan(
                                    text: '.ai',
                                    style: TextStyle(color: SC.accent),
                                  ),
                                ],
                              ),
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 25,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                                shadows: [
                                  Shadow(
                                    color: Colors.black.withValues(alpha: 0.6),
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // Mini white countdown just under the watermark —
                          // appears only when credit drops below 5 min.
                          const _LowCreditCounter(),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
                  ),
                );
              },
            ),
          ),
        ),
    );
  }

}

/// Tiny white "credit time left" readout. Renders a compact mm:ss only when
/// this side is genuinely being debited (the usage tracker is running — i.e.
/// not a paying callee, not test mode) AND the remaining credit has dropped
/// below five minutes. Zero-size otherwise, so it never shifts the layout
/// while there's plenty of credit left.
class _LowCreditCounter extends StatelessWidget {
  const _LowCreditCounter();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: UsageTracker.creditsRemaining,
      builder: (context, secs, _) {
        if (!UsageTracker.isRunning || secs <= 0 || secs >= 300) {
          return const SizedBox.shrink();
        }
        final m = secs ~/ 60;
        final s = (secs % 60).toString().padLeft(2, '0');
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '$m:$s',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              shadows: [Shadow(color: Colors.black, blurRadius: 6)],
            ),
          ),
        );
      },
    );
  }
}

/// Un tour de parole : ce qu'une des deux personnes vient de dire, déjà dans
/// la langue de CE device (ma phrase telle que je l'ai dite ; celle du pair
/// telle qu'elle m'arrive traduite).
class _SpokenTurn {
  _SpokenTurn({required this.mine, required this.text, this.delivered = true});
  final bool mine;
  final String text;

  /// Mine only: heard, but the peer never got it. Drawn dimmed.
  final bool delivered;
}

/// La légende de l'appel, dépliée depuis la zone de gauche du dock : les quatre
/// derniers tours en bulles de verre, le haut fondu en dégradé — on remonte
/// plus loin en faisant défiler. Un tap la referme. Aucune saisie : ça ne fait
/// que retranscrire la voix.
class _SpokenTurnsPanel extends StatelessWidget {
  const _SpokenTurnsPanel({
    required this.turns,
    required this.onToggle,
    required this.myName,
    required this.myAvatarUrl,
    required this.peerName,
    required this.peerAvatarUrl,
  });

  final List<_SpokenTurn> turns;
  final VoidCallback onToggle;
  final String myName;
  final String myAvatarUrl;
  final String peerName;
  final String peerAvatarUrl;

  /// Hauteur dépliée : quatre bulles tiennent dedans, la cinquième se devine
  /// sous le dégradé — c'est ce qui invite à faire défiler.
  static const double _openHeight = 232;

  @override
  Widget build(BuildContext context) {
    final list = ListView.builder(
      // Le plus récent en bas, et on remonte le temps en faisant défiler.
      reverse: true,
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: turns.length,
      itemBuilder: (ctx, i) {
        final turn = turns[turns.length - 1 - i];
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _TurnBubble(
            turn: turn,
            name: turn.mine ? myName : peerName,
            avatarUrl: turn.mine ? myAvatarUrl : peerAvatarUrl,
          ),
        );
      },
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: SizedBox(
        height: _openHeight,
        // Le fondu du haut : un dégradé posé PAR-DESSUS (pas un ShaderMask —
        // il isolerait le flou des bulles et le tuerait).
        child: Stack(
          children: [
            Positioned.fill(child: list),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 56,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.55),
                        Colors.black.withValues(alpha: 0.0),
                      ],
                    ),
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

/// Une bulle : la PDP de qui parle, puis sa phrase, sur du verre sombre.
class _TurnBubble extends StatelessWidget {
  const _TurnBubble({
    required this.turn,
    required this.name,
    required this.avatarUrl,
  });

  final _SpokenTurn turn;
  final String name;
  final String avatarUrl;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ProfileAvatar(
          displayName: name,
          avatarUrl: avatarUrl.isEmpty ? null : avatarUrl,
          size: 30,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  // Same accent, thinner — a phrase nobody received reads as a
                  // faded version of one that landed, not as another kind of
                  // message. No new colour: the alpha carries it.
                  color: turn.mine
                      ? SC.accent.withValues(alpha: turn.delivered ? 0.32 : 0.12)
                      : Colors.black.withValues(alpha: 0.42),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white
                        .withValues(alpha: turn.delivered ? 0.18 : 0.10),
                  ),
                ),
                child: Text(
                  turn.text,
                  style: TextStyle(
                    color: Colors.white
                        .withValues(alpha: turn.delivered ? 1.0 : 0.55),
                    fontSize: 14.5,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Les deux langues de l'appel dans une seule pastille, scindée en son milieu :
/// à gauche celle que je PARLE — ce que le micro transcrit —, à droite celle
/// que j'ENTENDS, dans laquelle la voix d'en face m'est dite. Les deux drapeaux
/// sont souvent le même (je parle et j'écoute ma langue) : la micro-icône de
/// chaque côté, micro et oreille, est ce qui les distingue alors.
///
/// Chaque moitié est un bouton : elle ouvre le sélecteur de SA langue.
class _LanguageButton extends StatelessWidget {
  const _LanguageButton({required this.country, required this.onTap});

  /// Code ISO pays (`FR`, `JP`) — celui du drapeau, pas de la langue.
  final String country;
  final VoidCallback onTap;

  static const double _size = 45;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: AppStrings.t('call_output_language_title'),
      button: true,
      child: Pressable(
        bounce: true,
        onTap: onTap,
        child: SizedBox(
          width: _size,
          height: _size,
          child: Stack(
            children: [
              Positioned.fill(
                child: ClipOval(
                  child: country.isEmpty
                      ? Container(
                          color: SC.bubbleIn,
                          child: const Icon(
                            Icons.translate,
                            size: 21,
                            color: Colors.white,
                          ),
                        )
                      : CountryFlag.fromCountryCode(
                          country,
                          theme: const ImageTheme(
                            width: _size,
                            height: _size,
                            shape: Circle(),
                          ),
                        ),
                ),
              ),
              // L'anneau : il détache le drapeau de la vidéo.
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.85),
                        width: 1.5,
                      ),
                    ),
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

/// La barre du bas : une seule pièce de verre, posée sur la vidéo, qui porte
/// tout ce dont on se sert en appel. De gauche à droite — la zone de légende
/// (un tap déplie ce qui se dit), la pastille de traduction, le chevron qui
/// déplie les réglages au-dessus, et raccrocher tout au bout.
class _CallDock extends StatelessWidget {
  const _CallDock({
    required this.preview,
    required this.previewMine,
    required this.hint,
    required this.turnsOpen,
    required this.hasTurns,
    required this.myName,
    required this.peerName,
    required this.peerAvatarUrl,
    required this.translationOn,
    required this.ttsSpeaking,
    required this.voiceLevel,
    required this.controlsOpen,
    required this.messageOpen,
    required this.dimmed,
    required this.onWake,
    required this.onToggleTurns,
    required this.onToggleTranslation,
    required this.onOrbLongPress,
    required this.onHangUp,
    required this.onToggleControls,
  });

  /// La dernière phrase dite, en une ligne — l'aperçu affiché dans la zone de
  /// gauche tant qu'elle est repliée. Vide = on montre l'invite.
  final String preview;

  /// C'est moi qui l'ai dite : la zone porte alors MA pastille, pas celle du
  /// correspondant.
  final bool previewMine;

  /// Affiché tant que rien n'a été dit.
  final String hint;
  final bool turnsOpen;
  final bool hasTurns;
  final String myName;
  final String peerName;
  final String peerAvatarUrl;
  final bool translationOn;
  final ValueListenable<bool> ttsSpeaking;
  final ValueListenable<double> voiceLevel;
  final bool controlsOpen;

  /// Une phrase vient d'arriver : la zone de texte prend toute la barre, le
  /// chevron et le raccrochage s'effacent, la pastille glisse à droite.
  final bool messageOpen;

  /// Silence : la barre s'estompe jusqu'à [_dimOpacity], et la pastille reste
  /// entière par-dessus. JAMAIS jusqu'à zéro : ce qui devient invisible devient
  /// introuvable, et on doit toujours pouvoir viser le raccrochage.
  final bool dimmed;
  final VoidCallback onWake;
  final VoidCallback onToggleTurns;
  final VoidCallback onToggleTranslation;
  final VoidCallback onOrbLongPress;
  final VoidCallback onHangUp;
  final VoidCallback onToggleControls;

  /// Le plancher d'opacité de la veille : assez bas pour disparaître dans la
  /// vidéo, assez haut pour qu'on voie encore où sont les boutons.
  static const double _dimOpacity = 0.22;

  static const double _gap = 8;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: dimmed ? 1 : 0),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
      builder: (context, dim, _) {
        // 1 en pleine lumière, [_dimOpacity] en veille — jamais moins.
        final live = 1 - (1 - _dimOpacity) * dim;
        return GestureDetector(
          // En veille, la barre entière devient une seule grande cible qui la
          // rallume : opaque, sinon le tap traverse et personne ne l'attrape.
          // En pleine lumière elle ne capte rien, ce sont les boutons qui
          // travaillent.
          behavior:
              dimmed ? HitTestBehavior.opaque : HitTestBehavior.deferToChild,
          onTap: dimmed ? onWake : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(34),
            child: BackdropFilter(
              // Le flou s'atténue avec le reste, sans jamais s'annuler : la
              // barre reste une barre, en retrait.
              filter: ui.ImageFilter.blur(
                sigmaX: 24 * live,
                sigmaY: 24 * live,
              ),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  // Le gris translucide de la barre de commentaire : du blanc
                  // très dilué sur du flou, rien de coloré.
                  color: Colors.white.withValues(alpha: 0.14 * live),
                  borderRadius: BorderRadius.circular(34),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.18 * live),
                  ),
                ),
                child: Row(
                  children: [
                    // La zone de texte prend tout ce que les boutons laissent :
                    // quand le chevron et le raccrochage se replient pour une
                    // phrase, c'est elle qui récupère la place.
                    Expanded(
                      child: Opacity(
                        opacity: live,
                        // En veille, le premier tap rallume : il ne doit pas
                        // aussi déplier la conversation.
                        child: IgnorePointer(
                          ignoring: dimmed,
                          child: _CaptionField(
                            preview: preview,
                            hint: hint,
                            open: turnsOpen,
                            hasTurns: hasTurns,
                            // La pastille de qui vient de parler — la
                            // conversation se lit dans les deux sens, comme
                            // dans la légende dépliée.
                            authorName: previewMine ? myName : peerName,
                            authorAvatarUrl: previewMine ? '' : peerAvatarUrl,
                            onTap: onToggleTurns,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: _gap),
                    // La pastille ne s'estompe jamais : c'est elle qui reste
                    // quand tout le reste s'efface. En veille, la toucher
                    // rallume la barre au lieu de couper la traduction — on ne
                    // coupe pas la traduction sans l'avoir vue.
                    _TranslationOrb(
                      on: translationOn,
                      ttsSpeaking: ttsSpeaking,
                      voiceLevel: voiceLevel,
                      onTap: dimmed ? onWake : onToggleTranslation,
                      onLongPress: onOrbLongPress,
                    ),
                    // Le chevron et le raccrochage se replient pendant qu'une
                    // phrase occupe la barre — AnimatedSize rogne lui-même ce
                    // qui dépasse en chemin.
                    AnimatedSize(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      child: messageOpen
                          ? const SizedBox(height: 46)
                          : Opacity(
                              opacity: live,
                              child: IgnorePointer(
                                ignoring: dimmed,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(width: _gap),
                                    _RailToggleButton(
                                      open: controlsOpen,
                                      onTap: onToggleControls,
                                    ),
                                    const SizedBox(width: 6),
                                    _DockCircleButton(
                                      icon: Icons.call_end_rounded,
                                      label: AppStrings.t('call_end'),
                                      background: const Color(0xFFE53935),
                                      onTap: onHangUp,
                                    ),
                                  ],
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
      },
    );
  }
}

/// La zone de gauche du dock : là où les phrases s'affichent. Rien à y écrire —
/// elle montre la dernière phrase dite et, au tap, déplie la conversation
/// complète au-dessus du dock.
class _CaptionField extends StatelessWidget {
  const _CaptionField({
    required this.preview,
    required this.hint,
    required this.open,
    required this.hasTurns,
    required this.authorName,
    required this.authorAvatarUrl,
    required this.onTap,
  });

  final String preview;
  final String hint;
  final bool open;
  final bool hasTurns;
  final String authorName;
  final String authorAvatarUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final empty = preview.trim().isEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: hasTurns ? onTap : null,
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(23),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Row(
          children: [
            ProfileAvatar(
              displayName: authorName,
              avatarUrl: authorAvatarUrl.isEmpty ? null : authorAvatarUrl,
              size: 30,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                empty ? hint : preview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: empty ? 0.55 : 0.92),
                  fontSize: 13.5,
                ),
              ),
            ),
            if (hasTurns)
              AnimatedRotation(
                turns: open ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                child: Icon(
                  Icons.keyboard_arrow_up_rounded,
                  size: 20,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Un rond plein du dock (raccrocher). Volontairement sans flou : il est posé
/// sur le verre du dock, qui a déjà flouté ce qu'il y a dessous.
class _DockCircleButton extends StatelessWidget {
  const _DockCircleButton({
    required this.icon,
    required this.label,
    required this.background,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color background;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: Pressable(
        bounce: true,
        onTap: onTap,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: background,
            border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
          ),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

/// La pastille de traduction, au centre du dock : un galet blanc irisé traversé
/// de trois barres. Elles frémissent quand quelqu'un parle et s'agitent
/// franchement quand la traduction est en train d'être dite — c'est le seul
/// endroit de l'écran qui montre que la machine travaille.
///
/// Un tap coupe la traduction : la pastille vire alors au blanc pur et se fige.
class _TranslationOrb extends StatefulWidget {
  const _TranslationOrb({
    required this.on,
    required this.ttsSpeaking,
    required this.voiceLevel,
    required this.onTap,
    required this.onLongPress,
  });

  /// La traduction tourne. False = coupée : galet blanc, barres immobiles.
  final bool on;
  final ValueListenable<bool> ttsSpeaking;
  final ValueListenable<double> voiceLevel;
  final VoidCallback onTap;

  /// Appui long : les deux panneaux de l'appel, côte à côte.
  final VoidCallback onLongPress;

  /// Le plus gros élément du dock : c'est lui qu'on vise sans regarder.
  static const double size = 50;

  @override
  State<_TranslationOrb> createState() => _TranslationOrbState();
}

class _TranslationOrbState extends State<_TranslationOrb>
    with SingleTickerProviderStateMixin {
  /// Le battement des barres. Tourne en boucle tant qu'il y a quelque chose à
  /// montrer, et s'arrête net au repos — pas de ticker qui brûle la batterie
  /// pendant qu'on écoute en silence.
  late final AnimationController _phase = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  /// Amplitude affichée, lissée vers [_target] frame par frame : une voix qui
  /// s'arrête fait retomber les barres, elle ne les coupe pas.
  final ValueNotifier<double> _amp = ValueNotifier<double>(0);
  double _target = 0;

  @override
  void initState() {
    super.initState();
    widget.ttsSpeaking.addListener(_retarget);
    widget.voiceLevel.addListener(_retarget);
    _phase.addListener(_tick);
    _retarget();
  }

  @override
  void didUpdateWidget(covariant _TranslationOrb old) {
    super.didUpdateWidget(old);
    if (old.ttsSpeaking != widget.ttsSpeaking) {
      old.ttsSpeaking.removeListener(_retarget);
      widget.ttsSpeaking.addListener(_retarget);
    }
    if (old.voiceLevel != widget.voiceLevel) {
      old.voiceLevel.removeListener(_retarget);
      widget.voiceLevel.addListener(_retarget);
    }
    if (old.on != widget.on) _retarget();
  }

  /// Deux régimes, comme demandé : la TTS pousse les barres à fond, une voix
  /// humaine ne fait que les faire frémir.
  void _retarget() {
    if (!widget.on) {
      _target = 0;
    } else if (widget.ttsSpeaking.value) {
      _target = 1.0;
    } else {
      final v = widget.voiceLevel.value;
      _target = v > 0.06 ? (0.16 + 0.24 * v).clamp(0.0, 0.4) : 0.0;
    }
    if (_target > 0 && !_phase.isAnimating) _phase.repeat();
  }

  void _tick() {
    final next = _amp.value + (_target - _amp.value) * 0.14;
    if (_target == 0 && next < 0.01) {
      _amp.value = 0;
      _phase.stop();
      return;
    }
    _amp.value = next;
  }

  @override
  void dispose() {
    widget.ttsSpeaking.removeListener(_retarget);
    widget.voiceLevel.removeListener(_retarget);
    _phase.removeListener(_tick);
    _phase.dispose();
    _amp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: AppStrings.t(
        widget.on ? 'call_translation_cut' : 'call_translation_resume',
      ),
      button: true,
      child: Pressable(
        bounce: true,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: Container(
          width: _TranslationOrb.size,
          height: _TranslationOrb.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.white.withValues(alpha: 0.28),
                blurRadius: 14,
                spreadRadius: 1,
              ),
            ],
          ),
          child: CustomPaint(
            painter: _OrbPainter(phase: _phase, amp: _amp, on: widget.on),
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.phase, required this.amp, required this.on})
      : super(repaint: Listenable.merge([phase, amp]));

  final Animation<double> phase;
  final ValueListenable<double> amp;
  final bool on;

  @override
  void paint(Canvas canvas, Size size) {
    final a = amp.value;
    final r = size.width / 2;
    final c = Offset(r, r);
    final rect = Rect.fromCircle(center: c, radius: r);

    // Coupée, la pastille perd ses reflets et devient blanc pur — on voit d'un
    // coup d'œil qu'elle ne traduit plus.
    final tint = on ? 1.0 : 0.0;

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          colors: [
            Colors.white,
            Color.lerp(Colors.white, SC.accent, 0.20 * tint)!,
            Color.lerp(Colors.white, SC.meshViolet, 0.28 * tint)!,
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(rect),
    );

    // Le liseré irisé.
    canvas.drawCircle(
      c,
      r - 0.7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = SweepGradient(
          colors: [
            Color.lerp(Colors.white, SC.accent, 0.55 * tint)!,
            Color.lerp(Colors.white, SC.meshViolet, 0.55 * tint)!,
            Color.lerp(Colors.white, SC.meshBlue, 0.45 * tint)!,
            Color.lerp(Colors.white, SC.accent, 0.55 * tint)!,
          ],
        ).createShader(rect),
    );

    // Les trois barres.
    final barW = size.width * 0.105;
    final gap = size.width * 0.095;
    final baseH = size.height * 0.20;
    final range = size.height * 0.30;
    final p = phase.value * 2 * math.pi;
    final bars = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(SC.accentDeep, Colors.white, on ? 0.0 : 0.55)!,
          Color.lerp(SC.meshViolet, Colors.white, on ? 0.0 : 0.55)!,
        ],
      ).createShader(rect);

    for (var i = -1; i <= 1; i++) {
      final wobble = 0.5 + 0.5 * math.sin(p + i * 1.1);
      final h = baseH +
          (i == 0 ? size.height * 0.05 : 0) +
          range * a * wobble;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(c.dx + i * (barW + gap), c.dy),
            width: barW,
            height: h,
          ),
          Radius.circular(barW / 2),
        ),
        bars,
      );
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.on != on;
}

/// The glass chevron that unfolds the blue controls above the dock — the same
/// pill as the one on a Discover card, a size up, and flipped: it points UP to
/// open them (they grow upward) and DOWN to fold them away again.
class _RailToggleButton extends StatelessWidget {
  const _RailToggleButton({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          // Pas de BackdropFilter ici : le bouton est POSÉ sur le dock, qui
          // floute déjà le fond — un second flou ne verrait que du verre et
          // coûterait une passe de plus.
          //
          // Déplié = engagé, donc blanc plein comme les bascules au-dessus :
          // les réglages sont ouverts, et ça se voit sans lire le chevron.
          color: open ? Colors.white : Colors.white.withValues(alpha: 0.14),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: open ? 0.0 : 0.22),
            width: 1,
          ),
        ),
        child: AnimatedRotation(
          turns: open ? 0.5 : 0.0,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          child: Icon(
            Icons.keyboard_arrow_up_rounded,
            color: open ? Colors.black : Colors.white,
            size: 26,
          ),
        ),
      ),
    );
  }
}

/// Un réglage d'appel, au-dessus du dock.
///
/// Les bascules suivent le geste natif (Téléphone / FaceTime d'iOS, WhatsApp) :
/// verre translucide au repos, **blanc plein et icône noire dès que l'état est
/// engagé** — muet, caméra coupée, haut-parleur. L'icône, elle, continue de
/// montrer l'état courant (micro barré quand on est muet) : le remplissage seul
/// est ambigu, on ne se souvient pas de la couleur "de repos" d'un bouton
/// (Nielsen Norman, «State-Switch Controls»). Les deux ensemble se lisent sans
/// rien avoir à retenir.
class _RoundCallButton extends StatelessWidget {
  const _RoundCallButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// L'état que porte ce bouton est engagé. Un bouton qui ouvre un panneau ne
  /// l'est jamais : il garde son verre.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final fill =
        active ? Colors.white : Colors.white.withValues(alpha: 0.14);
    // The label is no longer shown under the button (the icons speak for
    // themselves), but it is kept on Semantics so screen readers still
    // announce each control.
    return Semantics(
      label: label,
      button: true,
      toggled: active,
      child: Pressable(
        bounce: true,
        onTap: onTap,
        // Stable Flutter frosted-glass circle (NOT a platform view): the
        // native glass flickered/reset under the keyboard animation.
        child: ClipOval(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              width: 45,
              height: 45,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fill,
                border: Border.all(
                  color: Colors.white.withValues(alpha: active ? 0.0 : 0.22),
                ),
              ),
              child: Icon(
                icon,
                color: active ? Colors.black : Colors.white,
                size: 21,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Les deux langues de l'appel dans un seul panneau : « Langue que je parle »
/// à gauche, « Langue que j'entends » à droite, séparées par la flèche à deux
/// têtes qui dit que l'une va vers l'autre.
///
/// Une seule question par colonne, un seul drapeau affiché : on fait défiler la
/// roue jusqu'à celui qu'on veut. Rien n'est appliqué tant qu'on n'a pas
/// enregistré — chaque cran de la roue relancerait sinon le recogniser, ou
/// annoncerait une langue au pair, pour rien.
class _LanguagePairSheet extends StatelessWidget {
  const _LanguagePairSheet({
    required this.spokenCode,
    required this.heardCode,
    required this.onChanged,
  });

  final String spokenCode;
  final String heardCode;

  /// Appelé à chaque cran des roues. Rien n'est appliqué ici : c'est l'écran
  /// d'appel qui le fera quand le panneau se refermera.
  final void Function(String spoken, String heard) onChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetHandle(),
            _LanguageWheels(
              spokenCode: spokenCode,
              heardCode: heardCode,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

/// La poignée de tous les panneaux d'appel.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 18),
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// Les deux langues de l'appel : « Moi » à gauche, « Traduction » à droite,
/// séparées par la flèche à deux têtes qui dit que l'une va vers l'autre.
///
/// Une seule question par colonne, un seul drapeau affiché : on fait défiler la
/// roue jusqu'à celui qu'on veut. Rien n'est appliqué en direct — chaque cran
/// relancerait sinon le recogniser, ou annoncerait une langue au pair, pour des
/// drapeaux qu'on ne fait que survoler.
class _LanguageWheels extends StatefulWidget {
  const _LanguageWheels({
    required this.spokenCode,
    required this.heardCode,
    required this.onChanged,
    this.compact = false,
  });

  final String spokenCode;
  final String heardCode;
  final void Function(String spoken, String heard) onChanged;

  /// Serré : les deux roues partagent le panneau avec les réglages de son.
  final bool compact;

  @override
  State<_LanguageWheels> createState() => _LanguageWheelsState();
}

class _LanguageWheelsState extends State<_LanguageWheels> {
  late int _spoken = _indexOf(widget.spokenCode);
  late int _heard = _indexOf(widget.heardCode);

  void _report() => widget.onChanged(
        supportedLanguages[_spoken].code,
        supportedLanguages[_heard].code,
      );

  /// Une langue hors catalogue (ou vide) retombe sur la première : la roue doit
  /// toujours montrer quelque chose.
  static int _indexOf(String code) {
    final base = code.split('-').first.toLowerCase();
    final i = supportedLanguages.indexWhere((l) => l.code == base);
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _FlagWheel(
            title: AppStrings.t('call_lang_me'),
            icon: Icons.mic_rounded,
            index: _spoken,
            compact: widget.compact,
            onChanged: (i) {
              setState(() => _spoken = i);
              _report();
            },
          ),
        ),
        // La flèche à deux têtes : ce qui se dit d'un côté ressort de l'autre.
        // Posée à la hauteur des roues, pas des titres.
        Padding(
          padding: const EdgeInsets.only(top: 58),
          child: Icon(
            Icons.swap_horiz_rounded,
            size: widget.compact ? 16 : 22,
            color: Colors.white.withValues(alpha: 0.55),
          ),
        ),
        Expanded(
          child: _FlagWheel(
            title: AppStrings.t('call_lang_translation'),
            icon: Icons.hearing_rounded,
            index: _heard,
            compact: widget.compact,
            onChanged: (i) {
              setState(() => _heard = i);
              _report();
            },
          ),
        ),
      ],
    );
  }
}

/// Les deux panneaux d'un seul tenant, ouverts par un appui long sur la
/// pastille : le son à gauche, les langues à droite.
class _CallSettingsSheet extends StatelessWidget {
  const _CallSettingsSheet({
    required this.controller,
    required this.spokenCode,
    required this.heardCode,
    required this.onLanguagesChanged,
  });

  final AudioController controller;
  final String spokenCode;
  final String heardCode;
  final void Function(String spoken, String heard) onLanguagesChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetHandle(),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _AudioControls(controller: controller)),
                  // Le trait qui sépare les deux panneaux.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  Expanded(
                    child: _LanguageWheels(
                      spokenCode: spokenCode,
                      heardCode: heardCode,
                      onChanged: onLanguagesChanged,
                      compact: true,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Une roue de drapeaux : sa question au-dessus, un drapeau dans la fenêtre, le
/// nom de la langue en dessous. Les voisins restent visibles du coin de l'œil,
/// couchés par la perspective — c'est ce qui donne envie de faire défiler.
class _FlagWheel extends StatefulWidget {
  const _FlagWheel({
    required this.title,
    required this.icon,
    required this.index,
    required this.onChanged,
    this.compact = false,
  });

  final String title;

  /// Ce que fait cette colonne : ma voix qui entre, la traduction qui sort.
  final IconData icon;
  final int index;
  final ValueChanged<int> onChanged;

  /// Serré : la roue partage la largeur avec les réglages de son.
  final bool compact;

  @override
  State<_FlagWheel> createState() => _FlagWheelState();
}

class _FlagWheelState extends State<_FlagWheel> {
  late final FixedExtentScrollController _ctrl =
      FixedExtentScrollController(initialItem: widget.index);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(widget.icon, size: 13, color: SC.textMuted),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                widget.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: const TextStyle(
                  color: SC.textMuted,
                  fontSize: 12,
                  height: 1.25,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          height: widget.compact ? 70 : 84,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: ListWheelScrollView.useDelegate(
            controller: _ctrl,
            itemExtent: widget.compact ? 46 : 56,
            diameterRatio: 1.1,
            perspective: 0.006,
            physics: const FixedExtentScrollPhysics(),
            onSelectedItemChanged: widget.onChanged,
            childDelegate: ListWheelChildBuilderDelegate(
              childCount: supportedLanguages.length,
              // Sur le téléphone, l'emoji drapeau du système : c'est celui que
              // l'utilisateur voit partout ailleurs sur son appareil. Le web n'a
              // pas ce luxe — sous Windows le glyphe n'existe pas et Chrome
              // écrirait «FR» — alors là, on dessine le SVG rond.
              builder: (ctx, i) => Center(
                child: kIsWeb
                    ? CountryFlag.fromCountryCode(
                        supportedLanguages[i].countryCode,
                        theme: ImageTheme(
                          width: widget.compact ? 32 : 40,
                          height: widget.compact ? 32 : 40,
                          shape: const Circle(),
                        ),
                      )
                    : Text(
                        supportedLanguages[i].flag,
                        style: TextStyle(fontSize: widget.compact ? 30 : 38),
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          supportedLanguages[widget.index].label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: SC.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// In-call audio panel — just the sliders: mic level, translation volume and
/// original-voice volume. (The ducking toggle + speaker/earpiece route were
/// dropped on request.)
class _AudioSettingsSheet extends StatelessWidget {
  const _AudioSettingsSheet({required this.controller});

  final AudioController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetHandle(),
            _AudioControls(controller: controller),
          ],
        ),
      ),
    );
  }
}

/// Les deux volumes de l'appel : la vraie voix d'abord, sa traduction ensuite —
/// l'ordre dans lequel les deux arrivent à l'oreille. Le réglage s'entend
/// pendant qu'on le bouge ; rien à valider.
class _AudioControls extends StatelessWidget {
  const _AudioControls({required this.controller});

  final AudioController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SheetLabel(
              icon: Icons.mic_rounded,
              text: AppStrings.t('call_original_volume'),
            ),
            Slider(
              value: controller.originalVolume.clamp(0.0, 1.0).toDouble(),
              onChanged: controller.setOriginalVolume,
              activeColor: SC.accent,
              inactiveColor: Colors.white24,
            ),
            const SizedBox(height: 6),
            _SheetLabel(
              icon: Icons.hearing_rounded,
              text: AppStrings.t('call_translation_volume'),
            ),
            Slider(
              value: controller.translatedVolume.clamp(0.0, 1.0).toDouble(),
              onChanged: controller.setTranslatedVolume,
              activeColor: SC.accent,
              inactiveColor: Colors.white24,
            ),
          ],
        );
      },
    );
  }
}

/// Le libellé d'un réglage : son icône, puis son nom.
class _SheetLabel extends StatelessWidget {
  const _SheetLabel({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: SC.textMuted),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              color: SC.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraOffTile extends StatelessWidget {
  const _CameraOffTile({this.label, this.compact = false, this.muted = false});

  final String? label;
  final bool compact;

  /// This participant's mic is off. Both sides render it — a peer's mute
  /// arrives as a LiveKit `TrackMutedEvent`, our own from `_micOn` — so each
  /// caller can see who has gone silent.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final fontSize = compact ? 13.0 : 24.0;
    final iconSize = compact ? 28.0 : 56.0;
    final hasLabel = label != null && label!.isNotEmpty;
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.videocam_off_rounded,
            size: iconSize,
            color: Colors.white.withValues(alpha: 0.35),
          ),
          if (hasLabel) ...[
            SizedBox(height: compact ? 6 : 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (muted) ...[
                    Icon(
                      Icons.mic_off_rounded,
                      size: fontSize + 2,
                      color: const Color(0xFFFF3B30),
                    ),
                    SizedBox(width: compact ? 4 : 6),
                  ],
                  Flexible(
                    child: Text(
                      label!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: fontSize,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
