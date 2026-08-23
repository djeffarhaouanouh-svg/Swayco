import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/message_reactions.dart';

void main() {
  group('nextReactionEmoji', () {
    test('empty current stores the tap', () {
      expect(
        nextReactionEmoji(current: null, tapped: '👍'),
        '👍',
      );
    });

    test('same emoji again removes it', () {
      expect(
        nextReactionEmoji(current: '👍', tapped: '👍'),
        isNull,
      );
    });

    test('a different emoji replaces the current one', () {
      expect(
        nextReactionEmoji(current: '👍', tapped: '❤️'),
        '❤️',
      );
    });
  });

  group('reactionChipEmojis', () {
    MessageReaction r({
      required String id,
      required String emoji,
      String user = 'u',
    }) =>
        MessageReaction(
          id: id,
          messageId: 'm1',
          conversationId: 'c',
          userId: user,
          userName: '',
          messageAuthorId: 'a',
          emoji: emoji,
          createdAt: DateTime(2026, 1, 1),
        );

    test('keeps first-seen order and drops duplicates', () {
      expect(
        reactionChipEmojis([
          r(id: '1', emoji: '👍', user: 'a'),
          r(id: '2', emoji: '🔥', user: 'b'),
          r(id: '3', emoji: '👍', user: 'c'),
        ]),
        ['👍', '🔥'],
      );
    });

    test('skips empty emojis', () {
      expect(
        reactionChipEmojis([r(id: '1', emoji: '')]),
        isEmpty,
      );
    });
  });

  group('reactionsByMessage', () {
    test('groups by message id', () {
      final a = MessageReaction(
        id: '1',
        messageId: 'm1',
        conversationId: 'c',
        userId: 'u',
        userName: '',
        messageAuthorId: 'a',
        emoji: '👍',
        createdAt: DateTime(2026, 1, 1),
      );
      final b = MessageReaction(
        id: '2',
        messageId: 'm2',
        conversationId: 'c',
        userId: 'u',
        userName: '',
        messageAuthorId: 'a',
        emoji: '❤️',
        createdAt: DateTime(2026, 1, 1),
      );
      final grouped = reactionsByMessage([a, b, a]);
      expect(grouped['m1']!.length, 2);
      expect(grouped['m2']!.single.emoji, '❤️');
    });
  });

  group('MessageReaction.fromMap', () {
    test('reads the columns the API writes', () {
      final r = MessageReaction.fromMap({
        'id': 'id-1',
        'message_id': 'msg-1',
        'conversation_id': 'dm-a-b',
        'user_id': 'user-1',
        'user_name': 'Alex',
        'message_author_id': 'user-2',
        'emoji': '🎉',
        'created_at': '2026-08-23T02:00:00.000Z',
      });
      expect(r.id, 'id-1');
      expect(r.messageId, 'msg-1');
      expect(r.conversationId, 'dm-a-b');
      expect(r.userId, 'user-1');
      expect(r.userName, 'Alex');
      expect(r.messageAuthorId, 'user-2');
      expect(r.emoji, '🎉');
      expect(r.createdAt.isUtc, isFalse);
    });
  });
}
