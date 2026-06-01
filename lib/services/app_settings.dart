import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Hide my profile from Discover for users that share my language
  /// (used as a country proxy — see RemoteProfile.language).
  static const kHideFromCountry = 'pref_hide_from_country';

  /// Live cache of the local user's "hide online status" toggle. Used
  /// by every screen that renders presence (chat list, chat thread,
  /// own profile) so the rule is reciprocal: if I'm hiding from the
  /// network I shouldn't see anyone else's online dot either.
  /// Hydrated on app bootstrap by [hydrate] and kept in sync by the
  /// Settings screen on every toggle change.
  static final ValueNotifier<bool> hideOnlineLocal =
      ValueNotifier<bool>(false);

  /// Read once from SharedPreferences and seed the in-memory notifier.
  /// Safe to call multiple times — later writes from the Settings
  /// screen update the same notifier.
  static Future<void> hydrate() async {
    try {
      final p = await SharedPreferences.getInstance();
      hideOnlineLocal.value = p.getBool(kHideOnline) ?? false;
    } catch (_) {
      // Persistence is best-effort here; defaults to false on failure.
    }
  }
}
