import 'app_strings.dart';

/// Display translations for zodiac sign keys (French labels from `zodiac.dart`).
const Map<String, Map<String, String>> _kZodiacI18n = {
  'Bélier': {
    'en': 'Aries', 'es': 'Aries', 'de': 'Widder', 'it': 'Ariete',
    'pt': 'Áries', 'nl': 'Ram', 'ar': 'الحمل', 'ru': 'Овен',
    'zh': '白羊座', 'ja': '牡羊座', 'ko': '양자리',
  },
  'Taureau': {
    'en': 'Taurus', 'es': 'Tauro', 'de': 'Stier', 'it': 'Toro',
    'pt': 'Touro', 'nl': 'Stier', 'ar': 'الثور', 'ru': 'Телец',
    'zh': '金牛座', 'ja': '牡牛座', 'ko': '황소자리',
  },
  'Gémeaux': {
    'en': 'Gemini', 'es': 'Géminis', 'de': 'Zwillinge', 'it': 'Gemelli',
    'pt': 'Gêmeos', 'nl': 'Tweelingen', 'ar': 'الجوزاء', 'ru': 'Близнецы',
    'zh': '双子座', 'ja': '双子座', 'ko': '쌍둥이자리',
  },
  'Cancer': {
    'en': 'Cancer', 'es': 'Cáncer', 'de': 'Krebs', 'it': 'Cancro',
    'pt': 'Câncer', 'nl': 'Kreeft', 'ar': 'السرطان', 'ru': 'Рак',
    'zh': '巨蟹座', 'ja': '蟹座', 'ko': '게자리',
  },
  'Lion': {
    'en': 'Leo', 'es': 'Leo', 'de': 'Löwe', 'it': 'Leone',
    'pt': 'Leão', 'nl': 'Leeuw', 'ar': 'الأسد', 'ru': 'Лев',
    'zh': '狮子座', 'ja': '獅子座', 'ko': '사자자리',
  },
  'Vierge': {
    'en': 'Virgo', 'es': 'Virgo', 'de': 'Jungfrau', 'it': 'Vergine',
    'pt': 'Virgem', 'nl': 'Maagd', 'ar': 'العذراء', 'ru': 'Дева',
    'zh': '处女座', 'ja': '乙女座', 'ko': '처녀자리',
  },
  'Balance': {
    'en': 'Libra', 'es': 'Libra', 'de': 'Waage', 'it': 'Bilancia',
    'pt': 'Libra', 'nl': 'Weegschaal', 'ar': 'الميزان', 'ru': 'Весы',
    'zh': '天秤座', 'ja': '天秤座', 'ko': '천칭자리',
  },
  'Scorpion': {
    'en': 'Scorpio', 'es': 'Escorpio', 'de': 'Skorpion', 'it': 'Scorpione',
    'pt': 'Escorpião', 'nl': 'Schorpioen', 'ar': 'العقرب', 'ru': 'Скорпион',
    'zh': '天蝎座', 'ja': '蠍座', 'ko': '전갈자리',
  },
  'Sagittaire': {
    'en': 'Sagittarius', 'es': 'Sagitario', 'de': 'Schütze', 'it': 'Sagittario',
    'pt': 'Sagitário', 'nl': 'Boogschutter', 'ar': 'القوس', 'ru': 'Стрелец',
    'zh': '射手座', 'ja': '射手座', 'ko': '사수자리',
  },
  'Capricorne': {
    'en': 'Capricorn', 'es': 'Capricornio', 'de': 'Steinbock', 'it': 'Capricorno',
    'pt': 'Capricórnio', 'nl': 'Steenbok', 'ar': 'الجدي', 'ru': 'Козерог',
    'zh': '摩羯座', 'ja': '山羊座', 'ko': '염소자리',
  },
  'Verseau': {
    'en': 'Aquarius', 'es': 'Acuario', 'de': 'Wassermann', 'it': 'Acquario',
    'pt': 'Aquário', 'nl': 'Waterman', 'ar': 'الدلو', 'ru': 'Водолей',
    'zh': '水瓶座', 'ja': '水瓶座', 'ko': '물병자리',
  },
  'Poissons': {
    'en': 'Pisces', 'es': 'Piscis', 'de': 'Fische', 'it': 'Pesci',
    'pt': 'Peixes', 'nl': 'Vissen', 'ar': 'الحوت', 'ru': 'Рыбы',
    'zh': '双鱼座', 'ja': '魚座', 'ko': '물고기자리',
  },
};

String zodiacLabel(String key) {
  final lang = AppStrings.currentBcp47.value;
  if (lang == 'fr') return key;
  return _kZodiacI18n[key]?[lang] ?? key;
}

/// Short month labels (1 = January) for the zodiac date hint.
const Map<String, List<String>> _kMonthAbbrev = {
  'fr': [
    'janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin',
    'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.',
  ],
  'en': [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ],
  'es': [
    'ene.', 'feb.', 'mar.', 'abr.', 'may.', 'jun.',
    'jul.', 'ago.', 'sept.', 'oct.', 'nov.', 'dic.',
  ],
  'de': [
    'Jan.', 'Feb.', 'Mär.', 'Apr.', 'Mai', 'Jun.',
    'Jul.', 'Aug.', 'Sep.', 'Okt.', 'Nov.', 'Dez.',
  ],
  'it': [
    'gen.', 'feb.', 'mar.', 'apr.', 'mag.', 'giu.',
    'lug.', 'ago.', 'set.', 'ott.', 'nov.', 'dic.',
  ],
  'pt': [
    'jan.', 'fev.', 'mar.', 'abr.', 'mai.', 'jun.',
    'jul.', 'ago.', 'set.', 'out.', 'nov.', 'dez.',
  ],
  'nl': [
    'jan.', 'feb.', 'mrt.', 'apr.', 'mei', 'jun.',
    'jul.', 'aug.', 'sep.', 'okt.', 'nov.', 'dec.',
  ],
  'ar': [
    'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
    'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر',
  ],
  'ru': [
    'янв.', 'февр.', 'мар.', 'апр.', 'мая', 'июн.',
    'июл.', 'авг.', 'сент.', 'окт.', 'нояб.', 'дек.',
  ],
  'zh': [
    '1月', '2月', '3月', '4月', '5月', '6月',
    '7月', '8月', '9月', '10月', '11月', '12月',
  ],
  'ja': [
    '1月', '2月', '3月', '4月', '5月', '6月',
    '7月', '8月', '9月', '10月', '11月', '12月',
  ],
  'ko': [
    '1월', '2월', '3월', '4월', '5월', '6월',
    '7월', '8월', '9월', '10월', '11월', '12월',
  ],
};

/// Localised short month name for [month] (1–12).
String monthAbbrev(int month) {
  final m = month.clamp(1, 12);
  final lang = AppStrings.currentBcp47.value;
  final list = _kMonthAbbrev[lang] ?? _kMonthAbbrev['en']!;
  return list[m - 1];
}
