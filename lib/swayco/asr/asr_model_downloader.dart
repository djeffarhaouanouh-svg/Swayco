import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
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
      case UniversalAsrSpec():
        await _downloadUniversal(spec, dir, onProgress);
    }

    await File('${dir.path}/$_completeMarker').writeAsString('1');
    onProgress?.call(1);
    return dir;
  }

  /// File-by-file fetch. Our mirror publishes the files under the names the
  /// engine already wants, so there is nothing to remap on the way in.
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
      final base = receivedTotal;
      receivedTotal += await _downloadTo(
        spec.urlFor(file),
        tmp,
        onBytes: (n) => onProgress?.call(
          ((base + n) / totalBytes).clamp(0.0, 0.99),
        ),
      );
      await tmp.rename(dest.path);
    }
  }

  @visibleForTesting
  Future<int> downloadForTest(String url, File dest) => _downloadTo(url, dest);

  /// Nombre d'essais par fichier : une coupure réseau en cours de route ne fait
  /// plus tout recommencer, on reprend là où le fichier s'est arrêté.
  static const _maxAttempts = 4;

  /// Streams [url] into [dest]. Returns the size of the finished file.
  ///
  /// REPRISE : si [dest] (le `.tmp`) contient déjà le début du fichier — app
  /// fermée, réseau coupé, téléphone en veille —, on redemande seulement la suite
  /// (en-tête `Range`). Avant, chaque interruption repartait de zéro : sur un
  /// modèle de 244 Mo et une connexion mobile lente, certains n'y arrivaient
  /// jamais. Si le serveur ignore `Range` (réponse 200), on repart du début.
  Future<int> _downloadTo(
    String url,
    File dest, {
    void Function(int received)? onBytes,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      final client = http.Client();
      try {
        final have = await dest.exists() ? await dest.length() : 0;
        final req = http.Request('GET', Uri.parse(url));
        if (have > 0) req.headers['Range'] = 'bytes=$have-';
        final resp = await client.send(req);

        // 416 : le .tmp a déjà la taille complète (coupé juste avant le renommage).
        if (resp.statusCode == 416 && have > 0) return have;

        final resumed = resp.statusCode == 206 && have > 0;
        if (resp.statusCode != 200 && !resumed) {
          throw Exception('STT download HTTP ${resp.statusCode}: $url');
        }

        var received = resumed ? have : 0;
        final sink =
            dest.openWrite(mode: resumed ? FileMode.append : FileMode.write);
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
      } catch (e) {
        // On garde le .tmp : l'essai suivant reprend à sa taille actuelle.
        lastError = e;
        if (attempt < _maxAttempts - 1) {
          await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
        }
      } finally {
        client.close();
      }
    }
    throw lastError ?? Exception('STT download failed: $url');
  }
}
