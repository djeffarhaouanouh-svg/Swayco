import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Une ville du globe : son nom, où la poser (longitude, latitude), combien de
/// membres y vivent et la photo d'un membre (compte IA du lieu).
class CityBubble {
  const CityBubble({
    required this.name,
    required this.lon,
    required this.lat,
    required this.count,
    required this.photoUrl,
  });

  final String name;
  final double lon;
  final double lat;
  final int count;
  final String? photoUrl;
}

/// Ce que le globe sait d'un pays : ses membres et la photo d'un d'entre eux.
class CountryStat {
  const CountryStat({required this.count, required this.photoUrl});

  final int count;
  final String? photoUrl;
}

/// Pays, villes et photos pour les bulles du globe zoomé (niveaux 6a / 6b).
/// Les comptes sont lus une fois par session, dans les pays ouverts ; les
/// photos viennent des comptes IA seulement (stable : le plus petit `id`).
abstract final class GlobePlaces {
  static bool _loaded = false;
  static Future<void>? _loading;

  static final Map<String, CountryStat> _countries = {};
  static final Map<String, List<CityBubble>> _cities = {};

  /// `kGlobeCountries` dbName (libellé français) -> clé du globe.
  static Future<void> load(Map<String, String> keyByDbName) {
    if (_loaded) return Future.value();
    return _loading ??= _fetch(keyByDbName);
  }

  static CountryStat? country(String key) => _countries[key];

  static List<CityBubble> cities(String key) => _cities[key] ?? const [];

  static Future<void> _fetch(Map<String, String> keyByDbName) async {
    if (!isSupabaseReady) {
      _loading = null;
      return;
    }
    try {
      final rows = await Supabase.instance.client
          .from('profiles')
          .select('id, country, city, avatar_url, discover_photo_url, photos, is_ai')
          .inFilter('country', keyByDbName.keys.toList())
          .limit(20000);

      final countryCount = <String, int>{};
      final countryPhoto = <String, (String, String)>{}; // key -> (id, url)
      final cityCount = <String, Map<String, int>>{};
      final cityPhoto = <String, Map<String, (String, String)>>{};

      for (final r in rows) {
        final m = Map<String, dynamic>.from(r as Map);
        final key = keyByDbName[(m['country']?.toString() ?? '').trim()];
        if (key == null) continue;
        final city = (m['city']?.toString() ?? '').trim();
        final id = m['id']?.toString() ?? '';
        countryCount[key] = (countryCount[key] ?? 0) + 1;
        if (city.isNotEmpty) {
          final cc = cityCount.putIfAbsent(key, () => {});
          cc[city] = (cc[city] ?? 0) + 1;
        }
        if (m['is_ai'] != true || id.isEmpty) continue;
        var url = (m['avatar_url']?.toString() ?? '').trim();
        if (url.isEmpty) url = (m['discover_photo_url']?.toString() ?? '').trim();
        if (url.isEmpty) {
          final photos = m['photos'];
          if (photos is List && photos.isNotEmpty) url = photos.first.toString().trim();
        }
        if (url.isEmpty) continue;
        final cur = countryPhoto[key];
        if (cur == null || id.compareTo(cur.$1) < 0) countryPhoto[key] = (id, url);
        if (city.isNotEmpty) {
          final cp = cityPhoto.putIfAbsent(key, () => {});
          final c = cp[city];
          if (c == null || id.compareTo(c.$1) < 0) cp[city] = (id, url);
        }
      }

      _countries.clear();
      _cities.clear();
      for (final key in keyByDbName.values) {
        _countries[key] = CountryStat(
          count: countryCount[key] ?? 0,
          photoUrl: countryPhoto[key]?.$2,
        );
        final dbName = keyByDbName.entries.firstWhere((e) => e.value == key).key;
        final coords = _kCityCoords[dbName] ?? const {};
        final out = <CityBubble>[];
        for (final e in (cityCount[key] ?? const <String, int>{}).entries) {
          final at = coords[e.key];
          if (at == null) continue;
          out.add(CityBubble(
            name: e.key,
            lon: at.dx,
            lat: at.dy,
            count: e.value,
            // Pas de compte IA dans cette ville : la photo du pays.
            photoUrl: cityPhoto[key]?[e.key]?.$2 ?? countryPhoto[key]?.$2,
          ));
        }
        out.sort((a, b) => b.count.compareTo(a.count));
        _cities[key] = out;
      }
      _loaded = true;
    } catch (e) {
      debugPrint('GlobePlaces.load failed: $e');
      _loading = null;
    }
  }
}

/// Où poser les villes connues de l'app (libellés de `locations.dart`), par pays
/// ouvert : (longitude, latitude). À compléter avec les nouveaux pays.
const Map<String, Map<String, Offset>> _kCityCoords = {
  'France': {
    'Paris': Offset(2.35, 48.86), 'Marseille': Offset(5.37, 43.30),
    'Lyon': Offset(4.84, 45.76), 'Toulouse': Offset(1.44, 43.60),
    'Nice': Offset(7.26, 43.70), 'Nantes': Offset(-1.55, 47.22),
    'Montpellier': Offset(3.88, 43.61), 'Strasbourg': Offset(7.75, 48.57),
    'Bordeaux': Offset(-0.58, 44.84), 'Lille': Offset(3.06, 50.63),
    'Rennes': Offset(-1.68, 48.11), 'Toulon': Offset(5.93, 43.12),
  },
  'Belgique': {
    'Bruxelles': Offset(4.35, 50.85), 'Anvers': Offset(4.40, 51.22),
    'Gand': Offset(3.72, 51.05), 'Charleroi': Offset(4.44, 50.41),
    'Liège': Offset(5.57, 50.63), 'Bruges': Offset(3.22, 51.21),
    'Namur': Offset(4.87, 50.47),
  },
  'Canada': {
    'Montréal': Offset(-73.57, 45.50), 'Toronto': Offset(-79.38, 43.65),
    'Vancouver': Offset(-123.12, 49.28), 'Québec': Offset(-71.21, 46.81),
    'Ottawa': Offset(-75.70, 45.42), 'Calgary': Offset(-114.07, 51.05),
    'Edmonton': Offset(-113.49, 53.55), 'Winnipeg': Offset(-97.14, 49.90),
  },
  'Japon': {
    'Tokyo': Offset(139.69, 35.69), 'Osaka': Offset(135.50, 34.69),
    'Kyoto': Offset(135.77, 35.01), 'Yokohama': Offset(139.64, 35.44),
    'Nagoya': Offset(136.91, 35.18), 'Sapporo': Offset(141.35, 43.06),
    'Fukuoka': Offset(130.40, 33.59),
  },
  'Corée du Sud': {
    'Séoul': Offset(126.98, 37.57), 'Busan': Offset(129.08, 35.18),
    'Incheon': Offset(126.71, 37.46), 'Daegu': Offset(128.60, 35.87),
    'Daejeon': Offset(127.38, 36.35),
  },
  'Suède': {
    'Stockholm': Offset(18.07, 59.33), 'Göteborg': Offset(11.97, 57.71),
    'Malmö': Offset(13.00, 55.60), 'Uppsala': Offset(17.64, 59.86),
  },
  'Espagne': {
    'Madrid': Offset(-3.70, 40.42), 'Barcelone': Offset(2.17, 41.39),
    'Valence': Offset(-0.38, 39.47), 'Séville': Offset(-5.98, 37.39),
    'Bilbao': Offset(-2.93, 43.26), 'Malaga': Offset(-4.42, 36.72),
    'Saragosse': Offset(-0.88, 41.65), 'Grenade': Offset(-3.60, 37.18),
  },
  'Allemagne': {
    'Berlin': Offset(13.40, 52.52), 'Munich': Offset(11.58, 48.14),
    'Hambourg': Offset(9.99, 53.55), 'Cologne': Offset(6.96, 50.94),
    'Francfort': Offset(8.68, 50.11), 'Stuttgart': Offset(9.18, 48.78),
    'Düsseldorf': Offset(6.77, 51.23), 'Leipzig': Offset(12.37, 51.34),
  },
  'Mexique': {
    'Mexico': Offset(-99.13, 19.43), 'Guadalajara': Offset(-103.35, 20.67),
    'Monterrey': Offset(-100.32, 25.67), 'Puebla': Offset(-98.20, 19.04),
    'Tijuana': Offset(-117.04, 32.51), 'Cancún': Offset(-86.85, 21.16),
  },
  'Argentine': {
    'Buenos Aires': Offset(-58.38, -34.60), 'Córdoba': Offset(-64.18, -31.42),
    'Rosario': Offset(-60.65, -32.95), 'Mendoza': Offset(-68.84, -32.89),
    'La Plata': Offset(-57.95, -34.92),
  },
  'Colombie': {
    'Bogota': Offset(-74.07, 4.71), 'Medellín': Offset(-75.57, 6.24),
    'Cali': Offset(-76.53, 3.45), 'Barranquilla': Offset(-74.78, 10.96),
    'Cartagena': Offset(-75.51, 10.39),
  },
  'Brésil': {
    'São Paulo': Offset(-46.63, -23.55), 'Rio de Janeiro': Offset(-43.17, -22.91),
    'Brasília': Offset(-47.93, -15.78), 'Salvador': Offset(-38.51, -12.97),
    'Fortaleza': Offset(-38.54, -3.73), 'Belo Horizonte': Offset(-43.94, -19.92),
    'Curitiba': Offset(-49.27, -25.43),
  },
  'Maroc': {
    'Casablanca': Offset(-7.59, 33.57), 'Rabat': Offset(-6.84, 34.02),
    'Marrakech': Offset(-8.01, 31.63), 'Fès': Offset(-5.00, 34.03),
    'Tanger': Offset(-5.80, 35.76), 'Agadir': Offset(-9.60, 30.43),
    'Meknès': Offset(-5.55, 33.89),
  },
  'Philippines': {
    'Manille': Offset(120.98, 14.60), 'Quezon City': Offset(121.04, 14.68),
    'Cebu': Offset(123.89, 10.32), 'Davao': Offset(125.46, 7.19),
    'Makati': Offset(121.02, 14.55), 'Pasig': Offset(121.08, 14.58),
    'Taguig': Offset(121.05, 14.52), 'Baguio': Offset(120.59, 16.41),
  },
};
