import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'grok_mic_streamer_base.dart';

GrokMicStreamer createGrokMicStreamer() => _WebGrokMicStreamer();

/// Logs to the browser console (visible even in a release web build, unlike
/// stripped debugPrint) so the pipeline can be diagnosed from DevTools.
void _log(String m) => web.console.log('[grok-rt] $m'.toJS);

/// Web realtime mic streamer. REUSES the mic track LiveKit already captured
/// (read-only, via Web Audio) — it never opens a 2nd getUserMedia. A 2nd
/// getUserMedia steals/reconfigures the call mic and kills the original call
/// audio (learned the hard way). Since we only READ LiveKit's track and never
/// stop it, the worst case is "no translation", never "broken call audio".
/// The track is already AEC'd (LiveKit captures with echoCancellation), so no
/// loudspeaker feedback loop. Downsamples to PCM16 16 kHz with a ScriptProcessor
/// and streams 16-bit frames over a WebSocket to the backend Grok STT proxy.
///
/// ScriptProcessorNode is deprecated but self-contained (an AudioWorklet would
/// need a separately served JS module). Fine for the web test path.
class _WebGrokMicStreamer implements GrokMicStreamer {
  web.WebSocket? _ws;
  web.AudioContext? _ctx;
  web.MediaStreamAudioSourceNode? _src;
  web.ScriptProcessorNode? _proc;
  web.GainNode? _muteGain;
  web.MediaStreamTrack? _clonedTrack;

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
    required void Function(String orig, String trans, String lang, String audioB64)
        onTranslation,
    void Function(String partial)? onPartial,
    void Function(String error)? onError,
  }) async {
    if (_running) return;
    _running = true;
    _log('start wsUrl=$wsUrl');
    try {
      // 1) REUSE LiveKit's existing local mic track — never a 2nd getUserMedia.
      // localTrack is a flutter_webrtc MediaStreamTrack; on web it's a
      // MediaStreamTrackWeb exposing the underlying JS track via `.jsTrack`.
      // We wrap it in our own MediaStream just to feed Web Audio; we only READ
      // it and never stop it (LiveKit still owns it).
      web.MediaStreamTrack? jsTrack;
      try {
        final dynamic dyn = localTrack;
        jsTrack = dyn?.jsTrack as web.MediaStreamTrack?;
      } catch (_) {
        jsTrack = null;
      }
      if (jsTrack == null) {
        _log('no LiveKit local track — aborting (refusing to open a 2nd mic)');
        onError?.call('no_local_track');
        _running = false;
        return;
      }
      // CLONE the track. A MediaStreamTrack already consumed by LiveKit's own
      // Web Audio graph delivers SILENCE when fed into a second
      // createMediaStreamSource (Chromium). A clone is an independent track
      // sharing the same mic source — it carries real audio, and stopping it at
      // teardown does NOT affect LiveKit's original (call audio stays intact).
      final clone = jsTrack.clone();
      _clonedTrack = clone;
      final stream = web.MediaStream();
      stream.addTrack(clone);
      _log('cloned LiveKit mic track for capture');

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
          _log('msg ${msg['type']}: '
              '${(msg['trans'] ?? msg['text'] ?? '').toString()}');
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
        } catch (_) {
          // Ignore malformed frames.
        }
      }).toJS;

      // 3) Audio graph: mic → processor → muted gain → destination.
      // The processor must be connected to the graph to fire; routing through a
      // zero-gain node keeps it running WITHOUT monitoring the mic to speakers.
      final ctx = web.AudioContext();
      _ctx = ctx;
      // Browsers start an AudioContext "suspended" without a user gesture; a
      // suspended context never fires onaudioprocess, so no PCM is ever sent.
      // Resume it explicitly (this runs during an active call = user gesture).
      try {
        await ctx.resume().toDart;
      } catch (_) {}
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
        // Level meter (~every 2.5s) — level ~0 means silence / suspended
        // context / muted track; a non-zero level means real sound is flowing.
        _frames++;
        if (_frames % 30 == 0) {
          var sum = 0.0;
          for (var i = 0; i < input.length; i++) {
            sum += input[i] * input[i];
          }
          final level = input.isEmpty ? 0.0 : sum / input.length;
          _log('pcm frames=$_frames level=${level.toStringAsFixed(5)}');
        }
      }).toJS;

      src.connect(proc);
      proc.connect(muteGain);
      muteGain.connect(ctx.destination);
      _log('audio graph up, inRate=$inRate state=${ctx.state}');
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
    // Stop only OUR clone — never LiveKit's original track (that would mute the
    // call). The clone shares the mic source but is an independent handle.
    try {
      _clonedTrack?.stop();
    } catch (_) {}
    _clonedTrack = null;
    _proc = null;
    _src = null;
    _muteGain = null;
    _ctx = null;
    _ws = null;
  }
}
