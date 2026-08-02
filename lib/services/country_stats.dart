import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// How rare a country is among Swayco members. [share] is 0…1.
class CountryShare {
  const CountryShare({required this.n, required this.total});

  final int n;
  final int total;

  /// Fraction of all profiles living in that country. 0 when unknown.
  double get share => total <= 0 ? 0 : n / total;

  /// True when the country is under 1 % of members (the "RARE" card).
  bool get isRare => total > 0 && share > 0 && share < 0.01;

  /// e.g. `0,3 %` (French decimal comma) / `0.3%` for other UIs — caller formats.
  double get percent => share * 100;
}

/// In-memory cache so opening several match cards doesn't re-hit the RPC.
final Map<String, CountryShare> _cache = {};

abstract final class CountryStats {
  static SupabaseClient get _c => Supabase.instance.client;

  /// Share of members whose `profiles.country` equals [country].
  /// Returns null when Supabase isn't ready or the RPC fails.
  static Future<CountryShare?> shareFor(String country) async {
    final key = country.trim();
    if (key.isEmpty) return null;
    final hit = _cache[key];
    if (hit != null) return hit;
    if (!isSupabaseReady) return null;
    try {
      final res = await _c.rpc('country_member_share', params: {
        'p_country': key,
      });
      // rpc may return a list of rows or a single map depending on the client.
      Map<String, dynamic>? row;
      if (res is List && res.isNotEmpty) {
        row = Map<String, dynamic>.from(res.first as Map);
      } else if (res is Map) {
        row = Map<String, dynamic>.from(res);
      }
      if (row == null) return null;
      final share = CountryShare(
        n: (row['n'] as num?)?.toInt() ?? 0,
        total: (row['total'] as num?)?.toInt() ?? 0,
      );
      _cache[key] = share;
      return share;
    } catch (e) {
      debugPrint('CountryStats.shareFor failed: $e');
      return null;
    }
  }
}
