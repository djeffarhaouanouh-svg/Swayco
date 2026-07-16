/// The recogniser invents text when it is handed audio with no speech in it.
///
/// It was trained on subtitle tracks, so when a clip is silence, breath, a door,
/// or a scrap of the loudspeaker's own output, it falls back on the boilerplate
/// those tracks end with: "Sous-titrage Société Radio-Canada", "Thanks for
/// watching!", "ご視聴ありがとうございました". The recogniser reports these with full
/// confidence — nothing downstream can tell them from a real sentence.
///
/// In a call that is far worse than a bad transcription: the peer's phone speaks
/// a sentence nobody said, out loud, in the middle of the conversation.
///
/// A VAD in front of the recogniser removes most of the opportunity, but not all: the VAD
/// will hand over a 300 ms cough, and the recogniser will happily caption it. So every
/// transcript is checked here before it can travel.
library;

/// Fragments that only ever appear in the recogniser's subtitle boilerplate. Matched on
/// a lowercased, accent-insensitive form of the transcript, so one entry covers
/// its variants. Deliberately narrow: each is a phrase no one says on a call.
const List<String> _boilerplate = [
  // fr
  'sous-titrage', 'sous-titres', 'amara.org', 'societe radio-canada',
  'merci d\'avoir regarde', 'abonnez-vous',
  // en
  'thanks for watching', 'thank you for watching', 'subscribe to',
  'subtitles by', 'captions by',
  // es / pt / it
  'subtitulos', 'legendas', 'sottotitoli', 'suscribete',
  // de / nl
  'untertitel', 'ondertiteling', 'abonniere',
  // ja / zh / ko
  'ご視聴ありがとうございました', 'ご視聴ありがとう', '字幕',
  '請不吝點贊', '訂閱', '明鏡與點點欄目', '시청해주셔서 감사합니다', '구독',
  // ru / ar
  'субтитры', 'редактор субтитров', 'ترجمة',
];

/// Strips accents so 'société' and 'societe' are the same string.
String _fold(String s) {
  const from = 'áàâäãåéèêëíìîïóòôöõúùûüýÿçñ';
  const to = 'aaaaaaeeeeiiiiooooouuuuyycn';
  final b = StringBuffer();
  for (final ch in s.toLowerCase().runes) {
    final i = from.runes.toList().indexOf(ch);
    b.write(i >= 0 ? to[i] : String.fromCharCode(ch));
  }
  return b.toString();
}

/// Whisper sometimes emits a whole phrase twice inside a single clip —
/// "A。A。" — and the peer's bubble shows it doubled. Neither [_isStuckLoop]
/// (which wants one *word* repeated four times) nor the caller's cross-clip
/// repeat guard (which compares *separate* sends) catches a doubling that lives
/// inside one transcript, so it travels as-is.
///
/// Collapse a transcript that is exactly one unit repeated twice — with an
/// optional run of separators in the seam — back to that single unit. The unit
/// must be at least 6 characters, so a real short echo ("はいはい", "oui oui")
/// is left untouched.
String collapseSelfRepeat(String transcript) {
  final t = transcript.trim();
  if (t.length < 12) return t;
  final m = RegExp(
    r'^(.{6,}?)[\s。.!?！？、,…\-]*\1[\s。.!?！？、,…\-]*$',
    unicode: true,
    dotAll: true,
  ).firstMatch(t);
  return m != null ? m.group(1)!.trim() : t;
}

/// A Japanese transcript that is *only* grammatical tail — a sentence-final
/// particle or copula/verb ending with no content word — is a scrap the
/// segmenter split off (typically the tail of a phrase whose head was dropped
/// while the mic was muted for playback). The STT reads it correctly, but the
/// translator, handed 「よ」 or 「ますよ」, invents "Yo" / "Bien sûr" — junk spoken
/// on the peer's phone.
///
/// This is Japanese-specific ON PURPOSE. A German fragment ("sind", "nach
/// Hause") is a real word that still translates; a Japanese fragment is often a
/// contentless particle. So the filter runs only for `ja` and leaves every
/// other language untouched.
///
/// Safe by construction: any kanji or katakana means a content word is present
/// → not a scrap. Only an all-hiragana string that is *entirely* consumed by
/// known tail tokens is dropped, so real short answers survive — はい, うん,
/// そう, だめ, ありがとう, ごめん all contain non-tail kana and are kept.
bool isUntranslatableScrap(String transcript, String lang) {
  if (!lang.toLowerCase().startsWith('ja')) return false;
  var t = transcript.trim().replaceAll(
        RegExp(r'''^[\s。、！？!?,.…「」『』（）()〜~ー]+|[\s。、！？!?,.…「」『』（）()〜~ー]+$''',
            unicode: true),
        '',
      );
  if (t.isEmpty) return false; // empty is handled by [looksHallucinated]
  // A kanji or katakana run carries the meaning — never a scrap.
  if (RegExp(r'[一-鿿㐀-䶿゠-ヿ]', unicode: true)
      .hasMatch(t)) {
    return false;
  }
  // Grammatical tail tokens, longest first so greedy matching is correct.
  const tails = <String>[
    'んですけど', 'んですが', 'ませんでした', 'でしょう', 'ですね', 'ですよ', 'でした',
    'ません', 'ました', 'だよね', 'ますよ', 'ますね', 'けれども', 'けれど', 'んです',
    'だろう', 'でしょ', 'です', 'ます', 'かな', 'よね', 'っけ', 'から', 'ので', 'けど',
    'って', 'だよ', 'だね', 'だ', 'よ', 'ね', 'な', 'わ', 'ぞ', 'ぜ', 'さ', 'の', 'か', 'ん',
  ];
  var i = 0;
  while (i < t.length) {
    var matched = false;
    for (final tok in tails) {
      if (t.startsWith(tok, i)) {
        i += tok.length;
        matched = true;
        break;
      }
    }
    if (!matched) return false; // a non-tail kana = real content, keep it
  }
  return true; // the whole string was grammatical filler
}

/// True when [transcript] should be thrown away instead of translated.
///
/// [durationMs] is the length of the audio it came from: its inventions
/// cluster on very short clips, where a full sentence cannot physically have
/// been spoken. A 2-second clip that decodes to forty words is not a
/// transcription.
bool looksHallucinated(String transcript, {required int durationMs}) {
  final t = transcript.trim();
  if (t.isEmpty) return true;

  // No letters at all — punctuation, musical notes, "..." — nothing was said.
  if (!RegExp(r'\p{L}', unicode: true).hasMatch(t)) return true;

  // A whole transcript that is one bracketed group is the recogniser tagging
  // non-speech, not a spoken sentence: "(音声)", "(音楽)", "(英語)", "(musique)",
  // "[Music]". These slip past the no-letter guard above because the tag holds
  // real letters (kanji, "musique"), yet no one ever says a lone parenthesis
  // into the phone. Only a SINGLE group is matched (no bracket inside), so a
  // real sentence that merely contains "(...)" is left untouched.
  if (RegExp(r'^[(（\[［【〔][^()（）\[\]［］【】〔〕]*[)）\]］】〕]$').hasMatch(t)) {
    return true;
  }

  final folded = _fold(t);
  for (final phrase in _boilerplate) {
    if (folded.contains(_fold(phrase))) return true;
  }

  // Speech runs at roughly 12–20 characters a second. Well past double that and
  // the decoder is emitting faster than a mouth can move. Guard a zero duration.
  if (durationMs > 0 && t.length > 40 * (durationMs / 1000)) return true;

  if (_isStuckLoop(folded)) return true;

  if (_isLetterSalad(t)) return true;

  return false;
}

/// Handed a noise it cannot place, the decoder sometimes emits stray letters
/// rather than a phrase: `"L - L"`, `"A. A"`, `"T"`. Every guard above lets them
/// past — they hold letters, they are not boilerplate, the character rate is
/// plausible, and [_isStuckLoop] wants four words before it will speak up. So the
/// peer's phone reads them out, mid-conversation.
///
/// The tell is that no word reaches two letters. Nothing here may touch the real
/// short answers a call is made of — "Oui", "Ça va", "はい" — which is what the
/// script test below protects: in Japanese, Chinese, Korean and Thai a lone
/// character IS a word, and there are no spaces to split on. Those scripts are
/// left alone entirely; the rule only applies where words are spelled out.
bool _isLetterSalad(String t) {
  const denseRanges = <List<int>>[
    [0x3040, 0x30FF], // kana
    [0x3400, 0x4DBF], // han, extension A
    [0x4E00, 0x9FFF], // han
    [0xAC00, 0xD7AF], // hangul syllables
    [0x1100, 0x11FF], // hangul jamo
    [0x0E00, 0x0E7F], // thai
  ];
  for (final r in t.runes) {
    for (final range in denseRanges) {
      if (r >= range[0] && r <= range[1]) return false;
    }
  }

  final words = t
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.isNotEmpty);
  if (words.isEmpty) return true;
  return words.every((w) => w.runes.length < 2);
}

/// the decoder gets stuck and repeats one word until it runs out of
/// budget: "oui, oui, oui, oui, oui, oui…". The character-rate guard above misses
/// it — a short word repeated eight times over three seconds is a perfectly
/// human rate — so the repetition itself has to be what gives it away.
///
/// A person does repeat themselves ("non, non, non !"), so the bar is set where
/// insistence ends and a machine begins: four or more of the same word, AND that
/// word making up most of the sentence.
bool _isStuckLoop(String folded) {
  final words = folded
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.length < 4) return false;

  final counts = <String, int>{};
  for (final w in words) {
    counts[w] = (counts[w] ?? 0) + 1;
  }
  final top = counts.values.reduce((a, b) => a > b ? a : b);
  return top >= 4 && top / words.length >= 0.6;
}
