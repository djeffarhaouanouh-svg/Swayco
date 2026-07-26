import 'dart:ui' show PlatformDispatcher;

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

  /// ISO code of the country whose flag stands for this language (`ja` → `JP`),
  /// derived from [flag] rather than kept in a second table: a flag emoji IS a
  /// pair of regional indicators, i.e. two letters shifted up into their own
  /// Unicode block. Empty if [flag] is not a flag.
  ///
  /// Needed wherever the flag must be DRAWN rather than typed — the round SVG
  /// flags of the in-call language button, which don't depend on the system
  /// emoji font.
  String get countryCode {
    const first = 0x1F1E6; // 🇦
    final runes = flag.runes.toList();
    if (runes.length < 2) return '';
    final a = runes[0] - first;
    final b = runes[1] - first;
    if (a < 0 || a > 25 || b < 0 || b > 25) return '';
    return String.fromCharCodes([0x41 + a, 0x41 + b]);
  }
}

/// Every language that can be both TRANSCRIBED and SPOKEN on-device — i.e. the
/// intersection of the ASR catalogue (lattice + neural) and the TTS one (Piper +
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
  // Standard Arabic, explicitly. Both models are fus'ha-centric: the neural ar
  // training mix is Egyptian + Gulf + MSA with ZERO Maghrebi hours, and the
  // ar_JO Piper voice is MSA read by a Jordanian speaker. A Moroccan or Algerian
  // speaking their dialect into it gets ~85-90% WER (Casablanca, EMNLP 2024) —
  // and the recognisers hallucinate rather than fail, so the peer would
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

/// The phone's own language, when we support it — used to pre-select the
/// onboarding picker so a first-run user confirms instead of choosing.
///
/// [PlatformDispatcher.locales] is ordered by the user's OS preference, so the
/// first entry we support is the best guess. Returns null rather than a default
/// when none matches: the caller decides, and a wrong guess here becomes the
/// language their first call is transcribed in.
String? deviceLanguageCode() {
  for (final locale in PlatformDispatcher.instance.locales) {
    final match = findLanguageByCode(locale.languageCode);
    if (match != null) return match.code;
  }
  return null;
}

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
