/// Web-safe front door to [TtsBundleDownloader], which needs `dart:io` to write
/// the voice bundle to disk. Nothing is downloaded on the web, but the import
/// alone would break the build — hence the stub.
library;
export 'tts_downloader_stub.dart'
    if (dart.library.io) 'tts_bundle_downloader.dart';
