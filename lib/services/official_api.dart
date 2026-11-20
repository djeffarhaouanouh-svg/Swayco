import 'dart:async';

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
    this.mine = false,
  });

  /// Un message que J'ai écrit à l'équipe (et non un message de l'équipe).
  final bool mine;

  final String id;
  final String title;
  final String body;
  final DateTime createdAt;

  /// L'EXEMPLE posé sous le message : un GIF, une image ou une courte vidéo
  /// (`media_url`, migration 0087). Vide = pas d'exemple.
  final String mediaUrl;

  static OfficialPost? fromRow(Map<String, dynamic> m, {bool mine = false}) {
    final body = m['body']?.toString() ?? '';
    final at = DateTime.tryParse(m['created_at']?.toString() ?? '');
    if (body.isEmpty || at == null) return null;
    return OfficialPost(
      id: m['id']?.toString() ?? '',
      title: m['title']?.toString() ?? '',
      body: body,
      createdAt: at.toLocal(),
      mediaUrl: m['media_url']?.toString() ?? '',
      mine: mine,
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

  /// Mes messages à l'équipe (table `official_messages`, migration 0088), du
  /// plus ancien au plus récent. Vide si la table n'est pas encore migrée.
  static Future<List<OfficialPost>> fetchMine(String meId) async {
    if (meId.isEmpty) return const [];
    try {
      final rows = await _client
          .from('official_messages')
          .select()
          .eq('user_id', meId)
          .order('created_at', ascending: false)
          .limit(100);
      final out = <OfficialPost>[
        for (final r in rows as List)
          ?OfficialPost.fromRow(Map<String, dynamic>.from(r as Map),
              mine: true),
      ];
      out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return out;
    } catch (e) {
      debugPrint('OfficialApi.fetchMine failed: $e');
      return const [];
    }
  }

  /// Envoie un message à l'équipe : il est enregistré en base, l'équipe le lit
  /// depuis le back-office. Lève en cas d'échec (le champ garde alors le texte).
  static Future<void> send({
    required String meId,
    required String name,
    required String body,
  }) async {
    await _client.from('official_messages').insert({
      'user_id': meId,
      'user_name': name,
      'body': body,
    });
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
      final now = DateTime.now().toUtc().toIso8601String();
      await p.setString(_seenKey, now);
      // La toute première ouverture date la ligne dans la liste : elle ne
      // remonte plus ensuite à chaque ouverture, elle descend au fil des
      // nouvelles conversations.
      if (p.getString(_firstKey) == null) await p.setString(_firstKey, now);
    } catch (_) {}
    ChatUnread.setOfficialUnread(0);
  }

  static const _firstKey = 'official_first_seen_iso';

  /// Quand la ligne « Swayco » se range dans la liste : la date de son dernier
  /// message ; à défaut (que le guide) la première ouverture ; et tant qu'elle
  /// n'a jamais été ouverte, maintenant (en tête, comme une conversation qui
  /// vient d'arriver).
  static Future<DateTime> rowTime(List<OfficialPost> posts) async {
    if (posts.isNotEmpty) return posts.last.createdAt;
    try {
      final p = await SharedPreferences.getInstance();
      final first = DateTime.tryParse(p.getString(_firstKey) ?? '');
      if (first != null) return first.toLocal();
    } catch (_) {}
    return DateTime.now();
  }

  /// Combien de messages n'ont pas encore été vus : ceux de l'équipe plus le
  /// guide d'accueil (compté pour 1) tant que la conversation n'a jamais été
  /// ouverte. Le guide est dans l'app : il arrive dès la première ouverture,
  /// même sans réseau.
  static int unread(List<OfficialPost> posts, DateTime? seen) {
    if (seen == null) return posts.length + 1;
    return posts.where((p) => p.createdAt.isAfter(seen)).length;
  }

  static StreamSubscription<List<Map<String, dynamic>>>? _watch;
  static int _knownPosts = -1;

  /// Écoute les annonces de l'équipe EN DIRECT : un nouveau message met la
  /// pastille à jour et recharge la liste Messages tout de suite, sans attendre
  /// le prochain lancement. (La notification, elle, vient du serveur.)
  static void watch() {
    if (_watch != null) return;
    try {
      _watch = _client
          .from('official_posts')
          .stream(primaryKey: ['id'])
          .listen(
        (rows) {
          final first = _knownPosts < 0;
          final grew = rows.length != _knownPosts;
          _knownPosts = rows.length;
          unawaited(refreshBadge());
          if (!first && grew) ChatUnread.newInbound.value++;
        },
        onError: (Object e) => debugPrint('OfficialApi.watch error: $e'),
      );
    } catch (e) {
      debugPrint('OfficialApi.watch failed: $e');
    }
  }

  /// Recalcule la pastille de la barre de navigation (Messages) à partir du
  /// compte officiel. À l'ouverture de l'app, puis à chaque rechargement.
  static Future<void> refreshBadge() async {
    final posts = await fetch();
    final seen = await seenAt();
    ChatUnread.setOfficialUnread(unread(posts, seen));
  }
}
