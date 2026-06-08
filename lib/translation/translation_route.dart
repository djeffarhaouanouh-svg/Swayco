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

  /// The other person's spoken language (BCP-47). OPTIONAL: only a HINT for the
  /// OpenAI realtime-translate model, which auto-detects the input language
  /// (the backend doesn't even forward it unless an env gate is on). May be
  /// empty when the remote joined with no `sourceLang` in their JWT metadata.
  final String targetBcp47;

  /// Configured as soon as we know OUR output language ([sourceBcp47]) — the
  /// one thing the pipeline truly needs. The remote's language ([targetBcp47])
  /// is only an auto-detect hint, so we must NOT gate on it: doing so left the
  /// side whose peer joined without a `sourceLang` unable to translate at all
  /// ("only one side hears the translation"). With this relaxed gate that side
  /// still translates the auto-detected remote speech into [sourceBcp47], and
  /// re-binds with the hint later if the remote's language becomes known.
  bool get isConfigured => sourceBcp47.trim().isNotEmpty;
}
