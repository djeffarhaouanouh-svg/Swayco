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

/// Localised label for display; falls back to the raw string for unknowns.
String displayZodiac(String raw) {
  final key = normalizeZodiac(raw);
  if (key.isEmpty) return '';
  if (kZodiacSigns.contains(key)) return zodiacLabel(key);
  return key;
}
