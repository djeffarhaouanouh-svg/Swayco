import 'dart:ui' show PlatformDispatcher;

import 'app_strings.dart';

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
///
/// This is the LOOKUP table, not the picker: see [supportedLanguages] for what
/// the app actually offers. It stays complete so a peer (or an account created
/// before the shortlist) whose language is `es` still gets its flag and its
/// native label everywhere it is merely DISPLAYED.
const List<AppLanguage> allLanguages = <AppLanguage>[
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

/// Les langues réellement PROPOSÉES : onboarding, réglages, roues de l'appel.
///
/// Les 12 langues de l'interface (celles qui ont leur map dans `app_strings`),
/// remises à la demande : elles avaient été réduites à fr / en / de (puis pt)
/// pour un lancement sur trois marchés. Chacune a son texte complet, ses
/// reconnaissances vocales (`apple_asr_engine`, `android_asr_engine`) et sa voix
/// (`call_screen`). Les quatre autres de [allLanguages] (pl, tr, uk, hi) n'ont
/// pas de traduction d'interface : elles restent seulement AFFICHÉES.
///
/// [allLanguages] reste la table de correspondance pour tout ce qui n'est
/// qu'affiché ; élargir ou resserrer l'offre, c'est modifier cette liste-ci.
const List<AppLanguage> supportedLanguages = <AppLanguage>[
  AppLanguage(code: 'fr', flag: '🇫🇷', label: 'Français'),
  AppLanguage(code: 'en', flag: '🇬🇧', label: 'English'),
  AppLanguage(code: 'es', flag: '🇪🇸', label: 'Español'),
  AppLanguage(code: 'de', flag: '🇩🇪', label: 'Deutsch'),
  AppLanguage(code: 'it', flag: '🇮🇹', label: 'Italiano'),
  AppLanguage(code: 'pt', flag: '🇵🇹', label: 'Português'),
  AppLanguage(code: 'nl', flag: '🇳🇱', label: 'Nederlands'),
  AppLanguage(code: 'ar', flag: '🇸🇦', label: 'العربية الفصحى'),
  AppLanguage(code: 'ru', flag: '🇷🇺', label: 'Русский'),
  AppLanguage(code: 'zh', flag: '🇨🇳', label: '中文'),
  AppLanguage(code: 'ja', flag: '🇯🇵', label: '日本語'),
  AppLanguage(code: 'ko', flag: '🇰🇷', label: '한국어'),
];

/// Les sélecteurs de langue de l'INTERFACE (inscription, réglages) : comme
/// [supportedLanguages], mais le portugais y compte DEUX entrées — « Português
/// (Portugal) » et « Português (Brasil) », chacune avec son interface. Les deux
/// ont le même code de langue `pt` : seul l'affichage diffère (voir `UiVariant`).
/// Les roues de langue de l'appel gardent [supportedLanguages] : une seule
/// entrée portugaise (la langue parlée est la même).
const AppLanguage _ptPortugal =
    AppLanguage(code: 'pt', flag: '🇵🇹', label: 'Português (Portugal)');
const AppLanguage _ptBrazil =
    AppLanguage(code: 'pt-BR', flag: '🇧🇷', label: 'Português (Brasil)');

List<AppLanguage> get interfaceLanguages => <AppLanguage>[
      for (final l in supportedLanguages)
        if (l.code == 'pt') ...[_ptPortugal, _ptBrazil] else l,
    ];

/// Les langues parlées en APPEL (roues de langue, réglage de la langue d'appel,
/// invité) : comme [supportedLanguages], mais le portugais s'y appelle
/// « Português (Brasil) » avec le drapeau du Brésil — la voix et la
/// reconnaissance de l'appel sont déjà en `pt-BR`. Le code reste `pt` : rien
/// ne change pour les moteurs, la traduction ni les filtres.
const AppLanguage _ptBrazilCall =
    AppLanguage(code: 'pt', flag: '🇧🇷', label: 'Português (Brasil)');

List<AppLanguage> get callLanguages => <AppLanguage>[
      for (final l in supportedLanguages) l.code == 'pt' ? _ptBrazilCall : l,
    ];

/// [findLanguageByCode], vu depuis l'appel : `pt` rend « Português (Brasil) ».
AppLanguage? findCallLanguageByCode(String code) {
  final primary = code.trim().toLowerCase().split(RegExp('[-_]')).first;
  if (primary == 'pt') return _ptBrazilCall;
  return findLanguageByCode(code);
}

/// Le code de la LIGNE à cocher dans un sélecteur d'interface pour la langue
/// [lang] du compte : `pt` devient `pt-BR` quand l'interface brésilienne est active.
String interfacePickerCode(String lang) {
  final primary = lang.trim().toLowerCase().split(RegExp('[-_]')).first;
  return (primary == 'pt' && AppStrings.ptBrazilian.value) ? 'pt-BR' : lang;
}

/// L'inverse : la langue du COMPTE derrière une ligne du sélecteur (`pt-BR` → `pt`).
String interfaceLanguageOf(String pickerCode) =>
    pickerCode == 'pt-BR' ? 'pt' : pickerCode;

/// Le nom à afficher pour la langue d'interface active (avec la variante).
String interfaceLanguageLabel(String lang) {
  final code = interfacePickerCode(lang);
  for (final l in interfaceLanguages) {
    if (l.code == code) return l.label;
  }
  return findLanguageByCode(lang)?.label ?? lang.toUpperCase();
}

/// The phone's own language, when we OFFER it — used to pre-select the
/// onboarding picker so a first-run user confirms instead of choosing.
///
/// [PlatformDispatcher.locales] is ordered by the user's OS preference, so the
/// first entry we offer is the best guess. Matches against
/// [supportedLanguages], not [allLanguages]: pre-selecting a row the picker
/// doesn't contain would leave the step looking blank. Returns null rather than
/// a default when none matches: the caller decides, and a wrong guess here
/// becomes the language their first call is transcribed in.
String? deviceLanguageCode() {
  for (final locale in PlatformDispatcher.instance.locales) {
    final primary = locale.languageCode.trim().toLowerCase();
    for (final l in supportedLanguages) {
      if (l.code == primary) return l.code;
    }
  }
  return null;
}

/// Returns the language whose primary subtag matches [code] (case-insensitive),
/// or null if the code is empty or unknown.
///
/// Looks through [allLanguages]: this answers "how do I show this code", and the
/// code may come from a peer's profile written before the shortlist.
AppLanguage? findLanguageByCode(String code) {
  final trimmed = code.trim().toLowerCase();
  if (trimmed.isEmpty) return null;
  // Drop region subtag if present (`fr-FR` -> `fr`).
  final primary = trimmed.split('-').first;
  for (final l in allLanguages) {
    if (l.code == primary) return l;
  }
  return null;
}

/// True when [code] is one of the languages the app currently offers — i.e. a
/// legal value for the account language / the call wheels, as opposed to one we
/// merely know how to display.
bool isOfferedLanguage(String code) {
  final primary = code.trim().toLowerCase().split('-').first;
  return supportedLanguages.any((l) => l.code == primary);
}
