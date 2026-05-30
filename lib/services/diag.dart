import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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
        'build': '6.1.2+6',
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
}
