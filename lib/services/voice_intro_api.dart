import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'profile_api.dart';
import 'push_dispatcher.dart';
import 'supabase_service.dart';
import 'voice_recorder.dart';

/// Durée maximale d'une présentation vocale. Mesurée sur des phrases types : une
/// présentation complète de trois phrases (~180 caractères) dure environ 17 s à
/// voix posée.
const int kVoiceIntroMaxMs = 20000;

/// La présentation vocale du profil (migration 0098) : le fichier vit dans le
/// bucket `voice-intros`, dans mon dossier ; son adresse et sa durée sur ma ligne
/// `profiles`. Le serveur la transcrit ensuite, pour la traduction affichée sous
/// l'audio.
abstract final class VoiceIntroApi {
  static const _bucket = 'voice-intros';

  static SupabaseClient get _c => Supabase.instance.client;

  /// Envoie [rec] et en fait ma présentation. Lève en cas d'échec.
  static Future<void> save(VoiceRecording rec, {required String lang}) async {
    final me = AuthService.currentUserId;
    if (!isSupabaseReady || me.isEmpty) {
      throw StateError('voice intro: not signed in');
    }
    await ProfileApi.ensureMyProfileRow();
    final name = '${DateTime.now().millisecondsSinceEpoch}.${rec.ext}';
    final path = '$me/$name';
    await _c.storage.from(_bucket).uploadBinary(
          path,
          rec.bytes,
          fileOptions: FileOptions(
            contentType: rec.contentType,
            cacheControl: '3600',
          ),
        );
    await _c.from('profiles').update({
      'voice_intro_url': _c.storage.from(_bucket).getPublicUrl(path),
      'voice_intro_duration_ms': rec.durationMs.clamp(1, kVoiceIntroMaxMs),
      'voice_intro_transcript': '',
      'voice_intro_lang': lang,
    }).eq('id', me);
    // L'ancien fichier ne sert plus à personne.
    unawaited(_removeFiles(me, keep: name));
    unawaited(_transcribe());
  }

  /// Retire ma présentation vocale. Lève en cas d'échec.
  static Future<void> delete() async {
    final me = AuthService.currentUserId;
    if (!isSupabaseReady || me.isEmpty) {
      throw StateError('voice intro: not signed in');
    }
    await _c.from('profiles').update({
      'voice_intro_url': '',
      'voice_intro_duration_ms': null,
      'voice_intro_transcript': '',
      'voice_intro_lang': '',
    }).eq('id', me);
    unawaited(_removeFiles(me));
  }

  /// Avant la suppression du compte : les fichiers ne partent pas tout seuls.
  static Future<void> removeAllFiles() async {
    final me = AuthService.currentUserId;
    if (!isSupabaseReady || me.isEmpty) return;
    await _removeFiles(me);
  }

  static Future<void> _removeFiles(String me, {String keep = ''}) async {
    try {
      final files = await _c.storage.from(_bucket).list(path: me);
      final paths = [
        for (final f in files)
          if (f.name != keep) '$me/${f.name}',
      ];
      if (paths.isNotEmpty) await _c.storage.from(_bucket).remove(paths);
    } catch (e) {
      debugPrint('voice intro cleanup failed: $e');
    }
  }

  /// Best-effort : sans réponse, l'audio s'écoute quand même, sans traduction.
  static Future<void> _transcribe() async {
    try {
      final token = _c.auth.currentSession?.accessToken;
      if (token == null) return;
      final res = await http
          .post(
            PushDispatcher.apiUri('/profile/voice-intro/transcribe'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(const <String, String>{}),
          )
          .timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) {
        debugPrint('voice intro transcribe: ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      debugPrint('voice intro transcribe failed: $e');
    }
  }
}
