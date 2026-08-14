import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Où en est le PAIR dans sa lecture — la moitié partagée de l'état de
/// lecture, celle que [ChatUnread] ne peut pas porter parce qu'elle vit dans
/// les préférences locales de chaque téléphone.
///
/// Table `conversation_reads` (migration 0054). Tant qu'elle n'est pas
/// appliquée, tout ici échoue en silence et l'app se comporte comme avant :
/// pas de « Lu », rien de cassé.
abstract final class ChatReads {
  static SupabaseClient get _c => Supabase.instance.client;

  /// Je viens de lire ce fil jusqu'à maintenant.
  ///
  /// Un upsert sur (conversation, moi) : une seule ligne par personne et par
  /// fil, réécrite à chaque passage. Silencieux — un accusé de lecture qui ne
  /// part pas ne doit jamais empêcher de lire ses messages.
  static Future<void> markRead({
    required String conversationId,
    required String meId,
  }) async {
    if (!isSupabaseReady || conversationId.isEmpty || meId.isEmpty) return;
    try {
      await _c.from('conversation_reads').upsert({
        'conversation_id': conversationId,
        'user_id': meId,
        'last_read_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'conversation_id,user_id');
    } catch (e) {
      debugPrint('ChatReads.markRead failed: $e');
    }
  }

  /// Jusqu'où le pair a lu, maintenant. Null s'il n'a jamais ouvert le fil —
  /// ou si la table n'existe pas encore.
  static Future<DateTime?> fetchPeerLastRead({
    required String conversationId,
    required String peerId,
  }) async {
    if (!isSupabaseReady || conversationId.isEmpty || peerId.isEmpty) {
      return null;
    }
    try {
      final row = await _c
          .from('conversation_reads')
          .select('last_read_at')
          .eq('conversation_id', conversationId)
          .eq('user_id', peerId)
          .maybeSingle();
      final v = row?['last_read_at'];
      if (v == null) return null;
      return DateTime.tryParse(v.toString())?.toLocal();
    } catch (e) {
      debugPrint('ChatReads.fetchPeerLastRead failed: $e');
      return null;
    }
  }

  /// Le même, mais en direct : le « Lu » doit apparaître au moment où l'autre
  /// ouvre le fil, pas au prochain rechargement.
  ///
  /// Le filtre porte sur la conversation et pas sur la personne — un flux
  /// Supabase n'accepte qu'une égalité — donc les lignes des DEUX participants
  /// arrivent ici, et on garde celle du pair.
  static Stream<DateTime?> watchPeerLastRead({
    required String conversationId,
    required String peerId,
  }) {
    if (!isSupabaseReady || conversationId.isEmpty || peerId.isEmpty) {
      return const Stream<DateTime?>.empty();
    }
    return _c
        .from('conversation_reads')
        .stream(primaryKey: ['conversation_id', 'user_id'])
        .eq('conversation_id', conversationId)
        .map((rows) {
          for (final r in rows) {
            if (r['user_id']?.toString() != peerId) continue;
            final v = r['last_read_at'];
            if (v == null) return null;
            return DateTime.tryParse(v.toString())?.toLocal();
          }
          return null;
        })
        .handleError((Object e) {
          // Table absente / droits refusés : pas de « Lu », et c'est tout.
          debugPrint('ChatReads.watchPeerLastRead failed: $e');
        });
  }
}
