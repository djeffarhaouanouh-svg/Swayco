import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/like_undo.dart';

void main() {
  late List<String> withdrawn;
  late LikeUndo undo;

  setUp(() {
    withdrawn = [];
    undo = LikeUndo((id) async {
      withdrawn.add(id);
      return true;
    });
  });

  test('retour après un like arrivé : la ligne en attente est retirée', () async {
    undo.begin('anna').complete('row-1');
    expect(await undo.undo('anna'), 'row-1');
    expect(withdrawn, ['row-1']);
  });

  test('retour avant que le like soit arrivé : on retire dès qu\'il arrive', () async {
    final slot = undo.begin('anna');
    final result = undo.undo('anna');
    await pumpEventQueue();
    expect(withdrawn, isEmpty); // le like n'existe pas encore
    slot.complete('row-1');
    expect(await result, 'row-1');
    expect(withdrawn, ['row-1']);
  });

  test('un like qui n\'a rien écrit (déjà liké, ou match) : rien à retirer', () async {
    undo.begin('anna').complete(null);
    expect(await undo.undo('anna'), isNull);
    expect(withdrawn, isEmpty);
  });

  test('un refus après un like : plus rien à retirer', () async {
    undo.begin('anna').complete('row-1');
    undo.forget('anna');
    expect(await undo.undo('anna'), isNull);
    expect(withdrawn, isEmpty);
  });

  test('personne d\'autre n\'est touché', () async {
    undo.begin('anna').complete('row-1');
    undo.begin('bea').complete('row-2');
    expect(await undo.undo('bea'), 'row-2');
    expect(withdrawn, ['row-2']);
    expect(await undo.undo('anna'), 'row-1');
  });

  test('deux retours de suite ne retirent qu\'une fois', () async {
    undo.begin('anna').complete('row-1');
    await undo.undo('anna');
    expect(await undo.undo('anna'), isNull);
    expect(withdrawn, ['row-1']);
  });

  test('liker de nouveau attend la fin du retrait, sinon il l\'effacerait', () async {
    final delete = Completer<bool>();
    final slowUndo = LikeUndo((id) {
      withdrawn.add(id);
      return delete.future;
    });
    slowUndo.begin('anna').complete('row-1');
    final result = slowUndo.undo('anna');
    await pumpEventQueue();

    var turnCame = false;
    unawaited(slowUndo.turn('anna').then((_) => turnCame = true));
    await pumpEventQueue();
    expect(turnCame, isFalse); // le retrait n'est pas fini

    delete.complete(true);
    await result;
    await pumpEventQueue();
    expect(turnCame, isTrue);
  });

  test('personne à attendre : le tour vient tout de suite', () async {
    var came = false;
    unawaited(undo.turn('anna').then((_) => came = true));
    await pumpEventQueue();
    expect(came, isTrue);
  });

  test('la ligne est devenue un match entre-temps : rien n\'est annulé', () async {
    final noLongerPending = LikeUndo((id) async => false);
    noLongerPending.begin('anna').complete('row-1');
    expect(await noLongerPending.undo('anna'), isNull);
  });

  test('un retrait qui échoue ne bloque ni le retour ni le like suivant', () async {
    final broken = LikeUndo((id) async => throw StateError('réseau'));
    broken.begin('anna').complete('row-1');
    expect(await broken.undo('anna'), isNull);
    var came = false;
    unawaited(broken.turn('anna').then((_) => came = true));
    await pumpEventQueue();
    expect(came, isTrue);
  });

  testWidgets('un retrait qui ne finit jamais ne bloque pas la personne plus de 10 s',
      (tester) async {
    final stuck = LikeUndo((id) => Completer<bool>().future);
    stuck.begin('anna').complete('row-1');
    unawaited(stuck.undo('anna'));
    var came = false;
    unawaited(stuck.turn('anna').then((_) => came = true));
    await tester.pump(const Duration(seconds: 9));
    expect(came, isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(came, isTrue);
  });
}
