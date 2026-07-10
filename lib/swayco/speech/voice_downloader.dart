import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'model_downloader.dart';

class VoiceDownloader {
  static const _hfBase =
      'https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX'
      '/resolve/main/voices';

  // Mapping BCP-47 primary tag → default the local TTS engine voice name
  static const Map<String, String> _defaultVoices = {
    'en': 'af_heart',
    'fr': 'ff_siwis',
    'ja': 'jf_alpha',
    'ko': 'kf_alpha',
    'zh': 'zf_xiaobei',
    'es': 'ef_dora',
    'pt': 'pf_dora',
    'it': 'if_sara',
    'hi': 'hf_alpha',
    'de': 'af_heart', // No German voice yet — fallback to English
    'ar': 'af_heart', // No Arabic voice yet
    'tr': 'af_heart',
    'ru': 'af_heart',
    'nl': 'af_heart',
    'pl': 'af_heart',
    'sv': 'af_heart',
  };

  static String defaultVoiceFor(String langCode) {
    final lc = langCode.toLowerCase().split(RegExp(r'[-_]')).first;
    return _defaultVoices[lc] ?? 'af_heart';
  }

  // Voices for a given lang that should be pre-downloaded
  static List<String> voicesForLang(String langCode) {
    final voice = defaultVoiceFor(langCode);
    return [voice];
  }

  Future<File> ensureVoice(
    String voiceName, {
    void Function(double)? onProgress,
  }) async {
    final dir = await voicesDir();
    final file = File('${dir.path}/$voiceName.bin');
    if (await file.exists()) return file;

    onProgress?.call(0);
    final url = '$_hfBase/$voiceName.bin';
    final tmp = File('${dir.path}/$voiceName.bin.tmp');
    await _downloadTo(url, tmp, onProgress: onProgress);
    await tmp.rename(file.path);
    return file;
  }

  // Parses a voice .bin file: numpy .npy format or raw float32.
  // Returns Float32List of 256 values (the voice style embedding).
  static Float32List parseVoiceBytes(Uint8List bytes) {
    if (_isNpy(bytes)) return _parseNpy(bytes);
    // Raw float32 binary
    return bytes.buffer.asFloat32List(bytes.offsetInBytes);
  }

  static bool _isNpy(Uint8List b) =>
      b.length > 6 &&
      b[0] == 0x93 &&
      b[1] == 0x4E && // N
      b[2] == 0x55 && // U
      b[3] == 0x4D && // M
      b[4] == 0x50 && // P
      b[5] == 0x59; // Y

  static Float32List _parseNpy(Uint8List bytes) {
    final major = bytes[6];
    int dataOffset;
    if (major == 1) {
      final headerLen = bytes[8] | (bytes[9] << 8);
      dataOffset = 10 + headerLen;
    } else {
      // v2.0: 4-byte header length
      final headerLen = bytes[8] |
          (bytes[9] << 8) |
          (bytes[10] << 16) |
          (bytes[11] << 24);
      dataOffset = 12 + headerLen;
    }
    final numFloats = (bytes.length - dataOffset) ~/ 4;
    return bytes.buffer.asFloat32List(
      bytes.offsetInBytes + dataOffset,
      numFloats,
    );
  }

  static Future<Directory> voicesDir() async {
    final speechDir = await ModelDownloader.speechDir();
    final dir = Directory('${speechDir.path}/voices');
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
      throw Exception('Voice download HTTP ${resp.statusCode}: $url');
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
