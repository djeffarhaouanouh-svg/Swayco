import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'asr_catalogue.dart';

/// Downloads STT models into `<appSupport>/stt/<spec.id>/`.
///
/// Mirrors the local TTS engine downloaders: resumable-by-restart (writes to `.tmp`,
/// renames on success), idempotent (an existing complete directory is a no-op),
/// and reports 0.0 → 1.0 progress.
class AsrModelDownloader {
  /// Marker written once every file of a spec landed, so a half-finished
  /// download (app killed mid-transfer) is retried instead of loaded.
  static const _completeMarker = '.complete';

  static Future<Directory> sttDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/stt');
    await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> modelDir(AsrModelSpec spec) async {
    final base = await sttDir();
    return Directory('${base.path}/${spec.id}');
  }

  static const _segmenterFile = 'seg.onnx';

  /// The voice-activity segmenter (~2 MB) — not a model of any one language. It
  /// lives beside the language models rather than inside one, because it is
  /// shared and must survive [pruneExcept] wiping the others on a language
  /// switch. Returns the on-disk path.
  static Future<String> ensureSegmenter() async {
    final base = await sttDir();
    final dest = File('${base.path}/$_segmenterFile');
    if (await dest.exists() && await dest.length() > 0) return dest.path;
    final tmp = File('${dest.path}.tmp');
    await AsrModelDownloader()._downloadTo(kSegmenterUrl, tmp);
    await tmp.rename(dest.path);
    return dest.path;
  }

  static Future<bool> isInstalled(AsrModelSpec spec) async {
    final dir = await modelDir(spec);
    return File('${dir.path}/$_completeMarker').exists();
  }

  /// Deletes every installed model except [keep].
  ///
  /// STT reads this phone's own outgoing mic, so exactly one language is ever
  /// needed. Called after a successful language swap so switching fr → en → es
  /// leaves one model on disk instead of accumulating a directory per language.
  static Future<void> pruneExcept(AsrModelSpec keep) async {
    final base = await sttDir();
    if (!await base.exists()) return;
    await for (final entry in base.list()) {
      if (entry is! Directory) continue;
      if (entry.path.split(RegExp(r'[\\/]')).last == keep.id) continue;
      try {
        await entry.delete(recursive: true);
      } catch (_) {
        // A model still mmap'd by a live ONNX session can refuse deletion on
        // Windows; skip it — the next prune after dispose will collect it.
      }
    }
  }

  Future<Directory> ensureModel(
    AsrModelSpec spec, {
    void Function(double)? onProgress,
  }) async {
    final dir = await modelDir(spec);
    if (await isInstalled(spec)) return dir;

    await dir.create(recursive: true);
    onProgress?.call(0);

    switch (spec) {
      case NeuralAsrSpec():
        await _downloadNeural(spec, dir, onProgress);
      case LatticeAsrSpec():
        await _downloadLattice(spec, dir, onProgress);
      case UniversalAsrSpec():
        await _downloadUniversal(spec, dir, onProgress);
    }

    await File('${dir.path}/$_completeMarker').writeAsString('1');
    onProgress?.call(1);
    return dir;
  }

  /// Fetches each graph/tokenizer file, weighting progress by bytes received
  /// against the spec's advertised size (Hugging Face LFS omits Content-Length
  /// on some redirects, so a per-file fraction would stutter).
  Future<void> _downloadNeural(
    NeuralAsrSpec spec,
    Directory dir,
    void Function(double)? onProgress,
  ) async {
    final totalBytes = spec.approxMb * 1024 * 1024;
    var receivedTotal = 0;

    for (final file in spec.files) {
      // `onnx/encoder_model_quantized.onnx` → flat `encoder_model_quantized.onnx`
      final flat = file.split('/').last;
      final dest = File('${dir.path}/$flat');
      if (await dest.exists()) {
        receivedTotal += await dest.length();
        continue;
      }
      final tmp = File('${dest.path}.tmp');
      receivedTotal += await _downloadTo(
        spec.urlFor(file),
        tmp,
        onBytes: (n) => onProgress?.call(
          ((receivedTotal + n) / totalBytes).clamp(0.0, 0.99),
        ),
      );
      await tmp.rename(dest.path);
    }
  }

  /// Same file-by-file fetch as [_downloadNeural]. Our mirror publishes the
  /// files under the names the engine already wants, so there is nothing to
  /// remap on the way in.
  Future<void> _downloadUniversal(
    UniversalAsrSpec spec,
    Directory dir,
    void Function(double)? onProgress,
  ) async {
    final totalBytes = spec.approxMb * 1024 * 1024;
    var receivedTotal = 0;

    for (final file in spec.files) {
      final dest = File('${dir.path}/$file');
      if (await dest.exists()) {
        receivedTotal += await dest.length();
        continue;
      }
      final tmp = File('${dest.path}.tmp');
      receivedTotal += await _downloadTo(
        spec.urlFor(file),
        tmp,
        onBytes: (n) => onProgress?.call(
          ((receivedTotal + n) / totalBytes).clamp(0.0, 0.99),
        ),
      );
      await tmp.rename(dest.path);
    }
  }

  /// The lattice engine ships a zip whose single top-level folder is the model id. We flatten
  /// that folder into [dir] so the engine can point libvosk straight at it.
  Future<void> _downloadLattice(
    LatticeAsrSpec spec,
    Directory dir,
    void Function(double)? onProgress,
  ) async {
    final tmp = File('${dir.path}/${spec.id}.zip.tmp');
    final totalBytes = spec.approxMb * 1024 * 1024;
    await _downloadTo(
      spec.zipUrl,
      tmp,
      // Reserve the last 10% for extraction, which is not instant on a phone.
      onBytes: (n) => onProgress?.call(((n / totalBytes) * 0.9).clamp(0.0, 0.9)),
    );

    final archive = ZipDecoder().decodeBytes(await tmp.readAsBytes());
    for (final entry in archive) {
      if (!entry.isFile) continue;
      // Strip the leading `<model-id>/` component.
      final parts = entry.name.split('/')..removeAt(0);
      if (parts.isEmpty) continue;
      final out = File('${dir.path}/${parts.join('/')}');
      await out.parent.create(recursive: true);
      await out.writeAsBytes(entry.content as List<int>);
    }
    await tmp.delete();
    onProgress?.call(0.99);
  }

  /// Streams [url] into [dest]. Returns the number of bytes written.
  Future<int> _downloadTo(
    String url,
    File dest, {
    void Function(int received)? onBytes,
  }) async {
    final req = http.Request('GET', Uri.parse(url));
    final resp = await http.Client().send(req);
    if (resp.statusCode != 200) {
      throw Exception('STT download HTTP ${resp.statusCode}: $url');
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
    return received;
  }
}
