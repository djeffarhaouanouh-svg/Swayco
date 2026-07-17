import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';

/// The signed-in user's Supabase JWT, or null for guests / when Supabase isn't
/// initialised. Attached to the translation-session request so the backend can
/// gate on the caller's remaining live-translation credits.
String? _supabaseAccessToken() {
  try {
    return Supabase.instance.client.auth.currentSession?.accessToken;
  } catch (_) {
    return null;
  }
}

class TranslationApiException implements Exception {
  TranslationApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => 'TranslationApiException($statusCode): $message';
}

Uri _translationSessionUri() {
  const fromEnv = String.fromEnvironment('TOKEN_API_BASE');
  if (fromEnv.isNotEmpty) {
    final b = fromEnv.replaceAll(RegExp(r'/$'), '');
    return Uri.parse('$b/translation/realtime/session');
  }
  if (kIsWeb) {
    final o = Uri.base.removeFragment();
    return Uri(
      scheme: o.scheme,
      host: o.host,
      port: o.hasPort ? o.port : null,
      path: '/translation/realtime/session',
    );
  }
  final b = resolvedTokenApiBase().replaceAll(RegExp(r'/$'), '');
  return Uri.parse('$b/translation/realtime/session');
}

Uri _translationCallsUri() {
  const fromEnv = String.fromEnvironment('TOKEN_API_BASE');
  if (fromEnv.isNotEmpty) {
    final b = fromEnv.replaceAll(RegExp(r'/$'), '');
    return Uri.parse('$b/translation/realtime/calls');
  }
  if (kIsWeb) {
    final o = Uri.base.removeFragment();
    return Uri(
      scheme: o.scheme,
      host: o.host,
      port: o.hasPort ? o.port : null,
      path: '/translation/realtime/calls',
    );
  }
  final b = resolvedTokenApiBase().replaceAll(RegExp(r'/$'), '');
  return Uri.parse('$b/translation/realtime/calls');
}

Uri _translationTextUri() {
  const fromEnv = String.fromEnvironment('TOKEN_API_BASE');
  if (fromEnv.isNotEmpty) {
    final b = fromEnv.replaceAll(RegExp(r'/$'), '');
    return Uri.parse('$b/translation/text');
  }
  if (kIsWeb) {
    final o = Uri.base.removeFragment();
    return Uri(
      scheme: o.scheme,
      host: o.host,
      port: o.hasPort ? o.port : null,
      path: '/translation/text',
    );
  }
  final b = resolvedTokenApiBase().replaceAll(RegExp(r'/$'), '');
  return Uri.parse('$b/translation/text');
}

Uri _translationTtsUri() {
  const fromEnv = String.fromEnvironment('TOKEN_API_BASE');
  if (fromEnv.isNotEmpty) {
    final b = fromEnv.replaceAll(RegExp(r'/$'), '');
    return Uri.parse('$b/translation/tts');
  }
  if (kIsWeb) {
    final o = Uri.base.removeFragment();
    return Uri(
      scheme: o.scheme,
      host: o.host,
      port: o.hasPort ? o.port : null,
      path: '/translation/tts',
    );
  }
  final b = resolvedTokenApiBase().replaceAll(RegExp(r'/$'), '');
  return Uri.parse('$b/translation/tts');
}

Uri _translationVoiceUri() {
  const fromEnv = String.fromEnvironment('TOKEN_API_BASE');
  if (fromEnv.isNotEmpty) {
    final b = fromEnv.replaceAll(RegExp(r'/$'), '');
    return Uri.parse('$b/translation/voice');
  }
  if (kIsWeb) {
    final o = Uri.base.removeFragment();
    return Uri(
      scheme: o.scheme,
      host: o.host,
      port: o.hasPort ? o.port : null,
      path: '/translation/voice',
    );
  }
  final b = resolvedTokenApiBase().replaceAll(RegExp(r'/$'), '');
  return Uri.parse('$b/translation/voice');
}

/// Realtime STT WebSocket URI: `ws(s)://<backend>/translation/voice/stt`
/// Sender-side route: [from] = my spoken language, [to] = the peer's language
/// (the language we translate INTO and speak to them). Mirrors the resolution
/// of [_translationVoiceUri] but swaps the scheme to ws/wss.
Uri voiceSttWsUri({
  required String from,
  required String to,
  String voice = 'eve',
  // When true the backend skips cloud TTS and sends only translated text;
  // the native app generates audio locally with the local TTS engine.
  bool localTts = false,
}) {
  final query = <String, String>{
    if (from.isNotEmpty) 'from': from,
    'to': to,
    'voice': voice,
    'sample_rate': '16000',
    if (localTts) 'local_tts': 'true',
  };
  String wsScheme(String httpScheme) => httpScheme == 'https' ? 'wss' : 'ws';
  Uri build(String scheme, String host, int? port) => Uri(
        scheme: wsScheme(scheme),
        host: host,
        port: port,
        path: '/translation/voice/stt',
        queryParameters: query,
      );

  const fromEnv = String.fromEnvironment('TOKEN_API_BASE');
  if (fromEnv.isNotEmpty) {
    final u = Uri.parse(fromEnv.replaceAll(RegExp(r'/$'), ''));
    return build(u.scheme, u.host, u.hasPort ? u.port : null);
  }
  if (kIsWeb) {
    final o = Uri.base.removeFragment();
    return build(o.scheme, o.host, o.hasPort ? o.port : null);
  }
  final u = Uri.parse(resolvedTokenApiBase().replaceAll(RegExp(r'/$'), ''));
  return build(u.scheme, u.host, u.hasPort ? u.port : null);
}

Map<String, dynamic> _decodeObjectMap(String body) {
  final decoded = jsonDecode(body);
  if (decoded is Map) {
    return Map<String, dynamic>.from(decoded);
  }
  throw FormatException('response is not a JSON object');
}

/// Extract [expires_at] from the live engine `client_secrets` response (seconds or ms since epoch).
DateTime? pickSessionExpiresAt(Map<String, dynamic> j) {
  num? n;
  final cs = j['client_secret'];
  if (cs is Map && cs['expires_at'] != null) {
    final v = cs['expires_at'];
    if (v is num) {
      n = v;
    } else if (v is String) {
      n = num.tryParse(v.trim());
    }
  }
  if (n == null && j['expires_at'] != null) {
    final v = j['expires_at'];
    if (v is num) {
      n = v;
    } else if (v is String) {
      n = num.tryParse(v.trim());
    }
  }
  if (n == null) return null;
  final v = n.toDouble();
  if (v > 1e12) {
    return DateTime.fromMillisecondsSinceEpoch(v.toInt());
  }
  return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());
}

/// Extract ephemeral client secret from the live engine `client_secrets` JSON (shapes vary).
String? pickClientSecret(Map<String, dynamic> j) {
  final cs = j['client_secret'];
  if (cs is String && cs.isNotEmpty) return cs;
  if (cs is Map) {
    final v = cs['value'];
    if (v is String && v.isNotEmpty) return v;
  }
  final top = j['value'];
  if (top is String && top.isNotEmpty) return top;
  return null;
}

Future<Map<String, dynamic>> fetchTranslationSession({
  required String outputLanguage,
  String? inputLanguage,
}) async {
  final uri = _translationSessionUri();
  final body = <String, dynamic>{'outputLanguage': outputLanguage};
  if (inputLanguage != null && inputLanguage.trim().isNotEmpty) {
    body['inputLanguage'] = inputLanguage;
  }
  final headers = <String, String>{'Content-Type': 'application/json'};
  final token = _supabaseAccessToken();
  if (token != null && token.isNotEmpty) {
    headers['Authorization'] = 'Bearer $token';
  }
  final res = await http.post(uri, headers: headers, body: jsonEncode(body));
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw TranslationApiException(
      res.body.length > 400 ? '${res.body.substring(0, 400)}…' : res.body,
      statusCode: res.statusCode,
    );
  }
  return _decodeObjectMap(res.body);
}

Future<String> postTranslationCallsSdp({
  required String clientSecret,
  required String sdpOffer,
}) async {
  final uri = _translationCallsUri();
  final res = await http.post(
    uri,
    headers: {
      'Authorization': 'Bearer $clientSecret',
      'Content-Type': 'application/sdp',
    },
    body: sdpOffer,
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw TranslationApiException(
      res.body.length > 400 ? '${res.body.substring(0, 400)}…' : res.body,
      statusCode: res.statusCode,
    );
  }
  return res.body;
}

/// One thread message used as translation context. `author` is "me" when
/// the local user wrote it (the reader of the translation), "peer" when
/// the other party did. `text` is the original (untranslated) body.
class TranslationHistoryItem {
  const TranslationHistoryItem({
    required this.author,
    required this.text,
  });
  final String author; // "me" | "peer"
  final String text;

  Map<String, dynamic> toJson() => {
        'author': author,
        'text': text,
      };
}

/// Conversation-level context that lets the translator pick the right
/// gender agreement, pronouns and register. All fields are optional —
/// the backend will fill in safe defaults for anything missing.
class TranslationContext {
  const TranslationContext({
    this.authorName,
    this.authorGender,
    this.authorLang,
    this.peerName,
    this.peerGender,
    this.peerLang,
    this.relationship,
  });
  final String? authorName;
  final String? authorGender; // "m" | "f" | "x"
  final String? authorLang;
  final String? peerName;
  final String? peerGender;
  final String? peerLang;
  final String? relationship;

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{};
    if (authorName != null && authorName!.isNotEmpty) m['authorName'] = authorName;
    if (authorGender != null && authorGender!.isNotEmpty) m['authorGender'] = authorGender;
    if (authorLang != null && authorLang!.isNotEmpty) m['authorLang'] = authorLang;
    if (peerName != null && peerName!.isNotEmpty) m['peerName'] = peerName;
    if (peerGender != null && peerGender!.isNotEmpty) m['peerGender'] = peerGender;
    if (peerLang != null && peerLang!.isNotEmpty) m['peerLang'] = peerLang;
    if (relationship != null && relationship!.isNotEmpty) m['relationship'] = relationship;
    return m;
  }
}

/// Context-aware chat-message translation via the backend
/// (`/translation/text`, which prompts the text engine with conversation history and
/// speaker profiles). Returns the translated string; falls back to the
/// original [text] on any error so the UI never goes blank.
/// Set [speech] when [text] is a raw on-device STT transcript rather than
/// something the user typed: it tells the backend to expect phonetic errors and
/// translate the intended meaning instead of the mis-hearing. Never set it for
/// a typed message — those mean exactly what they say.
Future<String> fetchTextTranslation({
  required String text,
  required String to,
  String? from,
  List<TranslationHistoryItem>? history,
  TranslationContext? context,
  bool speech = false,
}) async {
  if (text.trim().isEmpty) return text;
  final uri = _translationTextUri();
  try {
    final body = <String, dynamic>{
      'text': text,
      if (from != null && from.isNotEmpty) 'from': from,
      'to': to,
      if (speech) 'speech': true,
    };
    if (history != null && history.isNotEmpty) {
      body['history'] = history.map((h) => h.toJson()).toList();
    }
    if (context != null) {
      final c = context.toJson();
      if (c.isNotEmpty) body['context'] = c;
    }
    final res = await http.post(
      uri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      return text;
    }
    final j = _decodeObjectMap(res.body);
    final t = j['translated'];
    return t is String && t.isNotEmpty ? t : text;
  } catch (_) {
    return text;
  }
}

/// Text-to-speech via the backend (`/translation/tts`, which drives the cloud
/// voice engine). POSTs the text (+ optional BCP-47 [lang] and [voice])
/// and returns the spoken audio bytes (mp3), or null on any error so the
/// caller can silently skip playback. The backend is expected to return the
/// raw audio body (Content-Type audio/mpeg).
Future<Uint8List?> fetchSpeech({
  required String text,
  String? lang,
  String voice = 'alloy',
}) async {
  if (text.trim().isEmpty) return null;
  final uri = _translationTtsUri();
  try {
    final res = await http.post(
      uri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'text': text,
        if (lang != null && lang.isNotEmpty) 'lang': lang,
        'voice': voice,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    return res.bodyBytes.isEmpty ? null : res.bodyBytes;
  } catch (_) {
    return null;
  }
}

/// Result of the cloud engine TEST pipeline: translated speech [audio] (mp3) plus the
/// recognised [transcript] and [translation] (echoed by the backend headers,
/// handy for the on-screen debug panel). Any field can be empty/null.
class SwayTranslationResult {
  const SwayTranslationResult({this.audio, this.transcript, this.translation});
  final Uint8List? audio;
  final String? transcript;
  final String? translation;
}

/// TEST — non-streaming clip STT (VAD-segmented). Web-only; revert with the
/// rest of the experiment.
///
/// One VAD-clipped utterance ([wavBytes], 16 kHz mono PCM16 WAV) → recogniser →
/// translation. Text only: the peer speaks it with its device TTS, so no audio
/// comes back. Returns null when the backend heard nothing (HTTP 204) or on any
/// error — a dropped segment must never tear the call down.
Future<ClipTranslationResult?> fetchClipTranslation({
  required Uint8List wavBytes,
  required String to,
  String? from,
}) async {
  if (wavBytes.isEmpty) return null;
  final uri = _translationUri('/translation/clip');
  try {
    final req = http.MultipartRequest('POST', uri)..fields['to'] = to;
    if (from != null && from.isNotEmpty) req.fields['from'] = from;
    final token = _supabaseAccessToken();
    if (token != null && token.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $token';
    }
    req.files.add(
      http.MultipartFile.fromBytes('audio', wavBytes, filename: 'utt.wav'),
    );
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode != 200) return null; // 204 = nothing said; 4xx/5xx = drop
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final trans = (body['trans'] ?? '').toString();
    if (trans.isEmpty) return null;
    final ms = (body['ms'] as Map?) ?? const {};
    return ClipTranslationResult(
      orig: (body['orig'] ?? '').toString(),
      trans: trans,
      lang: (body['lang'] ?? to).toString(),
      sttMs: (ms['stt'] as num?)?.toInt() ?? 0,
      translateMs: (ms['translate'] as num?)?.toInt() ?? 0,
    );
  } catch (_) {
    return null;
  }
}

class ClipTranslationResult {
  const ClipTranslationResult({
    required this.orig,
    required this.trans,
    required this.lang,
    required this.sttMs,
    required this.translateMs,
  });
  final String orig;
  final String trans;
  final String lang;
  final int sttMs;
  final int translateMs;
}

/// Same host resolution as the other `_translation*Uri()` builders above, but
/// takes the path — added for the streaming test rather than copy-pasting a sixth
/// identical function.
Uri _translationUri(String path) {
  const fromEnv = String.fromEnvironment('TOKEN_API_BASE');
  if (fromEnv.isNotEmpty) {
    return Uri.parse('${fromEnv.replaceAll(RegExp(r'/$'), '')}$path');
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
  return Uri.parse('${resolvedTokenApiBase().replaceAll(RegExp(r'/$'), '')}$path');
}

/// Posts one captured utterance ([audioBytes], with [mimeType] / [filename]
/// matching the recorder's container) to `/translation/voice`, which runs it
/// fully through the cloud engine (STT → translate → TTS) and returns the spoken
/// translation as mp3 bytes. Returns null on any error or when the backend
/// found nothing to say (HTTP 204). Does NOT touch the live pipeline.
Future<SwayTranslationResult?> fetchVoiceTranslation({
  required Uint8List audioBytes,
  required String to,
  String? from,
  String voice = 'eve',
  String filename = 'utt.webm',
}) async {
  if (audioBytes.isEmpty) return null;
  final uri = _translationVoiceUri();
  try {
    final req = http.MultipartRequest('POST', uri)
      ..fields['to'] = to
      ..fields['voice'] = voice;
    if (from != null && from.isNotEmpty) req.fields['from'] = from;
    final token = _supabaseAccessToken();
    if (token != null && token.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $token';
    }
    // No explicit contentType (avoids the http_parser MediaType dep) — the
    // backend infers the codec from the filename extension, same as
    // /messages/voice.
    req.files.add(http.MultipartFile.fromBytes(
      'audio',
      audioBytes,
      filename: filename,
    ));
    final streamed = await req.send();
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode == 204) return null; // nothing said
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw TranslationApiException(
        res.body.length > 300 ? '${res.body.substring(0, 300)}…' : res.body,
        statusCode: res.statusCode,
      );
    }
    String? decodeHeader(String key) {
      final v = res.headers[key];
      if (v == null || v.isEmpty) return null;
      try {
        return Uri.decodeComponent(v);
      } catch (_) {
        return v;
      }
    }

    // `x-grok-*` is the legacy spelling: fall back to it so a client shipped
    // ahead of the backend deploy still surfaces the debug transcript.
    String? header(String name, String legacy) =>
        decodeHeader(name) ?? decodeHeader(legacy);

    return SwayTranslationResult(
      audio: res.bodyBytes.isEmpty ? null : res.bodyBytes,
      transcript: header('x-sway-transcript', 'x-grok-transcript'),
      translation: header('x-sway-translation', 'x-grok-translation'),
    );
  } catch (e) {
    if (e is TranslationApiException) rethrow;
    return null;
  }
}
