import 'dart:math';

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
int _rank(RemoteProfile p) => int.parse(p.id.substring(1));

void main() {
  // 7 hommes bien classés + 15 plus bas : il en manque 5 pour atteindre 12.
  final lotPauvre = _lot(100, {3, 9, 14, 22, 30, 41, 47, for (var i = 60; i < 75; i++) i});

  test('un lot sans assez d\'hommes : on monte à 24 % (12 sur 50)', () {
    final deck = pickDiscoverDeck(lotPauvre, 50, rng: Random(1));
    expect(deck.length, 50);
    expect(_men(deck), 12);
    expect(deck.map((p) => p.id).toSet().length, 50); // aucun doublon
    // Les hommes déjà bien classés sont conservés.
    for (final i in [3, 9, 14, 22, 30, 41, 47]) {
      expect(deck.any((p) => p.id == 'p$i'), isTrue);
    }
  });

  test('les hommes ajoutés sont MÉLANGÉS dans tout le paquet, pas au fond', () {
    var premier7 = 0, deuxSur7 = 0, aucunSur20 = 0, plusLongueSerieDeFemmes = 0;
    var hommesDansLeDernierQuart = 0;
    for (var seed = 0; seed < 500; seed++) {
      final deck = pickDiscoverDeck(lotPauvre, 50, rng: Random(seed));
      final isM = deck.map((p) => p.gender == 'm').toList();
      final m7 = isM.take(7).where((x) => x).length;
      if (m7 >= 1) premier7++;
      if (m7 >= 2) deuxSur7++;
      if (!isM.take(20).any((x) => x)) aucunSur20++;
      hommesDansLeDernierQuart += isM.skip(38).where((x) => x).length;
      // La plus longue suite de femmes d'affilée.
      var run = 0, best = 0;
      for (final m in isM) {
        run = m ? 0 : run + 1;
        if (run > best) best = run;
      }
      if (best > plusLongueSerieDeFemmes) plusLongueSerieDeFemmes = best;
    }
    expect(premier7, 500); // toujours au moins 1 homme sur les 7 premières cartes
    expect(deuxSur7, greaterThan(250)); // et souvent 2
    expect(aucunSur20, 0);
    expect(plusLongueSerieDeFemmes, lessThanOrEqualTo(9)); // jamais un long désert
    // Pas tous au fond : il y en a aussi dans les 12 dernières places, mais pas que.
    expect(hommesDansLeDernierQuart / 500, inInclusiveRange(1.5, 5.0));
  });

  test('le mélange est vraiment aléatoire : deux paquets ne sont pas identiques', () {
    final a = pickDiscoverDeck(lotPauvre, 50, rng: Random(1)).map((p) => p.id).toList();
    final b = pickDiscoverDeck(lotPauvre, 50, rng: Random(2)).map((p) => p.id).toList();
    expect(a, isNot(b));
    // Mais pour une même graine, le résultat est le même (testable).
    expect(pickDiscoverDeck(lotPauvre, 50, rng: Random(1)).map((p) => p.id).toList(), a);
  });

  test('les femmes gardent l\'ordre de leur score, les hommes aussi', () {
    final deck = pickDiscoverDeck(lotPauvre, 50, rng: Random(7));
    final femmes = deck.where((p) => p.gender != 'm').map(_rank).toList();
    final hommes = deck.where((p) => p.gender == 'm').map(_rank).toList();
    expect(femmes, [...femmes]..sort());
    expect(hommes, [...hommes]..sort());
  });

  test('assez d\'hommes déjà : le paquet n\'est pas touché', () {
    final men = {for (var i = 0; i < 50; i += 3) i}; // 17 hommes dans les 50 premiers
    final lot = _lot(100, men);
    final deck = pickDiscoverDeck(lot, 50);
    expect(deck.map((p) => p.id), lot.take(50).map((s) => s.$1.id));
  });

  test('pas assez d\'hommes dans tout le lot : on prend ceux qu\'il y a', () {
    final deck = pickDiscoverDeck(_lot(100, {5, 60, 90}), 50, rng: Random(3));
    expect(deck.length, 50);
    expect(_men(deck), 3);
  });

  test('lot plus petit que la limite, vide, ou sans femmes : aucune erreur', () {
    expect(pickDiscoverDeck(_lot(20, {2}), 50).length, 20);
    expect(pickDiscoverDeck(const [], 50), isEmpty);
    expect(pickDiscoverDeck(_lot(60, {for (var i = 0; i < 60; i++) i}), 50).length, 50);
  });

  test('la part minimale est réglable', () {
    final lot = _lot(100, {for (var i = 55; i < 100; i++) i});
    expect(_men(pickDiscoverDeck(lot, 50, minMenShare: 0.5, rng: Random(1))), 25);
    expect(_men(pickDiscoverDeck(lot, 50, minMenShare: 0)), 0);
  });

  test('la taille du lot et la part minimale sont celles mesurées', () {
    expect(kDiscoverFetchSize, 100);
    expect((50 * kDiscoverMinMenShare).ceil(), 12);
  });
}
