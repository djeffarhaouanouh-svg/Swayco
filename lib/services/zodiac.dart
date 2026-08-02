import 'zodiac_i18n.dart';

export 'zodiac_i18n.dart';

/// The 12 Western zodiac signs, stored as French labels (same convention as
/// interests). The picker only ever writes one of these keys.
const List<String> kZodiacSigns = [
  'Bélier',
  'Taureau',
  'Gémeaux',
  'Cancer',
  'Lion',
  'Vierge',
  'Balance',
  'Scorpion',
  'Sagittaire',
  'Capricorne',
  'Verseau',
  'Poissons',
];

/// Inclusive calendar-month span for each sign (1 = January … 12 = December).
/// Approximate tropical dates — enough to hint "which months" next to the name.
const Map<String, (int, int)> kZodiacMonthSpan = {
  'Bélier': (3, 4), // 21 mars – 19 avril
  'Taureau': (4, 5),
  'Gémeaux': (5, 6),
  'Cancer': (6, 7),
  'Lion': (7, 8),
  'Vierge': (8, 9),
  'Balance': (9, 10),
  'Scorpion': (10, 11),
  'Sagittaire': (11, 12),
  'Capricorne': (12, 1),
  'Verseau': (1, 2),
  'Poissons': (2, 3),
};

/// Map a free-text legacy value (or a known synonym) onto a canonical key.
/// Returns the key when recognised, otherwise the trimmed original (or empty).
String normalizeZodiac(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '';
  if (kZodiacSigns.contains(t)) return t;
  final lower = t.toLowerCase();
  return _kZodiacAliases[lower] ?? t;
}

const Map<String, String> _kZodiacAliases = {
  // French variants
  'poisson': 'Poissons',
  'poissons': 'Poissons',
  'gémeau': 'Gémeaux',
  'gemeaux': 'Gémeaux',
  'gemeau': 'Gémeaux',
  'belier': 'Bélier',
  'bélier': 'Bélier',
  // English
  'aries': 'Bélier',
  'taurus': 'Taureau',
  'gemini': 'Gémeaux',
  'cancer': 'Cancer',
  'leo': 'Lion',
  'virgo': 'Vierge',
  'libra': 'Balance',
  'scorpio': 'Scorpion',
  'sagittarius': 'Sagittaire',
  'capricorn': 'Capricorne',
  'aquarius': 'Verseau',
  'pisces': 'Poissons',
};

/// Index of [key] in [kZodiacSigns], or 0 when unknown (picker default).
int zodiacIndex(String key) {
  final i = kZodiacSigns.indexOf(normalizeZodiac(key));
  return i < 0 ? 0 : i;
}

/// Localised sign name only.
String displayZodiac(String raw) {
  final key = normalizeZodiac(raw);
  if (key.isEmpty) return '';
  if (kZodiacSigns.contains(key)) return zodiacLabel(key);
  return key;
}

/// Sign + month span, e.g. `Poissons · févr.–mars` / `魚座 · 2–3月`.
String displayZodiacWithMonths(String raw) {
  final key = normalizeZodiac(raw);
  if (key.isEmpty) return '';
  final name = kZodiacSigns.contains(key) ? zodiacLabel(key) : key;
  final span = kZodiacMonthSpan[key];
  if (span == null) return name;
  final (a, b) = span;
  return '$name · ${monthAbbrev(a)}–${monthAbbrev(b)}';
}
