import 'app_strings.dart';
import 'translation_api.dart';

/// In-memory cache of translated free-text profile fields (bio today).
/// Key: `profileId|field|toLang` → translated string.
final Map<String, String> _kProfileTextCache = {};

/// In-flight requests so two widgets asking for the same bio don't double-hit
/// the API.
final Map<String, Future<String>> _kProfileTextInflight = {};

String _cacheKey(String profileId, String field, String to) =>
    '$profileId|$field|$to';

/// Translate a free-text profile field into the viewer's UI language.
///
/// Skips the network when [fromLang] matches the viewer, when [text] is empty,
/// or when a cached result already exists. On any failure the original [text]
/// is returned (same contract as chat auto-translate).
Future<String> translateProfileText({
  required String text,
  required String profileId,
  required String field,
  String fromLang = '',
}) async {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return text;

  final to = AppStrings.currentBcp47.value;
  final from = fromLang.trim().toLowerCase().split('-').first;
  if (from.isNotEmpty && from == to) return text;

  final key = _cacheKey(profileId, field, to);
  final cached = _kProfileTextCache[key];
  if (cached != null) return cached;

  final inflight = _kProfileTextInflight[key];
  if (inflight != null) return inflight;

  final future = () async {
    final translated = await fetchTextTranslation(
      text: trimmed,
      to: to,
      from: from.isEmpty ? null : from,
    );
    _kProfileTextCache[key] = translated;
    return translated;
  }();

  _kProfileTextInflight[key] = future;
  try {
    return await future;
  } finally {
    _kProfileTextInflight.remove(key);
  }
}
