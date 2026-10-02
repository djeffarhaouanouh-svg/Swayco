import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'app_strings.dart';
import 'locations.dart';
import 'profile_api.dart';

/// Un pays pour lequel l'écran de match sait dire « ton voyage {au} commence ».
/// La préposition (au / en / aux, to / nach…) vit dans la clé [auKey] de
/// chaque langue : elle n'est jamais construite par code.
class MatchCountry {
  const MatchCountry(this.code);

  /// ISO 3166-1 alpha-2, minuscules (`jp`) — aussi le code du drapeau.
  final String code;

  String get auKey => 'country_${code}_au';

  /// « au Japon », « en Corée du Sud »… dans la langue de l'interface.
  String get au => AppStrings.t(auKey);
}

/// Les pays dont la clé `country_xx_au` existe dans les 12 langues.
const Set<String> kMatchCountryCodes = {
  'jp', 'br', 'kr', 'es', 'ma', 'ca', 'fr', 'de', 'be', 'se', 'sn',
};

/// Le pays de [p] (nom stocké dans `profiles.country`, ou code ISO), ou null
/// quand il est vide / inconnu — l'écran garde alors son titre générique.
MatchCountry? matchCountryFor(RemoteProfile p) {
  final raw = p.country.trim();
  if (raw.isEmpty) return null;
  var code = countryIso2For(raw);
  if (code.isEmpty && raw.length == 2) code = raw.toLowerCase();
  return kMatchCountryCodes.contains(code) ? MatchCountry(code) : null;
}

// ── Distance entre deux villes ───────────────────────────────────────────────

/// Coordonnées d'une ville via l'API de géocodage Open-Meteo (gratuite, sans
/// clé), mises en cache pour la session. Null quand la ville est introuvable
/// ou que le réseau échoue : l'appelant masque alors la distance.
abstract final class CityGeo {
  static final Map<String, ({double lat, double lng})?> _cache = {};

  static Future<({double lat, double lng})?> coordsFor({
    required String city,
    required String country,
  }) async {
    final name = city.trim();
    if (name.isEmpty) return null;
    final iso = countryIso2For(country).toUpperCase();
    final key = '$iso|${name.toLowerCase()}';
    if (_cache.containsKey(key)) return _cache[key];
    try {
      final uri = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
        'name': name,
        'count': '10',
        'language': 'fr',
        'format': 'json',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final results =
          (jsonDecode(res.body) as Map<String, dynamic>)['results'];
      if (results is! List || results.isEmpty) {
        _cache[key] = null;
        return null;
      }
      Map<String, dynamic>? pick;
      for (final r in results) {
        final m = r as Map<String, dynamic>;
        if (iso.isEmpty || m['country_code']?.toString().toUpperCase() == iso) {
          pick = m;
          break;
        }
      }
      // Ville connue sous ce nom, mais pas dans CE pays : on ne devine pas.
      if (pick == null) {
        _cache[key] = null;
        return null;
      }
      final lat = (pick['latitude'] as num?)?.toDouble();
      final lng = (pick['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) return null;
      return _cache[key] = (lat: lat, lng: lng);
    } catch (e) {
      debugPrint('CityGeo.coordsFor($name) failed: $e');
      return null; // échec réseau : pas de cache, on pourra réessayer
    }
  }

  /// Distance orthodromique en kilomètres (haversine).
  static double distanceKm(
    ({double lat, double lng}) a,
    ({double lat, double lng}) b,
  ) {
    const r = 6371.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(b.lat - a.lat);
    final dLng = rad(b.lng - a.lng);
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.cos(rad(a.lat)) *
            math.cos(rad(b.lat)) *
            math.pow(math.sin(dLng / 2), 2);
    return 2 * r * math.asin(math.sqrt(h.toDouble()));
  }
}
