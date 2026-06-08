/// Language routing for a future **OpenAI Realtime** (or similar) translation bridge.
///
/// **Convention (1:1 calls)** — same names as JWT metadata `sourceLang` / `targetLang`:
/// - [sourceBcp47]: **Your** spoken language (e.g. `fr`). The pipeline should turn the
///   other person's speech **into** this language so **you** hear in your own language.
/// - [targetBcp47]: **The other person's** spoken language (e.g. `en`). Your speech should
///   be translated **into** this language so **they** hear you in theirs.
///
/// Example: you set `fr` + `en` → you speak French, they speak English; your audio is
/// translated to English for them; their audio is translated to French for you.
class TranslationRoute {
  const TranslationRoute({
    required this.sourceBcp47,
    required this.targetBcp47,
  });

  /// Your language (BCP-47). Empty = not configured.
  final String sourceBcp47;

  /// The other person's language (BCP-47). Empty = not configured.
  final String targetBcp47;

  bool get isConfigured =>
      sourceBcp47.trim().isNotEmpty && targetBcp47.trim().isNotEmpty;
}
