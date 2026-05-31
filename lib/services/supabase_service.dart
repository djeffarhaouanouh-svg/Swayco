import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';

/// Initializes the global Supabase client from build-time env. Safe to call
/// before `runApp`. No-ops (and logs a debug message) when keys are missing so
/// local dev without Supabase keys still boots normally.
Future<void> initSupabase() async {
  final url = resolvedSupabaseUrl();
  final key = resolvedSupabasePublishableKey();
  if (url.isEmpty || key.isEmpty) {
    debugPrint(
      'Supabase: SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY not set — '
      'client not initialized. Pass via --dart-define at build time.',
    );
    return;
  }
  await Supabase.initialize(url: url, anonKey: key);
}

/// Whether [Supabase.instance] is usable. False when the keys were missing at
/// build time AND when `Supabase.initialize` did not finish setting the
/// underlying client — touching `.client` is what surfaces that, because
/// `Supabase.instance` returns the wrapper even when its late `client`
/// field hasn't been assigned yet. Without this stricter check, a
/// half-initialized Supabase (e.g. when an outer `Future.timeout` cuts
/// `initSupabase` before Hive session recovery completes on a fresh iOS
/// release install) flagged as ready and the very first
/// `_auth.onAuthStateChange` read crashed initState with a
/// `LateInitializationError: Field 'client' has not been initialized`.
bool get isSupabaseReady {
  try {
    // ignore: unnecessary_statements
    Supabase.instance.client;
    return true;
  } catch (_) {
    return false;
  }
}
