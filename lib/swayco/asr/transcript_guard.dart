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
