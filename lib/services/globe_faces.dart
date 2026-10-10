import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Un visage posé sur le globe : la photo de profil d'un compte IA et son pays
/// (libellé stocké sur `profiles.country`, en français). Purement décoratif :
/// aucun identifiant n'est exposé à l'écran et rien n'est cliquable.
class GlobeFace {
  const GlobeFace({required this.id, required this.country, required this.url});

  /// Sert uniquement de graine pour que la place d'un visage reste la même.
  final String id;
  final String country;
  final String url;
}

/// Les visages du globe : les comptes IA (profiles.is_ai), qui animent les pays
/// ouverts. Chargés une fois par session, silencieux en cas d'erreur.
abstract final class GlobeFaces {
  static List<GlobeFace>? _cache;
  static Future<List<GlobeFace>>? _loading;

  static Future<List<GlobeFace>> load() {
    final cached = _cache;
    if (cached != null) return Future.value(cached);
    return _loading ??= _fetch().then((v) => _cache = v);
  }

  static Future<List<GlobeFace>> _fetch() async {
    if (!isSupabaseReady) return const [];
    try {
      final rows = await Supabase.instance.client
          .from('profiles')
          .select('id, country, avatar_url, discover_photo_url, photos')
          .eq('is_ai', true)
          .limit(600);
      final out = <GlobeFace>[];
      for (final r in rows) {
        final m = Map<String, dynamic>.from(r as Map);
        final id = m['id']?.toString() ?? '';
        final country = (m['country']?.toString() ?? '').trim();
        if (id.isEmpty || country.isEmpty) continue;
        var url = (m['avatar_url']?.toString() ?? '').trim();
        if (url.isEmpty) url = (m['discover_photo_url']?.toString() ?? '').trim();
        if (url.isEmpty) {
          final photos = m['photos'];
          if (photos is List && photos.isNotEmpty) {
            url = photos.first.toString().trim();
          }
        }
        if (url.isEmpty) continue;
        out.add(GlobeFace(id: id, country: country, url: url));
      }
      return out;
    } catch (e) {
      debugPrint('GlobeFaces.load failed: $e');
      return const [];
    }
  }
}
