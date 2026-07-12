/// Whisper invents text when it is handed audio with no speech in it.
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
/// A VAD in front of Whisper removes most of the opportunity, but not all: Silero
/// will hand over a 300 ms cough, and Whisper will happily caption it. So every
/// transcript is checked here before it can travel.
library;

/// Fragments that only ever appear in Whisper's subtitle boilerplate. Matched on
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
/// [durationMs] is the length of the audio it came from: Whisper's inventions
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
  // the decoder is looping, not transcribing — the other classic Whisper failure
  // ("oui oui oui oui oui…"). Guard against a zero duration.
  if (durationMs > 0 && t.length > 40 * (durationMs / 1000)) return true;

  return false;
}
