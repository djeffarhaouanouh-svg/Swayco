import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_strings.dart';
import 'profile_api.dart';
import 'push_dispatcher.dart';

/// L'état d'un quiz dans une conversation (table `chat_quizzes`).
class QuizState {
  const QuizState({
    required this.theme,
    required this.index,
    required this.total,
    required this.status,
    required this.startedBy,
    required this.stoppedBy,
  });

  final String theme;

  /// La question en cours, à partir de 1.
  final int index;
  final int total;

  /// `active`, `stopped` ou `done`.
  final String status;
  final String startedBy;
  final String stoppedBy;

  bool get active => status == 'active';
  bool get isLast => index >= total;

  static QuizState? fromRow(Object? row) {
    if (row is! Map) return null;
    final m = Map<String, dynamic>.from(row);
    final theme = m['theme']?.toString() ?? '';
    if (theme.isEmpty) return null;
    return QuizState(
      theme: theme,
      index: (m['q_index'] as num?)?.toInt() ?? 1,
      total: (m['total'] as num?)?.toInt() ?? 5,
      status: m['status']?.toString() ?? 'active',
      startedBy: m['started_by']?.toString() ?? '',
      stoppedBy: m['stopped_by']?.toString() ?? '',
    );
  }
}

/// Le quiz du chat : une question à la fois, choisie par le SERVEUR (fonctions
/// `quiz_start` / `quiz_next` / `quiz_stop`). Chaque carte est un message du
/// fil ; le texte de la question vit dans l'app (`quiz_q_<thème>_<n>`), donc
/// chacun la lit dans sa langue.
abstract final class QuizApi {
  static SupabaseClient get _client => Supabase.instance.client;

  /// Les six thèmes, dans l'ordre de la grille.
  static const themes = <String>[
    'food',
    'travel',
    'language',
    'culture',
    'fun',
    'personal',
  ];

  static const themeEmoji = <String, String>{
    'food': '🍜',
    'travel': '✈️',
    'language': '💬',
    'culture': '🎎',
    'fun': '😂',
    'personal': '💭',
  };

  /// Le texte de la question [n] du thème [theme], dans MA langue.
  static String questionText(String theme, int n) =>
      AppStrings.t('quiz_q_${theme}_$n');

  static Future<QuizState?> fetch(String conversationId) async {
    try {
      final row = await _client
          .from('chat_quizzes')
          .select()
          .eq('conversation_id', conversationId)
          .maybeSingle();
      return QuizState.fromRow(row);
    } catch (e) {
      debugPrint('QuizApi.fetch failed: $e');
      return null;
    }
  }

  static Stream<QuizState?> watch(String conversationId) {
    return _client
        .from('chat_quizzes')
        .stream(primaryKey: ['conversation_id'])
        .eq('conversation_id', conversationId)
        .map((rows) => rows.isEmpty ? null : QuizState.fromRow(rows.first));
  }

  /// Lance un quiz ([theme] vide ou inconnu = « Surprise », tiré par le
  /// serveur). Rend l'état, ou null si l'envoi a échoué.
  static Future<QuizState?> start({
    required String conversationId,
    required String theme,
    required String peerId,
    required String myName,
  }) async {
    final res = await _client.rpc('quiz_start', params: {
      'p_conv': conversationId,
      'p_theme': theme,
      'p_to': peerId,
      'p_name': myName,
    });
    final state = QuizState.fromRow(res);
    if (state != null) {
      unawaited(_push(peerId, myName, conversationId, state.index));
    }
    return state;
  }

  /// Question suivante (ou fin du quiz après la dernière). [from] = la question
  /// qu'on vient de voir : le serveur n'avance pas deux fois.
  static Future<QuizState?> next({
    required String conversationId,
    required int from,
    required String peerId,
    required String myName,
  }) async {
    final res = await _client.rpc('quiz_next', params: {
      'p_conv': conversationId,
      'p_from': from,
      'p_to': peerId,
      'p_name': myName,
    });
    final state = QuizState.fromRow(res);
    if (state != null && state.active && state.index != from) {
      unawaited(_push(peerId, myName, conversationId, state.index));
    }
    return state;
  }

  static Future<QuizState?> stop({
    required String conversationId,
    required String peerId,
    required String myName,
  }) async {
    final res = await _client.rpc('quiz_stop', params: {
      'p_conv': conversationId,
      'p_to': peerId,
      'p_name': myName,
    });
    return QuizState.fromRow(res);
  }

  /// La notification « Quiz · Question n » vers l'autre, dans SA langue.
  static Future<void> _push(
    String peerId,
    String myName,
    String conversationId,
    int index,
  ) async {
    try {
      final lang = (await ProfileApi.fetchById(peerId))?.language ?? '';
      await PushDispatcher.notify(
        recipientUid: peerId,
        title: myName.isEmpty ? AppStrings.tIn(lang, 'push_new_message') : myName,
        body: AppStrings.tIn(lang, 'quiz_push', args: {'n': '$index'}),
        type: 'message',
        data: {'conversationId': conversationId},
      );
    } catch (e) {
      debugPrint('QuizApi push failed: $e');
    }
  }
}
