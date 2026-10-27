import 'dart:ui' show Locale;

/// Langues dont le séparateur décimal est la virgule (`1,2k`) ; les autres
/// écrivent `1.2k`.
const Set<String> _kCommaLanguages = {'fr', 'es', 'it', 'pt', 'nl', 'de', 'ru'};

/// Un nombre de profils pour une puce : entier sous 1 000, puis `1,2k`, puis
/// `2,4M`. Un chiffre décimal, arrondi à l'inférieur (1999 -> `1,9k`, jamais
/// `2k`), sans « .0 » (2000 -> `2k`).
String formatCount(int n, Locale locale) {
  if (n < 1000) return '$n';
  final (value, unit) = n >= 1000000 ? (n ~/ 100000, 'M') : (n ~/ 100, 'k');
  // [value] est le nombre en dixièmes d'unité.
  final whole = value ~/ 10;
  final tenth = value % 10;
  if (tenth == 0) return '$whole$unit';
  final sep = _kCommaLanguages.contains(locale.languageCode) ? ',' : '.';
  return '$whole$sep$tenth$unit';
}
