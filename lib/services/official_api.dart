import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_unread.dart';

/// Un message du compte officiel Swayco (table `official_posts`).
class OfficialPost {
  const OfficialPost({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    this.mediaUrl = '',
  });

  final String id;
  final String title;
  final String body;
  final DateTime createdAt;

  /// L'EXEMPLE posé sous le message : un GIF, une image ou une courte vidéo
  /// (`media_url`, migration 0087). Vide = pas d'exemple.
  final String mediaUrl;

  static OfficialPost? fromRow(Map<String, dynamic> m) {
    final body = m['body']?.toString() ?? '';
    final at = DateTime.tryParse(m['created_at']?.toString() ?? '');
    if (body.isEmpty || at == null) return null;
    return OfficialPost(
      id: m['id']?.toString() ?? '',
      title: m['title']?.toString() ?? '',
      body: body,
      createdAt: at.toLocal(),
      mediaUrl: m['media_url']?.toString() ?? '',
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
    ChatUnread.setOfficialUnread(0);
  }

  /// Combien de messages n'ont pas encore été vus : ceux de l'équipe plus le
  /// guide d'accueil (compté pour 1) tant que la conversation n'a jamais été
  /// ouverte. Le guide est dans l'app : il arrive dès la première ouverture,
  /// même sans réseau.
  static int unread(List<OfficialPost> posts, DateTime? seen) {
    if (seen == null) return posts.length + 1;
    return posts.where((p) => p.createdAt.isAfter(seen)).length;
  }

  /// Recalcule la pastille de la barre de navigation (Messages) à partir du
  /// compte officiel. À l'ouverture de l'app, puis à chaque rechargement.
  static Future<void> refreshBadge() async {
    final posts = await fetch();
    final seen = await seenAt();
    ChatUnread.setOfficialUnread(unread(posts, seen));
  }
}
