import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/likes_empty_kind.dart';

void main() {
  // Mercredi 4 nov. 2026, 15 h : « aujourd'hui » = depuis mercredi 00 h 00.
  final now = DateTime(2026, 11, 4, 15);
  final today10 = DateTime(2026, 11, 4, 10);
  final yesterday23 = DateTime(2026, 11, 3, 23, 59);
  final lastWeek = DateTime(2026, 10, 28, 12);

  LikesEmptyKind kind(DateTime? received, DateTime? answered) =>
      classifyLikesEmpty(lastReceived: received, lastAnswered: answered, now: now);

  test('jamais rien reçu (nouvel arrivant) : never, même si j\'ai « répondu »', () {
    expect(kind(null, null), LikesEmptyKind.never);
    expect(kind(null, today10), LikesEmptyKind.never);
  });

  test('une demande reçue aujourd\'hui, tout traité : caughtUp', () {
    expect(kind(today10, null), LikesEmptyKind.caughtUp);
    expect(kind(today10, today10), LikesEmptyKind.caughtUp);
  });

  test('rien reçu aujourd\'hui, rien traité aujourd\'hui : quietToday', () {
    expect(kind(yesterday23, null), LikesEmptyKind.quietToday);
    expect(kind(lastWeek, lastWeek), LikesEmptyKind.quietToday);
    expect(kind(lastWeek, yesterday23), LikesEmptyKind.quietToday);
  });

  test('j\'ai répondu AUJOURD\'HUI à une demande d\'hier : caughtUp, pas quietToday', () {
    // Sans ça « Tu es à jour ! » repassait en « rien aujourd\'hui » 15 s plus tard.
    expect(kind(yesterday23, today10), LikesEmptyKind.caughtUp);
    expect(kind(lastWeek, today10), LikesEmptyKind.caughtUp);
  });

  test('la frontière est minuit, à l\'heure locale', () {
    final justAfterMidnight = DateTime(2026, 11, 4, 0, 0, 1);
    final exactlyMidnight = DateTime(2026, 11, 4);
    final justBefore = DateTime(2026, 11, 3, 23, 59, 59);
    expect(kind(justAfterMidnight, null), LikesEmptyKind.caughtUp);
    expect(kind(exactlyMidnight, null), LikesEmptyKind.caughtUp);
    expect(kind(justBefore, null), LikesEmptyKind.quietToday);
  });

  test('les trois états sont bien trois résultats différents', () {
    final all = {
      kind(null, null),
      kind(today10, null),
      kind(lastWeek, null),
    };
    expect(all, {
      LikesEmptyKind.never,
      LikesEmptyKind.caughtUp,
      LikesEmptyKind.quietToday,
    });
  });
}
