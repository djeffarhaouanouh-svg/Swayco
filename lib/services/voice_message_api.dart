import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import 'chat_api.dart';

/// Thrown when the backend rejects an upload (auth, payload, STT, etc.).
class VoiceMessageException implements Exception {
  VoiceMessageException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => 'VoiceMessageException($statusCode): $message';
}

Uri _voiceMessagesUri() => _backendUri('/messages/voice');
Uri _voiceDubUri() => _backendUri('/voice/dub');

Uri _backendUri(String path) {
  const fromEnv = String.fromEnvironment('TOKEN_API_BASE');
  if (fromEnv.isNotEmpty) {
    final b = fromEnv.replaceAll(RegExp(r'/$'), '');
    return Uri.parse('$b$path');
  }
  if (kIsWeb) {
    final o = Uri.base.removeFragment();
    return Uri(
      scheme: o.scheme,
      host: o.host,
      port: o.hasPort ? o.port : null,
      path: path,
    );
  }
  final b = resolvedTokenApiBase().replaceAll(RegExp(r'/$'), '');
  return Uri.parse('$b$path');
}

/// Upload a recorded voice message to the backend. The backend stores the
/// audio in Supabase Storage, runs Speech-to-Text via ElevenLabs Scribe,
/// inserts a row in `messages` and pushes the recipient. Returns the
/// inserted message so the UI can render it immediately without waiting
/// for the realtime stream.
///
/// [audioBytes] — the raw recording (typically m4a/aac on mobile, webm on web).
/// [mimeType]   — content-type of [audioBytes], e.g. `audio/m4a`, `audio/webm`.
/// [durationMs] — client-measured length of the recording in ms (capped at 120 s).
/// [hintLanguage] — optional BCP-47 primary subtag. When provided, Scribe
/// skips its auto-detection pass which trims a few hundred ms of latency.
Future<ChatMessage> uploadVoiceMessage({
  required Uint8List audioBytes,
  required String mimeType,
  required int durationMs,
  required String conversationId,
  required String recipientId,
  required String senderName,
  String? hintLanguage,
}) async {
  if (audioBytes.isEmpty) {
    throw VoiceMessageException('empty audio');
  }
  // The backend gates on the Supabase JWT: refuse early when there is
  // no session so the user sees a clean error instead of a silent 401.
  final session = Supabase.instance.client.auth.currentSession;
  final accessToken = session?.accessToken;
  if (accessToken == null || accessToken.isEmpty) {
    throw VoiceMessageException('not authenticated', statusCode: 401);
  }

  final uri = _voiceMessagesUri();
  final filename = (() {
    if (mimeType.contains('webm')) return 'voice.webm';
    if (mimeType.contains('ogg')) return 'voice.ogg';
    if (mimeType.contains('mpeg') || mimeType.contains('mp3')) return 'voice.mp3';
    if (mimeType.contains('wav')) return 'voice.wav';
    return 'voice.m4a';
  })();

  final req = http.MultipartRequest('POST', uri);
  req.headers['Authorization'] = 'Bearer $accessToken';
  req.fields['conversationId'] = conversationId;
  req.fields['recipientId'] = recipientId;
  req.fields['senderName'] = senderName;
  req.fields['durationMs'] = '$durationMs';
  if (hintLanguage != null && hintLanguage.isNotEmpty) {
    req.fields['hintLanguage'] = hintLanguage;
  }
  // We deliberately skip setting `contentType` on the MultipartFile —
  // it would require pulling in `http_parser`'s MediaType type. The
  // backend infers the codec from the filename extension instead
  // (see /messages/voice in server.js).
  req.files.add(
    http.MultipartFile.fromBytes(
      'audio',
      audioBytes,
      filename: filename,
    ),
  );

  final streamed = await req.send();
  final res = await http.Response.fromStream(streamed);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw VoiceMessageException(
      res.body.length > 400 ? '${res.body.substring(0, 400)}…' : res.body,
      statusCode: res.statusCode,
    );
  }
  final decoded = jsonDecode(res.body);
  if (decoded is! Map || decoded['message'] is! Map) {
    throw VoiceMessageException('unexpected response shape');
  }
  return ChatMessage.fromMap(Map<String, dynamic>.from(decoded['message'] as Map));
}

/// Outcome of a /voice/dub request — the public URL of the rendered
/// mp3 and a flag telling the UI whether the result came out of the
/// server-side cache (true → instant, no ElevenLabs bill).
class VoiceDubResult {
  const VoiceDubResult({required this.audioUrl, required this.cached});
  final String audioUrl;
  final bool cached;
}

/// Specific exception types the bubble UI surfaces to the user.
///   - upgradeRequired: the listener is on a tier without TTS dubbing
///     (Free). The CTA should point at the Plus / Ultra plans.
///   - quotaExceeded:   they're on Plus and have used their 60/mo cap.
///   - other:           network / backend hiccup — generic snackbar.
enum VoiceDubError { upgradeRequired, quotaExceeded, other }

class VoiceDubException implements Exception {
  VoiceDubException(this.code, this.message, {this.statusCode, this.resetAt});
  final VoiceDubError code;
  final String message;
  final int? statusCode;
  /// ISO timestamp of the next monthly reset, returned by the backend
  /// when [code] is [VoiceDubError.quotaExceeded]. Null otherwise.
  final String? resetAt;

  @override
  String toString() => 'VoiceDubException($code/$statusCode): $message';
}

/// Ask the backend to render an audio doubling of [messageId] in
/// [targetLang] using the already-translated [text]. The client passes
/// the translation in so the backend doesn't have to re-bill gpt-4.1
/// for text we already have on-screen.
///
/// Returns the public URL of the rendered mp3 (cached after the first
/// listener so a thread with N participants still costs one TTS call).
Future<VoiceDubResult> fetchVoiceDub({
  required String messageId,
  required String targetLang,
  required String text,
}) async {
  final uri = _voiceDubUri();
  final session = Supabase.instance.client.auth.currentSession;
  final accessToken = session?.accessToken;
  if (accessToken == null || accessToken.isEmpty) {
    throw VoiceDubException(VoiceDubError.other, 'not authenticated',
        statusCode: 401);
  }
  final res = await http.post(
    uri,
    headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'messageId': messageId,
      'targetLang': targetLang,
      'text': text,
    }),
  );
  if (res.statusCode == 402) {
    Map<String, dynamic>? body;
    try {
      final j = jsonDecode(res.body);
      if (j is Map) body = Map<String, dynamic>.from(j);
    } catch (_) {}
    final err = body?['error'];
    if (err == 'quota_exceeded') {
      throw VoiceDubException(
        VoiceDubError.quotaExceeded,
        'monthly cap reached',
        statusCode: 402,
        resetAt: body?['resetAt']?.toString(),
      );
    }
    throw VoiceDubException(
      VoiceDubError.upgradeRequired,
      'upgrade required',
      statusCode: 402,
    );
  }
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw VoiceDubException(
      VoiceDubError.other,
      res.body.length > 400 ? '${res.body.substring(0, 400)}…' : res.body,
      statusCode: res.statusCode,
    );
  }
  final decoded = jsonDecode(res.body);
  if (decoded is! Map || decoded['audioUrl'] is! String) {
    throw VoiceDubException(VoiceDubError.other, 'unexpected response shape');
  }
  return VoiceDubResult(
    audioUrl: decoded['audioUrl'] as String,
    cached: decoded['cached'] == true,
  );
}
