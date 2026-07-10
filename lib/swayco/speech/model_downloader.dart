import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class ModelDownloader {
  static const _hfUrl =
      'https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX'
      '/resolve/main/onnx/model_quantized.onnx';
  static const _fileName = 'model.onnx';

  Future<File> ensureModel({void Function(double)? onProgress}) async {
    final dir = await _speechDir();
    final file = File('${dir.path}/$_fileName');
    if (await file.exists()) return file;

    onProgress?.call(0);
    final tmp = File('${dir.path}/$_fileName.tmp');
    await _downloadTo(_hfUrl, tmp, onProgress: onProgress);
    await tmp.rename(file.path);
    return file;
  }

  static Future<Directory> speechDir() => _speechDir();

  static Future<Directory> _speechDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/speech');
    await dir.create(recursive: true);
    return dir;
  }

  static Future<void> _downloadTo(
    String url,
    File dest, {
    void Function(double)? onProgress,
  }) async {
    final req = http.Request('GET', Uri.parse(url));
    final resp = await http.Client().send(req);
    if (resp.statusCode != 200) {
      throw Exception('the local TTS engine download HTTP ${resp.statusCode}: $url');
    }
    final total = resp.contentLength ?? 0;
    var received = 0;
    final sink = dest.openWrite();
    try {
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    onProgress?.call(1);
  }
}
