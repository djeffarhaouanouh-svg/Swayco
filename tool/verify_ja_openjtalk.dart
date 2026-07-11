// Dev verification: native OpenJTalk reading -> Dart phonemizer, on desktop.
// Usage: dart run tool/verify_ja_openjtalk.dart <libja_openjtalk.dylib> <dictDir> <tokens.txt>
import 'dart:io';
import 'package:livekit_translate/swayco/speech/ja_openjtalk_ffi.dart';
import 'package:livekit_translate/swayco/speech/ja_phonemizer.dart';

void main(List<String> args) {
  final lib = args[0], dict = args[1], tokensPath = args[2];
  final tokens = parseTokens(File(tokensPath).readAsStringSync());
  final oj = JaOpenJTalk.load(dict, libraryPath: lib);

  const phrases = [
    '今日は元気ですか',
    '2026年7月に日本へ行きます',
    'よかったら、今度一緒に食事でもどうですか',
    '昨日、友達と美味しい料理を食べました',
    '私の名前はトマです',
  ];
  for (final p in phrases) {
    final kana = oj.kana(p);
    final expanded = expandChoonpu(kana);
    final out = phonemizeKatakana(expanded, tokens);
    stdout.writeln('text : $p');
    stdout.writeln('kana : $kana');
    stdout.writeln('tokens(${out.tokenIds.length}): ${out.tokenIds}');
    stdout.writeln('');
  }
  oj.dispose();
  stdout.writeln('OK');
}
