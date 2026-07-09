import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../services/call_audio.dart';
import 'grok_mic_streamer_base.dart';
import 'local_stt_mic_streamer_io.dart';

/// Native STT now runs on-device (Moonshine / Vosk) — see
/// [LocalSttMicStreamer]. The x.ai WebSocket path below is kept intact behind
/// this flag: flip it to true to fall back to the remote proxy.
const bool kUseXaiSttOnNative = false;

GrokMicStreamer createGrokMicStreamer() =>
    // ignore: dead_code
    kUseXaiSttOnNative ? _IoGrokMicStreamer() : LocalSttMicStreamer();

/// The remote x.ai streamer, used as a fallback when the on-device engine
/// cannot load — no libvosk on this platform, no model for the language, or a
/// corrupt download. Better a remote transcript than a silently dead call.
GrokMicStreamer createXaiMicStreamer() => _IoGrokMicStreamer();

/// Native (iOS/Android) realtime mic streamer, SENDER-side. Captures MY local
/// mic with `record` (PCM16 16 kHz stream, system AEC via echoCancel), opens a
/// WebSocket to the backend Grok STT proxy, streams the PCM, and surfaces
/// translations. Native can't tap the REMOTE WebRTC track, so this is the only
/// realtime path on iOS/Android — and it's enough: each phone sends its own
/// translated voice to the peer, who just plays it.
class _IoGrokMicStreamer implements GrokMicStreamer {
  final AudioRecorder _rec = AudioRecorder();
  WebSocket? _ws;
  StreamSubscription<Uint8List>? _audioSub;
  bool _running = false;
  bool _wsOpen = false;
  int _lastVoiceMs = 0;

  // VAD (mean-square) — low threshold + generous hangover so phrases aren't clipped.
  static const double _vadThreshold = 0.0002;
  static const int _vadHangoverMs = 1200;

  @override
  bool get isRunning => _running;

  @override
  bool get isStreaming => _running && _wsOpen;

  @override
  bool get accumulatesTranscript => true;

  // The x.ai path streams continuously; it never releases the mic.
  @override
  bool get isDozing => false;

  @override
  Future<void> wake() async {}

  @override
  Future<void> start({
    required Uri wsUrl,
    dynamic localTrack,
    bool captureLocalMic = true,
    String sourceLang = '',
    String targetLang = '',
    required void Function(String orig, String trans, String lang, String audioB64)
        onTranslation,
    void Function(String partial)? onPartial,
    void Function(String error)? onError,
  }) async {
    if (_running) return;
    // Native captures ONLY the local mic; the remote-track path doesn't exist.
    if (!captureLocalMic) {
      onError?.call('native_no_remote_capture');
      return;
    }
    _running = true;
    try {
      if (!await _rec.hasPermission()) {
        onError?.call('no_mic_permission');
        _running = false;
        return;
      }
      final ws = await WebSocket.connect(wsUrl.toString());
      _ws = ws;
      _wsOpen = true;
      ws.listen(
        (data) {
          if (data is! String) return;
          try {
            final msg = jsonDecode(data) as Map<String, dynamic>;
            switch (msg['type']) {
              case 'translation':
                onTranslation(
                  (msg['orig'] ?? '').toString(),
                  (msg['trans'] ?? '').toString(),
                  (msg['lang'] ?? '').toString(),
                  (msg['audio'] ?? '').toString(),
                );
                break;
              case 'partial':
                onPartial?.call((msg['text'] ?? '').toString());
                break;
              case 'error':
                onError?.call((msg['error'] ?? 'error').toString());
                break;
            }
          } catch (_) {}
        },
        onError: (_) {
          _wsOpen = false;
          onError?.call('ws_error');
        },
        onDone: () => _wsOpen = false,
        cancelOnError: true,
      );

      final stream = await _rec.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      ));
      _audioSub = stream.listen((bytes) {
        if (!_wsOpen) return;
        // Mute stops the translation, not just the LiveKit voice track; the
        // half-duplex gate keeps our own TTS out of the transcript. Same two
        // guards the on-device streamer applies — this path must not be the
        // hole they leak through when the fallback kicks in.
        if (isSendMuted || isTranslationPlaying) return;
        final level = _meanSquare(bytes);
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (level > _vadThreshold) _lastVoiceMs = nowMs;
        if (nowMs - _lastVoiceMs < _vadHangoverMs) {
          try {
            _ws?.add(bytes);
          } catch (_) {}
        }
      });
    } catch (e) {
      onError?.call('start_failed: $e');
      await stop();
    }
  }

  double _meanSquare(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    if (n == 0) return 0;
    final bd = ByteData.sublistView(bytes);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final s = bd.getInt16(i * 2, Endian.little) / 32768.0;
      sum += s * s;
    }
    return sum / n;
  }

  @override
  Future<void> stop() async {
    _running = false;
    _wsOpen = false;
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      await _rec.stop();
    } catch (_) {}
    try {
      _ws?.add('{"type":"audio.done"}');
    } catch (_) {}
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
  }
}
