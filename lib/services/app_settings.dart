/// Central registry of the user-preference keys stored in
/// SharedPreferences by the Settings screen. Screens that *read* a
/// preference (app bootstrap, call screen, …) and the one that *writes*
/// it all point here, so there is a single source of truth.
abstract final class AppSettings {
  /// Receive push notifications (native FCM).
  static const kPush = 'pref_push_enabled';

  /// Notification sounds (reserved — see Settings report).
  static const kSounds = 'pref_sounds_enabled';

  /// In-app sounds: the call ring / dial tone played by [CallAlert].
  static const kInAppSounds = 'pref_in_app_sounds_enabled';

  /// Hide the online status (persisted to the profile row).
  static const kHideOnline = 'pref_hide_online';

  /// Default call audio output: `'speaker'` or `'earpiece'`.
  static const kAudioOutput = 'pref_audio_output';
}
