import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart';

import '../services/analytics.dart';
import '../services/translation_api.dart';
import 'sway_utterance_recorder_base.dart';
import 'sway_utterance_recorder_io.dart'
    if (dart.library.js_interop) 'sway_utterance_recorder_web.dart';
import 'realtime_translation_port.dart';
import 'translation_route.dart';

/// Sender-side the cloud engine translation, chunk-based — the PROVEN capture path.
///
/// Mirrors [SwayChunkTranslation] but records the LOCAL mic (what I say) using
/// the same `MediaRecorder`-backed [SwayUtteranceRecorder] that already captures
/// reliably (Web Audio streaming gave silence — level=0). VAD = LiveKit
/// active-speaker for the LOCAL participant. On each utterance we POST the clip
/// to `/translation/voice` (the cloud engine STT → translate → TTS), then PUSH {orig, trans,
/// lang, audio} to the peer over the data channel; the peer displays it and
/// plays the cloud mp3 directly (call_screen `_onCaptionData`). Both phones run
/// this, so both directions are translated.
class SwayChunkSenderTranslation extends ChangeNotifier
    implements RealtimeTranslationPort {
  /// Ce que je viens de dire, dans MA langue — la légende locale s'y abonne.
  final ValueNotifier<SpokenLine> _localTranscript =
      ValueNotifier<SpokenLine>(const SpokenLine(seq: 0, text: ''));
  int _transcriptSeq = 0;

  @override
  ValueListenable<SpokenLine> get localTranscript => _localTranscript;

  /// Appelé par le pipeline dès qu'une phrase est reconnue au micro.
  void _emitLocalTranscript(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    _localTranscript.value = SpokenLine(seq: ++_transcriptSeq, text: t);
  }

  /// Must match call_screen's `_captionTopic`.
  static const String _captionTopic = 'swayco-chat';

  Room? _room;
  TranslationRoute? _route;
  EventsListener<RoomEvent>? _listener;

  /// The local mic track we record from.
  LocalAudioTrack? _recordTrack;
  String? _boundSid;

  SwayUtteranceRecorder? _recorder;

  bool _localHot = false;
  bool _attached = false;

  // ─── utterance state machine ───────────────────────────────────────────
  bool _recording = false;
  DateTime? _utteranceStartedAt;
  Timer? _hangoverTimer;
  Timer? _maxTimer;

  static const Duration _hangover = Duration(milliseconds: 700);
  static const Duration _maxUtterance = Duration(seconds: 12);
  static const Duration _minUtterance = Duration(milliseconds: 280);
  static const int _minBytes = 800;
  static const int _maxAudioB64 = 60000;

  int _sent = 0;
  String? _lastTranscript;
  String? _lastTranslation;
  String? _lastError;
  int _inFlight = 0;

  @override
  Listenable? get translationListenable => this;

  @override
  TranslationFeedbackPhase get translationFeedbackPhase {
    if (_room == null || _route == null || !_route!.isConfigured) {
      return TranslationFeedbackPhase.hidden;
    }
    if (_recordTrack == null) return TranslationFeedbackPhase.standby;
    if (_recording || _inFlight > 0) return TranslationFeedbackPhase.working;
    return TranslationFeedbackPhase.live;
  }

  @override
  bool get translationRemoteVoiceHot => false;

  @override
  bool get translationSpeaking => false;

  @override
  Future<void> setTranslatedAudioVolume(double volume) async {}

  @override
  Widget? buildTranslationAudioOverlay() => null;

  @override
  String get translationDiagnostics {
    final route = _route;
    final routeLabel = route == null
        ? 'NULL'
        : (!route.isConfigured
            ? 'NON-CONFIG'
            : '${route.sourceBcp47}→${route.targetBcp47}');
    final trk = _recordTrack != null ? 'OUI' : 'NON';
    final state = _recording ? 'enregistre' : (_inFlight > 0 ? 'envoi…' : 'prêt');
    final lines = <String>[
      'Stream SND(TEST): $state • micro: $trk • route: $routeLabel • envois: $_sent',
    ];
    if (_lastTranscript != null) lines.add('STT: $_lastTranscript');
    if (_lastTranslation != null) lines.add('TRAD: $_lastTranslation');
    if (_lastError != null) lines.add('ERR: $_lastError');
    return lines.join('\n');
  }

  // ─── attach / detach ────────────────────────────────────────────────────
  @override
  Future<void> attachToRoom(Room room, {required TranslationRoute route}) async {
    await detach();
    _room = room;
    _route = route;
    _attached = true;
    debugPrint('[sway-snd] attach configured=${route.isConfigured} '
        '${route.sourceBcp47}->${route.targetBcp47}');
    if (!route.isConfigured) return;

    _listener = room.createListener()
      ..on<LocalTrackPublishedEvent>((e) {
        if (e.publication.track is LocalAudioTrack) _bindLocalTrack();
      })
      ..on<LocalTrackUnpublishedEvent>((e) {
        if (e.publication.track is LocalAudioTrack) _bindLocalTrack();
      })
      ..on<ActiveSpeakersChangedEvent>(_onActiveSpeakersChanged);

    _bindLocalTrack();
    notifyListeners();
  }

  @override
  Future<void> detach() async {
    _attached = false;
    _hangoverTimer?.cancel();
    _hangoverTimer = null;
    _maxTimer?.cancel();
    _maxTimer = null;
    await _abortUtterance();
    _recordTrack = null;
    _boundSid = null;
    _localHot = false;
    await _listener?.dispose();
    _listener = null;
    _room = null;
    _route = null;
  }

  @override
  void dispose() {
    unawaited(detach());
    super.dispose();
  }

  // ─── local track binding ─────────────────────────────────────────────────
  void _bindLocalTrack() {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    LocalAudioTrack? pick;
    String? pickSid;
    for (final pub in lp.audioTrackPublications) {
      final t = pub.track;
      if (t is LocalAudioTrack) {
        pick = t;
        pickSid = pub.sid;
        break;
      }
    }
    if (pick == null) {
      if (_recordTrack != null) {
        _recordTrack = null;
        _boundSid = null;
        notifyListeners();
      }
      return;
    }
    if (pickSid == _boundSid && _recordTrack != null) return;
    _recordTrack = pick;
    _boundSid = pickSid;
    debugPrint('[sway-snd] bound local mic track sid=$pickSid');
    notifyListeners();
  }

  // ─── VAD endpointing (LOCAL speaker) ─────────────────────────────────────
  void _onActiveSpeakersChanged(ActiveSpeakersChangedEvent e) {
    final hot = e.speakers.any((p) => p is LocalParticipant);
    if (hot == _localHot) {
      if (hot) _hangoverTimer?.cancel();
      return;
    }
    _localHot = hot;
    if (hot) {
      _hangoverTimer?.cancel();
      _hangoverTimer = null;
      _maybeStartUtterance();
    } else if (_recording) {
      _hangoverTimer?.cancel();
      _hangoverTimer = Timer(_hangover, () {
        if (!_localHot && _recording) _finalizeUtterance();
      });
    }
    notifyListeners();
  }

  void _maybeStartUtterance() {
    if (!_attached || _recording) return;
    final track = _recordTrack;
    if (track == null) return;
    final route = _route;
    if (route == null || !route.isConfigured) return;
    unawaited(_startUtterance(track));
  }

  Future<void> _startUtterance(LocalAudioTrack track) async {
    final rec = createSwayRecorder();
    try {
      await rec.start(track.mediaStreamTrack);
    } catch (e) {
      _lastError = _short('rec.start', e);
      debugPrint('[sway-snd] recorder start failed: $e');
      try {
        await rec.dispose();
      } catch (_) {}
      notifyListeners();
      return;
    }
    _recorder = rec;
    _recording = true;
    _utteranceStartedAt = DateTime.now();
    _maxTimer?.cancel();
    _maxTimer = Timer(_maxUtterance, () {
      if (_recording) _finalizeUtterance();
    });
    debugPrint('[sway-snd] recording started');
    notifyListeners();
  }

  Future<void> _finalizeUtterance() async {
    if (!_recording) return;
    final rec = _recorder;
    final startedAt = _utteranceStartedAt;
    _recorder = null;
    _recording = false;
    _hangoverTimer?.cancel();
    _hangoverTimer = null;
    _maxTimer?.cancel();
    _maxTimer = null;
    _utteranceStartedAt = null;
    notifyListeners();

    if (rec == null) return;
    final filename = rec.filename;
    final tooShort = startedAt != null &&
        DateTime.now().difference(startedAt) < _minUtterance;
    final bytes = await rec.stopAndRead();
    debugPrint('[sway-snd] utterance bytes=${bytes?.length ?? -1} tooShort=$tooShort');
    if (tooShort || bytes == null || bytes.length < _minBytes) {
      return;
    }
    unawaited(_sendAndForward(bytes, filename));
  }

  Future<void> _abortUtterance() async {
    _recording = false;
    final rec = _recorder;
    _recorder = null;
    _hangoverTimer?.cancel();
    _hangoverTimer = null;
    _maxTimer?.cancel();
    _maxTimer = null;
    _utteranceStartedAt = null;
    if (rec != null) {
      try {
        await rec.dispose();
      } catch (_) {}
    }
  }

  /// POST the clip → the cloud engine (STT/translate/TTS) → push {orig, trans, lang, audio}
  /// to the peer. Sender-side route: from = my language, to = the peer's.
  Future<void> _sendAndForward(Uint8List bytes, String filename) async {
    final route = _route;
    final room = _room;
    if (route == null || !route.isConfigured || room == null) return;
    _inFlight++;
    _sent++;
    notifyListeners();
    try {
      final result = await fetchVoiceTranslation(
        audioBytes: bytes,
        to: route.targetBcp47,
        from: route.sourceBcp47,
        filename: filename,
      );
      if (result == null) return; // 204 / recoverable
      final orig = (result.transcript ?? '').trim();
      final trans = (result.translation ?? '').trim();
      _lastTranscript = orig;
      _lastTranslation = trans;
      _lastError = null;
      // Mes propres mots, dans MA langue → la légende locale les affiche.
      _emitLocalTranscript(orig);
      if (trans.isEmpty && orig.isEmpty) return;

      final map = <String, dynamic>{
        'orig': orig,
        'trans': trans,
        'lang': route.targetBcp47,
      };
      final audio = result.audio;
      if (audio != null && audio.isNotEmpty) {
        final b64 = base64Encode(audio);
        if (b64.length <= _maxAudioB64) map['audio'] = b64;
      }
      debugPrint('[sway-snd] forward orig="$orig" trans="$trans" '
          'audio=${(map['audio'] as String?)?.length ?? 0}b');
      await room.localParticipant?.publishData(
        Uint8List.fromList(utf8.encode(jsonEncode(map))),
        reliable: true,
        topic: _captionTopic,
      );
      Analytics.track(
        'translation_sent',
        langFrom: route.sourceBcp47,
        langTo: route.targetBcp47,
        props: {'phase': 'grok_snd'},
      );
    } on TranslationApiException catch (e) {
      _lastError = _short('stream', e);
    } catch (e) {
      _lastError = _short('stream', e);
    } finally {
      _inFlight--;
      notifyListeners();
    }
  }

  static String _short(String phase, Object e) {
    var s = e.toString().replaceAll('\n', ' ');
    if (s.length > 90) s = '${s.substring(0, 90)}…';
    return '$phase: $s';
  }
}
