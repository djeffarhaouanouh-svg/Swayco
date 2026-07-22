import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../services/debug_overlay.dart';

/// Fetches the two OpenVoice graphs into `<appSupport>/voice/`, where
/// [VoiceCloneService] looks for them.
///
/// Same shape as [TtsBundleDownloader], minus the archive step: these ship as
/// plain `.onnx`, not a tar. Resumable-by-restart (no `.complete` marker → the
/// pair is re-fetched), idempotent. The download is deferred and best-effort:
/// the call feature it powers is a garnish, so a failed or missing download just
/// means the peer keeps hearing the stock voice — never a broken call.
class VoiceModelDownloader {
  static const _mirror = 'https://huggingface.co/djeffar/swayco-tts/resolve/main';

  // The converter is dynamic-shape: one pass at the sentence's real length, no
  // padding a short "oui" up to 6 s. See docs/voice-cloning.md.
  static const _files = <({String name, String url})>[
    (name: 'ref_encoder.onnx', url: '$_mirror/voice/ref_encoder.onnx'),
    (name: 'converter.onnx', url: '$_mirror/voice/converter.onnx'),
  ];
  static const _completeMarker = '.complete';

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/voice');
    await dir.create(recursive: true);
    return dir;
  }

  static Future<bool> isInstalled() async {
    final dir = await _dir();
    return File('${dir.path}/$_completeMarker').exists();
  }

  /// Download the pair if not already present. Returns true when the models are
  /// on disk afterwards. Never throws — a failure is logged and returns false.
  static Future<bool> ensure({void Function(double)? onProgress}) async {
    try {
      if (await isInstalled()) return true;
      final dir = await _dir();
      var done = 0;
      for (final f in _files) {
        final tmp = File('${dir.path}/${f.name}.part');
        final req = http.Request('GET', Uri.parse(f.url));
        final resp = await http.Client().send(req);
        if (resp.statusCode != 200) {
          DebugOverlay.log('voice dl: ${f.name} HTTP ${resp.statusCode}');
          return false;
        }
        final total = resp.contentLength ?? 0;
        final sink = tmp.openWrite();
        var got = 0;
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) {
            onProgress?.call((done + got / total) / _files.length);
          }
        }
        await sink.close();
        await tmp.rename('${dir.path}/${f.name}');
        done++;
      }
      await File('${dir.path}/$_completeMarker').create();
      DebugOverlay.log('voice dl: models ready');
      return true;
    } catch (e) {
      DebugOverlay.log('voice dl: failed ($e)');
      return false;
    }
  }
}
