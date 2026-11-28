import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/profile_views_api.dart';

void main() {
  final now = DateTime(2026, 11, 28, 15);
  ProfileVisit visit(String id, int daysAgo, [int hour = 10]) => (
        viewerId: id,
        at: DateTime(2026, 11, 28 - daysAgo, hour),
      );

  final data = ProfileViewsData(
    visits: [
      visit('a', 0),
      visit('b', 0, 1),
      visit('a', 1),
      visit('c', 6, 0),
      visit('d', 7, 23),
      visit('e', 10),
      visit('f', 40),
    ],
  );

  test('les périodes comptent en jours calendaires', () {
    expect(data.count(7, now), 4);
    expect(data.count(30, now), 6);
  });

  test('évolution comparée à la période précédente', () {
    // 4 visites sur 7 jours contre 2 les 7 jours d'avant.
    expect(data.deltaPercent(7, now), 100);
    // 6 contre 1.
    expect(data.deltaPercent(30, now), 500);
  });

  test('pas de pourcentage sans période précédente', () {
    expect(ProfileViewsData(visits: [visit('a', 0)]).deltaPercent(7, now),
        isNull);
  });

  test('les barres : un jour chacune, aujourd’hui en dernier', () {
    expect(data.lastWeek(now), [1, 0, 0, 0, 0, 1, 2]);
  });
}
