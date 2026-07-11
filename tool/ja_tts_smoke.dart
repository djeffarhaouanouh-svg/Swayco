// Runtime smoke test for the on-device Japanese voice, in the real macOS app
// build (patched sherpa + OpenJTalk linked). Bypasses auth/download: points
// JaTtsEngine at a local bundle and speaks a few phrases on launch.
//
// Run: flutter run -d macos -t tool/ja_tts_smoke.dart --dart-define=JA_BUNDLE=/abs/path/to/ja_bundle
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:livekit_translate/swayco/speech/ja_tts_engine.dart';

void main() => runApp(const _App());

class _App extends StatefulWidget {
  const _App();
  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  final _engine = JaTtsEngine();
  final _log = <String>[];
  final _phrases = const [
    'こんにちは。今日は元気ですか',
    '2026年7月に日本へ行きます',
    'よかったら、今度一緒に食事でもどうですか',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _p(String s) {
    // ignore: avoid_print
    print('[ja-smoke] $s');
    setState(() => _log.add(s));
  }

  Future<void> _run() async {
    try {
      final support = await getApplicationSupportDirectory();
      final bundle = '${support.path}/ja_bundle';
      _p('bundle = $bundle');
      await _engine.configure(JaTtsModel(
        model: '$bundle/model.fp16.onnx',
        tokens: '$bundle/tokens.txt',
        lexicon: '$bundle/lexicon.txt',
        dictDir: '$bundle/open_jtalk_dic_utf_8-1.11',
      ));
      _p('configured: ${_engine.isReady}');
      for (final t in _phrases) {
        _p('speak: $t');
        await _engine.speak(t);
        await _engine.onPlaybackComplete.first;
        _p('  done');
      }
      _p('ALL OK');
    } catch (e, st) {
      _p('ERROR: $e');
      _p('$st');
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('ja TTS smoke')),
          body: ListView(
            children: [
              for (final l in _log)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  child: Text(l),
                ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: _run,
                  child: const Text('Speak again'),
                ),
              ),
            ],
          ),
        ),
      );
}
