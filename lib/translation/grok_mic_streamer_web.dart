import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'grok_mic_streamer_base.dart';

GrokMicStreamer createGrokMicStreamer() => _WebGrokMicStreamer();

void _log(String m) => web.console.log('[grok-rt] $m'.toJS);

// ── Minimal WebCodecs AudioData bindings (web 1.1.1 doesn't expose them) ──
extension type _AudioData(JSObject _) implements JSObject {
  external int get numberOfFrames;
  external num get sampleRate;
  external int allocationSize(_CopyOpts options);
  external void copyTo(JSAny destination, _CopyOpts options);
  external void close();
}

extension type _CopyOpts._(JSObject _) implements JSObject {
  external factory _CopyOpts({int planeIndex, String format});
}

/// Web realtime mic streamer, SENDER-side. Captures MY OWN mic via a dedicated
/// `getUserMedia` (echoCancellation = browser AEC, so it doesn't re-capture the
/// loudspeaker), reads frames via `MediaStreamTrackProcessor` (WebCodecs — avoids
/// the Web Audio silence bug), downsamples to PCM16 16 kHz, and streams to the
/// backend Grok STT WS. We stop ONLY our own getUserMedia track at teardown, so
/// LiveKit's call mic is untouched.
class _WebGrokMicStreamer implements GrokMicStreamer {
  web.WebSocket? _ws;
  web.MediaStream? _micStream;
  web.ReadableStreamDefaultReader? _reader;

  bool _running = false;
  bool _wsOpen = false;
  int _frames = 0;

  static const int _outRate = 16000;

  @override
  bool get isRunning => _running;

  @override
  bool get isStreaming => _running && _wsOpen;

  @override
  Future<void> start({
    required Uri wsUrl,
    Object? localTrack,
    bool captureLocalMic = true,
    required void Function(String orig, String trans, String lang, String audioB64)
        onTranslation,
    void Function(String partial)? onPartial,
    void Function(String error)? onError,
  }) async {
    if (_running) return;
    _running = true;
    _log('start ${captureLocalMic ? "LOCAL-mic" : "REMOTE-track"} wsUrl=$wsUrl');
    try {
      final web.MediaStreamTrack micTrack;
      if (captureLocalMic) {
        // Capture MY OWN mic. echoCancellation = browser AEC, so we don't
        // re-transcribe the translated voice coming out of the speaker.
        final micStream = await web.window.navigator.mediaDevices
            .getUserMedia(web.MediaStreamConstraints(
              audio: web.MediaTrackConstraints(
                echoCancellation: true.toJS,
                noiseSuppression: true.toJS,
                autoGainControl: true.toJS,
              ),
            ))
            .toDart;
        _micStream = micStream;
        final audioTracks = micStream.getAudioTracks().toDart;
        if (audioTracks.isEmpty) {
          _log('getUserMedia returned no audio track');
          onError?.call('no_mic');
          _running = false;
          return;
        }
        micTrack = audioTracks.first;
        _log('local mic acquired (AEC)');
      } else {
        // Capture the passed track (the REMOTE voice). Clone it so we never
        // stop the track LiveKit is playing.
        web.MediaStreamTrack? jsTrack;
        try {
          final dynamic dyn = localTrack;
          jsTrack = dyn?.jsTrack as web.MediaStreamTrack?;
        } catch (_) {
          jsTrack = null;
        }
        if (jsTrack == null) {
          _log('no remote track to capture');
          onError?.call('no_remote_track');
          _running = false;
          return;
        }
        micTrack = jsTrack.clone();
        final s = web.MediaStream();
        s.addTrack(micTrack);
        _micStream = s;
        _log('remote track cloned for capture');
      }

      // Backend WebSocket.
      final ws = web.WebSocket(wsUrl.toString());
      ws.binaryType = 'arraybuffer';
      _ws = ws;
      ws.onopen = ((web.Event _) {
        _wsOpen = true;
        _log('ws OPEN');
      }).toJS;
      ws.onerror = ((web.Event _) {
        _log('ws ERROR');
        onError?.call('ws_error');
      }).toJS;
      ws.onclose = ((web.CloseEvent _) {
        _wsOpen = false;
        _log('ws CLOSE');
      }).toJS;
      ws.onmessage = ((web.MessageEvent e) {
        final data = e.data;
        if (data == null || !data.isA<JSString>()) return;
        try {
          final msg =
              jsonDecode((data as JSString).toDart) as Map<String, dynamic>;
          _log('msg ${msg['type']}: '
              '${(msg['trans'] ?? msg['text'] ?? '').toString()} '
              '(audio=${(msg['audio'] ?? '').toString().length}b)');
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
              _log('backend error: ${msg['error']}');
              onError?.call((msg['error'] ?? 'error').toString());
              break;
          }
        } catch (_) {}
      }).toJS;

      // Pull audio frames directly from my mic track.
      final processor = web.MediaStreamTrackProcessor(
          web.MediaStreamTrackProcessorInit(track: micTrack));
      final reader =
          processor.readable.getReader() as web.ReadableStreamDefaultReader;
      _reader = reader;
      _log('MediaStreamTrackProcessor reader started');
      unawaited(_pump(reader));
    } catch (e) {
      _log('start FAILED: $e');
      onError?.call('start_failed: $e');
      await stop();
    }
  }

  Future<void> _pump(web.ReadableStreamDefaultReader reader) async {
    while (_running) {
      web.ReadableStreamReadResult result;
      try {
        result = await reader.read().toDart;
      } catch (e) {
        _log('reader.read failed: $e');
        break;
      }
      if (result.done) break;
      final value = result.value;
      if (value == null) continue;
      try {
        final audio = _AudioData(value as JSObject);
        final inRate = audio.sampleRate.toInt();
        final n = audio.numberOfFrames;
        final f32 = Float32List(n);
        audio.copyTo(
          f32.toJS,
          _CopyOpts(planeIndex: 0, format: 'f32-planar'),
        );
        audio.close();
        if (_wsOpen && n > 0) {
          final pcm = _downsampleToPcm16(f32, inRate, _outRate);
          if (pcm.isNotEmpty) {
            try {
              _ws?.send(pcm.toJS);
            } catch (_) {}
          }
          _frames++;
          if (_frames % 100 == 0) {
            var sum = 0.0;
            for (var i = 0; i < f32.length; i++) {
              sum += f32[i] * f32[i];
            }
            final level = f32.isEmpty ? 0.0 : sum / f32.length;
            _log('pcm frames=$_frames inRate=$inRate level=${level.toStringAsFixed(5)}');
          }
        }
      } catch (e) {
        _log('frame process failed: $e');
      }
    }
  }

  Int16List _downsampleToPcm16(Float32List input, int inRate, int outRate) {
    int toI16(double s) {
      final c = s.clamp(-1.0, 1.0);
      return (c < 0 ? c * 32768 : c * 32767).round();
    }

    if (inRate <= outRate) {
      final out = Int16List(input.length);
      for (var i = 0; i < input.length; i++) {
        out[i] = toI16(input[i]);
      }
      return out;
    }
    final ratio = inRate / outRate;
    final outLen = (input.length / ratio).floor();
    final out = Int16List(outLen);
    for (var i = 0; i < outLen; i++) {
      out[i] = toI16(input[(i * ratio).floor()]);
    }
    return out;
  }

  @override
  Future<void> stop() async {
    _running = false;
    _wsOpen = false;
    try {
      await _reader?.cancel('stop'.toJS).toDart;
    } catch (_) {}
    _reader = null;
    try {
      final ws = _ws;
      if (ws != null && ws.readyState == 1) {
        ws.send('{"type":"audio.done"}'.toJS);
        ws.close();
      }
    } catch (_) {}
    // Stop ONLY our own getUserMedia mic — never LiveKit's call mic.
    try {
      final tracks = _micStream?.getTracks().toDart;
      if (tracks != null) {
        for (final t in tracks) {
          t.stop();
        }
      }
    } catch (_) {}
    _micStream = null;
    _ws = null;
  }
}
