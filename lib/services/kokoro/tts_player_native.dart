import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

import 'voice_downloader.dart';

// ─────────────────────────── Kokoro vocabulary ───────────────────────────────
// Mirrors hexgrad/kokoro tokenize.py.  Characters absent from the map are
// silently dropped, so the tokenizer is safe with any phonemizer output.

const _kPunct = ';:,.!?¡¿—…"«»“” ';
const _kLetters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
const _kIpa =
    'ɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈθʦʧʨʉʌʍɣɤʏijkmnopqrstʊʋ';

final Map<String, int> _vocab = _buildVocab();

Map<String, int> _buildVocab() {
  final syms = <String>[r'$'];
  for (final r in _kPunct.runes) { syms.add(String.fromCharCode(r)); }
  for (final r in _kLetters.runes) { syms.add(String.fromCharCode(r)); }
  for (final r in _kIpa.runes) { syms.add(String.fromCharCode(r)); }
  final map = <String, int>{};
  for (var i = 0; i < syms.length; i++) {
    map[syms[i]] = i;
  }
  return map;
}

List<int> _tokenize(String phonemes) {
  final v = _vocab;
  final ids = <int>[];
  for (final r in phonemes.runes) {
    final id = v[String.fromCharCode(r)];
    if (id != null) ids.add(id);
  }
  return ids;
}

// ─────────────────────────── Phonemizers ─────────────────────────────────────

String _phonemize(String text, String langCode) {
  final lc = langCode.toLowerCase().split(RegExp(r'[-_]')).first;
  return switch (lc) {
    'ja' => _phonemizeJa(text),
    'fr' => _phonemizeFr(text),
    'es' => _phonemizeEs(text),
    'it' => _phonemizeIt(text),
    'pt' => _phonemizePt(text),
    'de' => _phonemizeDe(text),
    'ko' => _phonemizeKo(text),
    'zh' => _phonemizeZh(text),
    _ => _phonemizeEn(text),
  };
}

// ── English ───────────────────────────────────────────────────────────────────
// Common words table + digraph substitutions. Vowels are left as ASCII letters
// (they're in the Kokoro vocab); only consonant clusters and function words are
// phonemized to IPA for better accuracy.

const _enWords = <String, String>{
  'the': 'ðə', 'a': 'ə', 'an': 'ən', 'and': 'ænd', 'or': 'ɔɾ',
  'of': 'ʌv', 'in': 'ɪn', 'is': 'ɪz', 'it': 'ɪt', 'to': 'tə',
  'you': 'ju', 'i': 'aɪ', 'he': 'hiː', 'she': 'ʃiː', 'we': 'wiː',
  'they': 'ðeɪ', 'was': 'wʌz', 'are': 'ɑɾ', 'for': 'fɔɾ',
  'on': 'ɔn', 'at': 'æt', 'be': 'biː', 'have': 'hæv',
  'with': 'wɪð', 'this': 'ðɪs', 'that': 'ðæt', 'from': 'fɾʌm',
  'not': 'nɔt', 'but': 'bʌt', 'as': 'æz', 'do': 'duː',
  'my': 'maɪ', 'your': 'jɔɾ', 'his': 'hɪz', 'her': 'hɜɾ',
  'our': 'aʊɾ', 'their': 'ðɛɾ', 'what': 'wʌt', 'which': 'wɪtʃ',
  'who': 'huː', 'how': 'haʊ', 'when': 'wɛn', 'where': 'wɛɾ',
  'why': 'waɪ', 'can': 'kæn', 'will': 'wɪl', 'would': 'wʊd',
  'could': 'kʊd', 'should': 'ʃʊd', 'may': 'meɪ', 'might': 'maɪt',
  'yes': 'jɛs', 'no': 'noʊ', 'hello': 'həloʊ', 'hi': 'haɪ',
  'good': 'ɡʊd', 'ok': 'oʊkeɪ', 'okay': 'oʊkeɪ', 'please': 'pliːz',
  'thank': 'θæŋk', 'thanks': 'θæŋks', 'sorry': 'sɔɾi',
  'know': 'noʊ', 'think': 'θɪŋk', 'like': 'laɪk', 'want': 'wɔnt',
  'need': 'niːd', 'see': 'siː', 'come': 'kʌm', 'go': 'ɡoʊ',
  'get': 'ɡɛt', 'make': 'meɪk', 'time': 'taɪm', 'day': 'deɪ',
  'now': 'naʊ', 'about': 'əbaʊt', 'so': 'soʊ', 'very': 'vɛɾi',
  'just': 'dʒʌst', 'some': 'sʌm', 'more': 'mɔɾ', 'well': 'wɛl',
  'people': 'piːpəl', 'love': 'lʌv', 'help': 'hɛlp', 'right': 'ɾaɪt',
  'here': 'hɪɾ', 'there': 'ðɛɾ', 'new': 'njuː', 'old': 'oʊld',
  'big': 'bɪɡ', 'little': 'lɪtəl', 'first': 'fɜɾst', 'last': 'læst',
  'long': 'lɔŋ', 'great': 'ɡɾeɪt', 'own': 'oʊn', 'same': 'seɪm',
  'after': 'æftɜɾ', 'back': 'bæk', 'other': 'ʌðɜɾ', 'through': 'θɾuː',
  'much': 'mʌtʃ', 'before': 'bɪfɔɾ', 'between': 'bɪtwiːn',
  "i'm": 'aɪm', "you're": 'jɔɾ', "it's": 'ɪts', "don't": 'doʊnt',
  "can't": 'kænt', "won't": 'woʊnt', "i'll": 'aɪl', "we're": 'wɪɾ',
  'speak': 'spiːk', 'talk': 'tɔːk', 'say': 'seɪ', 'tell': 'tɛl',
  'call': 'kɔːl', 'look': 'lʊk', 'use': 'juːz',
  'find': 'faɪnd', 'give': 'ɡɪv', 'take': 'teɪk', 'live': 'lɪv',
  'feel': 'fiːl', 'try': 'tɾaɪ', 'ask': 'æsk', 'seem': 'siːm',
  'leave': 'liːv', 'keep': 'kiːp', 'let': 'lɛt',
  'begin': 'bɪɡɪn', 'show': 'ʃoʊ', 'hear': 'hɪɾ', 'play': 'pleɪ',
  'run': 'ɾʌn', 'move': 'muːv', 'walk': 'wɔːk',
};

String _phonemizeEn(String text) {
  final lower = text.toLowerCase();
  final words = lower.split(RegExp(r'(\s+)'));
  return words.map((w) {
    final clean = w.replaceAll(RegExp(r"[^a-z']"), '');
    return _enWords[clean] ?? _englishG2P(w);
  }).join('');
}

String _englishG2P(String word) {
  return word
      .replaceAll('tion', 'ʃən')
      .replaceAll('sion', 'ʒən')
      .replaceAll('tch', 'tʃ')
      .replaceAll('ph', 'f')
      .replaceAll('sh', 'ʃ')
      .replaceAll('ch', 'tʃ')
      .replaceAll('th', 'ð')
      .replaceAll('ng', 'ŋ')
      .replaceAll('ck', 'k')
      .replaceAll('wh', 'w')
      .replaceAll('gh', '')
      .replaceAll('kn', 'n')
      .replaceAll('wr', 'ɾ')
      .replaceAll('qu', 'kw')
      .replaceAll('ee', 'iː')
      .replaceAll('oo', 'uː')
      .replaceAll('ai', 'eɪ')
      .replaceAll('ay', 'eɪ')
      .replaceAll('oi', 'ɔɪ')
      .replaceAll('ou', 'aʊ')
      .replaceAll('ow', 'aʊ')
      .replaceAll('igh', 'aɪ');
}

// ── French ────────────────────────────────────────────────────────────────────

String _phonemizeFr(String text) {
  var t = text.toLowerCase();

  // Accented vowels
  t = t
      .replaceAll('é', 'e')
      .replaceAll('è', 'ɛ')
      .replaceAll('ê', 'ɛ')
      .replaceAll('ë', 'ɛ')
      .replaceAll('à', 'a')
      .replaceAll('â', 'a')
      .replaceAll('ô', 'o')
      .replaceAll('î', 'i')
      .replaceAll('ï', 'i')
      .replaceAll('û', 'y')
      .replaceAll('ü', 'y')
      .replaceAll('ù', 'y')
      .replaceAll('œ', 'ø')
      .replaceAll('æ', 'ɛ')
      .replaceAll('ç', 's');

  // Multi-char vowel groups FIRST
  t = t.replaceAll('eau', 'o');
  t = t.replaceAll('ien', 'jɛŋ');
  t = t.replaceAll('oin', 'wɛŋ');

  // Nasal vowels — must precede nasal consonant or be final
  t = t.replaceAllMapped(
    RegExp(r'(an|am|en|em)(?=[^aeiouyɛøɔ]|$)'),
    (_) => 'ɑŋ',
  );
  t = t.replaceAllMapped(
    RegExp(r'(in|im|ain|aim|ein|yn|ym)(?=[^aeiouyɛøɔ]|$)'),
    (_) => 'ɛŋ',
  );
  t = t.replaceAllMapped(
    RegExp(r'(on|om)(?=[^aeiouyɛøɔ]|$)'),
    (_) => 'ɔŋ',
  );
  t = t.replaceAllMapped(
    RegExp(r'(un|um)(?=[^aeiouyɛøɔ]|$)'),
    (_) => 'øŋ',
  );

  // Vowel digraphs
  t = t.replaceAll('au', 'o');
  t = t.replaceAll('ou', 'u');
  t = t.replaceAll('oi', 'wa');
  t = t.replaceAll('eu', 'ø');
  t = t.replaceAll('ai', 'ɛ');
  t = t.replaceAll('ei', 'ɛ');

  // Consonant digraphs
  t = t.replaceAll('ch', 'ʃ');
  t = t.replaceAll('gn', 'ɲ');
  t = t.replaceAll('ph', 'f');
  t = t.replaceAll('tion', 'sjɔŋ');

  // qu → k (silent u after q)
  t = t.replaceAll('qu', 'k');

  // gu before e/i → g (silent u)
  t = t.replaceAllMapped(
    RegExp(r'gu([eiɛ])'),
    (m) => 'g${m.group(1)}',
  );

  // c before front vowels → s
  t = t.replaceAllMapped(
    RegExp(r'c([eiɛøy])'),
    (m) => 's${m.group(1)}',
  );
  t = t.replaceAll('c', 'k');

  // g before front vowels → ʒ
  t = t.replaceAllMapped(
    RegExp(r'g([eiɛøy])'),
    (m) => 'ʒ${m.group(1)}',
  );

  t = t
      .replaceAll('j', 'ʒ')
      .replaceAll('r', 'ʁ')
      .replaceAll('u', 'y') // French u → y
      .replaceAll('x', 'ks');

  // Drop common silent final consonants (not c/r/f/l in most cases)
  t = t.replaceAllMapped(
    RegExp(r'([bdgmnpst])\b'),
    (m) => '',
  );

  return t;
}

// ── Spanish ───────────────────────────────────────────────────────────────────

String _phonemizeEs(String text) {
  var t = text.toLowerCase();
  t = t
      .replaceAll('á', 'a')
      .replaceAll('é', 'e')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ü', 'u')
      .replaceAll('ñ', 'ɲ')
      .replaceAll('ll', 'j')
      .replaceAll('ch', 'tʃ')
      .replaceAll('rr', 'r')
      .replaceAll('qu', 'k')
      .replaceAll('gu', 'g');
  t = t.replaceAllMapped(
    RegExp(r'c([eiéí])'),
    (m) => 's${m.group(1)}',
  );
  t = t.replaceAllMapped(
    RegExp(r'g([eiéí])'),
    (m) => 'x${m.group(1)}',
  );
  t = t
      .replaceAll('j', 'x')
      .replaceAll('v', 'b')
      .replaceAll('z', 's')
      .replaceAll('h', '');
  return t;
}

// ── Italian ───────────────────────────────────────────────────────────────────

String _phonemizeIt(String text) {
  var t = text.toLowerCase();
  t = t
      .replaceAll('à', 'a')
      .replaceAll('è', 'ɛ')
      .replaceAll('é', 'e')
      .replaceAll('ì', 'i')
      .replaceAll('í', 'i')
      .replaceAll('ò', 'ɔ')
      .replaceAll('ó', 'o')
      .replaceAll('ù', 'u')
      .replaceAll('ú', 'u')
      .replaceAll('gli', 'ʎi')
      .replaceAll('gl', 'ʎ')
      .replaceAll('gn', 'ɲ')
      .replaceAll('sci', 'ʃi')
      .replaceAll('sce', 'ʃe')
      .replaceAll('sc', 'sk')
      .replaceAll('ch', 'k')
      .replaceAll('gh', 'g');
  t = t.replaceAllMapped(
    RegExp(r'c([eiɛ])'),
    (m) => 'tʃ${m.group(1)}',
  );
  t = t.replaceAllMapped(
    RegExp(r'g([eiɛ])'),
    (m) => 'dʒ${m.group(1)}',
  );
  t = t
      .replaceAll('z', 'ts')
      .replaceAll('r', 'ɾ');
  return t;
}

// ── Portuguese ────────────────────────────────────────────────────────────────

String _phonemizePt(String text) {
  var t = text.toLowerCase();
  t = t
      .replaceAll('ã', 'ɐ̃')
      .replaceAll('â', 'a')
      .replaceAll('á', 'a')
      .replaceAll('à', 'a')
      .replaceAll('ê', 'e')
      .replaceAll('é', 'ɛ')
      .replaceAll('í', 'i')
      .replaceAll('î', 'i')
      .replaceAll('ô', 'o')
      .replaceAll('ó', 'ɔ')
      .replaceAll('õ', 'õ')
      .replaceAll('ú', 'u')
      .replaceAll('ü', 'u')
      .replaceAll('ç', 's')
      .replaceAll('nh', 'ɲ')
      .replaceAll('lh', 'ʎ')
      .replaceAll('ch', 'ʃ')
      .replaceAll('ss', 's')
      .replaceAll('rr', 'x');
  t = t.replaceAllMapped(
    RegExp(r'c([eiéê])'),
    (m) => 's${m.group(1)}',
  );
  t = t
      .replaceAll('c', 'k')
      .replaceAll('j', 'ʒ')
      .replaceAll('x', 'ʃ');
  return t;
}

// ── German ────────────────────────────────────────────────────────────────────

String _phonemizeDe(String text) {
  var t = text.toLowerCase();
  t = t
      .replaceAll('ä', 'ɛ')
      .replaceAll('ö', 'ø')
      .replaceAll('ü', 'y')
      .replaceAll('ß', 'ss')
      .replaceAll('sch', 'ʃ')
      .replaceAll('ch', 'x')
      .replaceAll('ck', 'k')
      .replaceAll('th', 't')
      .replaceAll('qu', 'kv')
      .replaceAll('ei', 'aɪ')
      .replaceAll('eu', 'ɔɪ')
      .replaceAll('au', 'aʊ')
      .replaceAll('ie', 'iː')
      .replaceAll('sp', 'ʃp')
      .replaceAll('st', 'ʃt')
      .replaceAll('ng', 'ŋ')
      .replaceAll('nk', 'ŋk')
      .replaceAll('v', 'f')
      .replaceAll('w', 'v')
      .replaceAll('j', 'j')
      .replaceAll('z', 'ts')
      .replaceAll('r', 'ɾ');
  return t;
}

// ── Korean ────────────────────────────────────────────────────────────────────
// Simplified Hangul → Latin approximation. Full romanization is complex;
// this covers initial consonants + vowels for common syllable blocks.

const _koInitial = <String, String>{
  'ㄱ': 'k', 'ㄴ': 'n', 'ㄷ': 't', 'ㄹ': 'ɾ', 'ㅁ': 'm',
  'ㅂ': 'p', 'ㅅ': 's', 'ㅇ': '', 'ㅈ': 'tɕ', 'ㅊ': 'tɕʰ',
  'ㅋ': 'kʰ', 'ㅌ': 'tʰ', 'ㅍ': 'pʰ', 'ㅎ': 'h',
  'ㄲ': 'k', 'ㄸ': 't', 'ㅃ': 'p', 'ㅆ': 's', 'ㅉ': 'tɕ',
};
const _koVowel = <String, String>{
  'ㅏ': 'a', 'ㅐ': 'ɛ', 'ㅑ': 'ja', 'ㅒ': 'jɛ', 'ㅓ': 'ɔ',
  'ㅔ': 'e', 'ㅕ': 'jɔ', 'ㅖ': 'je', 'ㅗ': 'o', 'ㅘ': 'wa',
  'ㅙ': 'wɛ', 'ㅚ': 'we', 'ㅛ': 'jo', 'ㅜ': 'u', 'ㅝ': 'wɔ',
  'ㅞ': 'we', 'ㅟ': 'wi', 'ㅠ': 'ju', 'ㅡ': 'ɯ', 'ㅢ': 'ɯi',
  'ㅣ': 'i',
};

String _phonemizeKo(String text) {
  final buf = StringBuffer();
  for (final r in text.runes) {
    final c = r - 0xAC00;
    if (c >= 0 && c < 11172) {
      // Hangul syllable block
      final init = c ~/ 588;
      final vowIdx = (c % 588) ~/ 28;
      final initials = [
        'ㄱ','ㄲ','ㄴ','ㄷ','ㄸ','ㄹ','ㅁ','ㅂ','ㅃ','ㅅ','ㅆ','ㅇ',
        'ㅈ','ㅉ','ㅊ','ㅋ','ㅌ','ㅍ','ㅎ',
      ];
      final vowels = [
        'ㅏ','ㅐ','ㅑ','ㅒ','ㅓ','ㅔ','ㅕ','ㅖ','ㅗ','ㅘ','ㅙ','ㅚ',
        'ㅛ','ㅜ','ㅝ','ㅞ','ㅟ','ㅠ','ㅡ','ㅢ','ㅣ',
      ];
      if (init < initials.length && vowIdx < vowels.length) {
        buf.write(_koInitial[initials[init]] ?? '');
        buf.write(_koVowel[vowels[vowIdx]] ?? '');
      }
    } else {
      buf.write(String.fromCharCode(r));
    }
  }
  return buf.toString();
}

// ── Japanese ──────────────────────────────────────────────────────────────────
// Complete hiragana + katakana → IPA. The mapping exactly covers the modern
// kana chart including contracted sounds (youon).

const _jaMap = <String, String>{
  // Hiragana — basic
  'あ':'a','い':'i','う':'ɯ','え':'e','お':'o',
  'か':'ka','き':'ki','く':'kɯ','け':'ke','こ':'ko',
  'さ':'sa','し':'ɕi','す':'sɯ','せ':'se','そ':'so',
  'た':'ta','ち':'tɕi','つ':'tsɯ','て':'te','と':'to',
  'な':'na','に':'ni','ぬ':'nɯ','ね':'ne','の':'no',
  'は':'ha','ひ':'hi','ふ':'ɸɯ','へ':'he','ほ':'ho',
  'ま':'ma','み':'mi','む':'mɯ','め':'me','も':'mo',
  'や':'ja','ゆ':'jɯ','よ':'jo',
  'ら':'ɾa','り':'ɾi','る':'ɾɯ','れ':'ɾe','ろ':'ɾo',
  'わ':'wa','ゐ':'i','ゑ':'e','を':'o',
  'ん':'n',
  // Voiced
  'が':'ɡa','ぎ':'ɡi','ぐ':'ɡɯ','げ':'ɡe','ご':'ɡo',
  'ざ':'dza','じ':'dʑi','ず':'dzɯ','ぜ':'dze','ぞ':'dzo',
  'だ':'da','ぢ':'dʑi','づ':'dzɯ','で':'de','ど':'do',
  'ば':'ba','び':'bi','ぶ':'bɯ','べ':'be','ぼ':'bo',
  // Semi-voiced
  'ぱ':'pa','ぴ':'pi','ぷ':'pɯ','ぺ':'pe','ぽ':'po',
  // Contracted (youon) — hiragana
  'きゃ':'kja','きゅ':'kjɯ','きょ':'kjo',
  'しゃ':'ɕa','しゅ':'ɕɯ','しょ':'ɕo',
  'ちゃ':'tɕa','ちゅ':'tɕɯ','ちょ':'tɕo',
  'にゃ':'nja','にゅ':'njɯ','にょ':'njo',
  'ひゃ':'hja','ひゅ':'hjɯ','ひょ':'hjo',
  'みゃ':'mja','みゅ':'mjɯ','みょ':'mjo',
  'りゃ':'ɾja','りゅ':'ɾjɯ','りょ':'ɾjo',
  'ぎゃ':'ɡja','ぎゅ':'ɡjɯ','ぎょ':'ɡjo',
  'じゃ':'dʑa','じゅ':'dʑɯ','じょ':'dʑo',
  'びゃ':'bja','びゅ':'bjɯ','びょ':'bjo',
  'ぴゃ':'pja','ぴゅ':'pjɯ','ぴょ':'pjo',
  // Katakana — basic
  'ア':'a','イ':'i','ウ':'ɯ','エ':'e','オ':'o',
  'カ':'ka','キ':'ki','ク':'kɯ','ケ':'ke','コ':'ko',
  'サ':'sa','シ':'ɕi','ス':'sɯ','セ':'se','ソ':'so',
  'タ':'ta','チ':'tɕi','ツ':'tsɯ','テ':'te','ト':'to',
  'ナ':'na','ニ':'ni','ヌ':'nɯ','ネ':'ne','ノ':'no',
  'ハ':'ha','ヒ':'hi','フ':'ɸɯ','ヘ':'he','ホ':'ho',
  'マ':'ma','ミ':'mi','ム':'mɯ','メ':'me','モ':'mo',
  'ヤ':'ja','ユ':'jɯ','ヨ':'jo',
  'ラ':'ɾa','リ':'ɾi','ル':'ɾɯ','レ':'ɾe','ロ':'ɾo',
  'ワ':'wa','ヲ':'o',
  'ン':'n',
  // Voiced katakana
  'ガ':'ɡa','ギ':'ɡi','グ':'ɡɯ','ゲ':'ɡe','ゴ':'ɡo',
  'ザ':'dza','ジ':'dʑi','ズ':'dzɯ','ゼ':'dze','ゾ':'dzo',
  'ダ':'da','ヂ':'dʑi','ヅ':'dzɯ','デ':'de','ド':'do',
  'バ':'ba','ビ':'bi','ブ':'bɯ','ベ':'be','ボ':'bo',
  'パ':'pa','ピ':'pi','プ':'pɯ','ペ':'pe','ポ':'po',
  // Long vowel mark
  'ー':'ː',
  // Small kana (youon base)
  'ャ':'ja','ュ':'jɯ','ョ':'jo',
  'ぁ':'a','ぃ':'i','ぅ':'ɯ','ぇ':'e','ぉ':'o',
  'ァ':'a','ィ':'i','ゥ':'ɯ','ェ':'e','ォ':'o',
};

String _phonemizeJa(String text) {
  final buf = StringBuffer();
  final chars = text.runes.map(String.fromCharCode).toList();
  var i = 0;
  while (i < chars.length) {
    // Try 2-char lookup first (youon contractions)
    if (i + 1 < chars.length) {
      final bigram = chars[i] + chars[i + 1];
      final hit = _jaMap[bigram];
      if (hit != null) {
        buf.write(hit);
        i += 2;
        continue;
      }
    }
    // Small tsu (っ/ッ) = geminate next consonant
    if (chars[i] == 'っ' || chars[i] == 'ッ') {
      if (i + 1 < chars.length) {
        final next = _jaMap[chars[i + 1]];
        if (next != null && next.isNotEmpty) buf.write(next[0]);
      }
      i++;
      continue;
    }
    final hit = _jaMap[chars[i]];
    if (hit != null) {
      buf.write(hit);
    } else {
      buf.write(chars[i]);
    }
    i++;
  }
  return buf.toString();
}

// ── Mandarin Chinese ─────────────────────────────────────────────────────────
// Very basic: passes pinyin/Latin through; drops hanzi (no pinyin lookup).

String _phonemizeZh(String text) {
  final buf = StringBuffer();
  for (final r in text.runes) {
    final c = String.fromCharCode(r);
    // Keep ASCII/Latin (pinyin) and punctuation; skip CJK ideographs
    if (r < 0x4E00 || r > 0x9FFF) buf.write(c);
  }
  return buf.toString();
}

// ─────────────────────────── WAV conversion ───────────────────────────────────

Uint8List _float32ToWav(Float32List samples, int sampleRate) {
  final numSamples = samples.length;
  final data = ByteData(44 + numSamples * 2);
  var o = 0;

  void setUint8(int v) => data.setUint8(o++, v);
  void setU16(int v) { data.setUint16(o, v, Endian.little); o += 2; }
  void setU32(int v) { data.setUint32(o, v, Endian.little); o += 4; }

  // RIFF
  setUint8(0x52); setUint8(0x49); setUint8(0x46); setUint8(0x46); // "RIFF"
  setU32(36 + numSamples * 2);
  setUint8(0x57); setUint8(0x41); setUint8(0x56); setUint8(0x45); // "WAVE"
  // fmt chunk
  setUint8(0x66); setUint8(0x6D); setUint8(0x74); setUint8(0x20); // "fmt "
  setU32(16);          // subchunk1 size
  setU16(1);           // PCM
  setU16(1);           // mono
  setU32(sampleRate);
  setU32(sampleRate * 2); // byte rate
  setU16(2);           // block align
  setU16(16);          // bits per sample
  // data chunk
  setUint8(0x64); setUint8(0x61); setUint8(0x74); setUint8(0x61); // "data"
  setU32(numSamples * 2);
  for (var i = 0; i < numSamples; i++) {
    final s = samples[i].clamp(-1.0, 1.0);
    data.setInt16(o, (s * 32767).round(), Endian.little);
    o += 2;
  }
  return data.buffer.asUint8List();
}

// ─────────────────────────── TtsPlayer ───────────────────────────────────────

class TtsPlayer {
  static const int _sampleRate = 24000;

  OrtSession? _session;
  final AudioPlayer _player = AudioPlayer();
  final Map<String, Float32List> _voiceCache = {};
  bool _inferring = false;

  // OrtSession wraps a native pointer and cannot cross isolate boundaries,
  // so we load synchronously (~1–3 s for the 21 MB quantised model).
  // Call this from a loading state — not from build() — to avoid jank.
  Future<void> loadModel(String modelPath) async {
    OrtEnv.instance.init();
    final opts = OrtSessionOptions();
    _session = OrtSession.fromFile(File(modelPath), opts);
    opts.release();
  }

  bool get isReady => _session != null;

  Future<void> speak(
    String text,
    String langCode,
    String voicePath,
  ) async {
    final session = _session;
    if (session == null) throw StateError('Kokoro model not loaded');
    if (_inferring) return; // Drop if already speaking
    _inferring = true;

    try {
      // Load voice embedding (cached)
      var voice = _voiceCache[voicePath];
      if (voice == null) {
        final bytes = await File(voicePath).readAsBytes();
        voice = VoiceDownloader.parseVoiceBytes(bytes);
        _voiceCache[voicePath] = voice;
      }

      // Phonemize + tokenize
      final phonemes = _phonemize(text, langCode);
      final ids = _tokenize(phonemes);
      if (ids.isEmpty) return;

      // Tokens: [0, ...ids, 0]  (BOS/EOS = pad token 0)
      final tokens = Int64List.fromList([0, ...ids, 0]);

      // Style: [1, 1, 256]. The voice file is a [510, 1, 256] table of style
      // embeddings indexed by *unpadded token count* — Kokoro conditions
      // prosody on utterance length. Row 0 is the embedding of an empty
      // sequence, so reading it for every phrase (as this used to) flattens
      // the prosody of all speech. The table stops at 510 tokens.
      const styleDim = 256;
      final rows = voice.length ~/ styleDim;
      final row = ids.length < rows ? ids.length : rows - 1;
      final styleData = Float32List(styleDim);
      for (var i = 0; i < styleDim; i++) {
        styleData[i] = voice[row * styleDim + i];
      }
      // Speed: [1]
      final speedData = Float32List.fromList([1.0]);

      final tokenTensor = OrtValueTensor.createTensorWithDataList(
        tokens,
        [1, tokens.length],
      );
      final styleTensor = OrtValueTensor.createTensorWithDataList(
        styleData,
        [1, 1, 256],
      );
      final speedTensor = OrtValueTensor.createTensorWithDataList(
        speedData,
        [1],
      );

      final runOpts = OrtRunOptions();
      final List<OrtValue?>? outputs = await session.runAsync(runOpts, {
        'tokens': tokenTensor,
        'style': styleTensor,
        'speed': speedTensor,
      });

      tokenTensor.release();
      styleTensor.release();
      speedTensor.release();
      runOpts.release();

      final list = outputs ?? <OrtValue?>[];
      Float32List? samples;
      final raw = list.isNotEmpty ? list.first?.value : null;
      if (raw is List && raw.isNotEmpty) {
        final inner = raw.first;
        if (inner is Float32List) {
          samples = inner;
        } else if (inner is List) {
          samples = Float32List.fromList(inner.cast<double>());
        }
      } else if (raw is Float32List) {
        samples = raw;
      }
      for (final v in list) {
        v?.release();
      }

      if (samples == null || samples.isEmpty) return;

      // Write WAV to a temp file and play
      final wav = _float32ToWav(samples, _sampleRate);
      final tmp = await getTemporaryDirectory();
      final wavFile = File('${tmp.path}/kokoro_out.wav');
      await wavFile.writeAsBytes(wav);

      await _player.stop();
      await _player.play(DeviceFileSource(wavFile.path));
    } finally {
      _inferring = false;
    }
  }

  /// Fires when the current utterance has finished playing.
  ///
  /// [speak] returns as soon as playback *starts* — audioplayers' `play()` does
  /// not await the end of the clip. Callers that need to know when the speaker
  /// actually goes quiet (the in-call half-duplex gate) listen here.
  Stream<void> get onPlaybackComplete => _player.onPlayerComplete;

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    await _player.dispose();
    _session?.release();
    _session = null;
  }
}

