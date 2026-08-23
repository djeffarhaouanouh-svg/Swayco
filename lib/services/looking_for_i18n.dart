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
  "Rencontrer d'autres cultures": {
    'en': 'Meet other cultures', 'es': 'Conocer otras culturas',
    'de': 'Andere Kulturen kennenlernen', 'it': 'Conoscere altre culture',
    'pt': 'Conhecer outras culturas', 'nl': 'Andere culturen ontmoeten',
    'ar': 'التعرف على ثقافات أخرى', 'ru': 'Знакомство с другими культурами',
    'zh': '认识其他文化', 'ja': '他の文化と出会う', 'ko': '다른 문화 만나기',
  },
  'Pratiquer une langue': {
    'en': 'Practice a language', 'es': 'Practicar un idioma',
    'de': 'Eine Sprache üben', 'it': 'Praticare una lingua',
    'pt': 'Praticar um idioma', 'nl': 'Een taal oefenen',
    'ar': 'ممارسة لغة', 'ru': 'Практика языка', 'zh': '练习语言',
    'ja': '語学の練習', 'ko': '언어 연습',
  },
  'Faire des activités ensemble': {
    'en': 'Do activities together', 'es': 'Hacer actividades juntos',
    'de': 'Gemeinsam Aktivitäten machen', 'it': 'Fare attività insieme',
    'pt': 'Fazer atividades juntos', 'nl': 'Samen activiteiten doen',
    'ar': 'القيام بأنشطة معًا', 'ru': 'Совместные занятия',
    'zh': '一起参加活动', 'ja': '一緒に活動する', 'ko': '함께 활동하기',
  },
  'Trouver des gamers': {
    'en': 'Find gaming buddies', 'es': 'Encontrar compañeros de juego',
    'de': 'Gaming-Buddies finden', 'it': 'Trovare compagni di gioco',
    'pt': 'Encontrar parceiros de jogo', 'nl': "Gamebuddy's vinden",
    'ar': 'العثور على أصدقاء الألعاب', 'ru': 'Найти игровых друзей',
    'zh': '寻找游戏搭子', 'ja': 'ゲーム仲間を探す', 'ko': '게임 친구 찾기',
  },
  'Networking': {
    'en': 'Networking', 'es': 'Contactos profesionales', 'de': 'Networking',
    'it': 'Networking', 'pt': 'Networking', 'nl': 'Netwerken',
    'ar': 'التواصل المهني', 'ru': 'Нетворкинг', 'zh': '人脉拓展',
    'ja': 'ネットワーキング', 'ko': '네트워킹',
  },
  'Voyager / rencontrer des locaux': {
    'en': 'Travel / meet locals', 'es': 'Viajar / conocer locales',
    'de': 'Reisen / Einheimische treffen',
    'it': 'Viaggiare / conoscere gente del posto',
    'pt': 'Viajar / conhecer locais', 'nl': 'Reizen / locals ontmoeten',
    'ar': 'السفر / التعرف على السكان المحليين',
    'ru': 'Путешествия / знакомство с местными',
    'zh': '旅行 / 结识当地人', 'ja': '旅行・現地の人と出会う',
    'ko': '여행 / 현지인 만나기',
  },
};

String lookingForLabel(String key) {
  final lang = AppStrings.currentBcp47.value;
  if (lang == 'fr') return key;
  return _kLookingForI18n[key]?[lang] ?? key;
}
