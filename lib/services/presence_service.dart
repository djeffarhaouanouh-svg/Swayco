import 'dart:async';

import 'profile_api.dart';
import 'supabase_service.dart';

/// Keeps the local user's `profiles.last_seen` fresh so other clients can
/// show an online indicator. Touches the row immediately on [start] and
/// then every 90 seconds. While the app is backgrounded the OS suspends
/// the timer — which is exactly what we want: "online" means foregrounded.
abstract final class PresenceService {
  static Timer? _timer;
  static String _userId = '';

  /// Begin (or re-target) the heartbeat for [userId]. Idempotent — calling
  /// it again with the same id while already running is a no-op.
  static void start(String userId) {
    if (userId.isEmpty || !isSupabaseReady) return;
    if (userId == _userId && _timer != null) return;
    _userId = userId;
    _timer?.cancel();
    _touch();
    _timer = Timer.periodic(const Duration(seconds: 90), (_) => _touch());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _userId = '';
  }

  static void _touch() {
    if (_userId.isEmpty) return;
    unawaited(ProfileApi.touchLastSeen(_userId));
  }
}
