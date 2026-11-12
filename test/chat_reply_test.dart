import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/chat_api.dart';
import 'package:livekit_translate/widgets/chat_reply_widgets.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(width: 300, height: 80, child: child))),
    );

void main() {
  test('une réponse porte l\'id du message cité', () {
    final m = ChatMessage.fromMap({
      'id': 'b',
      'created_at': '2026-11-12T10:00:00Z',
      'reply_to_id': 'a',
    });
    expect(m.isReply, isTrue);
    expect(m.replyToId, 'a');
    final plain = ChatMessage.fromMap({'id': 'c', 'created_at': '2026-11-12T10:00:00Z'});
    expect(plain.isReply, isFalse);
  });

  test('durée d\'un vocal cité : m:ss, 0:00 si inconnue', () {
    expect(voiceDuration(12000), '0:12');
    expect(voiceDuration(75000), '1:15');
    expect(voiceDuration(0), '0:00');
  });

  test('un GIF Giphy est reconnu, une photo non', () {
    expect(isGifUrl('https://media2.giphy.com/media/x/giphy.gif'), isTrue);
    expect(isGifUrl('https://x.supabase.co/storage/chat/1.jpg'), isFalse);
  });

  testWidgets('glisser vers la droite au-delà de 64 px répond', (tester) async {
    var replies = 0;
    await tester.pumpWidget(_host(SwipeToReply(
      enabled: true,
      onReply: () => replies++,
      child: const SizedBox(width: 120, height: 40, child: ColoredBox(color: Colors.blue)),
    )));
    await tester.drag(find.byType(ColoredBox).last, const Offset(110, 0));
    await tester.pumpAndSettle();
    expect(replies, 1);
  });

  testWidgets('un glissement court ne répond pas', (tester) async {
    var replies = 0;
    await tester.pumpWidget(_host(SwipeToReply(
      enabled: true,
      onReply: () => replies++,
      child: const SizedBox(width: 120, height: 40, child: ColoredBox(color: Colors.blue)),
    )));
    await tester.drag(find.byType(ColoredBox).last, const Offset(30, 0));
    await tester.pumpAndSettle();
    expect(replies, 0);
  });

  testWidgets('vers la gauche : rien (la page se ferme au doigt)', (tester) async {
    var replies = 0;
    await tester.pumpWidget(_host(SwipeToReply(
      enabled: true,
      onReply: () => replies++,
      child: const SizedBox(width: 120, height: 40, child: ColoredBox(color: Colors.blue)),
    )));
    await tester.drag(find.byType(ColoredBox).last, const Offset(-110, 0));
    await tester.pumpAndSettle();
    expect(replies, 0);
  });

  testWidgets('désactivé (carte spéciale reçue) : aucun glissement', (tester) async {
    var replies = 0;
    await tester.pumpWidget(_host(SwipeToReply(
      enabled: false,
      onReply: () => replies++,
      child: const SizedBox(width: 120, height: 40, child: ColoredBox(color: Colors.blue)),
    )));
    await tester.drag(find.byType(ColoredBox).last, const Offset(110, 0));
    await tester.pumpAndSettle();
    expect(replies, 0);
  });
}
