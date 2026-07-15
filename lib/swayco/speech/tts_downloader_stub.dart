import 'tts_catalogue.dart';

/// Web: no filesystem, no voice bundles. Shape-compatible with the native
/// [TtsBundleDownloader]; every caller in [SpeechService] is `kIsWeb`-guarded,
/// so none of this ever runs.
class TtsBundleDownloader {
  static Future<bool> isInstalled(TtsModelSpec spec) async => false;
  static Future<void> pruneExcept(Set<String> keepIds) async {}

  Future<BundleDir> ensureBundle(
    TtsModelSpec spec, {
    void Function(double)? onProgress,
  }) async =>
      const BundleDir();
}

/// Stands in for `dart:io`'s `Directory` — call sites only read `.path`.
class BundleDir {
  const BundleDir();
  String get path => '';
}
