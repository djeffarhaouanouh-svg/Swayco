import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../services/call_audio.dart';
import 'sway_mic_streamer_base.dart';

SwayMicStreamer createSwayMicStreamer() => _WebSwayMicStreamer();

void _log(String m) => web.console.log('[sway-rt] $m'.toJS);

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

// ── ScriptProcessorNode fallback for iOS Safari (no MediaStreamTrackProcessor) ──
extension type _ScriptProcNode(JSObject _) implements JSObject {
  external set onaudioprocess(JSFunction? cb);
  external void disconnect();
}

extension type _AudioProcEvent(JSObject _) implements JSObject {
  external _AudioBuf get inputBuffer;
}

extension type _AudioBuf(JSObject _) implements JSObject {
  external JSFloat32Array getChannelData(int channel);
  external num get sampleRate;
}

extension _AudioCtxExt on web.AudioContext {
  @JS('createScriptProcessor')
  external _ScriptProcNode createScriptProc(
      int bufferSize, int numIn, int numOut);
  @JS('createMediaStreamSource')
  external JSObject createMsSource(web.MediaStream stream);
}

extension _JsNodeConnect on JSObject {
  @JS('connect')
  external void connectTo(JSObject destination);
}

@JS('MediaStreamTrackProcessor')
external JSAny? get _mstpConstructor;

/// Web realtime mic streamer, SENDER-side. Captures MY OWN mic via a dedicated
/// `getUserMedia` (echoCancellation = browser AEC), downsamples to PCM16 16 kHz,
/// and streams continuously to the backend cloud STT WS.
/// Auto-reconnects the WS when it drops (iOS Safari network instability).
class _WebSwayMicStreamer implements SwayMicStreamer {
  web.WebSocket? _ws;
  web.MediaStream? _micStream;
  web.ReadableStreamDefaultReader? _reader;
  // ScriptProcessor fallback (iOS Safari)
  web.AudioContext? _audioCtx;
  _ScriptProcNode? _scriptProc;

  bool _running = false;
  bool _wsOpen = false;
  int _frames = 0;
  bool _captureLocalMic = true;

  // Stored so _openWs() can reconnect without restarting audio capture.
  Uri? _wsUrl;
  void Function(String orig, String trans, String lang, String audioB64)?
      _cbTranslation;
  void Function(String partial)? _cbPartial;
  void Function(String error)? _cbError;

  static const int _outRate = 16000;
  static const Duration _reconnectDelay = Duration(seconds: 2);

  @override
  bool get isRunning => _running;

  @override
  bool get isStreaming => _running && _wsOpen;

  @override
  set peerGender(String value) {}

  @override
  set onDropped(void Function(String heard)? value) {}

  @override
  void notePeerUtterance(String orig) {}

  @override
  bool get accumulatesTranscript => true;

  // The the cloud engine path streams continuously; it never releases the mic.
  @override
  bool get isDozing => false;

  @override
  Future<void> wake() async {}

  @override
  Future<void> start({
    required Uri wsUrl,
    Object? localTrack,
    bool captureLocalMic = true,
    // Web keeps the cloud engine path: the langs are already encoded in [wsUrl].
    String sourceLang = '',
    String targetLang = '',
    required void Function(String orig, String trans, String lang, String audioB64)
        onTranslation,
    void Function(String partial)? onPartial,
    void Function(String error)? onError,
  }) async {
    if (_running) return;
    _running = true;
    _captureLocalMic = captureLocalMic;
    _wsUrl = wsUrl;
    _cbTranslation = onTranslation;
    _cbPartial = onPartial;
    _cbError = onError;
    _log('start ${captureLocalMic ? "LOCAL-mic" : "REMOTE-track"} wsUrl=$wsUrl');
    try {
      final web.MediaStreamTrack micTrack;
      if (captureLocalMic) {
        // Prefer cloning the LiveKit track already open on this device.
        // A 2nd getUserMedia can cause AEC-reference mismatch and OS conflicts.
        // The clone shares the hardware source but is independent: we apply
        // STT-optimised constraints (AEC off, NS on, AGC on) without touching
        // the LiveKit call track.
        // LiveKit's LocalAudioTrack.mediaStreamTrack returns a flutter_webrtc
        // MediaStreamTrack, not a web.MediaStreamTrack. One more hop via .jsTrack
        // gives the underlying JS object.
        web.MediaStreamTrack? lkMst;
        if (localTrack != null) {
          try {
            final fwMst = (localTrack as dynamic).mediaStreamTrack;
            lkMst = (fwMst as dynamic).jsTrack as web.MediaStreamTrack?;
          } catch (_) {}
        }

        if (lkMst != null) {
          micTrack = lkMst.clone();
          final s = web.MediaStream();
          s.addTrack(micTrack);
          _micStream = s;
          // Clone inherits LiveKit's AudioCaptureOptions:
          //   AEC on · NS on · AGC OFF
          // AGC off is critical: with AGC on, any TTS leak captured by the mic
          // gets amplified each pass until audio runs away (the "son dégueulasse").
          // Without AGC the leak stays below source level and decays naturally.
          _log('LiveKit track cloned for STT (AEC on, NS on, AGC off)');
        } else {
          // Fallback: LiveKit track not yet published — open own getUserMedia
          // with the same constraint set as call_screen AudioCaptureOptions.
          final micStream = await web.window.navigator.mediaDevices
              .getUserMedia(web.MediaStreamConstraints(
                audio: web.MediaTrackConstraints(
                  echoCancellation: true.toJS,
                  noiseSuppression: true.toJS,
                  autoGainControl: false.toJS,
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
          _log('getUserMedia local mic fallback (AEC on, NS on, AGC off)');
        }
      } else {
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

      // Open WebSocket (with auto-reconnect on close).
      _openWs();

      // Pull audio frames: prefer MediaStreamTrackProcessor (Chrome/Firefox);
      // fall back to ScriptProcessorNode for iOS Safari.
      final bool hasMstp = _mstpConstructor != null;
      if (hasMstp) {
        final processor = web.MediaStreamTrackProcessor(
            web.MediaStreamTrackProcessorInit(track: micTrack));
        final reader = processor.readable.getReader()
            as web.ReadableStreamDefaultReader;
        _reader = reader;
        _log('MediaStreamTrackProcessor reader started');
        unawaited(_pump(reader));
      } else {
        _log('MediaStreamTrackProcessor unavailable — using ScriptProcessor');
        _startScriptProcessor(micTrack);
      }
    } catch (e) {
      _log('start FAILED: $e');
      onError?.call('start_failed: $e');
      await stop();
    }
  }

  /// Open (or reopen) the WebSocket. Called once at start and automatically
  /// after any unexpected close while [_running] is still true.
  void _openWs() {
    if (!_running) return;
    final url = _wsUrl;
    if (url == null) return;

    try {
      final ws = web.WebSocket(url.toString());
      ws.binaryType = 'arraybuffer';
      _ws = ws;

      ws.onopen = ((web.Event _) {
        _wsOpen = true;
        _log('ws OPEN');
      }).toJS;

      ws.onerror = ((web.Event _) {
        _log('ws ERROR');
        // Don't surface transient errors during reconnect cycles —
        // the onclose handler below will schedule a retry.
      }).toJS;

      ws.onclose = ((web.CloseEvent ev) {
        _wsOpen = false;
        _log('ws CLOSE code=${ev.code}');
        if (_running) {
          _log('ws closed unexpectedly — reconnect in ${_reconnectDelay.inSeconds}s');
          Future.delayed(_reconnectDelay, _openWs);
        }
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
              _cbTranslation?.call(
                (msg['orig'] ?? '').toString(),
                (msg['trans'] ?? '').toString(),
                (msg['lang'] ?? '').toString(),
                (msg['audio'] ?? '').toString(),
              );
              break;
            case 'partial':
              _cbPartial?.call((msg['text'] ?? '').toString());
              break;
            case 'error':
              _log('backend error: ${msg['error']}');
              _cbError?.call((msg['error'] ?? 'error').toString());
              break;
          }
        } catch (_) {}
      }).toJS;
    } catch (e) {
      _log('_openWs FAILED: $e');
      if (_running) {
        Future.delayed(_reconnectDelay, _openWs);
      }
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
        // Continuous stream — the cloud engine STT handles silence internally.
        // isTranslationPlaying pauses SEND while TTS plays so the mic doesn't
        // re-capture and re-translate our own speaker output. The gate is
        // cleared immediately in _toggleMic when the user unmutes, so it
        // never permanently blocks SEND.
        if (_wsOpen && n > 0 &&
            !(_captureLocalMic && isSendMuted) &&
            !(_captureLocalMic && isTranslationPlaying)) {
          final pcm = _downsampleToPcm16(f32, inRate, _outRate);
          if (pcm.isNotEmpty) {
            try { _ws?.send(pcm.toJS); } catch (_) {}
          }
          _frames++;
          if (_frames % 200 == 0) {
            _log('pcm frames=$_frames muted=$isSendMuted');
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

  // ── ScriptProcessor fallback (iOS Safari) ──────────────────────────────────
  void _startScriptProcessor(web.MediaStreamTrack track) {
    try {
      final ctx = web.AudioContext();
      _audioCtx = ctx;
      final inRate = ctx.sampleRate.toInt();

      final stream = _micStream ?? web.MediaStream();
      if (_micStream == null) stream.addTrack(track);

      final source = ctx.createMsSource(stream);
      final proc = ctx.createScriptProc(4096, 1, 1);
      _scriptProc = proc;

      source.connectTo(proc);
      proc.connectTo(ctx.destination as JSObject);

      proc.onaudioprocess = ((JSObject evt) {
        if (!_running || !_wsOpen) return;
        try {
          final e = _AudioProcEvent(evt);
          final buf = e.inputBuffer;
          final f32 = buf.getChannelData(0).toDart;
          final rate = buf.sampleRate.toInt();
          if (!(_captureLocalMic && isSendMuted) &&
              !(_captureLocalMic && isTranslationPlaying)) {
            final pcm = _downsampleToPcm16(f32, rate, _outRate);
            if (pcm.isNotEmpty) {
              try { _ws?.send(pcm.toJS); } catch (_) {}
            }
          }
          _frames++;
          if (_frames % 200 == 0) {
            _log('script-proc frames=$_frames muted=$isSendMuted rate=$rate');
          }
        } catch (_) {}
      }).toJS;

      _log('ScriptProcessor started inRate=$inRate');
    } catch (e) {
      _log('ScriptProcessor FAILED: $e');
    }
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
      _scriptProc?.disconnect();
      _scriptProc = null;
    } catch (_) {}
    try {
      unawaited(_audioCtx?.close().toDart);
      _audioCtx = null;
    } catch (_) {}
    try {
      final ws = _ws;
      if (ws != null && ws.readyState == 1) {
        ws.send('{"type":"audio.done"}'.toJS);
        ws.close();
      }
    } catch (_) {}
    _ws = null;
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
    _wsUrl = null;
    _cbTranslation = null;
    _cbPartial = null;
    _cbError = null;
  }
}
