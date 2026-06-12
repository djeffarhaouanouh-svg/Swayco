import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web/web.dart' as web;

import 'grok_utterance_recorder_base.dart';

GrokUtteranceRecorder createGrokRecorder() => _WebUtteranceRecorder();

/// Picks the best MediaRecorder audio container the browser actually supports.
/// Chrome → webm/opus; Safari → mp4 (it rejects webm). Returns the mime and a
/// matching file extension for the multipart filename.
({String mime, String ext}) _pickMime() {
  const candidates = <({String mime, String ext})>[
    (mime: 'audio/webm;codecs=opus', ext: 'webm'),
    (mime: 'audio/webm', ext: 'webm'),
    (mime: 'audio/mp4', ext: 'mp4'),
    (mime: 'audio/mpeg', ext: 'mp3'),
  ];
  for (final c in candidates) {
    try {
      if (web.MediaRecorder.isTypeSupported(c.mime)) return c;
    } catch (_) {}
  }
  return (mime: 'audio/webm', ext: 'webm');
}

class _WebUtteranceRecorder implements GrokUtteranceRecorder {
  MediaRecorder? _rec;
  MediaStream? _stream;
  String _ext = 'webm';
  bool _recording = false;

  @override
  bool get isRecording => _recording;

  @override
  String get filename => 'utt.$_ext';

  @override
  Future<void> start(MediaStreamTrack track) async {
    final picked = _pickMime();
    _ext = picked.ext;
    // Clone so disposing our temp stream later never touches the source the
    // remote/LiveKit is still using.
    final clone = await track.clone();
    _stream = await createLocalMediaStream('grok_utt_src');
    await _stream!.addTrack(clone);
    _rec = MediaRecorder();
    // No onDataChunk → the wrapper assembles every slice into one Blob and
    // stop() resolves to a blob: object-URL pointing at the whole recording.
    _rec!.startWeb(_stream!, mimeType: picked.mime);
    _recording = true;
  }

  @override
  Future<Uint8List?> stopAndRead() async {
    final rec = _rec;
    _rec = null;
    _recording = false;
    Uint8List? out;
    if (rec != null) {
      try {
        final result = await rec.stop();
        if (result is String && result.isNotEmpty) {
          out = await _bytesFromObjectUrl(result);
          try {
            web.URL.revokeObjectURL(result);
          } catch (_) {}
        }
      } catch (e) {
        debugPrint('Grok recorder(web): stop failed: $e');
      }
    }
    await _disposeStream();
    return out;
  }

  Future<Uint8List?> _bytesFromObjectUrl(String url) async {
    try {
      final resp = await web.window.fetch(url.toJS).toDart;
      final buf = await resp.arrayBuffer().toDart;
      final bytes = buf.toDart.asUint8List();
      return bytes.isEmpty ? null : bytes;
    } catch (e) {
      debugPrint('Grok recorder(web): blob read failed: $e');
      return null;
    }
  }

  Future<void> _disposeStream() async {
    final s = _stream;
    _stream = null;
    if (s != null) {
      try {
        await s.dispose();
      } catch (_) {}
    }
  }

  @override
  Future<void> dispose() async {
    if (_recording) {
      await stopAndRead();
    } else {
      await _disposeStream();
    }
  }
}
