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

  test('appel : deux lignes portugaises, Portugal puis Brésil dessous', () {
    final codes = callLanguages.map((l) => l.code).toList();
    final ip = codes.indexOf('pt-PT');
    final ib = codes.indexOf('pt-BR');
    expect(ip, greaterThanOrEqualTo(0));
    expect(ib, ip + 1, reason: 'Brasil juste sous Portugal, pas en premier');
    expect(callLanguages[ip].label, 'Português (Portugal)');
    expect(callLanguages[ib].label, 'Português (Brasil)');
    expect(callLanguages[ib].flag, '🇧🇷');
    expect(callLanguages.length, supportedLanguages.length + 1);
    expect(codes.contains('pt'), isFalse);
  });

  test('appel : un pt nu prend la variante de l\'interface, les régionaux restent', () {
    AppStrings.ptBrazilian.value = false;
    expect(callLanguageCode('pt'), 'pt-PT');
    AppStrings.ptBrazilian.value = true;
    expect(callLanguageCode('pt'), 'pt-BR');
    expect(callLanguageCode('pt_br'), 'pt-BR');
    expect(callLanguageCode('pt-PT'), 'pt-PT');
    expect(callLanguageCode('fr'), 'fr');
    expect(findCallLanguageByCode('pt-PT')?.label, 'Português (Portugal)');
    expect(findCallLanguageByCode('pt-BR')?.countryCode, 'BR');
    expect(findCallLanguageByCode('fr')?.code, 'fr');
    // Le catalogue d'affichage (profil des autres) garde « Português ».
    expect(findLanguageByCode('pt')?.label, 'Português');
  });

  test('« pt-PT » choisit l\'interface du Portugal', () {
    AppStrings.ptBrazilian.value = true;
    AppStrings.setFromCode('pt-PT');
    expect(AppStrings.ptBrazilian.value, isFalse);
    expect(AppStrings.currentBcp47.value, 'pt');
  });

  test('ordre exact : interface ET appel, Portugal puis Brésil juste dessous', () {
    String row(AppLanguage l) => '${l.code}:${l.label}';
    final ui = interfaceLanguages.map(row).toList();
    expect(ui, [
      'fr:Français',
      'en:English',
      'es:Español',
      'de:Deutsch',
      'it:Italiano',
      'pt:Português (Portugal)',
      'pt-BR:Português (Brasil)',
      'nl:Nederlands',
      'ar:العربية الفصحى',
      'ru:Русский',
      'zh:中文',
      'ja:日本語',
      'ko:한국어',
    ]);
    final call = callLanguages.map((l) => l.code).toList();
    expect(call, [
      'fr', 'en', 'es', 'de', 'it', 'pt-PT', 'pt-BR', 'nl', 'ar', 'ru', 'zh', 'ja', 'ko',
    ]);
  });
}