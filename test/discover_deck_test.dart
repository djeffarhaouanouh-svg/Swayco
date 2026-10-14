import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/profile_api.dart';

RemoteProfile _p(String id, String gender) => RemoteProfile(
      id: id,
      handle: id,
      displayName: id,
      language: 'fr',
      avatarColor: '',
      avatarUrl: '',
      gender: gender,
    );

/// [n] profils déjà triés par score décroissant : les hommes aux positions
/// [menAt], tout le reste des femmes.
List<(RemoteProfile, double)> _lot(int n, Set<int> menAt) => [
      for (var i = 0; i < n; i++)
        (_p('p$i', menAt.contains(i) ? 'm' : 'f'), (n - i).toDouble()),
    ];

int _men(List<RemoteProfile> d) => d.where((p) => p.gender == 'm').length;

void main() {
  test('un lot sans assez d\'hommes : on monte à 24 % (12 sur 50)', () {
    // 100 candidats, 7 hommes parmi les 50 premiers et 15 de plus plus bas.
    final men = {3, 9, 14, 22, 30, 41, 47, for (var i = 60; i < 75; i++) i};
    final deck = pickDiscoverDeck(_lot(100, men), 50);
    expect(deck.length, 50);
    expect(_men(deck), 12);
    // Les meilleures cartes restent : p0, p1, p2 sont toujours là, dans l'ordre.
    expect(deck.take(3).map((p) => p.id), ['p0', 'p1', 'p2']);
    // Les hommes déjà bien classés sont conservés.
    for (final i in [3, 9, 14, 22, 30, 41, 47]) {
      expect(deck.any((p) => p.id == 'p$i'), isTrue);
    }
    // Le paquet reste trié par score décroissant.
    final order = deck.map((p) => int.parse(p.id.substring(1))).toList();
    expect(order, [...order]..sort());
  });

  test('assez d\'hommes déjà : rien ne change', () {
    final men = {for (var i = 0; i < 50; i += 3) i}; // 17 hommes dans les 50 premiers (> 12)
    final lot = _lot(160, men);
    final deck = pickDiscoverDeck(lot, 50);
    expect(deck.map((p) => p.id), lot.take(50).map((s) => s.$1.id));
  });

  test('pas assez d\'hommes dans tout le lot : on prend ceux qu\'il y a', () {
    final deck = pickDiscoverDeck(_lot(160, {5, 80, 120}), 50);
    expect(deck.length, 50);
    expect(_men(deck), 3);
  });

  test('lot plus petit que la limite : aucune erreur', () {
    final deck = pickDiscoverDeck(_lot(20, {2}), 50);
    expect(deck.length, 20);
    expect(pickDiscoverDeck(const [], 50), isEmpty);
  });

  test('la part minimale est réglable', () {
    final lot = _lot(160, {for (var i = 70; i < 120; i++) i});
    expect(_men(pickDiscoverDeck(lot, 50, minMenShare: 0.5)), 25);
    expect(_men(pickDiscoverDeck(lot, 50, minMenShare: 0)), 0);
  });

  test('la taille du lot et la part minimale sont celles mesurées', () {
    expect(kDiscoverFetchSize, 100);
    expect((50 * kDiscoverMinMenShare).ceil(), 12);
  });
}

