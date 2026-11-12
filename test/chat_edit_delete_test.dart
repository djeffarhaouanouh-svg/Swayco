import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/app_strings.dart';
import 'package:livekit_translate/services/chat_api.dart';
import 'package:livekit_translate/widgets/chat_reply_widgets.dart';

ChatMessage _msg(Map<String, dynamic> extra) => ChatMessage.fromMap({
      'id': '7',
      'created_at': '2026-11-12T10:00:00Z',
      'sender': 'me',
      'body': 'Salut',
      'image_url': 'https://x/y.jpg',
      'audio_url': 'https://x/a.m4a',
      'audio_duration_ms': 4000,
      'discover_photo': 'https://x/d.jpg',
      ...extra,
    });

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SizedBox(width: 360, child: child)),
    );

void main() {
  setUp(() => AppStrings.currentBcp47.value = 'fr');

  test('modifié et supprimé se lisent dans la ligne', () {
    final m = _msg({'edited_at': '2026-11-12T10:05:00Z'});
    expect(m.isEdited, isTrue);
    expect(m.isDeleted, isFalse);
    final gone = _msg({
      'edited_at': '2026-11-12T10:05:00Z',
      'deleted_at': '2026-11-12T10:06:00Z',
    });
    expect(gone.isDeleted, isTrue);
    // Supprimé prime sur modifié.
    expect(gone.isEdited, isFalse);
    expect(_msg({}).isEdited, isFalse);
  });

  test('copyWith : la trace d\'une suppression n\'a plus aucun contenu', () {
    final m = _msg({});
    final t = m.copyWith(deletedAt: DateTime.now(), clearMedia: true);
    expect(t.isDeleted, isTrue);
    expect(t.body, '');
    expect(t.isImage, isFalse);
    expect(t.isVoice, isFalse);
    expect(t.hasDiscoverPhoto, isFalse);
    expect(t.audioDurationMs, 0);
    // Le reste suit.
    expect(t.id, '7');
    expect(t.senderId, 'me');
    expect(t.createdAt, m.createdAt);
  });

  test('copyWith : une modification change le corps et pose la date', () {
    final m = _msg({'image_url': '', 'audio_url': '', 'discover_photo': ''});
    final e = m.copyWith(body: 'Coucou', editedAt: DateTime(2026, 11, 12, 10, 5));
    expect(e.body, 'Coucou');
    expect(e.isEdited, isTrue);
    expect(m.isEdited, isFalse);
  });

  testWidgets('la trace affiche la phrase et l\'heure, sans bulle pleine',
      (tester) async {
    await tester.pumpWidget(_host(const DeletedBubble(
      mine: true,
      text: 'Tu as supprimé ce message',
      time: '14:35',
    )));
    expect(find.text('Tu as supprimé ce message'), findsOneWidget);
    expect(find.text('14:35'), findsOneWidget);
    expect(find.byIcon(Icons.block_rounded), findsOneWidget);
  });

  testWidgets('le bandeau « modifier » montre le texte d\'origine et annule',
      (tester) async {
    var cancelled = 0;
    await tester.pumpWidget(_host(EditBar(
      originalText: 'Mon texte avant',
      onCancel: () => cancelled++,
    )));
    expect(find.text('MODIFIER LE MESSAGE'), findsOneWidget);
    expect(find.text('Mon texte avant'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    expect(cancelled, 1);
  });

  test('les textes de modification existent dans les 13 langues', () {
    for (final code in ['fr', 'en', 'es', 'de', 'it', 'pt', 'nl', 'ar', 'ru', 'zh', 'ja', 'ko']) {
      for (final key in [
        'chat_edit',
        'chat_editing',
        'msg_edited',
        'msg_deleted_mine',
        'msg_deleted_peer',
        'msg_deleted_peer_anon',
        'chat_preview_deleted_mine',
        'chat_preview_deleted_peer',
      ]) {
        final v = AppStrings.tIn(code, key);
        expect(v, isNot(key), reason: '$code / $key manquant');
        expect(v.trim(), isNotEmpty);
      }
    }
    expect(AppStrings.tIn('pt-BR', 'msg_deleted_mine'), 'Você excluiu esta mensagem');
    expect(AppStrings.tIn('pt', 'msg_deleted_mine'), 'Eliminaste esta mensagem');
  });
}
