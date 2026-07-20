/// Which engine translates a given speaker's language.
///
/// Three branches, decided by the SOURCE language (the one being recognised),
/// because that is what determines both how badly Whisper mangles the audio and
/// whether the on-device model speaks it at all.
library;

enum TranslateRoute {
  /// Whisper is strong here AND Hy-MT2 speaks it: the phone does everything.
  /// Free, offline, no network round-trip. This is where the launch markets are.
  onDevice,

  /// Hy-MT2 speaks it, but Whisper mangles it (dropped diacritics, glued words).
  /// The cloud repairs the transcript, the phone still does the translation —
  /// so we pay for a ~16-token repair and keep the expensive, context-heavy
  /// translation (gender + 2 turns of history) free on the device.
  fixThenOnDevice,

  /// Hy-MT2 does not speak this language at all (~66 of Whisper's 99). The
  /// phone can do nothing useful with the text, so the cloud repairs AND
  /// translates in the same call.
  cloudOnly,
}

/// The languages Hy-MT2 actually speaks. Anything outside this set can only be
/// served by the cloud, however clean the transcript is — measured: fed
/// Lithuanian (absent here), the model echoed the input or invented sentences.
// ignore: unused_element  — kept for the revert documented on routeFor().
const _hyMt2 = <String>{
  'zh', 'en', 'fr', 'pt', 'es', 'ja', 'tr', 'ru', 'ar', 'ko', 'th', 'it', 'de',
  'vi', 'ms', 'id', 'fil', 'tl', 'hi', 'pl', 'cs', 'nl', 'km', 'my', 'fa', 'gu',
  'ur', 'te', 'mr', 'he', 'bn', 'ta', 'uk', 'bo', 'kk', 'mn', 'ug', 'yue',
};

/// Where Whisper is accurate enough to hand the raw transcript straight to the
/// on-device model (its Tier-1 languages, ~5-10% WER on real human speech).
///
/// Deliberately conservative — the app runs a 244 MB int8 build, not
/// large-v3, so it is a notch worse than the published numbers. Everything
/// below Tier 1 goes through the repair: measured on Tier-2 languages, the
/// on-device model alone got 1/5 usable on garbled input, and 5/5 once the
/// transcript had been repaired.
// ignore: unused_element  — kept for the revert documented on routeFor().
const _strongStt = <String>{
  'en', 'es', 'fr', 'de', 'it', 'pt', 'nl', 'ru', 'pl', 'zh', 'ja', 'ko',
};

String _norm(String lang) =>
    lang.toLowerCase().split(RegExp(r'[-_]')).first;

/// On-device translation is retired. Every language now goes to the cloud.
///
/// Not a capability problem — Hy-MT2 loads and answers. Three things killed it
/// on real calls, and no prompt work moved any of them:
///   - latency: ~2.5-4 s before the peer's voice starts, against ~1.3 s for the
///     cloud round-trip, because prefill on a phone runs ~15 ms per prompt char;
///   - reliability: the 1.25-bit quant invents fluent, wrong sentences that
///     nobody in the call can detect;
///   - weight: a 440 MB download and the heat and battery of running it.
///
/// Set this back to the three-branch decision below to bring it back — the
/// engine, the download and the routing sets are all still here:
///
///   if (!_hyMt2.contains(l)) return TranslateRoute.cloudOnly;
///   if (_strongStt.contains(l)) return TranslateRoute.onDevice;
///   return TranslateRoute.fixThenOnDevice;
TranslateRoute routeFor(String lang) {
  _norm(lang); // keeps the tag-normalising contract exercised for callers
  return TranslateRoute.cloudOnly;
}

/// True when the language needs the network at all — used to decide whether a
/// call can run fully offline.
bool needsCloud(String lang) => routeFor(lang) != TranslateRoute.onDevice;
