import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'grok_mic_streamer_base.dart';

GrokMicStreamer createGrokMicStreamer() => _WebGrokMicStreamer();

/// Logs to the browser console (visible even in a release web build, unlike
/// stripped debugPrint) so the pipeline can be diagnosed from DevTools.
void _log(String m) => web.console.log('[grok-rt] $m'.toJS);

/// Web realtime mic streamer. Captures the local mic via `getUserMedia` with
/// `echoCancellation` (so the browser cancels the LiveKit playback echo — no
/// feedback loop), downsamples to PCM16 16 kHz with a ScriptProcessor, and
/// streams 16-bit frames over a WebSocket to the backend Grok STT proxy.
///
/// ScriptProcessorNode is deprecated but self-contained (an AudioWorklet would
/// need a separately served JS module). Fine for the web test path.
class _WebGrokMicStreamer implements GrokMicStreamer {
  web.WebSocket? _ws;
  web.AudioContext? _ctx;
  web.MediaStream? _stream;
  web.MediaStreamAudioSourceNode? _src;
  web.ScriptProcessorNode? _proc;
  web.GainNode? _muteGain;

  bool _running = false;
  bool _wsOpen = false;

  static const int _outRate = 16000;

  @override
  bool get isRunning => _running;

  @override
  bool get isStreaming => _running && _wsOpen;

  @override
  Future<void> start({
    required Uri wsUrl,
    Object? localTrack, // web captures its own AEC'd mic; track is unused here
    required void Function(String orig, String trans, String lang) onTranslation,
    void Function(String partial)? onPartial,
    void Function(String error)? onError,
  }) async {
    if (_running) return;
    _running = true;
    _log('start wsUrl=$wsUrl');
    try {
      // 1) Local mic WITH browser AEC — this is what kills the loudspeaker echo.
      final audioConstraints = web.MediaTrackConstraints(
        echoCancellation: true.toJS,
        noiseSuppression: true.toJS,
        autoGainControl: true.toJS,
      );
      final stream = await web.window.navigator.mediaDevices
          .getUserMedia(web.MediaStreamConstraints(audio: audioConstraints))
          .toDart;
      _stream = stream;
      _log('mic acquired (AEC)');

      // 2) Backend WebSocket.
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
          _log('msg ${msg['type']}');
          switch (msg['type']) {
            case 'translation':
              onTranslation(
                (msg['orig'] ?? '').toString(),
                (msg['trans'] ?? '').toString(),
                (msg['lang'] ?? '').toString(),
              );
              break;
            case 'partial':
              onPartial?.call((msg['text'] ?? '').toString());
              break;
            case 'error':
              onError?.call((msg['error'] ?? 'error').toString());
              break;
          }
        } catch (_) {
          // Ignore malformed frames.
        }
      }).toJS;

      // 3) Audio graph: mic → processor → muted gain → destination.
      // The processor must be connected to the graph to fire; routing through a
      // zero-gain node keeps it running WITHOUT monitoring the mic to speakers.
      final ctx = web.AudioContext();
      _ctx = ctx;
      final src = ctx.createMediaStreamSource(stream);
      _src = src;
      final proc = ctx.createScriptProcessor(4096, 1, 1);
      _proc = proc;
      final muteGain = ctx.createGain();
      muteGain.gain.value = 0;
      _muteGain = muteGain;

      final inRate = ctx.sampleRate; // usually 48000
      proc.onaudioprocess = ((web.AudioProcessingEvent ev) {
        if (!_wsOpen) return;
        final input = ev.inputBuffer.getChannelData(0).toDart;
        final pcm = _downsampleToPcm16(input, inRate, _outRate);
        if (pcm.isNotEmpty) {
          try {
            _ws?.send(pcm.toJS);
          } catch (_) {}
        }
      }).toJS;

      src.connect(proc);
      proc.connect(muteGain);
      muteGain.connect(ctx.destination);
      _log('audio graph up, inRate=$inRate → ${_outRate}Hz');
    } catch (e) {
      _log('start FAILED: $e');
      onError?.call('start_failed: $e');
      await stop();
    }
  }

  /// Float32 [-1,1] → Int16 PCM, nearest-neighbour downsampled to [outRate].
  /// Browsers are little-endian, matching xAI's expected `pcm_s16le`.
  Int16List _downsampleToPcm16(Float32List input, num inRate, int outRate) {
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
      _proc?.disconnect();
    } catch (_) {}
    try {
      _src?.disconnect();
    } catch (_) {}
    try {
      _muteGain?.disconnect();
    } catch (_) {}
    try {
      await _ctx?.close().toDart;
    } catch (_) {}
    try {
      final ws = _ws;
      if (ws != null && ws.readyState == 1 /* OPEN */) {
        ws.send('{"type":"audio.done"}'.toJS);
        ws.close();
      }
    } catch (_) {}
    try {
      final tracks = _stream?.getTracks().toDart;
      if (tracks != null) {
        for (final t in tracks) {
          t.stop();
        }
      }
    } catch (_) {}
    _proc = null;
    _src = null;
    _muteGain = null;
    _ctx = null;
    _ws = null;
    _stream = null;
  }
}
