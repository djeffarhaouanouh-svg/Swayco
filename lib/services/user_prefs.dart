import 'package:shared_preferences/shared_preferences.dart';

/// Local profile + onboarding flags (no server yet).
abstract final class UserPrefs {
  static const String keyOnboardingDone = 'onboarding_done';
  static const String keyFirstName = 'profile_first_name';
  static const String keySourceLang = 'profile_source_lang';
  static const String keyTargetLang = 'profile_target_lang';
  /// Self-declared grammatical gender — `m` / `f` / `x` (neutral).
  /// Asked once during onboarding right after the language step and never
  /// shown again. Empty when not yet provided.
  static const String keyGender = 'profile_gender';
  /// The single "what defines you most" persona category (one of
  /// `kPersonaCategories`, persona_categories.dart). Asked once during
  /// onboarding right after gender and never shown again — same "asked
  /// once, editable later from the profile" pattern as [keyGender]. Empty
  /// when not yet provided.
  static const String keyPersonaCategory = 'profile_persona_category';
  static const String keyTranslatedVolume = 'audio_translated_volume';
  static const String keyOriginalVolume = 'audio_original_volume';
  static const String keyDuckingEnabled = 'audio_ducking_enabled';
  static const String keySpeakerOn = 'audio_speaker_on';
  // One-shot coach-marks: the post-onboarding "add a Discover photo"
  // nudge, and the first-time hint shown on the Profile tab.
  static const String keyOnboardingTipsSeen = 'onboarding_tips_seen';
  static const String keyProfileTipSeen = 'profile_tip_seen';
  // One-shot "glisse pour choisir" coach overlay: shown the very first time
  // the user lands on Discover, right after onboarding.
  static const String keySwipeCoachSeen = 'swipe_coach_seen';
  // One-shot "faire signe" coach overlay: shown the very first time the
  // Messages list has at least one conversation to preview.
  static const String keyWavePromoSeen = 'wave_promo_seen';


  /// Discover feed cursor: the profile id of the card the user was last
  /// parked on. Written on every page change so closing + reopening the app
  /// resumes on that person instead of snapping back to the top of the feed.
  /// We store the id (not a numeric index) so it stays correct even when the
  /// feed comes back in a different order next launch. Empty = start at the top.
  static const String keyDiscoverCursor = 'discover_cursor_profile_id';

  /// Calendar day (`yyyy-MM-dd`, local) the user finished the Discover deck.
  /// Cleared on a new day so the feed can start again tomorrow.
  static const String keyDiscoverDoneDay = 'discover_done_day';

  /// Profile ids of today's Discover deck — kept so "Recommencer" can replay
  /// even when the live feed is empty (everyone already liked / matched).
  static const String keyDiscoverDeckIds = 'discover_deck_ids';
  static const String keyDiscoverDeckDay = 'discover_deck_day';

  static Future<String> loadDiscoverCursor() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(keyDiscoverCursor) ?? '';
  }

  static Future<void> saveDiscoverCursor(String profileId) async {
    final p = await SharedPreferences.getInstance();
    final id = profileId.trim();
    if (id.isEmpty) {
      await p.remove(keyDiscoverCursor);
    } else {
      await p.setString(keyDiscoverCursor, id);
    }
  }

  static String _todayKey() {
    final n = DateTime.now();
    final m = n.month.toString().padLeft(2, '0');
    final d = n.day.toString().padLeft(2, '0');
    return '${n.year}-$m-$d';
  }

  /// True when the Discover deck was exhausted earlier today.
  static Future<bool> loadDiscoverDoneToday() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(keyDiscoverDoneDay) == _todayKey();
  }

  static Future<void> markDiscoverDoneToday() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(keyDiscoverDoneDay, _todayKey());
  }

  static Future<void> clearDiscoverDone() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(keyDiscoverDoneDay);
  }

  static Future<void> saveDiscoverDeck(List<String> ids) async {
    final p = await SharedPreferences.getInstance();
    final clean = [
      for (final id in ids)
        if (id.trim().isNotEmpty) id.trim(),
    ];
    if (clean.isEmpty) {
      await p.remove(keyDiscoverDeckIds);
      await p.remove(keyDiscoverDeckDay);
      return;
    }
    await p.setStringList(keyDiscoverDeckIds, clean);
    await p.setString(keyDiscoverDeckDay, _todayKey());
  }

  /// Today's cached Discover deck ids, or empty when none / another day.
  static Future<List<String>> loadDiscoverDeckToday() async {
    final p = await SharedPreferences.getInstance();
    if (p.getString(keyDiscoverDeckDay) != _todayKey()) return const [];
    return p.getStringList(keyDiscoverDeckIds) ?? const [];
  }


  static Future<bool> isOnboardingDone() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(keyOnboardingDone) ?? false;
  }

  static Future<void> completeOnboarding({
    required String firstName,
    required String sourceLang,
    required String targetLang,
    String gender = '',
    String personaCategory = '',
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(keyOnboardingDone, true);
    await p.setString(keyFirstName, firstName.trim());
    await p.setString(keySourceLang, sourceLang.trim());
    await p.setString(keyTargetLang, targetLang.trim());
    final g = gender.trim();
    if (g == 'm' || g == 'f' || g == 'x') {
      await p.setString(keyGender, g);
    }
    final pc = personaCategory.trim();
    if (pc.isNotEmpty) {
      await p.setString(keyPersonaCategory, pc);
    }
  }

  /// Update just the user's spoken/interface language (drives the app
  /// locale). Used by the Settings language picker without touching the
  /// other onboarding fields.
  static Future<void> setSourceLang(String code) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(keySourceLang, code.trim());
  }

  static Future<ProfileSnapshot?> loadProfile() async {
    final p = await SharedPreferences.getInstance();
    final name = p.getString(keyFirstName);
    if (name == null || name.isEmpty) return null;
    final g = (p.getString(keyGender) ?? '').trim();
    return ProfileSnapshot(
      firstName: name,
      sourceLang: p.getString(keySourceLang) ?? '',
      targetLang: p.getString(keyTargetLang) ?? '',
      gender: (g == 'm' || g == 'f' || g == 'x') ? g : '',
      personaCategory: (p.getString(keyPersonaCategory) ?? '').trim(),
    );
  }

  /// True once the user picked their gender at least once. The onboarding
  /// step is skipped on subsequent runs so it never re-prompts.
  static Future<bool> isGenderSet() async {
    final p = await SharedPreferences.getInstance();
    final g = (p.getString(keyGender) ?? '').trim();
    return g == 'm' || g == 'f' || g == 'x';
  }

  /// True once the user picked a persona category at least once. Mirrors
  /// [isGenderSet] — the onboarding step is skipped on subsequent runs.
  static Future<bool> isPersonaCategorySet() async {
    final p = await SharedPreferences.getInstance();
    return (p.getString(keyPersonaCategory) ?? '').trim().isNotEmpty;
  }

  /// Clears onboarding flag so the welcome flow shows again (e.g. from
  /// settings). Also clears the coach-mark flags so the photo nudges
  /// replay alongside the fresh onboarding.
  static Future<void> resetOnboarding() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(keyOnboardingDone);
    await p.remove(keyOnboardingTipsSeen);
    await p.remove(keyProfileTipSeen);
    await p.remove(keySwipeCoachSeen);
    await p.remove(keyWavePromoSeen);
  }

  /// Whether the "glisse pour choisir" Discover coach has already played.
  static Future<bool> isSwipeCoachSeen() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(keySwipeCoachSeen) ?? false;
  }

  static Future<void> markSwipeCoachSeen() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(keySwipeCoachSeen, true);
  }

  /// Whether the "faire signe" Messages coach has already played.
  static Future<bool> isWavePromoSeen() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(keyWavePromoSeen) ?? false;
  }

  static Future<void> markWavePromoSeen() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(keyWavePromoSeen, true);
  }

  /// Whether the two post-onboarding "add a Discover photo" popups have
  /// already been shown.
  static Future<bool> isOnboardingTipsSeen() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(keyOnboardingTipsSeen) ?? false;
  }

  static Future<void> markOnboardingTipsSeen() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(keyOnboardingTipsSeen, true);
  }

  /// Whether the first-visit hint on the Profile tab has been shown.
  static Future<bool> isProfileTipSeen() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(keyProfileTipSeen) ?? false;
  }

  static Future<void> markProfileTipSeen() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(keyProfileTipSeen, true);
  }

  /// The language the user last said they would SPEAK on a call, and whether
  /// they asked not to be prompted again.
  ///
  /// Deliberately separate from [keySourceLang] (the account/profile language):
  /// the profile says what someone speaks in general, this says what they chose
  /// for calls. Someone registered in French may run their calls in Japanese
  /// without rewriting their profile.
  static const String keyCallSpokenLang = 'call_spoken_lang';
  static const String keyCallSpokenLangDontAsk = 'call_spoken_lang_dont_ask';

  /// ('', false) until the user has answered the gate once.
  static Future<({String lang, bool dontAsk})> loadCallSpokenLang() async {
    final p = await SharedPreferences.getInstance();
    return (
      lang: p.getString(keyCallSpokenLang)?.trim() ?? '',
      dontAsk: p.getBool(keyCallSpokenLangDontAsk) ?? false,
    );
  }

  /// The language is remembered even when [dontAsk] is false — it then serves
  /// as the pre-selection next time, which beats falling back to the profile.
  static Future<void> saveCallSpokenLang(String lang, {required bool dontAsk}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(keyCallSpokenLang, lang);
    await p.setBool(keyCallSpokenLangDontAsk, dontAsk);
  }

  /// Re-arms the gate — for a "ask me again before each call" setting.
  static Future<void> clearCallSpokenLangDontAsk() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(keyCallSpokenLangDontAsk, false);
  }


  static Future<AudioPrefs> loadAudio() async {
    final p = await SharedPreferences.getInstance();
    return AudioPrefs(
      // Mêmes valeurs de départ que AudioController (3/4 et 1/2) : c'est ici
      // que tombe l'utilisateur qui n'a jamais touché aux curseurs.
      translatedVolume: p.getDouble(keyTranslatedVolume) ?? 0.5,
      originalVolume: p.getDouble(keyOriginalVolume) ?? 0.75,
      duckingEnabled: p.getBool(keyDuckingEnabled) ?? true,
      // Earpiece by default — see AudioController's own default for why.
      speakerOn: p.getBool(keySpeakerOn) ?? false,
    );
  }

  static Future<void> saveAudio(AudioPrefs prefs) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(keyTranslatedVolume, prefs.translatedVolume);
    await p.setDouble(keyOriginalVolume, prefs.originalVolume);
    await p.setBool(keyDuckingEnabled, prefs.duckingEnabled);
    await p.setBool(keySpeakerOn, prefs.speakerOn);
  }
}

class AudioPrefs {
  const AudioPrefs({
    required this.translatedVolume,
    required this.originalVolume,
    required this.duckingEnabled,
    required this.speakerOn,
  });

  final double translatedVolume;
  final double originalVolume;
  final bool duckingEnabled;
  final bool speakerOn;

  AudioPrefs copyWith({
    double? translatedVolume,
    double? originalVolume,
    bool? duckingEnabled,
    bool? speakerOn,
  }) =>
      AudioPrefs(
        translatedVolume: translatedVolume ?? this.translatedVolume,
        originalVolume: originalVolume ?? this.originalVolume,
        duckingEnabled: duckingEnabled ?? this.duckingEnabled,
        speakerOn: speakerOn ?? this.speakerOn,
      );
}

class ProfileSnapshot {
  const ProfileSnapshot({
    required this.firstName,
    required this.sourceLang,
    required this.targetLang,
    this.gender = '',
    this.personaCategory = '',
  });

  final String firstName;
  final String sourceLang;
  final String targetLang;

  /// `m` / `f` / `x` / `''` — see [UserPrefs.keyGender].
  final String gender;

  /// A `kPersonaCategories` label, or `''` — see [UserPrefs.keyPersonaCategory].
  final String personaCategory;
}
