/// Small curated list of UI-facing languages (BCP-47 primary subtag).
class AppLanguage {
  const AppLanguage({
    required this.code,
    required this.flag,
    required this.label,
  });

  /// BCP-47 primary subtag (e.g. `fr`, `en`).
  final String code;

  /// Unicode flag emoji (rendered natively by the OS / browser).
  final String flag;

  /// Native-script label shown in the picker.
  final String label;
}

/// Every language that can be both TRANSCRIBED and SPOKEN on-device — i.e. the
/// intersection of the ASR catalogue (Vosk + Moonshine) and the TTS one (Piper +
/// mimic3 + the Japanese engine). A language that could only be heard, or only
/// spoken, would break one direction of a call, so nothing else belongs here.
///
/// The last four have no `app_strings` map: their UI falls back to English
/// (AppStrings.t → requested → en → fr). They are still first-class *spoken*
/// languages — Vosk transcribes them and Piper speaks them.
///
/// Swedish is the one Piper voice with no companion here: Vosk's only "small"
/// Swedish model weighs 289 MB, 6x every other one, so it is not offered.
const List<AppLanguage> supportedLanguages = <AppLanguage>[
  AppLanguage(code: 'fr', flag: '🇫🇷', label: 'Français'),
  AppLanguage(code: 'en', flag: '🇬🇧', label: 'English'),
  AppLanguage(code: 'es', flag: '🇪🇸', label: 'Español'),
  AppLanguage(code: 'de', flag: '🇩🇪', label: 'Deutsch'),
  AppLanguage(code: 'it', flag: '🇮🇹', label: 'Italiano'),
  AppLanguage(code: 'pt', flag: '🇵🇹', label: 'Português'),
  AppLanguage(code: 'nl', flag: '🇳🇱', label: 'Nederlands'),
  // Standard Arabic, explicitly. Both models are fus'ha-centric: Moonshine's ar
  // training mix is Egyptian + Gulf + MSA with ZERO Maghrebi hours, and the
  // ar_JO Piper voice is MSA read by a Jordanian speaker. A Moroccan or Algerian
  // speaking their dialect into it gets ~85-90% WER (Casablanca, EMNLP 2024) —
  // and Whisper-family models hallucinate rather than fail, so the peer would
  // hear confident nonsense. Naming the variety is the honest minimum until a
  // Darija model exists.
  AppLanguage(code: 'ar', flag: '🇸🇦', label: 'العربية الفصحى'),
  AppLanguage(code: 'ru', flag: '🇷🇺', label: 'Русский'),
  AppLanguage(code: 'zh', flag: '🇨🇳', label: '中文'),
  AppLanguage(code: 'ja', flag: '🇯🇵', label: '日本語'),
  AppLanguage(code: 'ko', flag: '🇰🇷', label: '한국어'),
  AppLanguage(code: 'pl', flag: '🇵🇱', label: 'Polski'),
  AppLanguage(code: 'tr', flag: '🇹🇷', label: 'Türkçe'),
  AppLanguage(code: 'uk', flag: '🇺🇦', label: 'Українська'),
  AppLanguage(code: 'hi', flag: '🇮🇳', label: 'हिन्दी'),
];

/// Returns the language whose primary subtag matches [code] (case-insensitive),
/// or null if the code is empty or unknown.
AppLanguage? findLanguageByCode(String code) {
  final trimmed = code.trim().toLowerCase();
  if (trimmed.isEmpty) return null;
  // Drop region subtag if present (`fr-FR` -> `fr`).
  final primary = trimmed.split('-').first;
  for (final l in supportedLanguages) {
    if (l.code == primary) return l;
  }
  return null;
}
