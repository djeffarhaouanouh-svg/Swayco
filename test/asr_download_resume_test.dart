import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/swayco/asr/asr_model_downloader.dart';

/// Petit serveur local : sert [data], avec ou sans support de `Range`, et peut
/// couper la première réponse en plein milieu.
Future<HttpServer> _serve(
  Uint8List data, {
  bool honorRange = true,
  bool cutFirst = false,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var calls = 0;
  server.listen((req) async {
    calls++;
    final range = req.headers.value('range');
    var start = 0;
    if (honorRange && range != null) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      req.response.statusCode = 206;
    }
    final body = data.sublist(start);
    req.response.contentLength = body.length;
    if (cutFirst && calls == 1) {
      req.response.add(body.sublist(0, body.length ~/ 2));
      await req.response.flush();
      // Moins d'octets que `Content-Length` : le serveur ferme la connexion, le
      // client voit une coupure en plein transfert.
      try {
        await req.response.close();
      } catch (_) {}
      return;
    }
    req.response.add(body);
    await req.response.close();
  });
  return server;
}

void main() {
  final data = Uint8List.fromList(List.generate(200000, (i) => i % 251));

  test('une coupure en cours de route : on reprend, le fichier est complet', () async {
    final server = await _serve(data, cutFirst: true);
    final dir = await Directory.systemTemp.createTemp('asr_resume');
    final tmp = File('${dir.path}/m.onnx.tmp');
    final n = await AsrModelDownloader()
        .downloadForTest('http://127.0.0.1:${server.port}/m', tmp);
    expect(n, data.length);
    expect(await tmp.readAsBytes(), data);
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  test('un .tmp resté d\'une ouverture précédente est complété, pas refait', () async {
    final server = await _serve(data);
    final dir = await Directory.systemTemp.createTemp('asr_resume');
    final tmp = File('${dir.path}/m.onnx.tmp');
    await tmp.writeAsBytes(data.sublist(0, 70000));
    final n = await AsrModelDownloader()
        .downloadForTest('http://127.0.0.1:${server.port}/m', tmp);
    expect(n, data.length);
    expect(await tmp.readAsBytes(), data);
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  test('serveur sans Range (réponse 200) : on repart du début, jamais de fichier corrompu', () async {
    final server = await _serve(data, honorRange: false);
    final dir = await Directory.systemTemp.createTemp('asr_resume');
    final tmp = File('${dir.path}/m.onnx.tmp');
    await tmp.writeAsBytes(data.sublist(0, 70000));
    final n = await AsrModelDownloader()
        .downloadForTest('http://127.0.0.1:${server.port}/m', tmp);
    expect(n, data.length);
    expect(await tmp.readAsBytes(), data);
    await server.close(force: true);
    await dir.delete(recursive: true);
  });
}
