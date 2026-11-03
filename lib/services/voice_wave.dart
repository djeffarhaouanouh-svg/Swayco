import 'dart:math' as math;

/// Les barres de l'onde d'un vocal, de 0 à 1.
///
/// Rien n'est stocké en base : la forme se déduit de l'id du message, donc les
/// deux téléphones dessinent la même onde. Enveloppe en cloche (les bords sont
/// plus bas), modulée par la graine. FNV-1a plutôt que `String.hashCode`, qui
/// n'est pas le même d'une plateforme à l'autre.
List<double> voiceBars(String id, {int count = 26}) {
  var h = 0x811C9DC5;
  for (final c in id.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
  }
  final seed = (h % 1000) / 100; // 0 à 10
  final last = math.max(1, count - 1);
  return [
    for (var i = 0; i < count; i++)
      () {
        final bell = math.sin(math.pi * (0.12 + 0.76 * i / last));
        final wobble = (math.sin(0.83 * i + seed) * math.sin(0.31 * i + 1.7 * seed))
            .abs();
        return (bell * math.pow(wobble, 0.8)).clamp(0.0, 1.0).toDouble();
      }(),
  ];
}

/// `m:ss` — la durée d'un vocal au repos.
String voiceClock(Duration d) {
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// `mm:ss` — le minuteur de l'enregistrement.
String voiceTimer(Duration d) {
  final s = d.inSeconds;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:'
      '${(s % 60).toString().padLeft(2, '0')}';
}
