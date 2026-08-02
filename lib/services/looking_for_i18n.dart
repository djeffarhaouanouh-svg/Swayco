import 'app_strings.dart';

/// Display translations for looking-for keys (French labels from `looking_for.dart`).
const Map<String, Map<String, String>> _kLookingForI18n = {
  'Amitié': {
    'en': 'Friendship', 'es': 'Amistad', 'de': 'Freundschaft',
    'it': 'Amicizia', 'pt': 'Amizade', 'nl': 'Vriendschap',
    'ar': 'صداقة', 'ru': 'Дружба', 'zh': '友情', 'ja': '友達', 'ko': '우정',
  },
  'Une relation': {
    'en': 'A relationship', 'es': 'Una relación', 'de': 'Eine Beziehung',
    'it': 'Una relazione', 'pt': 'Um relacionamento', 'nl': 'Een relatie',
    'ar': 'علاقة', 'ru': 'Отношения', 'zh': '恋爱关系', 'ja': '恋愛',
    'ko': '연애',
  },
  'Du fun': {
    'en': 'Something fun', 'es': 'Diversión', 'de': 'Spaß',
    'it': 'Divertimento', 'pt': 'Diversão', 'nl': 'Plezier',
    'ar': 'مرح', 'ru': 'Веселье', 'zh': '找乐子', 'ja': '楽しさ',
    'ko': '재미',
  },
  'Je ne sais pas encore': {
    'en': 'Not sure yet', 'es': 'Aún no lo sé', 'de': 'Weiß ich noch nicht',
    'it': 'Non lo so ancora', 'pt': 'Ainda não sei', 'nl': 'Weet ik nog niet',
    'ar': 'لست متأكدًا بعد', 'ru': 'Пока не знаю', 'zh': '还不确定',
    'ja': 'まだわからない', 'ko': '아직 잘 모르겠음',
  },
};

String lookingForLabel(String key) {
  final lang = AppStrings.currentBcp47.value;
  if (lang == 'fr') return key;
  return _kLookingForI18n[key]?[lang] ?? key;
}
