import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Un message du compte officiel Swayco (table `official_posts`).
class OfficialPost {
  const OfficialPost({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
  });

  final String id;
  final String title;
  final String body;
  final DateTime createdAt;

  static OfficialPost? fromRow(Map<String, dynamic> m) {
    final body = m['body']?.toString() ?? '';
    final at = DateTime.tryParse(m['created_at']?.toString() ?? '');
    if (body.isEmpty || at == null) return null;
    return OfficialPost(
      id: m['id']?.toString() ?? '',
      title: m['title']?.toString() ?? '',
      body: body,
      createdAt: at.toLocal(),
    );
  }
}

/// Le compte officiel « Swayco » : une conversation épinglée, en LECTURE SEULE.
/// L'équipe y écrit depuis le back-office (admin/scripts/post_official.mjs) ;
/// l'app ne fait que lire. Le « non lu » est un simple point de lecture local.
abstract final class OfficialApi {
  static const _seenKey = 'official_seen_iso';

  static SupabaseClient get _client => Supabase.instance.client;

  /// Les messages, du plus ancien au plus récent.
  static Future<List<OfficialPost>> fetch({int limit = 100}) async {
    try {
      final rows = await _client
          .from('official_posts')
          .select()
          .order('created_at', ascending: false)
          .limit(limit);
      final out = <OfficialPost>[
        for (final r in rows as List)
          ?OfficialPost.fromRow(Map<String, dynamic>.from(r as Map)),
      ];
      out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return out;
    } catch (e) {
      // Table pas encore migrée, ou réseau : la ligne n'apparaît simplement pas.
      debugPrint('OfficialApi.fetch failed: $e');
      return const [];
    }
  }

  static Future<DateTime?> seenAt() async {
    try {
      final p = await SharedPreferences.getInstance();
      return DateTime.tryParse(p.getString(_seenKey) ?? '')?.toLocal();
    } catch (_) {
      return null;
    }
  }

  /// Ouvrir la conversation = tout avoir vu.
  static Future<void> markSeen() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_seenKey, DateTime.now().toUtc().toIso8601String());
    } catch (_) {}
  }

  /// Combien de messages de l'équipe n'ont pas encore été vus.
  static int unread(List<OfficialPost> posts, DateTime? seen) {
    if (seen == null) return posts.length;
    return posts.where((p) => p.createdAt.isAfter(seen)).length;
  }
}
