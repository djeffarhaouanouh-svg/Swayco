import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/count_format.dart';

void main() {
  const fr = Locale('fr');
  const en = Locale('en');

  test('sous 1 000 : l\'entier', () {
    expect(formatCount(0, fr), '0');
    expect(formatCount(312, fr), '312');
    expect(formatCount(999, fr), '999');
  });

  test('à partir de 1 000 : un chiffre et « k », arrondi à l\'inférieur', () {
    expect(formatCount(1000, fr), '1k');
    expect(formatCount(1234, fr), '1,2k');
    expect(formatCount(1999, fr), '1,9k');
    expect(formatCount(2000, fr), '2k');
    expect(formatCount(2049, fr), '2k'); // 2,04 -> 2,0 -> pas de « .0 »
    expect(formatCount(999999, fr), '999,9k');
  });

  test('à partir d\'un million : « M », même règle', () {
    expect(formatCount(1000000, fr), '1M');
    expect(formatCount(2400000, fr), '2,4M');
    expect(formatCount(2499999, fr), '2,4M');
  });

  test('le séparateur suit la langue', () {
    expect(formatCount(1234, en), '1.2k');
    expect(formatCount(1234, const Locale('de')), '1,2k');
    expect(formatCount(2400000, en), '2.4M');
    expect(formatCount(1234, const Locale('ja')), '1.2k');
  });
}
