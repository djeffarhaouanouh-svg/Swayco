import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/locations.dart';

void main() {
  test('la Bolivie et les autres pays d\'Amérique latine sont choisissables', () {
    final names = kCountries.map((c) => c.name).toSet();
    for (final n in ['Bolivie', 'Pérou', 'Chili', 'Équateur', 'Venezuela', 'Uruguay', 'Paraguay']) {
      expect(names, contains(n));
      expect(countryIso2For(n), isNotEmpty, reason: n);
      expect(countryFlagFor(n), isNotNull, reason: n);
    }
  });

  test('la détection GPS (code ISO -> nom) retrouve les nouveaux pays', () {
    expect(countryNameForIso2('bo'), 'Bolivie');
    expect(countryNameForIso2('PE'), 'Pérou');
    expect(countryNameForIso2('fr'), 'France');
    expect(countryNameForIso2('mn'), isNull); // la Mongolie n'est volontairement pas proposée
  });

  test('chaque pays a un code ISO, un drapeau, et aucun nom en double', () {
    final names = kCountries.map((c) => c.name).toList();
    expect(names.toSet().length, names.length);
    for (final c in kCountries) {
      expect(countryIso2For(c.name), isNotEmpty, reason: c.name);
      expect(c.flag.isNotEmpty, isTrue, reason: c.name);
    }
  });
}
