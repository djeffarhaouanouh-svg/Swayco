import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/match_celebration.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('deux matchs d\'un coup : les DEUX sont célébrés, dans l\'ordre d\'arrivée', () {
    // Laura (manquée depuis une heure) puis Gabriela, offerts à la suite.
    MatchCelebration.offer('laura-1');
    MatchCelebration.offer('gabriela-1');
    expect(MatchCelebration.pendingPeerId.value, 'gabriela-1'); // le signal
    expect(MatchCelebration.takeNext(), 'laura-1');
    expect(MatchCelebration.takeNext(), 'gabriela-1'); // avant : écrasée, jamais montrée
    expect(MatchCelebration.takeNext(), isNull);
    expect(MatchCelebration.pendingPeerId.value, isNull);
  });

  test('un match offert PENDANT une célébration reste dans la file', () {
    MatchCelebration.offer('a-2');
    expect(MatchCelebration.takeNext(), 'a-2'); // l'animation de « a » démarre
    MatchCelebration.offer('b-2'); // arrive pendant l'animation de « a »
    MatchCelebration.offer('c-2');
    expect(MatchCelebration.takeNext(), 'b-2');
    expect(MatchCelebration.takeNext(), 'c-2');
    expect(MatchCelebration.takeNext(), isNull);
  });

  test('un même match n\'est jamais célébré deux fois', () {
    MatchCelebration.offer('d-3');
    MatchCelebration.offer('d-3'); // doublon
    MatchCelebration.markShown('e-3'); // déjà célébré localement (acceptation à la main)
    MatchCelebration.offer('e-3');
    expect(MatchCelebration.takeNext(), 'd-3');
    expect(MatchCelebration.takeNext(), isNull);
  });

  test('file vide : rien à célébrer, pas d\'erreur', () {
    expect(MatchCelebration.takeNext(), isNull);
    expect(MatchCelebration.pendingPeerId.value, isNull);
    MatchCelebration.offer('   ');
    expect(MatchCelebration.takeNext(), isNull);
  });
}
