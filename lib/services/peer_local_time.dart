/// Best-effort "what time is it where my peer lives" resolver.
///
/// The profile only stores a *free-text* city + country (see [RemoteProfile]),
/// so there is no real timezone attached to a user. We map the most common
/// world cities (and a country fallback) to a UTC offset and apply the local
/// daylight-saving rule (EU / US / southern hemisphere) so the displayed clock
/// stays correct year-round. Anything we don't recognise returns `null` and the
/// caller simply hides the clock bubble.
///
/// This is intentionally dependency-free (no `timezone`/`intl` package) — the
/// table covers the cities our users actually type; DST boundaries are computed
/// to the day, which is plenty for a casual "it's night over there" hint.
library;

/// Resolved local time at the peer's place. [isDay] drives the ☀️ / 🌙 emoji.
class PeerLocalTime {
  const PeerLocalTime({required this.local, required this.isDay});

  /// Wall-clock time at the peer's location (kind is irrelevant — only the
  /// hour/minute fields are read).
  final DateTime local;

  /// True between 07:00 and 19:59 local — sun; otherwise moon.
  final bool isDay;

  String get hhmm =>
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';

  String get emoji => isDay ? '☀️' : '🌙';
}

/// Resolve the peer's local time from their free-text [city] (preferred) with a
/// [country] fallback. Returns `null` when neither is recognised.
PeerLocalTime? resolvePeerLocalTime({
  required String city,
  String country = '',
  DateTime? nowUtc,
}) {
  final tz = _lookupCity(city) ?? _lookupCountry(country);
  if (tz == null) return null;
  final utc = (nowUtc ?? DateTime.now()).toUtc();
  final local = utc.add(Duration(minutes: _currentOffsetMinutes(tz, utc)));
  final isDay = local.hour >= 7 && local.hour < 20;
  return PeerLocalTime(local: local, isDay: isDay);
}

// ───────────────────────── internals ─────────────────────────

enum _DstRule { none, eu, us, southern }

class _Tz {
  const _Tz(this.baseMinutes, [this.rule = _DstRule.none]);

  /// Standard-time offset from UTC, in minutes (e.g. Paris = +60, NYC = -300).
  final int baseMinutes;
  final _DstRule rule;
}

int _currentOffsetMinutes(_Tz tz, DateTime utc) {
  switch (tz.rule) {
    case _DstRule.none:
      return tz.baseMinutes;
    case _DstRule.eu:
      return tz.baseMinutes + (_euDstActive(utc) ? 60 : 0);
    case _DstRule.us:
      return tz.baseMinutes + (_usDstActive(utc, tz.baseMinutes) ? 60 : 0);
    case _DstRule.southern:
      return tz.baseMinutes + (_southernDstActive(utc) ? 60 : 0);
  }
}

/// Last Sunday of [month] in [year] at 00:00 UTC.
DateTime _lastSundayUtc(int year, int month) {
  final nextMonthFirst = month == 12
      ? DateTime.utc(year + 1, 1, 1)
      : DateTime.utc(year, month + 1, 1);
  final lastDay = nextMonthFirst.subtract(const Duration(days: 1));
  final daysSinceSunday = lastDay.weekday % 7; // Sun(7)->0, Mon(1)->1, …
  return lastDay.subtract(Duration(days: daysSinceSunday));
}

/// [n]-th Sunday of [month] in [year] at 00:00 UTC (n starts at 1).
DateTime _nthSundayUtc(int year, int month, int n) {
  final first = DateTime.utc(year, month, 1);
  final daysToSunday = (7 - first.weekday) % 7; // Sun(7)->0
  return first.add(Duration(days: daysToSunday + 7 * (n - 1)));
}

/// EU rule: 01:00 UTC last Sunday of March → 01:00 UTC last Sunday of October.
bool _euDstActive(DateTime utc) {
  final start = _lastSundayUtc(utc.year, 3).add(const Duration(hours: 1));
  final end = _lastSundayUtc(utc.year, 10).add(const Duration(hours: 1));
  return !utc.isBefore(start) && utc.isBefore(end);
}

/// US/Canada rule: 02:00 local 2nd Sunday of March → 02:00 local 1st Sunday of
/// November. Transition instants are derived from the standard offset.
bool _usDstActive(DateTime utc, int baseMinutes) {
  final offset = Duration(minutes: 120 - baseMinutes); // 02:00 local in UTC
  final start = _nthSundayUtc(utc.year, 3, 2).add(offset);
  final end = _nthSundayUtc(utc.year, 11, 1).add(offset);
  return !utc.isBefore(start) && utc.isBefore(end);
}

/// Southern-hemisphere rule (AU east / NZ / Chile) — DST roughly October →
/// March. Boundaries approximated to the first Sunday of Apr/Oct; good enough
/// for a casual clock.
bool _southernDstActive(DateTime utc) {
  final m = utc.month;
  if (m >= 11 || m <= 2) return true; // peak summer down south
  if (m >= 5 && m <= 8) return false; // peak winter
  if (m == 3) return true;
  if (m == 4) return utc.isBefore(_nthSundayUtc(utc.year, 4, 1));
  if (m == 9) return false;
  return !utc.isBefore(_nthSundayUtc(utc.year, 10, 1)); // October
}

/// Lowercase, strip diacritics, collapse to single spaces.
String _norm(String s) {
  const accents = {
    'à': 'a',
    'á': 'a',
    'â': 'a',
    'ä': 'a',
    'ã': 'a',
    'å': 'a',
    'è': 'e',
    'é': 'e',
    'ê': 'e',
    'ë': 'e',
    'ì': 'i',
    'í': 'i',
    'î': 'i',
    'ï': 'i',
    'ò': 'o',
    'ó': 'o',
    'ô': 'o',
    'ö': 'o',
    'õ': 'o',
    'ù': 'u',
    'ú': 'u',
    'û': 'u',
    'ü': 'u',
    'ç': 'c',
    'ñ': 'n',
    'ß': 'ss',
    'ø': 'o',
    'æ': 'ae',
  };
  final sb = StringBuffer();
  for (final ch in s.trim().toLowerCase().split('')) {
    sb.write(accents[ch] ?? ch);
  }
  return sb.toString().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

_Tz? _lookupCity(String raw) {
  final n = _norm(raw);
  if (n.isEmpty) return null;
  final direct = _cities[n];
  if (direct != null) return direct;
  // Multi-word names first ("new york", "hong kong") so "new york city" still
  // matches before we fall through to single tokens.
  for (final entry in _cities.entries) {
    if (entry.key.contains(' ') && n.contains(entry.key)) return entry.value;
  }
  // Inputs like "Paris, France" or "Lyon 7e" → try each word.
  for (final w in n.split(' ')) {
    final hit = _cities[w];
    if (hit != null) return hit;
  }
  return null;
}

_Tz? _lookupCountry(String raw) {
  final n = _norm(raw);
  if (n.isEmpty) return null;
  final direct = _countries[n];
  if (direct != null) return direct;
  for (final w in n.split(' ')) {
    final hit = _countries[w];
    if (hit != null) return hit;
  }
  return null;
}

// Shared offsets, named for readability.
const _eu = _Tz(60, _DstRule.eu); // CET (Paris/Berlin/Madrid/Rome…)
const _ee = _Tz(120, _DstRule.eu); // EET (Athens/Helsinki/Kyiv…)
const _uk = _Tz(0, _DstRule.eu); // London/Lisbon/Dublin
const _etUs = _Tz(-300, _DstRule.us); // US/CA Eastern
const _ctUs = _Tz(-360, _DstRule.us); // US/CA Central
const _mtUs = _Tz(-420, _DstRule.us); // US/CA Mountain
const _ptUs = _Tz(-480, _DstRule.us); // US/CA Pacific

const _cities = <String, _Tz>{
  // ── France ──
  'paris': _eu, 'lyon': _eu, 'marseille': _eu, 'toulouse': _eu, 'nice': _eu,
  'nantes': _eu, 'montpellier': _eu, 'strasbourg': _eu, 'bordeaux': _eu,
  'lille': _eu, 'rennes': _eu, 'reims': _eu, 'toulon': _eu, 'grenoble': _eu,
  'dijon': _eu, 'angers': _eu, 'nimes': _eu, 'clermont ferrand': _eu,
  'le havre': _eu, 'aix en provence': _eu, 'brest': _eu, 'cannes': _eu,
  // ── Western / Central Europe (CET) ──
  'madrid': _eu, 'barcelona': _eu, 'barcelone': _eu, 'valencia': _eu,
  'sevilla': _eu, 'seville': _eu, 'malaga': _eu, 'bilbao': _eu,
  'berlin': _eu, 'munich': _eu, 'munchen': _eu, 'hamburg': _eu,
  'frankfurt': _eu, 'cologne': _eu, 'koln': _eu, 'stuttgart': _eu,
  'dusseldorf': _eu, 'rome': _eu, 'roma': _eu, 'milan': _eu, 'milano': _eu,
  'naples': _eu, 'napoli': _eu, 'turin': _eu, 'torino': _eu, 'florence': _eu,
  'firenze': _eu, 'venice': _eu, 'venezia': _eu, 'amsterdam': _eu,
  'rotterdam': _eu, 'brussels': _eu, 'bruxelles': _eu, 'antwerp': _eu,
  'vienna': _eu, 'wien': _eu, 'vienne': _eu, 'zurich': _eu, 'geneva': _eu,
  'geneve': _eu, 'bern': _eu, 'basel': _eu, 'lausanne': _eu,
  'warsaw': _eu, 'varsovie': _eu, 'krakow': _eu, 'prague': _eu, 'praha': _eu,
  'budapest': _eu, 'stockholm': _eu, 'oslo': _eu, 'copenhagen': _eu,
  'copenhague': _eu, 'luxembourg': _eu, 'monaco': _eu, 'belgrade': _eu,
  // ── UK / Ireland / Portugal (WET) ──
  'london': _uk, 'londres': _uk, 'manchester': _uk, 'birmingham': _uk,
  'liverpool': _uk, 'glasgow': _uk, 'edinburgh': _uk, 'leeds': _uk,
  'bristol': _uk, 'dublin': _uk, 'cork': _uk, 'lisbon': _uk, 'lisbonne': _uk,
  'lisboa': _uk, 'porto': _uk,
  // ── Eastern Europe / Greece / Turkey (EET) ──
  'athens': _ee, 'athenes': _ee, 'thessaloniki': _ee, 'helsinki': _ee,
  'kyiv': _ee, 'kiev': _ee, 'bucharest': _ee, 'sofia': _ee, 'riga': _ee,
  'tallinn': _ee, 'vilnius': _ee,
  'istanbul': _Tz(180), 'ankara': _Tz(180), // Turkey: no DST, UTC+3
  'moscow': _Tz(180), 'moscou': _Tz(180), 'saint petersburg': _Tz(180),
  // ── North America ──
  'new york': _etUs, 'newyork': _etUs, 'nyc': _etUs, 'brooklyn': _etUs,
  'washington': _etUs, 'boston': _etUs, 'miami': _etUs, 'atlanta': _etUs,
  'philadelphia': _etUs, 'detroit': _etUs, 'toronto': _etUs, 'ottawa': _etUs,
  'montreal': _etUs, 'quebec': _etUs,
  'chicago': _ctUs, 'houston': _ctUs, 'dallas': _ctUs, 'austin': _ctUs,
  'san antonio': _ctUs, 'new orleans': _ctUs, 'winnipeg': _ctUs,
  'denver': _mtUs, 'phoenix': _Tz(-420), // Arizona: no DST
  'salt lake city': _mtUs, 'calgary': _mtUs, 'edmonton': _mtUs,
  'los angeles': _ptUs, 'san francisco': _ptUs, 'san diego': _ptUs,
  'seattle': _ptUs, 'portland': _ptUs, 'las vegas': _ptUs, 'sacramento': _ptUs,
  'vancouver': _ptUs,
  // Mexico abolished DST in 2022 → fixed offsets.
  'mexico': _Tz(-360), 'mexico city': _Tz(-360), 'guadalajara': _Tz(-360),
  'monterrey': _Tz(-360), 'cancun': _Tz(-300),
  // ── Central / South America ──
  'bogota': _Tz(-300), 'lima': _Tz(-300), 'quito': _Tz(-300),
  'panama': _Tz(-300), 'caracas': _Tz(-240), 'la paz': _Tz(-240),
  'santiago': _Tz(-240, _DstRule.southern), // Chile (DST)
  'buenos aires': _Tz(-180), 'montevideo': _Tz(-180), 'asuncion': _Tz(-180),
  'sao paulo': _Tz(-180), 'rio de janeiro': _Tz(-180), 'rio': _Tz(-180),
  'brasilia': _Tz(-180), 'salvador': _Tz(-180), 'belo horizonte': _Tz(-180),
  // ── Middle East / Africa ──
  'tel aviv': _Tz(120, _DstRule.eu), 'jerusalem': _Tz(120, _DstRule.eu),
  'cairo': _Tz(120), 'le caire': _Tz(120), 'alexandria': _Tz(120),
  'casablanca': _Tz(60), 'rabat': _Tz(60), 'tunis': _Tz(60),
  'algiers': _Tz(60), 'alger': _Tz(60),
  'dubai': _Tz(240), 'dubai uae': _Tz(240), 'abu dhabi': _Tz(240),
  'doha': _Tz(180), 'riyadh': _Tz(180), 'riyad': _Tz(180), 'jeddah': _Tz(180),
  'kuwait': _Tz(180), 'baghdad': _Tz(180), 'beirut': _Tz(120, _DstRule.eu),
  'amman': _Tz(180), 'tehran': _Tz(210),
  'lagos': _Tz(60), 'abuja': _Tz(60), 'nairobi': _Tz(180),
  'addis ababa': _Tz(180), 'dakar': _Tz(0), 'abidjan': _Tz(0),
  'johannesburg': _Tz(120), 'cape town': _Tz(120), 'pretoria': _Tz(120),
  // ── Asia ──
  'tokyo': _Tz(540), 'osaka': _Tz(540), 'kyoto': _Tz(540), 'nagoya': _Tz(540),
  'yokohama': _Tz(540), 'sapporo': _Tz(540),
  'seoul': _Tz(540), 'seoul kr': _Tz(540), 'busan': _Tz(540),
  'beijing': _Tz(480), 'pekin': _Tz(480), 'shanghai': _Tz(480),
  'shenzhen': _Tz(480), 'guangzhou': _Tz(480), 'chengdu': _Tz(480),
  'hong kong': _Tz(480), 'hongkong': _Tz(480), 'macau': _Tz(480),
  'taipei': _Tz(480), 'singapore': _Tz(480), 'singapour': _Tz(480),
  'kuala lumpur': _Tz(480), 'manila': _Tz(480), 'perth': _Tz(480),
  'bangkok': _Tz(420), 'jakarta': _Tz(420), 'hanoi': _Tz(420),
  'ho chi minh': _Tz(420), 'saigon': _Tz(420), 'phnom penh': _Tz(420),
  'yangon': _Tz(390),
  'mumbai': _Tz(330), 'bombay': _Tz(330), 'delhi': _Tz(330),
  'new delhi': _Tz(330), 'bangalore': _Tz(330), 'bengaluru': _Tz(330),
  'kolkata': _Tz(330), 'chennai': _Tz(330), 'hyderabad': _Tz(330),
  'colombo': _Tz(330), 'kathmandu': _Tz(345),
  'karachi': _Tz(300), 'lahore': _Tz(300), 'islamabad': _Tz(300),
  'dhaka': _Tz(360), 'almaty': _Tz(300), 'tashkent': _Tz(300),
  // ── Oceania ──
  'sydney': _Tz(600, _DstRule.southern),
  'melbourne': _Tz(600, _DstRule.southern),
  'canberra': _Tz(600, _DstRule.southern), 'brisbane': _Tz(600), // QLD: no DST
  'adelaide': _Tz(570, _DstRule.southern), 'darwin': _Tz(570),
  'auckland': _Tz(720, _DstRule.southern),
  'wellington': _Tz(720, _DstRule.southern),
};

/// Country fallback when the city is unrecognised — uses the capital / most
/// populous timezone. English + French + common native names.
const _countries = <String, _Tz>{
  'france': _eu,
  'spain': _eu,
  'espagne': _eu,
  'espana': _eu,
  'germany': _eu,
  'allemagne': _eu,
  'deutschland': _eu,
  'italy': _eu,
  'italie': _eu,
  'italia': _eu,
  'netherlands': _eu,
  'pays bas': _eu,
  'belgium': _eu,
  'belgique': _eu,
  'switzerland': _eu,
  'suisse': _eu,
  'austria': _eu,
  'autriche': _eu,
  'poland': _eu,
  'pologne': _eu,
  'sweden': _eu,
  'suede': _eu,
  'norway': _eu,
  'norvege': _eu,
  'denmark': _eu,
  'danemark': _eu,
  'united kingdom': _uk,
  'uk': _uk,
  'england': _uk,
  'angleterre': _uk,
  'royaume uni': _uk,
  'ireland': _uk,
  'irlande': _uk,
  'portugal': _uk,
  'greece': _ee,
  'grece': _ee,
  'finland': _ee,
  'ukraine': _ee,
  'romania': _ee,
  'roumanie': _ee,
  'turkey': _Tz(180),
  'turquie': _Tz(180),
  'russia': _Tz(180),
  'russie': _Tz(180),
  'united states': _etUs,
  'usa': _etUs,
  'us': _etUs,
  'etats unis': _etUs,
  'america': _etUs,
  'canada': _etUs,
  'mexico': _Tz(-360),
  'mexique': _Tz(-360),
  'brazil': _Tz(-180),
  'bresil': _Tz(-180),
  'brasil': _Tz(-180),
  'argentina': _Tz(-180),
  'argentine': _Tz(-180),
  'chile': _Tz(-240, _DstRule.southern),
  'chili': _Tz(-240, _DstRule.southern),
  'colombia': _Tz(-300),
  'colombie': _Tz(-300),
  'peru': _Tz(-300),
  'perou': _Tz(-300),
  'israel': _Tz(120, _DstRule.eu),
  'egypt': _Tz(120),
  'egypte': _Tz(120),
  'morocco': _Tz(60),
  'maroc': _Tz(60),
  'tunisia': _Tz(60),
  'tunisie': _Tz(60),
  'algeria': _Tz(60),
  'algerie': _Tz(60),
  'uae': _Tz(240),
  'emirates': _Tz(240),
  'emirats': _Tz(240),
  'saudi arabia': _Tz(180),
  'arabie saoudite': _Tz(180),
  'qatar': _Tz(180),
  'lebanon': _Tz(120, _DstRule.eu),
  'liban': _Tz(120, _DstRule.eu),
  'iran': _Tz(210),
  'nigeria': _Tz(60),
  'kenya': _Tz(180),
  'south africa': _Tz(120),
  'afrique du sud': _Tz(120),
  'senegal': _Tz(0),
  'japan': _Tz(540),
  'japon': _Tz(540),
  'korea': _Tz(540),
  'south korea': _Tz(540),
  'coree': _Tz(540),
  'coree du sud': _Tz(540),
  'china': _Tz(480),
  'chine': _Tz(480),
  'taiwan': _Tz(480),
  'singapore': _Tz(480),
  'singapour': _Tz(480),
  'malaysia': _Tz(480),
  'malaisie': _Tz(480),
  'philippines': _Tz(480),
  'hong kong': _Tz(480),
  'thailand': _Tz(420),
  'thailande': _Tz(420),
  'vietnam': _Tz(420),
  'indonesia': _Tz(420),
  'indonesie': _Tz(420),
  'india': _Tz(330),
  'inde': _Tz(330),
  'pakistan': _Tz(300),
  'bangladesh': _Tz(360),
  'sri lanka': _Tz(330),
  'nepal': _Tz(345),
  'australia': _Tz(600, _DstRule.southern),
  'australie': _Tz(600, _DstRule.southern),
  'new zealand': _Tz(720, _DstRule.southern),
  'nouvelle zelande': _Tz(720, _DstRule.southern),
};
