import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_strings.dart';
import 'profile_api.dart';
import 'push_dispatcher.dart';
import 'supabase_service.dart';

/// Quick-react strip shown on long-press. Double-tap sends the first one
/// (thumbs-up) without opening the strip.
const kQuickReactionEmojis = <String>['👍', '👌', '🎉', '❤️', '🔥'];
const kThumbsUpEmoji = '👍';

class MessageReaction {
  const MessageReaction({
    required this.id,
    required this.messageId,
    required this.conversationId,
    required this.userId,
    required this.userName,
    required this.messageAuthorId,
    required this.emoji,
    required this.createdAt,
  });

  final String id;
  final String messageId;
  final String conversationId;
  final String userId;
  final String userName;
  final String messageAuthorId;
  final String emoji;
  final DateTime createdAt;

  factory MessageReaction.fromMap(Map<String, dynamic> m) {
    final created = m['created_at'];
    return MessageReaction(
      id: m['id']?.toString() ?? '',
      messageId: m['message_id']?.toString() ?? '',
      conversationId: m['conversation_id']?.toString() ?? '',
      userId: m['user_id']?.toString() ?? '',
      userName: m['user_name']?.toString() ?? '',
      messageAuthorId: m['message_author_id']?.toString() ?? '',
      emoji: m['emoji']?.toString() ?? '',
      createdAt: created is String
          ? DateTime.tryParse(created)?.toLocal() ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

/// Same-emoji tap removes; any other emoji replaces. Null means "delete".
String? nextReactionEmoji({required String? current, required String tapped}) {
  if (tapped.isEmpty) return current;
  if (current == tapped) return null;
  return tapped;
}

/// Distinct emojis in first-seen order — the WhatsApp corner chip.
List<String> reactionChipEmojis(Iterable<MessageReaction> reactions) {
  final seen = <String>{};
  final out = <String>[];
  for (final r in reactions) {
    if (r.emoji.isEmpty) continue;
    if (seen.add(r.emoji)) out.add(r.emoji);
  }
  return out;
}

/// Groups a flat reaction list by message id, preserving arrival order.
Map<String, List<MessageReaction>> reactionsByMessage(
  Iterable<MessageReaction> reactions,
) {
  final out = <String, List<MessageReaction>>{};
  for (final r in reactions) {
    if (r.messageId.isEmpty) continue;
    out.putIfAbsent(r.messageId, () => []).add(r);
  }
  return out;
}

/// Thin wrapper over `message_reactions`. Failures from a missing table
/// (migration not applied yet) are swallowed so the rest of chat keeps
/// working — same stance as [ChatReads].
abstract final class MessageReactions {
  static SupabaseClient get _client => Supabase.instance.client;

  static Future<List<MessageReaction>> fetchForConversation(
    String conversationId,
  ) async {
    if (!isSupabaseReady || conversationId.isEmpty) return const [];
    try {
      final rows = await _client
          .from('message_reactions')
          .select()
          .eq('conversation_id', conversationId)
          .order('created_at', ascending: true);
      return (rows as List)
          .map((r) =>
              MessageReaction.fromMap(Map<String, dynamic>.from(r as Map)))
          .toList(growable: false);
    } catch (e) {
      debugPrint('MessageReactions.fetch failed: $e');
      return const [];
    }
  }

  /// Live list of every reaction in [conversationId]. Re-emits the full
  /// set on insert/update/delete.
  static Stream<List<MessageReaction>> subscribeForConversation(
    String conversationId,
  ) {
    if (!isSupabaseReady || conversationId.isEmpty) {
      return const Stream<List<MessageReaction>>.empty();
    }
    return _client
        .from('message_reactions')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: true)
        .map((rows) {
          final list = rows
              .map((m) => MessageReaction.fromMap(Map<String, dynamic>.from(m)))
              .toList();
          list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          return List<MessageReaction>.unmodifiable(list);
        })
        .handleError((Object e) {
          debugPrint('MessageReactions.subscribe failed: $e');
        });
  }

  /// Reactions on messages *I* wrote — feeds the in-app banner for the
  /// author, independent of whichever thread is open.
  static Stream<List<MessageReaction>> subscribeForAuthor(String authorId) {
    if (!isSupabaseReady || authorId.isEmpty) {
      return const Stream<List<MessageReaction>>.empty();
    }
    return _client
        .from('message_reactions')
        .stream(primaryKey: ['id'])
        .eq('message_author_id', authorId)
        .map((rows) {
          return [
            for (final m in rows)
              MessageReaction.fromMap(Map<String, dynamic>.from(m)),
          ];
        })
        .handleError((Object e) {
          debugPrint('MessageReactions.subscribeForAuthor failed: $e');
        });
  }

  /// Apply [emoji] to [messageId] for [userId]. Same emoji again → remove.
  /// Notifies the message author on add/replace, never on remove, never
  /// when reacting to your own message.
  static Future<void> set({
    required String messageId,
    required String conversationId,
    required String userId,
    required String userName,
    required String messageAuthorId,
    required String emoji,
    String? currentEmoji,
    String authorLang = '',
  }) async {
    if (!isSupabaseReady ||
        messageId.isEmpty ||
        userId.isEmpty ||
        emoji.isEmpty) {
      return;
    }
    await ProfileApi.ensureMyProfileRow();
    final next = nextReactionEmoji(current: currentEmoji, tapped: emoji);
    if (next == null) {
      await _client
          .from('message_reactions')
          .delete()
          .eq('message_id', messageId)
          .eq('user_id', userId);
      return;
    }
    await _client.from('message_reactions').upsert(
      {
        'message_id': messageId,
        'conversation_id': conversationId,
        'user_id': userId,
        'user_name': userName,
        'message_author_id': messageAuthorId,
        'emoji': next,
      },
      onConflict: 'message_id,user_id',
    );
    if (messageAuthorId.isEmpty || messageAuthorId == userId) return;
    unawaited(_notifyReaction(
      authorId: messageAuthorId,
      authorLang: authorLang,
      reactorName: userName,
      conversationId: conversationId,
      reactorId: userId,
      emoji: next,
    ));
  }

  static Future<void> _notifyReaction({
    required String authorId,
    required String authorLang,
    required String reactorName,
    required String conversationId,
    required String reactorId,
    required String emoji,
  }) async {
    final lang = authorLang.isNotEmpty
        ? authorLang
        : (await ProfileApi.fetchById(authorId))?.language ?? '';
    await PushDispatcher.notify(
      recipientUid: authorId,
      title: reactorName.isEmpty
          ? AppStrings.tIn(lang, 'push_new_message')
          : reactorName,
      body: AppStrings.tIn(lang, 'push_reaction_body', args: {'emoji': emoji}),
      // Same routing shape as a chat message: tap opens the thread.
      type: 'message',
      data: {
        'conversationId': conversationId,
        'senderId': reactorId,
        'kind': 'reaction',
      },
    );
  }
}
