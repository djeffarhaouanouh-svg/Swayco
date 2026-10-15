import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';

/// Thin client for the dev-only `/livekit/egress/*` routes — records both
/// call participants' video + audio straight to the Supabase Storage
/// bucket, for ad footage only. Access is an allow-list kept server-side
/// (`EGRESS_ADMIN_EMAIL(S)` in Railway), checked fresh on every call —
/// [checkAllowed] is what lets the call screen show/hide the REC button
/// without that list being baked into the app build.
abstract final class EgressApi {
  static Uri _endpoint(String path) {
    const fromEnv = String.fromEnvironment('TOKEN_API_BASE');
    Uri o;
    if (fromEnv.isNotEmpty) {
      o = Uri.parse(fromEnv.replaceAll(RegExp(r'/$'), ''));
    } else if (kIsWeb) {
      o = Uri.base.removeFragment();
    } else {
      o = Uri.parse(resolvedTokenApiBase().replaceAll(RegExp(r'/$'), ''));
    }
    return Uri(
      scheme: o.scheme,
      host: o.host,
      port: o.hasPort ? o.port : null,
      path: path,
    );
  }

  /// Whether the signed-in account may record calls, per the server-side
  /// allow-list. `false` on any error or when signed out — the REC button
  /// stays hidden rather than risk showing a button that will 403.
  static Future<bool> checkAllowed() async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null) return false;
    try {
      final res = await http
          .get(
            _endpoint('/livekit/egress/allowed'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return false;
      final j = jsonDecode(res.body);
      return j is Map && j['allowed'] == true;
    } catch (e) {
      debugPrint('EgressApi.checkAllowed exception: $e');
      return false;
    }
  }

  /// Starts recording `roomName`. Returns the egress id to pass to [stop],
  /// or `null` when not signed in, unauthorized, or the backend rejects it.
  static Future<String?> start(String roomName) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null) {
      debugPrint('EgressApi.start: no auth session');
      return null;
    }
    try {
      final res = await http
          .post(
            _endpoint('/livekit/egress/start'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'roomName': roomName}),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        debugPrint('EgressApi.start failed: ${res.statusCode} ${res.body}');
        return null;
      }
      final j = jsonDecode(res.body);
      if (j is! Map) return null;
      final id = j['egressId']?.toString() ?? '';
      return id.isEmpty ? null : id;
    } catch (e) {
      debugPrint('EgressApi.start exception: $e');
      return null;
    }
  }

  /// Stops a recording started by [start]. Best-effort: returns whether the
  /// backend confirmed the stop.
  static Future<bool> stop(String egressId) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null) return false;
    try {
      final res = await http
          .post(
            _endpoint('/livekit/egress/stop'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'egressId': egressId}),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        debugPrint('EgressApi.stop failed: ${res.statusCode} ${res.body}');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('EgressApi.stop exception: $e');
      return false;
    }
  }
}
