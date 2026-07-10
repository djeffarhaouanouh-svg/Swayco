import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Records ONE utterance off a WebRTC [MediaStreamTrack] (the remote speaker)
/// and hands the encoded bytes back, for the cloud engine TEST translation pipeline.
///
/// Two implementations, selected by conditional import:
///  - web  → flutter_webrtc `MediaRecorder.startWeb` (works well; Chrome/Safari).
///  - native (io) → flutter_webrtc native `MediaRecorder.start(file)` — BEST
///    EFFORT only. iOS' native recorder is video-oriented and audio-only
///    capture of a remote track is unreliable, so [stopAndRead] may return null
///    there. Surfaced in the on-screen debug panel rather than thrown.
abstract class SwayUtteranceRecorder {
  /// Begin capturing [track]. Safe to call once per utterance.
  Future<void> start(MediaStreamTrack track);

  /// Stop and return the recorded bytes (or null if nothing usable). Always
  /// releases internal resources for this utterance.
  Future<Uint8List?> stopAndRead();

  /// Multipart filename whose extension matches the produced container —
  /// the backend infers the codec from it.
  String get filename;

  /// True once [start] has been called and not yet stopped.
  bool get isRecording;

  /// Release any long-lived resources.
  Future<void> dispose();
}
