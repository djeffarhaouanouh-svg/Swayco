import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'tts_catalogue.dart';

/// Downloads + extracts a the runtime TTS bundle into `<appSupport>/tts/<id>/`.
///
/// Mirrors [AsrModelDownloader]: resumable-by-restart (a half-extracted dir has
/// no `.complete` marker, so it is re-fetched), idempotent, 0.0 → 1.0 progress.
/// Each bundle is a `.tar.bz2` with a single top-level folder that we flatten,
/// so the engine can point straight at `model.onnx`, `the phonemiser-data/`, etc.
class TtsBundleDownloader {
  static const _completeMarker = '.complete';

  static Future<Directory> ttsDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/tts');
    await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> modelDir(TtsModelSpec spec) async {
    final base = await ttsDir();
    return Directory('${base.path}/${spec.id}');
  }

  static Future<bool> isInstalled(TtsModelSpec spec) async {
    final dir = await modelDir(spec);
    return File('${dir.path}/$_completeMarker').exists();
  }

  /// Deletes every installed TTS bundle except [keep].
  ///
  /// A device speaks exactly one voice at a time (the peer's language), so an
  /// earlier bundle is dead weight once a new one is configured. Called after a
  /// successful language swap. Best-effort: a failed delete is swallowed.
  static Future<void> pruneExcept(TtsModelSpec keep) async {
    final base = await ttsDir();
    if (!await base.exists()) return;
    await for (final entry in base.list()) {
      if (entry is! Directory) continue;
      if (entry.path.split(RegExp(r'[\\/]')).last == keep.id) continue;
      try {
        await entry.delete(recursive: true);
      } catch (_) {
        // A bundle still open in the sherpa runtime can refuse deletion; skip
        // it — the next prune after the engine reconfigures will collect it.
      }
    }
  }

  Future<Directory> ensureBundle(
    TtsModelSpec spec, {
    void Function(double)? onProgress,
  }) async {
    final dir = await modelDir(spec);
    if (await isInstalled(spec)) return dir;

    await dir.create(recursive: true);
    onProgress?.call(0);

    final tmp = File('${dir.path}/${spec.id}.tar.bz2.tmp');
    final totalBytes = spec.approxMb * 1024 * 1024;
    // Reserve the last 15% for decode+extract, which is not instant on a phone.
    await _downloadTo(
      spec.bundleUrl,
      tmp,
      onBytes: (n) =>
          onProgress?.call(((n / totalBytes) * 0.85).clamp(0.0, 0.85)),
    );

    final tar = BZip2Decoder().decodeBytes(await tmp.readAsBytes());
    final archive = TarDecoder().decodeBytes(tar);
    for (final entry in archive) {
      if (!entry.isFile) continue;
      // Strip the leading `<bundle-name>/` component so paths are flat.
      final parts = entry.name.split('/')..removeAt(0);
      if (parts.isEmpty || parts.last.isEmpty) continue;
      final out = File('${dir.path}/${parts.join('/')}');
      await out.parent.create(recursive: true);
      await out.writeAsBytes(entry.content as List<int>);
    }
    await tmp.delete();

    await File('${dir.path}/$_completeMarker').writeAsString('1');
    onProgress?.call(1);
    return dir;
  }

  Future<void> _downloadTo(
    String url,
    File dest, {
    void Function(int received)? onBytes,
  }) async {
    final req = http.Request('GET', Uri.parse(url));
    final resp = await http.Client().send(req);
    if (resp.statusCode != 200) {
      throw Exception('TTS bundle download HTTP ${resp.statusCode}: $url');
    }
    var received = 0;
    final sink = dest.openWrite();
    try {
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        onBytes?.call(received);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }
}
