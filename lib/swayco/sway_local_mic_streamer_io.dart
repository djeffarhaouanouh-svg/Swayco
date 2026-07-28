import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../services/call_audio.dart';
import '../services/debug_overlay.dart';
import 'sway_webrtc_mic_tap.dart';
import 'asr/asr_model_downloader.dart';
import 'asr/asr_service.dart';
import 'asr/transcript_guard.dart';
import '../services/translation_api.dart';
import '../services/user_prefs.dart';
import 'sway_mic_streamer_base.dart';
import 'sway_mic_streamer_io.dart' show createCloudMicStreamer;

/// Native (iOS/Android) SENDER-side pipeline, fully on-device for the STT step.
///
/// Replaces the cloud WebSocket: instead of shipping mic PCM to a remote STT
/// proxy, the audio never leaves the phone. Only the recognised **text** goes
/// out, to the backend text-translation endpoint.
///
///   record (PCM16 16 kHz, system AEC) → VAD segmentation → neural|lattice
///     → fetchTextTranslation → onTranslation → peer synthesises with its device TTS
///
/// STT runs on the LOCAL outgoing mic, never the remote track, and that mic is
/// echo-cancelled — otherwise it would re-capture the translated voice coming
/// out of the loudspeaker and transcribe it as if the user had spoken it.
class LocalSttMicStreamer implements SwayMicStreamer {
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _audioSub;
  bool _running = false;
  bool _modelReady = false;


  /// Set when on-device STT is unavailable and we hand the call back to the
  /// remote cloud pipeline. Every member below then delegates to it.
  SwayMicStreamer? _fallback;

  String _sourceLang = '';
  String _targetLang = '';
  void Function(String orig, String trans, String lang, String audioB64)?
      _onTranslation;
  void Function(String error)? _onError;

  // Retained so the fallback can be started with the arguments we were given.
  Uri? _wsUrl;
  Object? _localTrack;
  void Function(String partial)? _onPartial;

  /// Last frame that carried voice. The STREAMING engine's backstop only —
  /// the VAD holds its own state for the clip engines.
  int _lastVoiceMs = 0;

  /// True while the mute / half-duplex gate is dropping audio. Edge-triggered so
  /// we reset the streaming decoder once on entry, not on every dropped frame.
  bool _gated = false;

  /// Whether our `record` capture is currently open, and whether it SHOULD be.
  ///
  /// Dropping buffers is enough to stop translating, but it leaves a SECOND
  /// capture open on a microphone LiveKit already holds — the two then share one
  /// audio session, and on iOS the voice-processing gain that session applies
  /// drives the signal into clipping (peak 1.000 in the phrase log, against
  /// 0.3-0.7 once the LiveKit track is stopped). A muted mic must therefore be
  /// released, not merely ignored.
  ///
  /// Two fields rather than one because a mute can flip twice before the first
  /// `stop()` has even returned: the listener only records the WANTED state, and
  /// the serialized worker converges on it.
  bool _captureOpen = false;
  bool _captureWanted = true;

  /// True while the capture is the WebRTC tap (iOS) rather than a `record`
  /// stream. Decides which one [_closeCapture] / [stop] must tear down.
  bool _tapActive = false;

  /// Capture open/close operations, serialized. Deliberately separate from
  /// [_sttChain]: that one guards the native decoder, and a capture restart must
  /// not queue behind a pending transcription (nor the reverse).
  Future<void> _captureChain = Future.value();

  /// Frames seen since start. The web streamer logs this and it is the first
  /// thing you want when nothing is transcribed: it separates "the mic gives us
  /// nothing" from "the recogniser gives us nothing". On iOS `record` opens a
  /// SECOND capture of a mic LiveKit already holds, which is exactly the kind of
  /// failure that shows up as a silent, well-behaved stream of zeroes.
  int _frames = 0;

  /// Last partial we surfaced, so we don't log or re-emit an unchanged one.
  String _lastPartial = '';

  /// True while the decoder holds an un-closed hypothesis. Separate from
  /// [_lastPartial] on purpose: that one is display state, this one is the
  /// backstop's trigger, and conflating them made a stale partial re-arm a
  /// flush that then returned "" from an already-finalised recognizer.
  bool _hasPending = false;

  /// Every operation that touches the recognizer runs through this chain.
  /// `acceptFrame` and `flush` mutate the same native decoder, and both used to
  /// be fired unawaited from the audio callback — so they interleaved across
  /// their await points. Networked translation deliberately stays OFF the chain:
  /// awaiting an HTTP round trip here stalled the next utterance's flush, which
  /// is exactly why only the first sentence of a pair was ever sent.
  Future<void> _sttChain = Future.value();

  void _serialize(Future<void> Function() op) {
    _sttChain = _sttChain
        .then((_) => op())
        .catchError((Object e) => DebugOverlay.log('stt op error: $e'));
  }

  /// The VAD (sherpa-onnx) — what decides where a phrase begins and ends for
  /// a CLIP engine (universal, neural). It replaced a mean-square energy
  /// threshold, which fired on doors, keyboards and breath, and could not tell
  /// speech from noise of the same loudness.
  ///
  /// It does its own min-speech and max-speech bounding, so the old
  /// `_minUtteranceSamples` / `_maxUtteranceSamples` guards are gone with it.
  sherpa.VoiceActivityDetector? _vad;
  static bool _sherpaBindingsReady = false;

  /// The VAD cuts on any pause this long — short, deliberately. These are not the
  /// phrase boundaries: they are every real silence in the audio, including the
  /// ones inside a sentence (commas, breath). [_mergeGapMs] is what turns them
  /// back into phrases.
  ///
  /// Splitting the job in two is what lets us never cut mid-word. A single
  /// endpoint value cannot: set it long (700 ms) and a speaker who does not pause
  /// — a synthetic voice, someone reading — runs until the hard cap and gets
  /// guillotined mid-syllable; set it short and ordinary sentences are chopped in
  /// half. Cutting at every real silence and re-joining afterwards gives both.
  ///
  /// Lowered 0.35 → 0.30 to shave latency: the VAD closes each segment 50 ms
  /// sooner. Must stay well below [_mergeGapMs], or a segment could be cut on a
  /// gap wider than the merge window and never re-joined to its own sentence.
  static const double _silenceSeconds = 0.30;

  /// Silence that ends a PHRASE. Segments separated by less than this are the
  /// same sentence and are re-joined before they reach the recogniser.
  ///
  /// One value for every language, on purpose. The chopped-sentence bug was
  /// never this threshold: measured on the TTS actually used for testing, the
  /// pauses INSIDE a sentence are 380-460 ms and the ones between sentences
  /// ~700 ms — already far under the 1400 ms it was briefly raised to, and it
  /// chopped anyway. The real cause was [_flushIfIdle] closing a phrase while
  /// the speaker was still mid-burst; with that fixed, 700 ms keeps clauses
  /// together AND still closes on a genuine end-of-sentence pause, so the peer
  /// hears a sentence as soon as it lands instead of waiting out a whole
  /// paragraph. A speaker who never really pauses stays in one clip — correct:
  /// bubbles follow real silences, they are not cut artificially.
  ///
  /// Settled at 600 ms. 700 was the safe original; 500 shaved latency but chopped
  /// — on a live call a speaker hesitated ~597 ms mid-clause and 500 split it, so
  /// the transcript lost a word. 600 clears those ~597 ms hesitations for +100 ms
  /// vs 500, and the cost of over-merging is now nil: per-sentence STREAMING
  /// re-splits a merged phrase on its own sentence boundaries, so a slightly
  /// generous merge stays fluid. Total wait = [_silenceSeconds] + this = ~900 ms.
  static const int _mergeGapMs = 600;

  /// A speaker who never pauses has to be cut somewhere. We hold at most this
  /// much before sending — and we cut at the LAST REAL SILENCE inside it, never
  /// mid-word.
  ///
  /// NOT 30 s, however tempting: the recogniser reads exactly 30 s of audio and the
  /// engine appends 3 s of tail padding ([UniversalAsrEngine._tailPaddings]), so
  /// anything past ~27 s is TRUNCATED and the words in it are genuinely lost —
  /// the one outcome this whole change exists to prevent. 26 s + 3 s of padding
  /// sits just under the ceiling.
  ///
  /// This is straight latency for a monologue: 26 s of speech means the peer
  /// waits 26 s. That is the price of never cutting mid-sentence.
  static const int _maxMergedMs = 26000;

  /// Hard ceiling on one VAD segment: a voice with genuinely no pause at all
  /// for this long is cut regardless. Unavoidable, and rare.
  static const double _maxSpeechSeconds = 15.0;

  /// Shorter than this is a cough, a click, a chair — and, crucially, a scrap of
  /// our own loudspeaker. Raised from 0.25 s: the recogniser hallucinates in direct
  /// proportion to how little speech it is given, and a 250 ms fragment is
  /// exactly what it captions with subtitle boilerplate.
  static const double _minSpeechSeconds = 0.4;

  /// The VAD's speech-probability threshold (0..1). Above sherpa's 0.5 default:
  /// every marginal segment that squeaks past becomes a hallucination
  /// spoken out loud on the peer's phone, so the cost of a false positive here
  /// is far higher than the cost of missing a mumbled word.
  static const double _speechProbThreshold = 0.6;

  /// Peak amplitude a segment must reach to be worth transcribing (0..1).
  ///
  /// The last line against our own echo. The VAD says "this is speech" — and it
  /// is right, it IS speech: it is the translation coming out of our own
  /// loudspeaker, and the VAD has no idea whose voice it is. But that residue,
  /// once AEC has had it and with AGC off, is far quieter than someone actually
  /// talking into the phone. Level is the one thing that still tells them apart.
  static const double _speechFloor = 0.06;

  /// Transcriptions run one at a time, in order. See [_sendPending].
  Future<void> _asrQueue = Future.value();

  /// The phrase being assembled out of the VAD's chunks — see [_drainSegmenter].
  final List<double> _pending = [];

  /// Where the last chunk ended, in the VAD's own sample clock. Compared against
  /// the next chunk's start to measure the silence between them.
  int _pendingEndSample = 0;

  /// Wall clock of the last chunk appended, so [_flushIfIdle] can tell that the
  /// speaker has stopped — silence produces no VAD event to react to.
  int _pendingLastMs = 0;

  /// Loudest sample across the whole assembled phrase.
  double _pendingPeak = 0;

  /// Set when a chunk arrived on the gate's closing edge: the phrase predates the
  /// mute press and must be published anyway.
  bool _pendingForce = false;

  /// Last transcript we accepted, and when. An identical one inside this window
  /// is our own translation coming back around, not the user saying it twice.
  String _lastOrig = '';
  int _lastOrigMs = 0;
  static const int _repeatWindowMs = 8000;

  /// The last few turns of the conversation — BOTH sides, in arrival order,
  /// each as its ORIGINAL text rather than the translation. Handed to the
  /// translator as context for the next utterance, since each one is otherwise
  /// translated in its own request knowing nothing of what came before.
  ///
  /// Verified to matter: 「疲れた。」 alone comes back "Je suis crevé"
  /// (masculine); with lines behind it establishing the speaker is a woman it
  /// comes back "Je suis fatiguée". The peer's half earns its place too — a
  /// reply ("oui, avec plaisir") is meaningless without the question it answers,
  /// and quoting the peer's own wording keeps terms consistent: they said
  /// ポートフォリオ, so our "portfolio" goes back as ポートフォリオ, not a synonym.
  ///
  /// Deliberately shallow: a call runs for minutes, so the prompt must not grow
  /// with it. Two turns is enough to disambiguate a "oui" or fix an agreement,
  /// and going deeper buys little — measured, 5 turns instead of 2 costs ~7%
  /// more per call, because the bill is dominated by the OUTPUT tokens, not by
  /// the context. The backend caps history on its side too.
  final List<TranslationHistoryItem> _history = [];
  static const int _historyDepth = 2;

  void _note(String author, String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    _history.add(TranslationHistoryItem(author: author, text: t));
    while (_history.length > _historyDepth) {
      _history.removeAt(0);
    }
  }

  /// This speaker's self-declared grammatical gender (`m` / `f` / `x`), read
  /// once per call from the local profile. Empty when unknown — we then send no
  /// gender and the translator falls back to its own guess, as before.
  String _myGender = '';

  /// The peer's gender. A setter rather than a [start] argument because their
  /// profile is fetched asynchronously and often lands after the call connects.
  String _peerGender = '';

  @override
  set peerGender(String value) => _peerGender = value.trim();

  void Function(String heard)? _onDropped;

  @override
  set onDropped(void Function(String heard)? value) => _onDropped = value;

  @override
  void notePeerUtterance(String orig) => _note('peer', orig);

  // Kept for the STREAMING engine (lattice) only, whose endpointer sometimes never
  // fires: if a hypothesis is pending and the mic has been quiet this long, we
  // force the close ourselves. Unused by the clip engines, which the VAD segments.
  static const double _vadThreshold = 0.0002;
  static const int _silenceFlushMs = 700;

  static const int _sampleRate = 16000;

  @override
  bool get isRunning => _fallback?.isRunning ?? _running;

  @override
  bool get isStreaming => _fallback?.isStreaming ?? (_running && _modelReady);

  /// the cloud engine re-sends the growing session transcript; the on-device path emits
  /// independent utterances. The caller reads this per callback, so it tracks
  /// whichever pipeline is actually live.
  @override
  bool get accumulatesTranscript => _fallback?.accumulatesTranscript ?? false;

  /// The mic now stays open for the whole call — dozing (releasing it after 20 s
  /// of silence, to spare the battery) is gone. It cost the first syllable of
  /// every phrase that woke it, and the VAD is cheap enough to run continuously.
  @override
  bool get isDozing => _fallback?.isDozing ?? false;

  @override
  Future<void> start({
    required Uri wsUrl, // unused: nothing is streamed off-device
    Object? localTrack,
    bool captureLocalMic = true,
    String sourceLang = '',
    String targetLang = '',
    required void Function(String orig, String trans, String lang, String audioB64)
        onTranslation,
    void Function(String partial)? onPartial,
    void Function(String error)? onError,
  }) async {
    if (_running) return;
    if (!captureLocalMic) {
      onError?.call('native_no_remote_capture');
      return;
    }
    if (sourceLang.isEmpty || targetLang.isEmpty) {
      onError?.call('no_route');
      return;
    }
    _sourceLang = sourceLang;
    _targetLang = targetLang;
    _history.clear(); // a new call starts with no conversation behind it
    // Our own grammatical gender, handed to the translator. Japanese marks no
    // gender and French demands it on the very first adjective, so without this
    // every woman is translated "je suis prêt" / "je suis crevé" — or worse, the
    // model hedges with "content(e)" and "allé(e) seul(e)", which the TTS then
    // reads out loud, parenthesis and all. Best-effort: no profile, or gender
    // never set, means we send nothing and behave exactly as before.
    try {
      _myGender = (await UserPrefs.loadProfile())?.gender.trim() ?? '';
    } catch (_) {
      _myGender = '';
    }
    _onTranslation = onTranslation;
    _onError = onError;
    _onPartial = onPartial;
    _wsUrl = wsUrl;
    _localTrack = localTrack;
    _running = true;

    try {
      if (!await _rec.hasPermission()) {
        onError?.call('no_mic_permission');
        _running = false;
        return;
      }

      if (!AsrService.supportsLang(sourceLang)) {
        await _startFallback('unsupported_lang:$sourceLang');
        return;
      }

      // the VAD (~2 MB) is fetched once and shared by every language. Without it
      // a clip engine has nothing to tell it where a phrase ends, so it would
      // never transcribe anything — hence the fallback.
      unawaited(_startSegmenter());

      // First call in a language downloads the model (universal: ~357 MB).
      // Capture starts anyway so the call is never blocked on it; utterances are
      // dropped until ready.
      unawaited(
        AsrService.instance.ensureLanguageInstalled(sourceLang).then((_) async {
          _modelReady = AsrService.instance.isReady;
          DebugOverlay.log('stt model ready=$_modelReady lang=$sourceLang');
          // Download failed, or the engine could not load — most often libvosk
          // missing on this platform. Hand the call to the cloud engine rather than let the
          // user speak into a pipeline that will never answer.
          if (!_modelReady) await _startFallback('model_unavailable');
        }),
      );

      // Muting must RELEASE the mic, not just silence it, so follow the flag's
      // transitions rather than only reading it per buffer.
      addSendMutedListener(_onSendMutedChanged);
      _captureWanted = !isSendMuted;
      if (_captureWanted) await _startCapture();
    } catch (e) {
      // record_ios throws here when inputNode.setVoiceProcessingEnabled() is
      // refused — which is what a clash with WebRTC's own VoiceProcessingIO on
      // the same mic looks like. Worth its own line: it is not an STT failure.
      DebugOverlay.log('stt START FAILED: $e');
      onError?.call('start_failed: $e');
      await stop();
    }
  }

  /// The user muted or unmuted. Release the microphone outright while muted:
  /// LiveKit has already stopped ITS capture (`stopOnMute` is on for every
  /// platform but Firefox), so continuing to hold ours is what keeps two
  /// captures alive on a call that is supposed to be silent.
  ///
  /// Whatever the recogniser was holding when the mute landed is flushed FIRST,
  /// with `force`, exactly as the per-buffer gate does — those words were spoken
  /// before the press, on purpose, and closing the capture would otherwise
  /// swallow the sentence a mute interrupts.
  void _onSendMutedChanged(bool muted) {
    if (!_running) return;
    // The cloud fallback owns its own recorder; it reads `isSendMuted` itself.
    if (_fallback != null) return;

    if (muted && !_gated) {
      _gated = true;
      DebugOverlay.log('stt gate CLOSED (muted)');
      final onTranslation = _onTranslation;
      if (onTranslation != null) _flushForGateClose(onTranslation);
    }

    _captureWanted = !muted;
    _captureChain = _captureChain
        .then((_) => _applyCaptureState())
        .catchError((Object e) => DebugOverlay.log('stt capture toggle error: $e'));
  }

  /// Converge the capture on [_captureWanted]. Re-read at the moment it runs, so
  /// a mute/unmute burst settles on the final state instead of replaying each
  /// step of it.
  Future<void> _applyCaptureState() async {
    if (!_running) return;
    if (_captureWanted == _captureOpen) return;
    if (_captureWanted) {
      try {
        await _startCapture();
      } catch (e) {
        // The mic did not come back. Say so loudly: the call carries on with no
        // translation at all, and silence is indistinguishable from "nobody
        // spoke" unless it is on the record.
        DebugOverlay.log('stt capture FAILED to reopen after unmute: $e');
        _onError?.call('capture_reopen_failed: $e');
      }
    } else {
      await _closeCapture();
    }
  }

  /// Release the microphone. The recogniser and the VAD are left alone — the
  /// user is expected to unmute and carry on, and rebuilding them costs a model
  /// load.
  Future<void> _closeCapture() async {
    await _audioSub?.cancel();
    _audioSub = null;
    await _stopCaptureSource();
    _captureOpen = false;
    DebugOverlay.log('stt capture RELEASED (muted) — mic left to LiveKit alone');
  }

  /// The tap can attach cleanly and still deliver nothing — that is exactly how
  /// the first attempt (AddSink on the track source) failed, silently. Silence
  /// is otherwise indistinguishable from "nobody spoke", so give it a few
  /// seconds and fall back to `record` rather than run a whole call with no
  /// translation at all. The log line is what tells the two apart.
  void _armTapWatchdog() {
    Timer(const Duration(seconds: 5), () {
      if (!_running || !_tapActive) return;
      if (SwayWebrtcMicTap.instance.receiving) return;
      DebugOverlay.log('stt tap delivered NO audio in 5s — falling back to '
          'record (the whistle may come back; this line is the reason)');
      _captureChain = _captureChain.then((_) async {
        if (!_running || !_tapActive) return;
        await _audioSub?.cancel();
        _audioSub = null;
        await _stopCaptureSource(); // clears _tapActive
        _captureOpen = false;
        await _startCapture();
      }).catchError((Object e) {
        DebugOverlay.log('stt tap fallback error: $e');
      });
    });
  }

  /// Tear down whichever capture source is live — the WebRTC tap or `record`.
  Future<void> _stopCaptureSource() async {
    if (_tapActive) {
      _tapActive = false;
      try {
        await SwayWebrtcMicTap.instance.stop();
      } catch (e) {
        DebugOverlay.log('stt tap stop error: $e');
      }
    } else {
      try {
        await _rec.stop();
      } catch (e) {
        DebugOverlay.log('stt capture stop error: $e');
      }
    }
  }

  /// Download the VAD once and build the detector. Its buffer holds
  /// [_maxSpeechSeconds] plus a margin, so a long phrase is never truncated by
  /// the ring buffer before the VAD itself cuts it.
  Future<void> _startSegmenter() async {
    try {
      final model = await AsrModelDownloader.ensureSegmenter();
      if (!_running || _vad != null) return;
      if (!_sherpaBindingsReady) {
        sherpa.initBindings();
        _sherpaBindingsReady = true;
      }
      // `sileroVad` names the architecture the segmenter graph was exported in —
      // sherpa dispatches on the field, so it is the runtime's vocabulary, not
      // ours. Everything else here calls it the segmenter.
      _vad = sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: model,
            threshold: _speechProbThreshold,
            minSilenceDuration: _silenceSeconds,
            minSpeechDuration: _minSpeechSeconds,
            maxSpeechDuration: _maxSpeechSeconds,
          ),
          sampleRate: _sampleRate,
          debug: false,
        ),
        bufferSizeInSeconds: _maxSpeechSeconds + 5,
      );
      DebugOverlay.log('stt VAD ready — '
          '${(_silenceSeconds * 1000).round()}ms silence closes a phrase');
    } catch (e) {
      DebugOverlay.log('stt VAD FAILED: $e');
      await _startFallback('vad_unavailable');
    }
  }

  /// Tear down our capture and run the remote the cloud engine streamer instead.
  Future<void> _startFallback(String reason) async {
    if (_fallback != null || !_running) return;
    DebugOverlay.log('stt fallback → the cloud engine ($reason)');

    await _audioSub?.cancel();
    _audioSub = null;
    _freeSegmenter();
    await _stopCaptureSource();
    // Ours is closed for good; from here the fallback owns the microphone, and
    // [_onSendMutedChanged] bows out to it.
    _captureOpen = false;
    _captureWanted = false;

    final streamer = createCloudMicStreamer();
    _fallback = streamer;
    try {
      await streamer.start(
        wsUrl: _wsUrl!,
        localTrack: _localTrack,
        captureLocalMic: true,
        sourceLang: _sourceLang,
        targetLang: _targetLang,
        onTranslation: _onTranslation!,
        onPartial: _onPartial,
        onError: _onError,
      );
    } catch (e) {
      _fallback = null;
      _onError?.call('fallback_failed: $e');
    }
  }

  /// Open the mic, retrying once after a beat.
  ///
  /// The first attempt can lose a race it has no way to see: an input language
  /// change restarts this streamer, and iOS may still be holding the audio
  /// session we just released — [record] then throws, and the call would run to
  /// the end with no STT at all. The session is free a moment later, so one
  /// retry is the whole fix. A genuine failure (no route, mic taken by another
  /// app) throws again and reaches the caller's handler as before.
  Future<void> _startCapture() async {
    try {
      await _openMicStream();
    } catch (e) {
      if (!_running) rethrow;
      DebugOverlay.log('stt capture refused ($e) — retrying in 300ms');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!_running) return;
      await _openMicStream();
      DebugOverlay.log('stt capture recovered on retry');
    }
  }

  Future<void> _openMicStream() async {
    _lastVoiceMs = DateTime.now().millisecondsSinceEpoch;

    // iOS: tap WebRTC's ALREADY-OPEN mic capture instead of opening a second
    // `record` capture. Two captures on one iOS mic self-oscillate into a
    // startup whistle (proven on-device: cutting translation, which closes this
    // capture, was the only thing that silenced it). The web build clones the
    // LiveKit track for the same reason; native has no clone, so it taps the
    // capture post-processing hook, which is global and so survives the track
    // restart every unmute causes.
    if (!kIsWeb && Platform.isIOS) {
      try {
        await SwayWebrtcMicTap.instance.start();
        _tapActive = true;
        _captureOpen = true;
        DebugOverlay.log('stt capture via WebRTC tap (no 2nd mic)');
        _audioSub = SwayWebrtcMicTap.instance.pcm16k.listen(
          (bytes) => _onPcm(bytes, _onTranslation!, _onError),
          onError: (Object e) => DebugOverlay.log('stt tap stream error: $e'),
          onDone: () => DebugOverlay.log('stt tap stream closed'),
        );
        _armTapWatchdog();
        return;
      } catch (e) {
        DebugOverlay.log('stt WebRTC tap failed ($e) — falling back to record');
        _tapActive = false;
      }
    }

    // iOS: do NOT let `record` touch the shared AVAudioSession. Its own docs say
    // to turn this off "if another plugin is already managing the AVAudioSession"
    // — LiveKit is, from AppDelegate's RTCAudioSessionConfiguration. Left on (the
    // default), opening this capture re-applies record's own category and options
    // over WebRTC's mid-call, and the call's voice processing goes with them.
    //
    // Confirmed on a live call: with translation running, the peer heard constant
    // crackling that stopped dead the moment the pipeline was detached — the only
    // thing that changed being whether this second capture was open.
    try {
      await _rec.ios?.manageAudioSession(false);
    } catch (_) {
      // Not iOS, or an older plugin: the config below still applies.
    }
    final stream = await _rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _sampleRate,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      // Android: match the call, don't fight it. Every default here is wrong for
      // a capture opened *during* a WebRTC call:
      //   audioSource     defaultSource picks a plain recording source; the call
      //                   runs on voiceCommunication, which is the one carrying
      //                   the platform's AEC/NS for a two-way conversation.
      //   audioManagerMode modeNormal is the killer — `record` would drop the
      //                   AudioManager out of MODE_IN_COMMUNICATION mid-call,
      //                   taking the call's whole voice-processing chain with it.
      //   manageBluetooth  record would open its own Bluetooth SCO link while
      //                   LiveKit is already routing the call.
      androidConfig: AndroidRecordConfig(
        audioSource: AndroidAudioSource.voiceCommunication,
        audioManagerMode: AudioManagerMode.modeInCommunication,
        manageBluetooth: false,
      ),
      // AGC OFF. It was on, and it was actively harmful here: what AEC leaves of
      // the loudspeaker's own output is quiet — and AGC's whole job is to pull
      // quiet things up. It was handing the VAD an amplified echo that looks like
      // speech, and the recogniser captioned it. Without AGC the residue stays under
      // [_speechFloor] and never reaches the recogniser.
      autoGain: false,
    ));
    _captureOpen = true;
    DebugOverlay.log('stt capture started — 16 kHz pcm16, aec+ns on, agc OFF');
    _audioSub = stream.listen(
      (bytes) => _onPcm(bytes, _onTranslation!, _onError),
      onError: (Object e) => DebugOverlay.log('stt capture stream error: $e'),
      onDone: () => DebugOverlay.log('stt capture stream closed'),
    );
  }

  /// The mic no longer dozes — it stays open for the whole call, so there is
  /// nothing to wake. Kept to satisfy [SwayMicStreamer]; the caller only ever
  /// calls it when [isDozing], which is now always false.
  @override
  Future<void> wake() async {}

  void _onPcm(
    Uint8List bytes,
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError,
  ) {
    // Two reasons to throw this buffer away rather than transcribe it:
    //
    //  isSendMuted        — the user muted. Muting the LiveKit track only
    //                       silences the raw voice; this is a separate
    //                       AudioRecorder, so without this the peer keeps
    //                       hearing the translation of everything they say.
    //  isTranslationPlaying — a translation is coming out of our own
    //                       loudspeaker. AEC alone has not proven enough here:
    //                       the TTS speaks the language our STT is listening
    //                       for, so any residual echo transcribes cleanly and
    //                       gets sent back to the peer, who answers it. Costs
    //                       barge-in: you cannot interrupt a translation.
    //
    // The gate is EDGE-triggered: on the closing edge, whatever the VAD is
    // already holding was spoken BEFORE the gate shut — before the mute was
    // pressed, before our own TTS started. Those words were said out loud, on
    // purpose, to be heard, so they are flushed and published with `force`
    // (which is what gets them past the mute re-check in _translateAndSend).
    // Everything captured after the edge is simply not fed to the VAD.
    if (isSendMuted || isTranslationPlaying) {
      if (!_gated) {
        _gated = true;
        final gate = isSendMuted ? 'muted' : 'tts';
        DebugOverlay.log('stt gate CLOSED ($gate)');
        _flushForGateClose(onTranslation);
      }
      _lastVoiceMs = DateTime.now().millisecondsSinceEpoch;
      return;
    }
    if (_gated) {
      _gated = false;
      DebugOverlay.log('stt gate OPEN');
      // the VAD kept scoring nothing while the gate was shut; drop whatever half
      // state it holds so the next phrase starts clean.
      _vad?.reset();
    }

    final samples = _toFloat32(bytes);
    if (samples.isEmpty) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // Streaming engine (Vosk): it endpoints for itself — but not always.
    // Observed on device: partials build up and accept_waveform never returns 1,
    // so no utterance ever closes. The old mean-square VAD stays as its backstop.
    // The universal engine is a clip engine, so this branch is unreachable today.
    if (AsrService.instance.isStreaming) {
      final voiced = _meanSquare(samples) > _vadThreshold;
      if (voiced) _lastVoiceMs = nowMs;
      if (_modelReady) {
        _serialize(() => _feed(samples, onTranslation, onError));
        if (_hasPending && !voiced && nowMs - _lastVoiceMs >= _silenceFlushMs) {
          // Claim it synchronously, before the flush is even queued: two silent
          // frames back to back would otherwise both queue one, and the second
          // returns "" from a recognizer already finalised.
          _hasPending = false;
          DebugOverlay.log('stt vad backstop: ${_silenceFlushMs}ms silence, forcing flush');
          _serialize(() => _flushAndSend(onTranslation));
        }
      }
      return;
    }

    // Clip engine (universal): the VAD decides where phrases start and end.
    //
    // It was assumed here to keep its own pre-roll, so that the first syllable
    // survived. That was never verified and `SileroVadModelConfig` exposes no
    // padding knob (model, threshold, minSilenceDuration, minSpeechDuration,
    // windowSize, maxSpeechDuration — nothing else), so treat it as unknown:
    // reported from a live call, "T'aime le français" came back as "Aime le
    // français" and "Laime le français". Onset clipping fits those; it does NOT
    // fit "que tu aimes le français" from the same sentence, which has words
    // ADDED, so at least one other cause is in play.
    final vad = _vad;
    if (vad == null) return; // still downloading — nothing to segment with

    vad.acceptWaveform(samples);
    if (++_frames % 100 == 0) {
      DebugOverlay.log('stt pcm frames=$_frames speaking=${vad.isDetected()} '
          'ready=$_modelReady held=${_pendingMs}ms');
    }
    _drainSegmenter(onTranslation, onError);
    // Silence emits no VAD event, so the end of a phrase can only be noticed by
    // the clock. Checked on every frame.
    _flushIfIdle(onTranslation, onError);
  }

  /// What the gate's CLOSING edge does with the words already captured: close
  /// the phrase in flight and publish it with `force`, so it survives the mute
  /// re-check on the way back from the translator.
  ///
  /// Shared by the per-buffer gate in [_onPcm] and by [_onSendMutedChanged].
  /// The mute listener cannot rely on the buffer path: it releases the mic, so
  /// the buffer that would have carried the flush never arrives.
  void _flushForGateClose(
    void Function(String, String, String, String) onTranslation,
  ) {
    if (!_modelReady) {
      _vad?.reset();
      _resetPending();
    } else if (AsrService.instance.isStreaming) {
      DebugOverlay.log('stt gate — flushing what was already said');
      _serialize(() => _flushAndSend(onTranslation, force: true));
    } else {
      _flushSegmenter(onTranslation, force: true);
    }
  }

  /// Collect the VAD's chunks and re-join them into whole phrases.
  ///
  /// the VAD cuts at every real silence, including the ones inside a sentence.
  /// A chunk that follows the previous one by less than [_mergeGapMs] is the same
  /// sentence carrying on, so it is appended rather than sent. What forces a send
  /// is a genuine pause ([_flushIfIdle], driven by the clock) or the [_maxMergedMs]
  /// ceiling — and the ceiling lands on a silence between two chunks, never inside
  /// a word.
  void _drainSegmenter(
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError, {
    bool force = false,
  }) {
    final vad = _vad;
    if (vad == null) return;
    while (!vad.isEmpty()) {
      final segment = vad.front();
      vad.pop();
      if (!_modelReady) continue; // model still downloading — drop the phrase

      final peak = _peak(segment.samples);
      final ms = (segment.samples.length / _sampleRate * 1000).round();

      // Too quiet to be someone talking INTO this phone. the VAD is not wrong that
      // it is speech — it just cannot know whose. It is our own loudspeaker's, and
      // handing it to the recogniser is how the peer ends up hearing sentences nobody
      // said.
      if (peak < _speechFloor) {
        DebugOverlay.log('stt chunk ${ms}ms DROPPED — too quiet '
            '(peak ${peak.toStringAsFixed(3)} < $_speechFloor)');
        continue;
      }

      // A gap longer than _mergeGapMs means the previous phrase ended. Send it
      // before starting the new one.
      final gapMs = _pending.isEmpty
          ? 0
          : ((segment.start - _pendingEndSample) / _sampleRate * 1000).round();
      if (_pending.isNotEmpty && gapMs >= _mergeGapMs) {
        _sendPending(onTranslation, onError, why: '${gapMs}ms pause');
      }

      _pending.addAll(segment.samples);
      _pendingEndSample = segment.start + segment.samples.length;
      _pendingLastMs = DateTime.now().millisecondsSinceEpoch;
      _pendingPeak = peak > _pendingPeak ? peak : _pendingPeak;
      if (force) _pendingForce = true;

      // Never let one phrase grow past what the recogniser can read. The cut falls here,
      // on the boundary between two chunks — i.e. in a silence.
      if (_pendingMs >= _maxMergedMs) {
        _sendPending(onTranslation, onError, why: 'no pause, ceiling reached');
      } else {
        // Decode it now, while the merge wait runs. Most phrases arrive as one
        // segment and nothing follows, so this result is the final one and the
        // wait costs nothing instead of a second.
        _speculate();
      }
    }
  }

  int get _pendingMs => (_pending.length / _sampleRate * 1000).round();

  /// The speaker has genuinely stopped: [_mergeGapMs] of silence with nothing new
  /// from the VAD. Called on every audio frame — it is the clock, not the VAD, that
  /// tells us a phrase is over, because a VAD that emits nothing emits no event.
  void _flushIfIdle(
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError,
  ) {
    if (_pending.isEmpty) return;
    // Never close a phrase while the speaker is STILL TALKING. The clock below
    // measures wall time since the VAD last handed us a chunk — and the VAD
    // hands over nothing for the whole length of an ongoing burst. So a clause
    // that runs longer than [_mergeGapMs] made this fire mid-sentence and ship
    // the previous chunk on its own: one sentence arriving as fragments, each
    // translated out of context. Raising the gap never fixed it because the
    // clause simply outlasts whatever gap you pick. Only real silence — the VAD
    // hearing nothing — may end a phrase.
    if (_vad?.isDetected() ?? false) return;
    final idleMs = DateTime.now().millisecondsSinceEpoch - _pendingLastMs;
    if (idleMs >= _mergeGapMs) {
      _sendPending(onTranslation, onError, why: '${idleMs}ms silence');
    }
  }

  void _sendPending(
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError, {
    required String why,
  }) {
    if (_pending.isEmpty) return;
    final samples = Float32List.fromList(_pending);
    final ms = _pendingMs;
    final peak = _pendingPeak;
    // A phrase only reaches here from UNMUTED frames — the gate drops muted (and
    // TTS-playing) audio before it can enter the VAD. So whatever we finalise was
    // said out loud, on purpose, to be heard, and must survive a mute pressed
    // DURING its cloud round trip. `_pendingForce` alone did not cover this: it
    // is set only when the mute EDGE flushes the VAD, not when a phrase was
    // already closed by silence and is mid-translation when the user mutes to
    // listen. Losing that phrase — the last thing you said before going quiet —
    // was the real bug. Finalised while unmuted ⇒ publish, full stop.
    final force = _pendingForce || !isSendMuted;
    // Reuse the decode started during the merge wait, but only if it covers
    // EXACTLY this audio. A phrase that grew since falls back to a fresh decode
    // — translating a stale half-sentence would be worse than the wait.
    final spec = _speculativeSamples == samples.length ? _speculative : null;
    _resetPending();

    // QUEUED, never fired in parallel. The universal engine drops a transcribe
    // request that lands while it is already busy (`if (_busy) return ''`) — and
    // it takes seconds to decode a long phrase, so the phrase that followed was
    // being thrown away in silence. That is why the second half of a cut sentence
    // never arrived. Waiting our turn costs latency; dropping costs the words.
    //
    // Chaining also keeps the phrases in order: unqueued, a short phrase decoded
    // after a long one could overtake it and reach the peer first.
    DebugOverlay.log('stt phrase ${ms}ms peak=${peak.toStringAsFixed(3)} '
        '($why) → queued');
    _asrQueue = _asrQueue
        .then((_) => _recognizeAndTranslate(samples, onTranslation, onError,
            force: force, decoded: spec))
        .catchError((Object e) => DebugOverlay.log('stt queue error: $e'));
  }

  /// A decode started DURING the merge wait, on the phrase as it stands.
  ///
  /// [_mergeGapMs] of silence has to pass before a phrase is closed, because a
  /// sentence can arrive as several VAD segments (a breath, a comma) and they
  /// have to be rejoined before the recogniser sees them. That wait is dead
  /// time: the audio is already in hand and nothing computes. Measured on a real
  /// call it is ~700 ms, on top of the VAD's own 300 ms, in front of a ~600 ms
  /// decode — a full second before any work starts.
  ///
  /// So the decode starts as soon as a segment lands. If nothing follows, the
  /// answer is ready when the wait expires and the phrase costs no decode at
  /// all. If the speaker does continue, this result covers the wrong audio and
  /// is thrown away.
  ///
  /// Two rules keep the bad case bounded. It runs on [_asrQueue] like every
  /// other decode — the engine DROPS a request that lands while it is busy
  /// (`if (_busy) return ''`), and a dropped one is how the second half of a cut
  /// sentence used to vanish. And only one is ever in flight, so a real phrase
  /// waits behind at most one speculative decode, never a queue of them.
  Future<AsrResult>? _speculative;

  /// Sample count [_speculative] covers. A phrase that has grown since compares
  /// unequal and takes the slow path — the guard against speaking a translation
  /// of half a sentence.
  int _speculativeSamples = -1;

  void _speculate() {
    if (_speculative != null || _pending.isEmpty) return;
    final samples = Float32List.fromList(_pending);
    _speculativeSamples = samples.length;
    final f =
        _asrQueue.then((_) => AsrService.instance.transcribeDetailed(samples));
    _speculative = f;
    // Keep the chain going whatever happens, so one failed speculation cannot
    // wedge every phrase after it.
    _asrQueue = f.then((_) {}, onError: (Object e) {
      DebugOverlay.log('stt speculative error: $e');
    });
  }

  void _resetPending() {
    _pending.clear();
    _pendingEndSample = 0;
    _pendingLastMs = 0;
    _pendingPeak = 0;
    _speculative = null;
    _speculativeSamples = -1;
    _pendingForce = false;
  }

  /// Loudest sample in the segment, 0..1.
  double _peak(Float32List samples) {
    var m = 0.0;
    for (final s in samples) {
      final a = s.abs();
      if (a > m) m = a;
    }
    return m;
  }

  /// Close whatever phrase the VAD is mid-way through and send it. Used on the
  /// gate's closing edge, so the sentence a mute press interrupts still lands.
  void _flushSegmenter(
    void Function(String, String, String, String) onTranslation, {
    bool force = false,
  }) {
    final vad = _vad;
    if (vad == null) return;
    vad.flush();
    _drainSegmenter(onTranslation, _onError, force: force);
    vad.reset();
    // Mark the phrase itself, not just whatever the flush drained. `force` used
    // to reach _drainSegmenter only, which sets `_pendingForce` as it appends
    // segments — so a phrase ALREADY complete in `_pending` when the mute landed
    // drained nothing, kept `_pendingForce` false, and was dropped by the mute
    // re-check after its round trip. That is the common case, not a corner one:
    // you finish a sentence, you mute to listen, and the sentence is gone.
    if (force) _pendingForce = true;
    // And the phrase we were still assembling: without this it would sit in the
    // buffer until the user next spoke, and be spliced onto whatever they said.
    _sendPending(onTranslation, _onError, why: 'gate closed');
  }

  /// Streaming path: one frame in, partials out, and a finished utterance
  /// whenever the endpointer closes one.
  Future<void> _feed(
    Float32List samples,
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError,
  ) async {
    try {
      final chunk = await AsrService.instance.acceptFrame(samples);
      if (chunk.partial.isNotEmpty) {
        _hasPending = true;
        if (chunk.partial != _lastPartial) {
          _lastPartial = chunk.partial;
          DebugOverlay.log('stt partial="${chunk.partial}"');
          _onPartial?.call(chunk.partial);
        }
      }
      if (chunk.hasFinal) {
        _hasPending = false;
        _lastPartial = '';
        DebugOverlay.log('stt final="${chunk.finalText}" → translating');
        // Off the chain: the HTTP round trip must not hold up the next frame.
        unawaited(_translateAndSend(chunk.finalText, onTranslation, onError));
      }
    } catch (e) {
      onError?.call('stt:$e');
    }
  }

  /// Close the utterance the streaming decoder is holding and ship it. Used by
  /// the VAD backstop and by the half-duplex gate; guarded because both can fire
  /// on the same frame and `flush` is destructive.
  Future<void> _flushAndSend(
    void Function(String, String, String, String) onTranslation, {
    bool force = false,
  }) async {
    final text = await AsrService.instance.flush();
    _lastPartial = '';
    _hasPending = false;
    if (text.trim().isEmpty) return;
    DebugOverlay.log('stt flushed="$text" → translating');
    // Off the chain, as in _feed: this awaits the backend.
    unawaited(_translateAndSend(text, onTranslation, _onError, force: force));
  }

  /// Clip path (neural): decode the whole VAD-clipped utterance at once.
  ///
  /// [force] publishes even though the gate has since closed — set it for the
  /// utterance the mute press itself interrupted (see the gate in [_onPcm]).
  Future<void> _recognizeAndTranslate(
    Float32List samples,
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError, {
    bool force = false,
    Future<AsrResult>? decoded,
  }) async {
    try {
      // [decoded] is the speculative decode started during the merge wait, and
      // it covers exactly these samples — awaiting it returns at once when it
      // finished inside the wait, which is the whole point of starting it early.
      final res =
          await (decoded ?? AsrService.instance.transcribeDetailed(samples));
      final orig = res.text;
      final durationMs = (samples.length / _sampleRate * 1000).round();
      if (decoded != null) DebugOverlay.log('stt decode reused (merge wait)');

      // the recogniser captions silence and noise with subtitle boilerplate, and it
      // does it confidently. Unfiltered, the peer's phone says a sentence nobody
      // spoke, out loud, mid-conversation.
      if (looksHallucinated(orig, durationMs: durationMs)) {
        DebugOverlay.log('stt DROPPED hallucination: "$orig" (${durationMs}ms)');
        return;
      }

      // A Japanese fragment that is only grammatical tail ("よ", "ますよ"): the
      // segmenter split off a phrase's ending (often its head was dropped while
      // the mic was muted for playback). The STT reads it correctly, but the
      // translator turns the contentless scrap into junk — "Yo", "Bien sûr" —
      // spoken on the peer's phone. Drop it before it can travel.
      if (isUntranslatableScrap(orig, _sourceLang)) {
        DebugOverlay.log('stt DROPPED scrap: "$orig"');
        return;
      }

      // The same sentence twice in a row, seconds apart, is the recogniser
      // chewing on its own echo — not someone repeating themselves.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (orig == _lastOrig && nowMs - _lastOrigMs < _repeatWindowMs) {
        DebugOverlay.log('stt DROPPED repeat: "$orig"');
        return;
      }
      _lastOrig = orig;
      _lastOrigMs = nowMs;

      DebugOverlay.log('stt orig="$orig" (${durationMs}ms)');
      await _translateAndSend(orig, onTranslation, onError,
          force: force, hypotheses: res);
    } catch (e) {
      onError?.call('stt:$e');
    }
  }

  /// [force] publishes even if the mic is muted by the time the backend answers.
  /// Set it for a flush triggered *by* the mute: those words predate the press.
  ///
  /// [hypotheses] carries what the recogniser knew beyond its best guess. It
  /// travels with the transcript to the repair prompt: a rival reading of the
  /// same audio is the one thing that tells the repair model WHERE to look, and
  /// it costs nothing to obtain — the OS already computed it. Absent (ONNX
  /// engines, streaming flush) it degrades to exactly the previous behaviour.
  Future<void> _translateAndSend(
    String orig,
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError, {
    bool force = false,
    AsrResult hypotheses = AsrResult.empty,
  }) async {
    final TranscriptFix fixed;
    try {
      // Repair AND translate in the cloud. The repair-vs-translate decision and
      // the per-language rules live in /translation/fix; the phone hands it the
      // raw transcript plus gender and target and speaks the result. This used to
      // fork to an on-device translator (Hy-MT2 on llama.cpp) — see the git
      // history and the retired routeFor() — dropped for unreliable output,
      // phone weight, and latency.
      //
      // STREAMING: each SENTENCE is published the instant it lands, so a long
      // turn (the peer talking without pausing → one big segment → a multi-
      // sentence translation) reaches the far end piece by piece instead of as
      // one late block. The caption is NOT emitted here — it is shown once,
      // below, as the REPAIRED source, never the raw STT.
      fixed = await fetchTranscriptFixStream(
        text: orig,
        from: _sourceLang,
        to: _targetLang,
        authorGender: _myGender.isEmpty ? null : _myGender,
        peerGender: _peerGender.isEmpty ? null : _peerGender,
        alternatives: hypotheses.alternatives,
        lowConfidence: hypotheses.lowConfidence,
        onSentence: (sentence) {
          _publish('', sentence, onTranslation, force: force);
        },
      );
    } catch (e) {
      DebugOverlay.log('stt translate FAILED ($_sourceLang→$_targetLang): $e');
      onError?.call('translate:$e');
      return;
    }
    if (fixed.unclear) {
      // No model could read it. Nothing goes to the PEER rather than an
      // invention: a fluent wrong sentence is undetectable by them, a missing
      // one is recoverable ("répète ?"). unclear is only set when NO sentence
      // was published, so there is nothing half-said to take back.
      //
      // But it still surfaces on MY screen, greyed. Dropping it silently on
      // both sides at once left nothing to react to — no way to tell "it did
      // not understand me" from "the call is broken", just an empty panel. Now
      // the raw transcript is there, visibly not delivered, and the obvious
      // move (say it again) is the right one. Muted follows the same rule as a
      // real send: what was said with the mic open is shown.
      DebugOverlay.log('stt DROPPED unreadable transcript: "$orig"');
      if (!isSendMuted || force) _onDropped?.call(orig);
      _note('me', orig);
      return;
    }
    // Log the repaired SOURCE next to the raw transcript, not just the result.
    // Whether the recogniser really errs on live audio is what decides if this
    // path needs the repair prompt at all, or whether a plain translation
    // (half the tokens, ~1 s faster, more natural output) would have served.
    // The sentences were already published above as they streamed in.
    DebugOverlay.log(
      'stt fix[${fixed.route}](${fixed.engine}) '
      '${fixed.repaired ? "MOT CHANGE" : "sans effet"} → "${fixed.text}"',
    );
    // What the call actually cost, rather than what it was assumed to cost.
    // `cache` is the share of the prompt served at 1/50th the input price: the
    // instruction block never varies and comes first, so a warm cache should
    // put this in the 80-95% range. Stuck near 0% means the prefix moved and
    // the bill is ~2.5x. `out` is the tokens the model wrote — once the prompt
    // caches, that is where nearly all the money goes.
    final promptTok = fixed.cacheHit + fixed.cacheMiss;
    if (promptTok > 0) {
      final pct = (fixed.cacheHit * 100 / promptTok).round();
      DebugOverlay.log(
        '  cache  : $pct% ($promptTok prompt, out ${fixed.outTokens})',
      );
    }
    if (fixed.repaired) {
      DebugOverlay.log('  brut   : "$orig"');
      DebugOverlay.log('  repare : "${fixed.fixed}"');
    }

    // The caption on MY screen shows what DeepSeek repaired, not what the
    // recogniser misheard ("doli prenne" → "doliprane"). It lands here, after
    // the round trip, rather than the instant I speak — deliberately: a clean
    // caption a second late beats a wrong one now. Empty trans so it only paints
    // the local bubble and publishes nothing to the peer; muted follows the same
    // rule as a real send. Falls back to the raw orig only when there is no
    // repair to show (the translate route produces no `fixed`).
    final caption = fixed.fixed.isNotEmpty ? fixed.fixed : orig;
    if (!isSendMuted || force) {
      onTranslation(caption, '', _targetLang, '');
    }
    _note('me', orig);
  }

  /// Last gate before the peer hears it. Kept separate from the translate call
  /// so the mute rule lives in one place and can never be bypassed.
  void _publish(
    String orig,
    String trans,
    void Function(String, String, String, String) onTranslation, {
    bool force = false,
  }) {
    if (trans.trim().isEmpty) {
      DebugOverlay.log('stt translate returned EMPTY ($_sourceLang→$_targetLang)');
      return;
    }

    // Audio captured *after* the mute must never surface. Audio captured before
    // it must — the user said those words out loud, intending to be heard, and
    // the round trip merely spans hundreds of ms.
    if (isSendMuted && !force) {
      DebugOverlay.log('stt drop: muted while translating');
      return;
    }
    DebugOverlay.log('stt send trans="$trans"');

    // audioB64 empty: no TTS is generated here. The peer receives the text as
    // a local-TTS packet and synthesises it locally, in its own language.
    onTranslation(orig, trans, _targetLang, '');
  }

  Float32List _toFloat32(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final out = Float32List(n);
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  double _meanSquare(Float32List samples) {
    if (samples.isEmpty) return 0;
    var sum = 0.0;
    for (final s in samples) {
      sum += s * s;
    }
    return sum / samples.length;
  }

  /// the VAD is native memory — it has to be freed by hand, and never used again
  /// after (a second free, or a use-after-free, takes the whole app down).
  void _freeSegmenter() {
    final vad = _vad;
    _vad = null;
    try {
      vad?.free();
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    // The engine outlives this streamer (AsrService caches the loaded model),
    // so leave its decoder clean for the next call rather than letting the last
    // half-utterance of this one prefix it.
    if (_modelReady && AsrService.instance.isStreaming) {
      try {
        await AsrService.instance.reset();
      } catch (_) {}
    }
    // Before anything else: a listener left registered on a module-level list
    // outlives this streamer and would drive a dead recorder on the next call.
    removeSendMutedListener(_onSendMutedChanged);
    _running = false;
    _modelReady = false;
    _gated = false;
    _hasPending = false;
    _lastPartial = '';
    _freeSegmenter();
    _onTranslation = null;
    _onError = null;
    _onPartial = null;
    final fallback = _fallback;
    _fallback = null;
    if (fallback != null) {
      try {
        await fallback.stop();
      } catch (_) {}
    }
    await _audioSub?.cancel();
    _audioSub = null;
    await _stopCaptureSource();
    _captureOpen = false;
  }
}
