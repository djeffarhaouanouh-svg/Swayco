import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../config/app_config.dart';

/// Boot-time diagnostic pings sent fire-and-forget to the backend's
/// `/diag` route. The whole point is to figure out where a Release build
/// hangs on a real device when there's no way to attach a debugger and
/// no crash report (because the engine never crashes — it just sits
/// there with no Flutter UI in front of it).
///
/// Every call is bounded and swallows every error: nothing in here may
/// ever throw or block the caller, otherwise the diagnostic would
/// itself become the bug we're trying to find.
abstract final class Diag {
  /// Sequence number — lets the Railway log show events in the order
  /// the device produced them even when arrival order is shuffled by
  /// concurrency / retries.
  static int _seq = 0;
  static String? _sessionId;
  /// Cached "version+buildNumber" of the running binary, populated once
  /// by [bind] from `package_info_plus`. Hardcoding this field had been
  /// actively misleading — every iOS install reported `6.1.2+6` no
  /// matter what was actually compiled, which made it impossible to
  /// tell from a Railway log whether the device was on the build that
  /// included a specific fix.
  static String _build = 'unknown';

  /// Read once at boot and cache. Safe to call multiple times. Never
  /// throws — falls back to the previous value if the platform channel
  /// is unavailable (early in WidgetsFlutterBinding initialisation).
  static Future<void> bind() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _build = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // Leave the previous fallback in place.
    }
  }

  /// Cheap session id so a backend reader can group one device's
  /// startup pings. Not a UUID — `${ts}-${rnd}` is plenty for log
  /// correlation and avoids depending on dart:math.Random.secure()
  /// during the earliest possible boot moments.
  static String _session() {
    final s = _sessionId;
    if (s != null) return s;
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final r = (ts.hashCode & 0xffff).toRadixString(36);
    return _sessionId = '$ts-$r';
  }

  static String _platform() {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isIOS) return 'ios';
      if (Platform.isAndroid) return 'android';
      if (Platform.isMacOS) return 'macos';
      if (Platform.isWindows) return 'windows';
      if (Platform.isLinux) return 'linux';
    } catch (_) {}
    return 'unknown';
  }

  /// Resolves the backend base URL with a production fallback so that
  /// even a Release build that forgot to pass --dart-define=TOKEN_API_BASE
  /// still reaches Railway. Without this, an iOS build assembled on a
  /// Mac without the dart-defines would silently drop every diag ping
  /// onto localhost and we'd get zero signal.
  static String _resolvedBase() {
    final raw = resolvedTokenApiBase();
    if (raw.startsWith('http://127.0.0.1') ||
        raw.startsWith('http://10.0.2.2') ||
        raw.startsWith('http://localhost')) {
      return 'https://www.swayco.fr';
    }
    return raw;
  }

  /// Fire-and-forget ping. Never awaited by the caller — the future
  /// returned here always resolves, never throws. Hard 2s cap so a
  /// dead backend doesn't queue requests forever.
  static Future<void> ping(String step, {String? note}) async {
    try {
      final base = _resolvedBase().replaceAll(RegExp(r'/$'), '');
      if (base.isEmpty) return;
      final n = ++_seq;
      final params = <String, String>{
        'step': step,
        'session': _session(),
        'seq': n.toString(),
        'platform': _platform(),
        'build': _build,
        if (note != null && note.isNotEmpty) 'note': note,
      };
      final uri = Uri.parse('$base/diag').replace(queryParameters: params);
      // Fire and forget — never await the response chain from the
      // caller's perspective, but use a short timeout here so the
      // background pool isn't choked on a stuck backend.
      unawaited(
        http
            .get(uri)
            .timeout(const Duration(seconds: 2))
            .then(
              (_) {},
              onError: (_) {},
            ),
      );
    } catch (_) {
      // Diagnostic must never break the boot path.
    }
  }

  /// Record an exception with a short stack trace head. Same fire-and-
  /// forget contract as [ping].
  static void error(String step, Object e, StackTrace s, {String? note}) {
    final head = s.toString().split('\n').take(4).join(' | ');
    final payload = '${e.toString()} :: $head';
    final clipped =
        payload.length > 800 ? payload.substring(0, 800) : payload;
    ping(
      step,
      note: note == null ? clipped : '$note :: $clipped',
    );
  }

  /// POST a larger payload (widget tree dump, base64-encoded PNG) to
  /// `/diag`. Same fire-and-forget contract as [ping]. Payloads above
  /// ~900 kB are clipped client-side because the backend caps the JSON
  /// body at 1 MB and we'd rather log the head than nothing.
  static Future<void> upload(String step, String payload) async {
    try {
      final base = _resolvedBase().replaceAll(RegExp(r'/$'), '');
      if (base.isEmpty) return;
      final n = ++_seq;
      final clipped =
          payload.length > 900000 ? payload.substring(0, 900000) : payload;
      final body = jsonEncode({
        'step': step,
        'session': _session(),
        'seq': n.toString(),
        'platform': _platform(),
        'build': _build,
        'payload': clipped,
      });
      final uri = Uri.parse('$base/diag');
      unawaited(
        http
            .post(
              uri,
              headers: const {'Content-Type': 'application/json'},
              body: body,
            )
            .timeout(const Duration(seconds: 6))
            .then(
              (_) {},
              onError: (_) {},
            ),
      );
    } catch (_) {
      // Diagnostic must never break the boot path.
    }
  }
}
