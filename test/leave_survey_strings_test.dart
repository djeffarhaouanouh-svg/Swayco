import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/app_strings.dart';

const _keys = [
  'leave_why_title', 'leave_why_skip', 'leave_why_no_replies', 'leave_why_fake',
  'leave_why_translation', 'leave_why_other_app', 'leave_why_ads',
  'leave_why_testing', 'leave_why_other',
];

void main() {
  test('le questionnaire de départ existe dans toutes les langues (pas de repli anglais)', () {
    AppStrings.currentBcp47.value = 'en';
    final en = {for (final k in _keys) k: AppStrings.t(k)};
    for (final k in _keys) {
      expect(en[k], isNot(k), reason: 'en $k');
    }
    for (final lang in ['fr', 'es', 'de', 'it', 'pt', 'nl', 'ar', 'ru', 'zh', 'ja', 'ko']) {
      AppStrings.currentBcp47.value = lang;
      for (final k in _keys) {
        final t = AppStrings.t(k);
        expect(t, isNot(k), reason: '$lang $k');
        expect(t, isNot(en[k]), reason: '$lang $k retombe sur l\'anglais');
      }
    }
  });
}
