import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import 'notification_api.dart';

/// Callback fired with the CallKit call id (which is our `incoming_calls`
/// row id — the caller looks the room up from it).
typedef CallKitAction = void Function(String callId);

/// iOS-only glue around `flutter_callkit_incoming`. Native PushKit code in
/// AppDelegate wakes on a VoIP push and shows the system call screen; this
/// listens for the user's accept/decline and registers the device's VoIP
/// push token so the backend knows where to ring.
///
/// Every entry point is gated to iOS: the plugin has no web implementation
/// and we deliberately don't drive CallKit on Android (full-screen there is
/// handled by the local-notification path instead).
abstract final class IosCallKit {
  static bool _started = false;

  static bool get _isIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Wire CallKit accept/decline events and register the VoIP token for
  /// [userId]. Idempotent — safe to call on every sign-in.
  static Future<void> start({
    required String userId,
    required CallKitAction onAccept,
    required CallKitAction onDecline,
  }) async {
    if (!_isIos) return;
    if (!_started) {
      _started = true;
      FlutterCallkitIncoming.onEvent.listen((event) {
        if (event == null) return;
        switch (event) {
          case CallEventActionCallAccept(:final id):
            onAccept(id);
          case CallEventActionCallDecline(:final id):
            onDecline(id);
          case CallEventActionCallTimeout(:final id):
            // Unanswered ring auto-dismisses → treat like a decline so the
            // caller stops waiting.
            onDecline(id);
          case CallEventActionDidUpdateDevicePushTokenVoip():
            unawaited(_registerToken(userId));
          default:
            break;
        }
      });
    }
    // Catch the token if PushKit registered it before we subscribed.
    await _registerToken(userId);
  }

  static Future<void> _registerToken(String userId, {int attempts = 8}) async {
    if (!_isIos || userId.isEmpty) return;
    // The VoIP token may not be ready the instant we start — PushKit delivers
    // it slightly after launch. Poll a few times until it's available instead
    // of giving up on the first empty read.
    for (var i = 0; i < attempts; i++) {
      try {
        final token = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
        if (token != null && token.isNotEmpty) {
          await NotificationApi.registerVoip(userId: userId, voipToken: token);
          return;
        }
      } catch (e) {
        debugPrint('IosCallKit._registerToken failed: $e');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  /// Read the `extra` payload (callId, roomName, callerId) the VoIP push
  /// carried for [callId], straight from CallKit's active-calls list. Lets
  /// the accept handler get the room without a Supabase round-trip (which
  /// may not be ready the instant the call is answered).
  static Future<Map<String, dynamic>> extraFor(String callId) async {
    if (!_isIos || callId.isEmpty) return const {};
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      for (final c in calls) {
        if (c.id == callId) {
          return Map<String, dynamic>.from(c.extra ?? const <String, dynamic>{});
        }
      }
    } catch (e) {
      debugPrint('IosCallKit.extraFor failed: $e');
    }
    return const {};
  }

  /// Dismiss the native CallKit UI for [callId] once we've taken over
  /// (joined the room) or the call is gone.
  static Future<void> endCall(String callId) async {
    if (!_isIos || callId.isEmpty) return;
    try {
      await FlutterCallkitIncoming.endCall(callId);
    } catch (_) {}
  }
}
