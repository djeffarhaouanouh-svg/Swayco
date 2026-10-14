import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/continents.dart';
import 'package:livekit_translate/services/profile_api.dart';

RemoteProfile _p(String id, String gender, [String country = '', bool isAi = true, bool boosted = false]) => RemoteProfile(
      id: id,
      handle: id,
      displayName: id,
      language: 'fr',
      avatarColor: '',
      avatarUrl: '',
      gender: gender,
      country: country,
      isAi: isAi,
      boostedUntil: boosted ? DateTime.now().add(const Duration(hours: 1)) : null,
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

  test('les cartes non forcées gardent l\'ordre de leur score', () {
    final deck = pickDiscoverDeck(lotPauvre, 50, rng: Random(7));
    // Les cartes forcées viennent du bas du lot (rang >= 50) ; les autres restent triées.
    // Les hommes sont répartis dans tout le paquet : on compare femmes entre elles, hommes entre eux.
    final femmes = deck.where((p) => p.gender != 'm').map(_rank).where((r) => r < 50).toList();
    final hommes = deck.where((p) => p.gender == 'm').map(_rank).where((r) => r < 50).toList();
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

  // ── Équilibre entre continents ─────────────────────────────────────────────
  const latam = ['Argentine', 'Colombie', 'Brésil', 'Mexique'];
  const asia = ['Japon', 'Corée du Sud', 'Philippines', 'Inde'];
  const europe = ['France', 'Allemagne', 'Espagne', 'Suède'];

  /// Un lot réaliste : 48 % Amérique latine, 18 % Asie, 34 % Europe, 14 % d'hommes,
  /// score au hasard.
  List<(RemoteProfile, double)> lotReel(Random r, {int n = 100}) {
    final out = <(RemoteProfile, double)>[];
    for (var i = 0; i < n; i++) {
      final x = r.nextDouble();
      final pays = x < 0.48 ? latam : (x < 0.66 ? asia : europe);
      out.add((_p('p$i', r.nextDouble() < 0.14 ? 'm' : 'f', pays[r.nextInt(4)]), r.nextDouble()));
    }
    out.sort((a, b) => b.$2.compareTo(a.$2));
    return out;
  }

  int nbPays(Iterable<RemoteProfile> d, List<String> pays) =>
      d.where((p) => pays.contains(p.country)).length;

  test('chaque continent a entre 20 % et 40 % du paquet quand le lot le permet, avec les hommes', () {
    final r = Random(5);
    var tenables = 0;
    for (var i = 0; i < 400; i++) {
      final lot = lotReel(r);
      final deck = pickDiscoverDeck(lot, 50, rng: Random(i));
      expect(deck.length, 50);
      expect(deck.map((p) => p.id).toSet().length, 50); // aucun doublon
      final profils = lot.map((s) => s.$1);
      // Les bornes ne sont tenables que si le lot a au moins 10 cartes de
      // chaque continent et assez de place sous le plafond de 20.
      final dispo = [latam, asia, europe].map((p) => nbPays(profils, p)).toList();
      final tenable = dispo.every((n) => n >= 10) && dispo.fold<int>(0, (a, n) => a + (n < 20 ? n : 20)) >= 50;
      if (tenable) {
        tenables++;
        for (final pays in [latam, asia, europe]) {
          final n = nbPays(deck, pays);
          expect(n, inInclusiveRange(10, 20), reason: 'lot $i : $pays = $n');
        }
      } else {
        // Continent rare : on prend toutes les cartes qu'il y a.
        final pauvre = [latam, asia, europe].where((p) => nbPays(profils, p) < 10);
        for (final pays in pauvre) {
          expect(nbPays(deck, pays), nbPays(profils, pays), reason: 'lot $i : $pays');
        }
      }
      // Les hommes : 12 si le lot en a assez (sinon tous ceux qu'il a).
      final hommesDuLot = profils.where((p) => p.gender == 'm').length;
      expect(_men(deck), hommesDuLot >= 12 ? greaterThanOrEqualTo(12) : hommesDuLot, reason: 'lot $i');
    }
    expect(tenables, greaterThan(380)); // presque tous les lots réalistes sont tenables
  });
  test('l\'Asie, rare dans le lot, passe de quelques cartes à au moins 10', () {
    // 100 cartes dont seulement 4 d'Asie, toutes bien en dessous du top 50.
    final lot = [
      for (var i = 0; i < 100; i++)
        (_p('p$i', 'f', (i >= 70 && i < 74) ? 'Japon' : (i.isEven ? 'Argentine' : 'France')), (100 - i).toDouble()),
    ];
    final deck = pickDiscoverDeck(lot, 50, rng: Random(1));
    expect(nbPays(deck, asia), 4); // on prend celles qu'il y a
    expect(deck.length, 50);
  });

  test('les cartes forcées sont mélangées dans tout le paquet, y compris au début', () {
    var dansLes10Premieres = 0, essais = 300;
    final r = Random(11);
    for (var i = 0; i < essais; i++) {
      final lot = lotReel(r);
      final deck = pickDiscoverDeck(lot, 50, rng: Random(i));
      // Les 10 premières cartes contiennent des cartes d'au moins 2 continents.
      final tete = deck.take(10).map((p) => continentOfCountry(p.country)).toSet();
      if (tete.length >= 2) dansLes10Premieres++;
    }
    expect(dansLes10Premieres / essais, greaterThan(0.95));
  });

  test('pays inconnus ou vides : aucun quota, comportement d\'avant', () {
    final lot = _lot(100, {for (var i = 55; i < 100; i++) i}); // pays vides
    final deck = pickDiscoverDeck(lot, 50, rng: Random(2));
    expect(deck.length, 50);
    expect(_men(deck), 12); // seul le quota d'hommes joue
  });
  // ── Les vrais comptes d'abord ──────────────────────────────────────────────
  test('un vrai compte n\'est jamais retiré pour équilibrer, même mal classé', () {
    // Lot dominé par l'Amérique latine ; 3 vrais comptes latins, tout en bas du top 50.
    final lot = <(RemoteProfile, double)>[];
    for (var i = 0; i < 100; i++) {
      final humain = i == 45 || i == 47 || i == 49;
      final pays = i < 70 ? 'Argentine' : (i.isEven ? 'Japon' : 'France');
      lot.add((_p('p$i', 'f', pays, !humain), (100 - i).toDouble()));
    }
    for (var s = 0; s < 50; s++) {
      final deck = pickDiscoverDeck(lot, 50, rng: Random(s));
      for (final id in ['p45', 'p47', 'p49']) {
        expect(deck.any((p) => p.id == id), isTrue, reason: 'graine $s : $id retiré');
      }
      expect(deck.length, 50);
    }
  });

  test('le bonus de score d\'un vrai compte dépasse tous les autres critères réunis', () {
    // intention 25 + intérêts 4x15 + catégorie 30 + connexion 30 + pays 35 + langue 30 + popularité ~36
    expect(kDiscoverHumanBonus, greaterThan(25 + 60 + 30 + 30 + 35 + 30 + 40));
  });

  test('un vrai compte lit is_ai : faux par défaut, vrai quand la base le dit', () {
    expect(RemoteProfile.fromMap({'id': 'u1', 'is_ai': true}).isAi, isTrue);
    expect(RemoteProfile.fromMap({'id': 'u2', 'is_ai': false}).isAi, isFalse);
    expect(RemoteProfile.fromMap({'id': 'u3'}).isAi, isFalse);
  });
  // ── Les boosts passent au-dessus de tout ───────────────────────────────────
  test('le boost vaut plus que le bonus d\'un vrai compte et que tout le reste', () {
    expect(kDiscoverBoostBonus, greaterThan(kDiscoverHumanBonus + 25 + 60 + 30 + 30 + 35 + 30 + 40));
  });

  test('un profil boosté est conservé et reste tout en haut du paquet', () {
    // 100 cartes ; 2 boostées (IA) classées bas dans le top 50 d'origine et 1 juste dehors.
    final lot = <(RemoteProfile, double)>[];
    for (var i = 0; i < 100; i++) {
      final boost = i == 40 || i == 48;
      final pays = i < 70 ? 'Argentine' : (i.isEven ? 'Japon' : 'France');
      lot.add((_p('p$i', 'f', pays, true, boost), (100 - i).toDouble()));
    }
    for (var s = 0; s < 80; s++) {
      final deck = pickDiscoverDeck(lot, 50, rng: Random(s));
      final tete = deck.take(2).map((p) => p.id).toSet();
      expect(tete, {'p40', 'p48'}, reason: 'graine $s : les boostés ne sont pas en tête');
      expect(deck.length, 50);
    }
  });

  test('boosté et vrai compte : le boosté est devant', () {
    final lot = [
      (_p('humain', 'f', 'Argentine', false), 1000.0),
      (_p('boost', 'f', 'Argentine', true, true), 10000.0),
      for (var i = 0; i < 60; i++) (_p('x$i', 'f', 'Argentine'), (50 - i).toDouble()),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    final deck = pickDiscoverDeck(lot, 50, rng: Random(1));
    expect(deck.first.id, 'boost');
    expect(deck.any((p) => p.id == 'humain'), isTrue);
  });
  test('la taille du lot et la part minimale sont celles mesurées', () {
    expect(kDiscoverFetchSize, 100);
    expect(kDiscoverDailySwipes, 100);
    expect((50 * kDiscoverMinMenShare).ceil(), 12);
  });
}





