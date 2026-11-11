import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/revenue_cat.dart';

void main() {
  tearDown(() => RevenueCat.setServerGrantedPro(false));

  test('un compte Pro en base est Pro dans l\'app, sans achat sur le téléphone', () {
    expect(RevenueCat.proActive.value, isFalse);
    RevenueCat.setServerGrantedPro(true);
    expect(RevenueCat.proActive.value, isTrue);
    RevenueCat.setServerGrantedPro(false);
    expect(RevenueCat.proActive.value, isFalse);
  });

  test('le notifier prévient les écrans qui l\'écoutent', () {
    var calls = 0;
    void l() => calls++;
    RevenueCat.proActive.addListener(l);
    RevenueCat.setServerGrantedPro(true);
    RevenueCat.setServerGrantedPro(true); // même valeur : pas de bruit
    RevenueCat.setServerGrantedPro(false);
    RevenueCat.proActive.removeListener(l);
    expect(calls, 2);
  });
}