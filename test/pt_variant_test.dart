import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/app_strings.dart';
import 'package:livekit_translate/services/languages.dart';

void main() {
  tearDown(() {
    AppStrings.ptBrazilian.value = false;
    AppStrings.currentBcp47.value = 'en';
  });

  test('pt : l\'interface du Portugal et celle du Brésil sont deux textes', () {
    AppStrings.currentBcp47.value = 'pt';
    AppStrings.ptBrazilian.value = false;
    expect(AppStrings.t('save_failed'), 'Falha ao guardar.');
    AppStrings.ptBrazilian.value = true;
    expect(AppStrings.t('save_failed'), 'Falha ao salvar.');
  });

  test('la variante ne touche que le portugais', () {
    AppStrings.ptBrazilian.value = true;
    AppStrings.currentBcp47.value = 'fr';
    expect(AppStrings.t('save_failed'), isNot('Falha ao salvar.'));
    expect(AppStrings.currentBcp47.value, 'fr');
  });

  test('« pt-BR » active l\'interface brésilienne et garde le code pt', () {
    AppStrings.ptBrazilian.value = false;
    AppStrings.setFromCode('pt-BR');
    expect(AppStrings.currentBcp47.value, 'pt');
    expect(AppStrings.ptBrazilian.value, isTrue);
  });

  test('« pt » seul ne change pas la variante déjà choisie', () {
    AppStrings.ptBrazilian.value = true;
    AppStrings.setFromCode('pt');
    expect(AppStrings.ptBrazilian.value, isTrue);
  });

  test('tIn : pt-BR = Brésil, pt = Portugal', () {
    expect(AppStrings.tIn('pt-BR', 'save_failed'), 'Falha ao salvar.');
    expect(AppStrings.tIn('pt', 'save_failed'), 'Falha ao guardar.');
  });

  test('les sélecteurs d\'interface ont DEUX lignes portugaises, les roues d\'appel une', () {
    final ui = interfaceLanguages.map((l) => l.code).toList();
    expect(ui.where((c) => c == 'pt').length, 1);
    expect(ui.where((c) => c == 'pt-BR').length, 1);
    expect(supportedLanguages.where((l) => l.code == 'pt').length, 1);
    expect(supportedLanguages.any((l) => l.code == 'pt-BR'), isFalse);
    expect(interfaceLanguages.length, supportedLanguages.length + 1);
  });

  test('la ligne cochée suit la variante, et la langue du compte reste pt', () {
    AppStrings.ptBrazilian.value = true;
    expect(interfacePickerCode('pt'), 'pt-BR');
    expect(interfaceLanguageOf('pt-BR'), 'pt');
    AppStrings.ptBrazilian.value = false;
    expect(interfacePickerCode('pt'), 'pt');
    expect(interfacePickerCode('fr'), 'fr');
    expect(interfaceLanguageLabel('pt'), 'Português (Portugal)');
    AppStrings.ptBrazilian.value = true;
    expect(interfaceLanguageLabel('pt'), 'Português (Brasil)');
  });

  test('appel : une seule ligne portugaise, « Português (Brasil) », code pt', () {
    final pt = callLanguages.where((l) => l.code == 'pt').toList();
    expect(pt.length, 1);
    expect(pt.single.label, 'Português (Brasil)');
    expect(pt.single.flag, '🇧🇷');
    expect(callLanguages.length, supportedLanguages.length);
    expect(findCallLanguageByCode('pt')?.countryCode, 'BR');
    expect(findCallLanguageByCode('pt-BR')?.code, 'pt');
    expect(findCallLanguageByCode('fr')?.code, 'fr');
    // Le catalogue d'affichage (profil des autres) garde « Português ».
    expect(findLanguageByCode('pt')?.label, 'Português');
  });
}