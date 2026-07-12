import 'asr_catalogue.dart';

/// Web: on-device STT is unavailable (see `asr_engine_stub.dart`), so there is
/// no model to fetch. Shape-compatible with the native [AsrModelDownloader].
class AsrModelDownloader {
  static Future<bool> isInstalled(AsrModelSpec spec) async => false;
  static Future<void> pruneExcept(AsrModelSpec keep) async {}

  Future<ModelDir> ensureModel(
    AsrModelSpec spec, {
    void Function(double)? onProgress,
  }) async =>
      const ModelDir();
}

/// Stands in for `dart:io`'s `Directory` — call sites only read `.path`.
class ModelDir {
  const ModelDir();
  String get path => '';
}
