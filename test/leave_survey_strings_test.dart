import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/app_strings.dart';

const _keys = [
  'leave_why_title', 'leave_why_skip', 'leave_why_no_replies', 'leave_why_fake',
  'leave_why_translation', 'leave_why_other_app', 'leave_why_ads',
  'leave_why_testing', 'leave_why_other',
  'tuto_tr_l3s', // version courte, colonne étroite sous le galet
];

void main() {
  test('le questionnaire de départ existe dans toutes les langues (pas de repli anglais)', () {
    AppStrings.currentBcp47.value = 'en';
    final en = {for (final k in _keys) k: AppStrings.t(k, args: {'name': 'Aiko'})};
    for (final k in _keys) {
      expect(en[k], isNot(k), reason: 'en $k');
    }
    for (final lang in ['fr', 'es', 'de', 'it', 'pt', 'nl', 'ar', 'ru', 'zh', 'ja', 'ko']) {
      AppStrings.currentBcp47.value = lang;
      for (final k in _keys) {
        final t = AppStrings.t(k, args: {'name': 'Aiko'});
        expect(t, isNot(k), reason: '$lang $k');
        expect(t, isNot(en[k]), reason: '$lang $k retombe sur l\'anglais');
      }
    }
  });

  test('les libellés de la roue restent courts (une ligne, 21 px)', () {
    // Les libellés de la roue sont sur UNE ligne et coupés par « … » au-delà :
    // ~26 caractères latins au plus (les écritures asiatiques comptent ~1,75 fois).
    for (final lang in ['fr', 'en', 'es', 'de', 'it', 'pt', 'nl', 'ru', 'ar', 'zh', 'ja', 'ko']) {
      AppStrings.currentBcp47.value = lang;
      for (final k in _keys.where((k) => k.startsWith('leave_why_') && k != 'leave_why_title')) {
        final t = AppStrings.t(k);
        final wide = RegExp(r'[぀-ヿ㐀-鿿가-힯]').hasMatch(t);
        final len = wide ? (t.length * 1.75).round() : t.length;
        expect(len, lessThanOrEqualTo(26), reason: '$lang $k : "$t"');
      }
    }
  });
}
