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
  static const String keyTranslatedVolume = 'audio_translated_volume';
  static const String keyOriginalVolume = 'audio_original_volume';
  static const String keyDuckingEnabled = 'audio_ducking_enabled';
  static const String keySpeakerOn = 'audio_speaker_on';
  // One-shot coach-marks: the post-onboarding "add a Discover photo"
  // nudge, and the first-time hint shown on the Profile tab.
  static const String keyOnboardingTipsSeen = 'onboarding_tips_seen';
  static const String keyProfileTipSeen = 'profile_tip_seen';

  /// Referral code captured from a `?ref=<code>` query at app boot, held
  /// until the user finishes sign-up + onboarding so it can be passed to
  /// `attribute_referral` once they actually have a profile row.
  /// Cleared after a successful attribution.
  static const String keyPendingReferralCode = 'pending_referral_code';

  static Future<String> readPendingReferralCode() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(keyPendingReferralCode) ?? '';
  }

  static Future<void> writePendingReferralCode(String code) async {
    final p = await SharedPreferences.getInstance();
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      await p.remove(keyPendingReferralCode);
    } else {
      await p.setString(keyPendingReferralCode, trimmed);
    }
  }

  static Future<void> clearPendingReferralCode() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(keyPendingReferralCode);
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
    );
  }

  /// True once the user picked their gender at least once. The onboarding
  /// step is skipped on subsequent runs so it never re-prompts.
  static Future<bool> isGenderSet() async {
    final p = await SharedPreferences.getInstance();
    final g = (p.getString(keyGender) ?? '').trim();
    return g == 'm' || g == 'f' || g == 'x';
  }

  /// Clears onboarding flag so the welcome flow shows again (e.g. from
  /// settings). Also clears the coach-mark flags so the photo nudges
  /// replay alongside the fresh onboarding.
  static Future<void> resetOnboarding() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(keyOnboardingDone);
    await p.remove(keyOnboardingTipsSeen);
    await p.remove(keyProfileTipSeen);
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

  static Future<AudioPrefs> loadAudio() async {
    final p = await SharedPreferences.getInstance();
    return AudioPrefs(
      translatedVolume: p.getDouble(keyTranslatedVolume) ?? 1.0,
      originalVolume: p.getDouble(keyOriginalVolume) ?? 1.0,
      duckingEnabled: p.getBool(keyDuckingEnabled) ?? true,
      speakerOn: p.getBool(keySpeakerOn) ?? true,
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
  });

  final String firstName;
  final String sourceLang;
  final String targetLang;

  /// `m` / `f` / `x` / `''` — see [UserPrefs.keyGender].
  final String gender;
}
