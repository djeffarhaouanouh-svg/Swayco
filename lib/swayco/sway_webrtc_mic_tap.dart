import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../services/debug_overlay.dart';

/// Reads the PCM of WebRTC's ALREADY-OPEN local mic capture, via the native
/// [SwayMicTap] (iOS). This exists so the STT does not open a SECOND `record`
/// capture on the same microphone — two captures on one iOS mic self-oscillate
/// into a startup whistle. The web build solves the same problem by cloning the
/// LiveKit track; native has no clone, so it taps instead.
///
/// Output is always PCM16 mono at [outRate] (16 kHz), resampled here from
/// whatever rate WebRTC delivers (typically 48 kHz), so the VAD/recogniser get
/// exactly what they got from `record`.
class SwayWebrtcMicTap {
  SwayWebrtcMicTap._() {
    _method.setMethodCallHandler(_onMethod);
  }
  static final SwayWebrtcMicTap instance = SwayWebrtcMicTap._();

  static const int outRate = 16000;

  static const MethodChannel _method = MethodChannel('swayco/mic_tap');
  static const EventChannel _event = EventChannel('swayco/mic_tap/pcm');

  StreamSubscription<dynamic>? _rawSub;
  StreamController<Uint8List>? _out;

  // Resampler state (linear interpolation, carried across buffers).
  double _inRate = 48000; // updated by the native "format" callback
  double _ratio = 48000 / outRate;
  double _pos = 0; // fractional read position, relative to current buffer start
  double _prev = 0; // last sample of the previous buffer (index -1)
  bool _hasPrev = false;

  /// PCM16 mono @ 16 kHz. Valid between [start] and [stop].
  Stream<Uint8List> get pcm16k {
    _out ??= StreamController<Uint8List>.broadcast();
    return _out!.stream;
  }

  Future<void> _onMethod(MethodCall call) async {
    if (call.method == 'format') {
      final rate = (call.arguments['sampleRate'] as num?)?.toDouble() ?? 48000;
      if (rate > 0) {
        _inRate = rate;
        _ratio = _inRate / outRate;
        DebugOverlay.log('mic tap format — in=${rate.toStringAsFixed(0)}Hz '
            '→ ${outRate ~/ 1000}kHz (ratio ${_ratio.toStringAsFixed(3)})');
      }
    }
  }

  /// True once at least one PCM buffer has come through. The caller uses it as a
  /// watchdog: an attach that reports success but delivers nothing is exactly
  /// how the first (AddSink) attempt failed, and silence is otherwise
  /// indistinguishable from "nobody spoke".
  bool get receiving => _received > 0;
  int _received = 0;

  /// Attach to WebRTC's capture post-processing and begin streaming.
  ///
  /// No track id: the hook is global to the audio pipeline, so it keeps working
  /// across the track restarts that every unmute causes.
  Future<void> start() async {
    _out ??= StreamController<Uint8List>.broadcast();
    _resetResampler();
    _received = 0;
    final res = await _method.invokeMethod<String>('start');
    DebugOverlay.log('mic tap start → $res');
    _rawSub = _event.receiveBroadcastStream().listen(
      (dynamic data) {
        if (data is Uint8List) _onRaw(data);
      },
      onError: (Object e) => DebugOverlay.log('mic tap stream error: $e'),
    );
  }

  Future<void> stop() async {
    await _rawSub?.cancel();
    _rawSub = null;
    try {
      await _method.invokeMethod('stop');
    } catch (_) {}
  }

  void _resetResampler() {
    _pos = 0;
    _prev = 0;
    _hasPrev = false;
  }

  void _onRaw(Uint8List bytes) {
    _received++;
    final controller = _out;
    if (controller == null || controller.isClosed) return;
    controller.add(_resampleToPcm16(bytes));
  }

  /// Linear-interpolation resample of one PCM16 mono buffer at [_inRate] down to
  /// [outRate]. State ([_pos], [_prev]) carries across buffers so a fractional
  /// read that lands between two buffers still interpolates correctly.
  Uint8List _resampleToPcm16(Uint8List inBytes) {
    final inLen = inBytes.length ~/ 2;
    if (inLen == 0) return Uint8List(0);
    final src = ByteData.sublistView(inBytes);

    double sampleAt(int i) {
      if (i < 0) return _hasPrev ? _prev : src.getInt16(0, Endian.little).toDouble();
      return src.getInt16(i * 2, Endian.little).toDouble();
    }

    // Upper bound on outputs: ceil(inLen / ratio) + 1.
    final out = <int>[];
    while (true) {
      final i = _pos.floor();
      if (i + 1 > inLen - 1) break; // need i and i+1; i+1 must be in this buffer
      final frac = _pos - i;
      final a = sampleAt(i);
      final b = sampleAt(i + 1);
      var v = (a + (b - a) * frac).round();
      if (v > 32767) v = 32767;
      if (v < -32768) v = -32768;
      out.add(v);
      _pos += _ratio;
    }
    // Shift origin to the next buffer and carry its last sample as index -1.
    _pos -= inLen;
    _prev = src.getInt16((inLen - 1) * 2, Endian.little).toDouble();
    _hasPrev = true;

    final result = Uint8List(out.length * 2);
    final dst = ByteData.sublistView(result);
    for (var k = 0; k < out.length; k++) {
      dst.setInt16(k * 2, out[k], Endian.little);
    }
    return result;
  }
}
