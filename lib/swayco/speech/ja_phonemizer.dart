/// Deterministic katakana → (token ids, tone ids) phonemizer for the on-device
/// Japanese voice (see `docs/ja_tts_engine_plan.md`).
///
/// This is the pure-Dart half of the Japanese frontend. It is a faithful port of
/// the ja model `model/text/japanese.py` `kata2phoneme`, plus the token/tone assembly
/// that the `the ja model` ja neural export expects:
///   * phonemes wrapped with the `_` sil, tones all 0 (`num_ja_tones == 1`),
///   * every tone shifted by `tone_start` (= 6, from the export `metadata.json`),
///   * `add_blank == 1`: interleave the pad id (0) around every symbol.
/// Verified bit-for-bit against the Python reference on 14 golden vectors
/// (`test/data/ja_phonemizer_goldens.json`), incl. small-tsu and elongation.
///
/// **Upstream boundary (native the reading frontend).** The kanji→reading step is NOT here.
/// A native the reading frontend frontend converts arbitrary Japanese text into a *katakana
/// reading*, which is the input to [phonemizeKatakana]. Two contracts the reading
/// step must honour so this port stays faithful to the trained model:
///   1. Emit **kakasi-style long vowels as explicit vowel kana** (リョウリ), NOT
///      the chōonpu リョーリ. the ja model table maps `ー` to nothing, so an unnormalised
///      `ー` silently drops the long vowel. [expandChoonpu] does this normalisation
///      for readings that do contain `ー`.
///   2. Produce only characters this table knows (katakana + the handful of
///      punctuation marks); unknown symbols pass through and must exist in
///      `tokens.txt` or [phonemizeKatakana] throws.
library;

/// Result of phonemising: parallel token-id / tone-id sequences ready to feed the
/// ja neural model's `x` and `tones` inputs (already blank-interleaved).
class JaPhonemized {
  const JaPhonemized(this.tokenIds, this.toneIds);
  final List<int> tokenIds;
  final List<int> toneIds;
}

/// `tone_start` for Japanese, from the export `metadata.json`. JP has a single
/// tone (0); the model's global tone id for it is `0 + _toneStart`.
const int _toneStart = 6;

/// Pad / blank / sil token id (`_` → 0 in `tokens.txt`).
const int _padId = 0;

// ── katakana → phoneme rules (ported verbatim from the ja model `_CONVRULES`) ──────
// Values are the space-joined phoneme lists (already past the reference's
// `split(" ")[1:]`); an empty value contributes no phoneme (only `ー`).

const Map<String, String> _rule2 = {
  'アァ': 'a a', 'イィ': 'i i', 'イェ': 'i e', 'イャ': 'y a', 'ウァ': 'u a',
  'ウィ': 'w i', 'ウゥ': 'u:', 'ウェ': 'w e', 'ウォ': 'w o', 'エェ': 'e e',
  'オォ': 'o:', 'カァ': 'k a:', 'ガァ': 'g a:', 'キィ': 'k i:', 'キャ': 'ky a',
  'キュ': 'ky u', 'キョ': 'ky o', 'ギィ': 'g i:', 'ギャ': 'gy a', 'ギュ': 'gy u',
  'ギョ': 'gy o', 'クゥ': 'k u:', 'クャ': 'ky a', 'クュ': 'ky u', 'クョ': 'ky o',
  'グゥ': 'g u:', 'グャ': 'gy a', 'グュ': 'gy u', 'グョ': 'gy o', 'ケェ': 'k e:',
  'ゲェ': 'g e:', 'コォ': 'k o:', 'ゴォ': 'g o:', 'サァ': 's a:', 'ザァ': 'z a:',
  'シィ': 'sh i:', 'シェ': 'sh e', 'シャ': 'sh a', 'シュ': 'sh u', 'ショ': 'sh o',
  'ジィ': 'j i:', 'ジェ': 'j e', 'ジャ': 'j a', 'ジュ': 'j u', 'ジョ': 'j o',
  'スィ': 's i', 'スゥ': 's u:', 'スャ': 'sh a', 'スュ': 'sh u', 'スョ': 'sh o',
  'ズァ': 'z u a', 'ズィ': 'z i', 'ズゥ': 'z u', 'ズェ': 'z e', 'ズォ': 'z o',
  'ズャ': 'zy a', 'ズュ': 'zy u', 'ズョ': 'zy o', 'セェ': 's e:', 'ゼェ': 'z e:',
  'ソォ': 's o:', 'ゾォ': 'z o:', 'タァ': 't a:', 'ダァ': 'd a:', 'チィ': 'ch i:',
  'チェ': 'ch e', 'チャ': 'ch a', 'チュ': 'ch u', 'チョ': 'ch o', 'ヂィ': 'j i:',
  'ヂェ': 'j e', 'ヂャ': 'j a', 'ヂュ': 'j u', 'ヂョ': 'j o', 'ツァ': 'ts a',
  'ツィ': 'ts i', 'ツゥ': 'ts u:', 'ツェ': 'ts e', 'ツォ': 'ts o', 'ツャ': 'ch a',
  'ツュ': 'ch u', 'ツョ': 'ch o', 'ヅゥ': 'd u:', 'ヅャ': 'zy a', 'ヅュ': 'zy u',
  'ヅョ': 'zy o', 'ティ': 't i', 'テェ': 't e:', 'テャ': 'ty a', 'テュ': 'ty u',
  'テョ': 'ty o', 'ディ': 'd i', 'デェ': 'd e:', 'デャ': 'dy a', 'デュ': 'dy u',
  'デョ': 'dy o', 'トゥ': 't u', 'トォ': 't o:', 'トャ': 'ty a', 'トュ': 'ty u',
  'トョ': 'ty o', 'ドァ': 'd o a', 'ドゥ': 'd u', 'ドォ': 'd o:', 'ドャ': 'dy a',
  'ドュ': 'dy u', 'ドョ': 'dy o', 'ナァ': 'n a:', 'ニィ': 'n i:', 'ニャ': 'ny a',
  'ニュ': 'ny u', 'ニョ': 'ny o', 'ヌゥ': 'n u:', 'ヌャ': 'ny a', 'ヌュ': 'ny u',
  'ヌョ': 'ny o', 'ネェ': 'n e:', 'ノォ': 'n o:', 'ハァ': 'h a:', 'バァ': 'b a:',
  'パァ': 'p a:', 'ヒィ': 'h i:', 'ヒャ': 'hy a', 'ヒュ': 'hy u', 'ヒョ': 'hy o',
  'ビィ': 'b i:', 'ビャ': 'by a', 'ビュ': 'by u', 'ビョ': 'by o', 'ピィ': 'p i:',
  'ピャ': 'py a', 'ピュ': 'py u', 'ピョ': 'py o', 'ファ': 'f a', 'フィ': 'f i',
  'フゥ': 'f u', 'フェ': 'f e', 'フォ': 'f o', 'フャ': 'hy a', 'フュ': 'hy u',
  'フョ': 'hy o', 'ブゥ': 'b u:', 'ブュ': 'by u', 'プゥ': 'p u:', 'プャ': 'py a',
  'プュ': 'py u', 'プョ': 'py o', 'ヘェ': 'h e:', 'ベェ': 'b e:', 'ペェ': 'p e:',
  'ホォ': 'h o:', 'ボォ': 'b o:', 'ポォ': 'p o:', 'マァ': 'm a:', 'ミィ': 'm i:',
  'ミャ': 'my a', 'ミュ': 'my u', 'ミョ': 'my o', 'ムゥ': 'm u:', 'ムャ': 'my a',
  'ムュ': 'my u', 'ムョ': 'my o', 'メェ': 'm e:', 'モォ': 'm o:', 'ヤァ': 'y a:',
  'ユゥ': 'y u:', 'ユャ': 'y a:', 'ユュ': 'y u:', 'ユョ': 'y o:', 'ヨォ': 'y o:',
  'ラァ': 'r a:', 'リィ': 'r i:', 'リャ': 'ry a', 'リュ': 'ry u', 'リョ': 'ry o',
  'ルゥ': 'r u:', 'ルャ': 'ry a', 'ルュ': 'ry u', 'ルョ': 'ry o', 'レェ': 'r e:',
  'ロォ': 'r o:', 'ワァ': 'w a:', 'ヲォ': 'o:', 'ヴァ': 'b a', 'ヴィ': 'b i',
  'ヴェ': 'b e', 'ヴォ': 'b o', 'ヴュ': 'by u',
};

const Map<String, String> _rule1 = {
  '、': ',', '。': '.', 'ァ': 'a', 'ア': 'a', 'ィ': 'i', 'イ': 'i', 'ゥ': 'u',
  'ウ': 'u', 'ェ': 'e', 'エ': 'e', 'ォ': 'o', 'オ': 'o', 'カ': 'k a', 'ガ': 'g a',
  'キ': 'k i', 'ギ': 'g i', 'ク': 'k u', 'グ': 'g u', 'ケ': 'k e', 'ゲ': 'g e',
  'コ': 'k o', 'ゴ': 'g o', 'サ': 's a', 'ザ': 'z a', 'シ': 'sh i', 'ジ': 'j i',
  'ス': 's u', 'ズ': 'z u', 'セ': 's e', 'ゼ': 'z e', 'ソ': 's o', 'ゾ': 'z o',
  'タ': 't a', 'ダ': 'd a', 'チ': 'ch i', 'ヂ': 'j i', 'ッ': 'q', 'ツ': 'ts u',
  'ヅ': 'z u', 'テ': 't e', 'デ': 'd e', 'ト': 't o', 'ド': 'd o', 'ナ': 'n a',
  'ニ': 'n i', 'ヌ': 'n u', 'ネ': 'n e', 'ノ': 'n o', 'ハ': 'h a', 'バ': 'b a',
  'パ': 'p a', 'ヒ': 'h i', 'ビ': 'b i', 'ピ': 'p i', 'フ': 'f u', 'ブ': 'b u',
  'プ': 'p u', 'ヘ': 'h e', 'ベ': 'b e', 'ペ': 'p e', 'ホ': 'h o', 'ボ': 'b o',
  'ポ': 'p o', 'マ': 'm a', 'ミ': 'm i', 'ム': 'm u', 'メ': 'm e', 'モ': 'm o',
  'ャ': 'y a', 'ヤ': 'y a', 'ュ': 'y u', 'ユ': 'y u', 'ョ': 'y o', 'ヨ': 'y o',
  'ラ': 'r a', 'リ': 'r i', 'ル': 'r u', 'レ': 'r e', 'ロ': 'r o', 'ヮ': 'w a',
  'ワ': 'w a', 'ヰ': 'i', 'ヱ': 'e', 'ヲ': 'o', 'ン': 'N', 'ヴ': 'b u', 'ヶ': 'k e',
  '・': ',', 'ー': '', '煞': 'sh y a', '琦': 'ch i', '髙': 't a k a', '！': '!',
  '？': '?',
};

/// Greedy 2-then-1 katakana → phoneme conversion (the ja model `kata2phoneme`).
List<String> kataToPhonemes(String text) {
  text = text.trim();
  final res = <String>[];
  var i = 0;
  final n = text.length;
  while (i < n) {
    if (i + 2 <= n) {
      final two = text.substring(i, i + 2);
      final x = _rule2[two];
      if (x != null) {
        if (x.isNotEmpty) res.addAll(x.split(' '));
        i += 2;
        continue;
      }
    }
    final one = text.substring(i, i + 1);
    final x = _rule1[one];
    if (x != null) {
      if (x.isNotEmpty) res.addAll(x.split(' '));
      i += 1;
      continue;
    }
    res.add(one);
    i += 1;
  }
  return res;
}

/// Interleave [pad] before, between and after every element of [xs]
/// (the ja model `commons.intersperse`), for `add_blank == 1`.
List<int> _intersperse(List<int> xs, int pad) {
  final out = List<int>.filled(xs.length * 2 + 1, pad);
  for (var i = 0; i < xs.length; i++) {
    out[i * 2 + 1] = xs[i];
  }
  return out;
}

/// Convert a katakana [reading] into the model's blank-interleaved token and
/// tone id sequences, mapping phonemes through [tokens] (parsed from the voice
/// bundle's `tokens.txt`). Throws [ArgumentError] if a phoneme is missing from
/// [tokens] — that means the reading contained a symbol the voice can't speak.
JaPhonemized phonemizeKatakana(String reading, Map<String, int> tokens) {
  final phs = kataToPhonemes(reading);
  final phones = <String>['_', ...phs, '_'];
  final tokenIds = <int>[];
  for (final p in phones) {
    final id = tokens[p];
    if (id == null) {
      throw ArgumentError('phoneme "$p" not in tokens.txt (reading="$reading")');
    }
    tokenIds.add(id);
  }
  // JP tone is always 0 → 0 + _toneStart for every phone.
  final toneIds = List<int>.filled(phones.length, _toneStart);
  return JaPhonemized(
    _intersperse(tokenIds, _padId),
    _intersperse(toneIds, _padId),
  );
}

/// Parse a the runtime `tokens.txt` (`<symbol> <id>` per line) into a map. The
/// symbol may itself be a space, so split on the LAST space only.
Map<String, int> parseTokens(String contents) {
  final map = <String, int>{};
  for (final raw in contents.split('\n')) {
    final line = raw.replaceAll('\r', '');
    if (line.isEmpty) continue;
    final sp = line.lastIndexOf(' ');
    if (sp <= 0) continue;
    final sym = line.substring(0, sp);
    final id = int.tryParse(line.substring(sp + 1).trim());
    if (id != null) map[sym] = id;
  }
  return map;
}

// ── chōonpu (ー) normalisation ────────────────────────────────────────────────
// the reading frontend emits long vowels as `ー`; the ja model table drops it. Rewrite `ー` to
// the vowel kana that matches the previous mora so the trained phoneme sequence
// is preserved. The vowel is decided from the previous *character*'s row.

const Set<String> _aRow = {
  'ア','カ','ガ','サ','ザ','タ','ダ','ナ','ハ','バ','パ','マ','ヤ','ラ','ワ','ャ','ァ',
};
const Set<String> _iRow = {
  'イ','キ','ギ','シ','ジ','チ','ヂ','ニ','ヒ','ビ','ピ','ミ','リ','ヰ','ィ',
};
const Set<String> _uRow = {
  'ウ','ク','グ','ス','ズ','ツ','ヅ','ヌ','フ','ブ','プ','ム','ユ','ル','ュ','ゥ','ヴ',
};
const Set<String> _eRow = {
  'エ','ケ','ゲ','セ','ゼ','テ','デ','ネ','ヘ','ベ','ペ','メ','レ','ヱ','ェ',
};
const Set<String> _oRow = {
  'オ','コ','ゴ','ソ','ゾ','ト','ド','ノ','ホ','ボ','ポ','モ','ヨ','ロ','ヲ','ョ','ォ',
};

/// Rewrite each `ー` to the matching vowel kana of the preceding mora, matching
/// how kakasi-derived training data spells long vowels (so `ー` is never dropped
/// by [kataToPhonemes]). Leading `ー` (no preceding mora) is dropped.
String expandChoonpu(String reading) {
  final out = StringBuffer();
  String? prev;
  for (final ch in reading.split('')) {
    if (ch == 'ー') {
      if (prev == null) continue;
      if (_aRow.contains(prev)) {
        out.write('ア');
      } else if (_iRow.contains(prev)) {
        out.write('イ');
      } else if (_uRow.contains(prev)) {
        out.write('ウ');
      } else if (_eRow.contains(prev)) {
        out.write('エ');
      } else if (_oRow.contains(prev)) {
        out.write('ウ'); // long-o is spelled オウ in kakasi output
      } else {
        continue; // previous mora has no vowel (e.g. ン, ッ) → drop
      }
      // prev stays the same so a run of ーー keeps extending the same vowel.
      continue;
    }
    out.write(ch);
    prev = ch;
  }
  return out.toString();
}
