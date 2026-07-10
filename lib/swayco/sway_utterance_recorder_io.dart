import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';

import 'sway_utterance_recorder_base.dart';

SwayUtteranceRecorder createSwayRecorder() => _IoUtteranceRecorder();

/// Native (iOS / Android) recorder — BEST EFFORT. flutter_webrtc's native
/// `MediaRecorder` is built around a video track + AVAssetWriter; audio-only
/// capture of a remote WebRTC track is not reliably supported on iOS. We still
/// wire it (it works on Android and may work on some iOS builds) and let
/// [stopAndRead] return null when the file never materialised, so the port can
/// surface "no bytes" in the debug panel instead of crashing the call.
class _IoUtteranceRecorder implements SwayUtteranceRecorder {
  MediaRecorder? _rec;
  String? _path;
  bool _recording = false;
  static int _seq = 0;

  @override
  bool get isRecording => _recording;

  @override
  String get filename => 'utt.m4a';

  @override
  Future<void> start(MediaStreamTrack track) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/sway_utt_${_seq++}.m4a';
    // Remove a stale file from a previous utterance with the same name.
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    _path = path;
    _rec = MediaRecorder();
    // OUTPUT = the remote/playback channel (what we hear) — the speaker we
    // want to translate. No videoTrack: audio-only (unsupported on iOS today).
    await _rec!.start(path, audioChannel: RecorderAudioChannel.OUTPUT);
    _recording = true;
  }

  @override
  Future<Uint8List?> stopAndRead() async {
    final rec = _rec;
    final path = _path;
    _rec = null;
    _path = null;
    _recording = false;
    if (rec != null) {
      try {
        await rec.stop();
      } catch (e) {
        debugPrint('recorder(native): stop failed: $e');
      }
    }
    if (path == null) return null;
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      try {
        await f.delete();
      } catch (_) {}
      return bytes.isEmpty ? null : bytes;
    } catch (e) {
      debugPrint('recorder(native): read failed: $e');
      return null;
    }
  }

  @override
  Future<void> dispose() async {
    if (_recording) await stopAndRead();
  }
}
