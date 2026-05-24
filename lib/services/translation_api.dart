import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../config/app_config.dart';

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

Map<String, dynamic> _decodeObjectMap(String body) {
  final decoded = jsonDecode(body);
  if (decoded is Map) {
    return Map<String, dynamic>.from(decoded);
  }
  throw FormatException('response is not a JSON object');
}

/// Extract [expires_at] from OpenAI `client_secrets` response (seconds or ms since epoch).
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

/// Extract ephemeral client secret from OpenAI `client_secrets` JSON (shapes vary).
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
  final res = await http.post(
    uri,
    headers: const {'Content-Type': 'application/json'},
    body: jsonEncode(body),
  );
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
/// (`/translation/text` → OpenAI gpt-4.1 with conversation history and
/// speaker profiles). Returns the translated string; falls back to the
/// original [text] on any error so the UI never goes blank.
Future<String> fetchTextTranslation({
  required String text,
  required String to,
  String? from,
  List<TranslationHistoryItem>? history,
  TranslationContext? context,
}) async {
  if (text.trim().isEmpty) return text;
  final uri = _translationTextUri();
  try {
    final body = <String, dynamic>{
      'text': text,
      if (from != null && from.isNotEmpty) 'from': from,
      'to': to,
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
