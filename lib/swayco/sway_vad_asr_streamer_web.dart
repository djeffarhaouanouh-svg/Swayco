/// STT non-continu sur le WEB : le découpage des phrases se fait dans le
/// navigateur, la reconnaissance et la traduction dans le cloud.
///
///   micro ouvert pendant tout l'appel
///        ↓
///   l'énergie du signal est mesurée par blocs de 128 ms (Web Audio)
///        ↓
///   «Bonjour…» → la parole commence (avec 512 ms de pré-roll, la première
///                 syllabe n'est jamais coupée)
///        ↓
///   ~1 s sous le seuil → la phrase est close et découpée
///        ↓
///   ce segment-là part au cloud → traduction → pair
///
/// Rien ne quitte le navigateur pendant les silences, et le moteur de
/// reconnaissance reçoit une phrase entière plutôt que des mots isolés.
///
/// LE DÉCOUPAGE NE DÉPEND PLUS D'UN MODÈLE LOCAL. Il tournait avant sur Silero
/// v5 via onnxruntime-web : chaque appel construisait une session WASM, et
/// comme la lib n'était que mise en pause, elles s'accumulaient jusqu'à
/// «RangeError: Out of memory» — après quoi le runtime restait cassé pour toute
/// la page et plus une seule phrase n'était segmentée. Un détecteur d'énergie
/// n'a ni modèle, ni WASM, ni mémoire à fuir : il ne peut pas tomber en panne
/// de cette façon. Il distingue moins finement la voix d'un bruit continu, ce
/// que compense un seuil calé sur le bruit ambiant de la pièce.
///
/// Le natif n'est pas concerné : il segmente avec son propre moteur.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../services/call_audio.dart';
import '../services/debug_overlay.dart';
import '../services/translation_api.dart';
import 'asr/transcript_guard.dart';
import 'sway_mic_streamer_base.dart';

SwayMicStreamer createSwayMicStreamer() => _VadAsrStreamer();

void _log(String m) {
  web.console.log('[stt] $m'.toJS);
  DebugOverlay.log('[stt] $m');
}


class _VadAsrStreamer implements SwayMicStreamer {
  web.MediaStream? _micStream;
  bool _ownsMicStream = false;

  /// La chaîne Web Audio qui écoute le micro : contexte, prise de son,
  /// processeur de blocs, et le gain à zéro qui ferme la boucle sans rien
  /// renvoyer dans les haut-parleurs (le connecter à la sortie ferait un
  /// larsen immédiat, mais sans connexion le processeur ne tourne pas).
  web.AudioContext? _ctx;
  web.MediaStreamAudioSourceNode? _source;
  web.ScriptProcessorNode? _processor;
  web.GainNode? _mute;

  bool _running = false;
  bool _ready = false;
  int _segments = 0;

  /// Diagnostic : le plus fort niveau vu depuis le dernier rapport, et le
  /// compteur de blocs qui rythme ces rapports.
  double _peak = 0;
  int _frames = 0;

  /// Le bruit de la pièce, appris en continu : il descend vite vers le silence
  /// et remonte lentement, si bien qu'une voix ne le tire pas vers le haut.
  double _noiseFloor = 0.004;

  /// La phrase en cours de constitution, bloc par bloc, et ce qui la précède.
  final List<Float32List> _phrase = <Float32List>[];
  final List<Float32List> _preroll = <Float32List>[];
  bool _inSpeech = false;
  int _hotBlocks = 0;
  int _silentBlocks = 0;

  /// Set when the current phrase began while our own speaker was playing a
  /// translation — i.e. it is echo, and must not be sent back to the peer.
  bool _tainted = false;

  String _from = '';
  String _to = '';
  void Function(String orig, String trans, String lang, String audioB64)?
      _cbTranslation;
  void Function(String error)? _cbError;

  /// Recogniser calls are chained, never run in parallel: two overlapping segments
  /// would race and the peer could hear the second sentence before the first.
  Future<void> _queue = Future<void>.value();

  @override
  bool get isRunning => _running;

  @override
  bool get isStreaming => _running && _ready;

  @override
  set peerGender(String value) {}

  @override
  set onDropped(void Function(String heard)? value) {}

  @override
  void notePeerUtterance(String orig) {}

  /// Each callback is one independent VAD-clipped utterance, so the caller must
  /// NOT apply the streaming path's delta/dedup logic.
  @override
  bool get accumulatesTranscript => false;

  /// The mic stays open for the entire call — that is the point of the test.
  @override
  bool get isDozing => false;

  @override
  Future<void> wake() async {}

  @override
  Future<void> start({
    required Uri wsUrl, // unused: this path is HTTP, not WebSocket
    Object? localTrack,
    bool captureLocalMic = true,
    String sourceLang = '',
    String targetLang = '',
    required void Function(
            String orig, String trans, String lang, String audioB64)
        onTranslation,
    void Function(String partial)? onPartial,
    void Function(String error)? onError,
  }) async {
    if (_running) return;
    _running = true;
    _from = sourceLang;
    _to = targetLang;
    _cbTranslation = onTranslation;
    _cbError = onError;

    try {
      final stream = await _acquireMic(localTrack);
      if (stream == null) {
        onError?.call('no_mic');
        _running = false;
        return;
      }
      _micStream = stream;
      _startEnergyDetector(stream);
      _ready = true;
      _log('listening — energy gate, $_kBlock-sample blocks, $_from→$_to');
    } catch (e) {
      _log('start FAILED: $e');
      onError?.call('start_failed: $e');
      await stop();
    }
  }

  /// Taille d'un bloc : 2048 échantillons à 16 kHz, soit 128 ms. Assez court
  /// pour attraper le début d'un mot, assez long pour que le RMS d'un bloc
  /// veuille dire quelque chose.
  static const int _kBlock = 2048;
  static const int _kRate = 16000;

  /// Deux blocs (~256 ms) au-dessus du seuil ouvrent une phrase : un claquement
  /// de porte en fait un, pas deux.
  static const int _kHotToOpen = 2;

  /// Huit blocs (~1 s) sous le seuil la referment. C'est la valeur qui laisse
  /// une phrase respirer sans la couper à chaque virgule.
  static const int _kSilentToClose = 8;

  /// Sous 400 ms, ce n'est pas une phrase : une toux, un choc, un raclement.
  static const int _kMinSpeechMs = 400;

  /// Au-delà, on découpe d'office — une phrase qui n'en finit pas garderait sa
  /// traduction en otage.
  static const int _kMaxSpeechMs = 15000;

  /// Le pré-roll rattaché à chaque phrase : quatre blocs, soit ~512 ms. Sans
  /// lui, la première syllabe manque — le seuil n'est franchi qu'une fois le
  /// mot commencé.
  static const int _kPrerollBlocks = 4;

  /// Écoute le micro par blocs et en tire des phrases.
  ///
  /// ScriptProcessorNode est déprécié au profit d'AudioWorklet, et c'est
  /// délibéré : le worklet demande un fichier séparé servi à part, là où ceci
  /// tient dans le bundle et fonctionne sur tous les navigateurs visés. Le
  /// coût — le traitement passe par le thread principal — se compte en
  /// microsecondes par bloc pour un calcul de moyenne quadratique.
  void _startEnergyDetector(web.MediaStream stream) {
    final ctx = web.AudioContext(
      web.AudioContextOptions(sampleRate: _kRate.toDouble()),
    );
    _ctx = ctx;
    final source = ctx.createMediaStreamSource(stream);
    _source = source;
    final processor = ctx.createScriptProcessor(_kBlock, 1, 1);
    _processor = processor;
    final mute = ctx.createGain();
    mute.gain.value = 0;
    _mute = mute;

    processor.onaudioprocess = ((web.AudioProcessingEvent e) {
      if (!_running) return;
      final block = e.inputBuffer.getChannelData(0).toDart;
      _onBlock(block);
    }).toJS;

    source.connect(processor);
    processor.connect(mute);
    mute.connect(ctx.destination);
  }

  /// Un bloc de 128 ms : mesure, décision, accumulation.
  void _onBlock(Float32List block) {
    var sum = 0.0;
    for (final v in block) {
      sum += v * v;
    }
    final rms = sum <= 0 ? 0.0 : math.sqrt(sum / block.length);

    // Le plancher suit le silence de près et la voix de très loin.
    _noiseFloor = rms < _noiseFloor
        ? _noiseFloor * 0.7 + rms * 0.3
        : _noiseFloor * 0.995 + rms * 0.005;
    final threshold = math.max(0.006, _noiseFloor * 3);
    final hot = rms > threshold;

    if (rms > _peak) _peak = rms;
    if (++_frames % 24 == 0) {
      _log('peak over last 3s ${_peak.toStringAsFixed(4)} '
          '(speech starts at ${threshold.toStringAsFixed(4)})');
      _peak = 0;
    }

    // Une copie : le tampon que WebAudio nous prête est réutilisé au bloc
    // suivant, le garder tel quel donnerait une phrase faite du même son
    // répété.
    final copy = Float32List.fromList(block);

    if (!_inSpeech) {
      _preroll.add(copy);
      if (_preroll.length > _kPrerollBlocks) _preroll.removeAt(0);
      _hotBlocks = hot ? _hotBlocks + 1 : 0;
      if (_hotBlocks >= _kHotToOpen) {
        _inSpeech = true;
        _silentBlocks = 0;
        _phrase
          ..clear()
          ..addAll(_preroll);
        _preroll.clear();
        // La garde anti-écho se décide ICI, à la première syllabe — pas à la
        // fin. L'écho commence pendant que notre haut-parleur parle ; votre
        // phrase suivante, elle, commence après qu'il s'est tu.
        _tainted = isTranslationPlaying;
        _log('speech start${_tainted ? ' — DURING playback, will drop as echo' : ''}');
      }
      return;
    }

    _phrase.add(copy);
    _silentBlocks = hot ? 0 : _silentBlocks + 1;
    final ms = _phrase.length * _kBlock * 1000 ~/ _kRate;
    if (_silentBlocks >= _kSilentToClose || ms >= _kMaxSpeechMs) {
      _closePhrase(ms);
    }
  }

  void _closePhrase(int ms) {
    _inSpeech = false;
    _hotBlocks = 0;
    _silentBlocks = 0;
    final blocks = List<Float32List>.from(_phrase);
    _phrase.clear();
    if (ms < _kMinSpeechMs) {
      _log('misfire — $ms ms, too short to be a phrase');
      return;
    }
    var n = 0;
    for (final b in blocks) {
      n += b.length;
    }
    final samples = Float32List(n);
    var at = 0;
    for (final b in blocks) {
      samples.setAll(at, b);
      at += b.length;
    }
    _onSegment(samples);
  }

  /// The LiveKit track, cloned. Falls back to our own getUserMedia only when
  /// LiveKit hasn't published yet — same constraints either way (AEC on, NS on,
  /// AGC off; AGC would amplify any speaker leak until the audio runs away).
  Future<web.MediaStream?> _acquireMic(Object? localTrack) async {
    web.MediaStreamTrack? lkTrack;
    if (localTrack != null) {
      try {
        final fwTrack = (localTrack as dynamic).mediaStreamTrack;
        lkTrack = (fwTrack as dynamic).jsTrack as web.MediaStreamTrack?;
      } catch (_) {}
    }

    if (lkTrack != null) {
      final stream = web.MediaStream();
      stream.addTrack(lkTrack.clone());
      _ownsMicStream = true;
      _log('LiveKit track cloned (AEC on, NS on, AGC off)');
      return stream;
    }

    final stream = await web.window.navigator.mediaDevices
        .getUserMedia(web.MediaStreamConstraints(
          audio: web.MediaTrackConstraints(
            echoCancellation: true.toJS,
            noiseSuppression: true.toJS,
            autoGainControl: false.toJS,
          ),
        ))
        .toDart;
    if (stream.getAudioTracks().toDart.isEmpty) {
      _log('getUserMedia returned no audio track');
      return null;
    }
    _ownsMicStream = true;
    _log('getUserMedia fallback (LiveKit track not published yet)');
    return stream;
  }

  /// One finished utterance, 16 kHz mono float. Transcribe it, translate it, hand
  /// the text back to the caller, which publishes it on the data channel.
  void _onSegment(Float32List samples) {
    if (!_running || samples.isEmpty) return;

    // Two reasons to throw a segment away rather than translate it:
    //
    //  isSendMuted — the user muted.
    //  _tainted    — the phrase STARTED while a translation was coming out of
    //                our own speaker, so it is our own playback echoing back.
    //                AEC alone is not enough: the TTS speaks the very language
    //                our STT listens for, so the residue transcribes cleanly and
    //                we would send the peer their own translation back. Native
    //                gates on this for exactly that reason.
    //
    // Judged at the phrase's START (see onSpeechStart), never at its end: a
    // phrase you begin after the speaker falls quiet must survive, even if the
    // next translation starts playing while you are still talking.
    final tainted = _tainted;
    _tainted = false;
    if (isSendMuted || tainted) {
      _log('segment dropped — ${isSendMuted ? 'mic muted' : 'echo of our own speaker'}');
      return;
    }

    final durationMs = (samples.length / 16000 * 1000).round();
    final wav = _encodeWav16kMono(samples);
    final seq = ++_segments;
    _log('segment #$seq ${durationMs}ms → ${wav.length ~/ 1024}KB');

    final queuedAt = DateTime.now();
    _queue = _queue.then((_) async {
      if (!_running) return;
      final sentAt = DateTime.now();
      final waited = sentAt.difference(queuedAt).inMilliseconds;
      final res = await fetchClipTranslation(
        wavBytes: wav,
        from: _from,
        to: _to,
      );
      if (!_running) return;
      final roundTrip = DateTime.now().difference(sentAt).inMilliseconds;
      if (res == null) {
        _log('segment #$seq → nothing (silence, or backend refused)');
        return;
      }
      // Muted while the backend was answering: these words predate the press,
      // but the user has since asked not to be heard. Native drops them too.
      if (isSendMuted) {
        _log('segment #$seq dropped — muted while translating');
        return;
      }
      // Latency the peer actually feels: 300 ms of VAD redemption, plus the
      // queue wait, plus the round-trip. Their TTS starts right after this.
      _log('segment #$seq "${res.orig}" → "${res.trans}" | '
          'vad=300ms queue=${waited}ms stt=${res.sttMs}ms '
          'trad=${res.translateMs}ms net=${roundTrip - res.sttMs - res.translateMs}ms '
          'TOTAL=${300 + waited + roundTrip}ms');
      // A Japanese fragment that is only grammatical tail ("よ", "ますよ") — the
      // segmenter split off a phrase's ending — reads correctly but translates
      // to junk ("Yo", "Bien sûr"). The backend already spent the round trip,
      // but we can still refuse to speak the scrap on the peer's phone.
      if (isUntranslatableScrap(res.orig, _from)) {
        _log('segment #$seq dropped scrap: "${res.orig}"');
        return;
      }
      _cbTranslation?.call(res.orig, res.trans, res.lang, '');
    }).catchError((Object e) {
      _log('segment #$seq FAILED: $e');
      _cbError?.call('asr:$e');
    });
  }

  /// Float32 @16 kHz → 16-bit PCM WAV. the recogniser wants a real container, and this
  /// is the cheapest one to build (44-byte header, no encoder).
  Uint8List _encodeWav16kMono(Float32List samples) {
    const int sampleRate = 16000;
    final int dataBytes = samples.length * 2;
    final bytes = Uint8List(44 + dataBytes);
    final view = ByteData.view(bytes.buffer);

    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        bytes[offset + i] = s.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    view.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    view.setUint32(16, 16, Endian.little); // PCM chunk size
    view.setUint16(20, 1, Endian.little); // format = PCM
    view.setUint16(22, 1, Endian.little); // mono
    view.setUint32(24, sampleRate, Endian.little);
    view.setUint32(28, sampleRate * 2, Endian.little); // byte rate
    view.setUint16(32, 2, Endian.little); // block align
    view.setUint16(34, 16, Endian.little); // bits per sample
    ascii(36, 'data');
    view.setUint32(40, dataBytes, Endian.little);

    for (var i = 0; i < samples.length; i++) {
      final s = samples[i].clamp(-1.0, 1.0);
      view.setInt16(
          44 + i * 2, (s < 0 ? s * 32768 : s * 32767).round(), Endian.little);
    }
    return bytes;
  }

  @override
  Future<void> stop() async {
    _running = false;
    _ready = false;
    _inSpeech = false;
    _phrase.clear();
    _preroll.clear();
    try {
      _processor?.onaudioprocess = null;
      _processor?.disconnect();
      _source?.disconnect();
      _mute?.disconnect();
      _ctx?.close();
    } catch (_) {}
    _processor = null;
    _source = null;
    _mute = null;
    _ctx = null;
    // Only ever our own clone — never the track LiveKit is using for the call.
    if (_ownsMicStream) {
      try {
        for (final t in _micStream?.getTracks().toDart ?? <web.MediaStreamTrack>[]) {
          t.stop();
        }
      } catch (_) {}
    }
    _micStream = null;
    _ownsMicStream = false;
    _cbTranslation = null;
    _cbError = null;
  }
}
