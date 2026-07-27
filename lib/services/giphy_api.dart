import 'dart:convert';

import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:http/http.dart' as http;

import 'app_strings.dart';

/// Un GIF Giphy, réduit à ce dont le chat a besoin.
class GiphyGif {
  const GiphyGif({
    required this.previewUrl,
    required this.sendUrl,
    required this.aspect,
    required this.title,
  });

  /// Version légère et animée, pour la grille du sélecteur.
  final String previewUrl;

  /// Ce qui part dans le message. Le bundle `messaging_non_clips` ne renvoie
  /// pas de `downsized` : on tombe donc sur `fixed_width` (200 px de large,
  /// ~100 Ko), la vignette que Giphy destine justement à la messagerie.
  /// L'original, lui, peut peser plusieurs Mo — il n'est qu'un dernier repli.
  final String sendUrl;

  /// largeur / hauteur, pour poser la tuile sans attendre le chargement.
  final double aspect;

  final String title;
}

/// Recherche de GIF (API REST Giphy v1). Pas de SDK : deux endpoints, du JSON.
abstract final class GiphyApi {
  /// Une clé par plateforme, comme Giphy les délivre. Elles finissent de toute
  /// façon dans le binaire client — un `--dart-define` du même nom les
  /// remplace au build si tu en changes.
  static const _iosKey = String.fromEnvironment(
    'GIPHY_KEY_IOS',
    defaultValue: 'EjcdOxBhT9rs6r2PZbgBGy9PjiWfAC1G',
  );
  static const _androidKey = String.fromEnvironment(
    'GIPHY_KEY_ANDROID',
    defaultValue: 'DkWspwyAL3uUxBF7C3eQFuk1jfWrXFpT',
  );

  /// Le web n'a pas encore sa clé : il emprunte celle d'Android (l'API REST ne
  /// vérifie pas la plateforme). Passer `--dart-define=GIPHY_KEY_WEB=...` le
  /// jour où une clé web existe, pour que les quotas ne soient pas mélangés.
  static const _webKey = String.fromEnvironment(
    'GIPHY_KEY_WEB',
    defaultValue: _androidKey,
  );

  static String get _key {
    if (kIsWeb) return _webKey;
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS => _iosKey,
      _ => _androidKey,
    };
  }

  /// Vrai quand une clé est présente — le bouton GIF se cache sinon.
  static bool get isConfigured => _key.isNotEmpty;

  /// Les GIF du moment, ce que le sélecteur montre tant qu'on n'a rien tapé.
  static Future<List<GiphyGif>> trending({int limit = 30, int offset = 0}) =>
      _fetch('trending', {'limit': '$limit', 'offset': '$offset'});

  /// Recherche par mots-clés, dans la langue de l'interface.
  static Future<List<GiphyGif>> search(
    String query, {
    int limit = 30,
    int offset = 0,
  }) {
    final q = query.trim();
    if (q.isEmpty) return trending(limit: limit, offset: offset);
    return _fetch('search', {
      'q': q,
      'limit': '$limit',
      'offset': '$offset',
      'lang': AppStrings.currentBcp47.value,
    });
  }

  static Future<List<GiphyGif>> _fetch(
    String path,
    Map<String, String> params,
  ) async {
    if (!isConfigured) return const [];
    final uri = Uri.https('api.giphy.com', '/v1/gifs/$path', {
      'api_key': _key,
      // Une app de rencontre : on reste sous le seuil "adulte".
      'rating': 'pg-13',
      'bundle': 'messaging_non_clips',
      ...params,
    });
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        debugPrint('GiphyApi $path failed: ${res.statusCode}');
        return const [];
      }
      final body = jsonDecode(res.body);
      if (body is! Map || body['data'] is! List) return const [];
      final out = <GiphyGif>[];
      for (final raw in body['data'] as List) {
        final gif = _parse(raw);
        if (gif != null) out.add(gif);
      }
      return out;
    } catch (e) {
      debugPrint('GiphyApi $path failed: $e');
      return const [];
    }
  }

  static GiphyGif? _parse(dynamic raw) {
    if (raw is! Map) return null;
    final images = raw['images'];
    if (images is! Map) return null;

    String urlOf(String name) {
      final entry = images[name];
      if (entry is! Map) return '';
      final url = entry['url']?.toString() ?? '';
      // Giphy renvoie parfois une entrée sans `url` (format non généré).
      return url.startsWith('http') ? url : '';
    }

    final preview = urlOf('fixed_width');
    final send = [
      urlOf('downsized'),
      urlOf('fixed_width'),
      urlOf('original'),
    ].firstWhere((u) => u.isNotEmpty, orElse: () => '');
    if (preview.isEmpty || send.isEmpty) return null;

    // Le ratio vient de la vignette : c'est elle qu'on pose dans la grille.
    final fw = images['fixed_width'];
    var aspect = 1.0;
    if (fw is Map) {
      final w = double.tryParse('${fw['width']}') ?? 0;
      final h = double.tryParse('${fw['height']}') ?? 0;
      if (w > 0 && h > 0) aspect = (w / h).clamp(0.4, 2.5);
    }
    return GiphyGif(
      previewUrl: preview,
      sendUrl: send,
      aspect: aspect,
      title: raw['title']?.toString() ?? '',
    );
  }
}
