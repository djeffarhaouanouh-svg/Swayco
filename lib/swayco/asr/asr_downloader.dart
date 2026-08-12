/// Web-safe front door to [AsrModelDownloader] (`dart:io`). The ASR *engine*
/// already had a web stub; its downloader never got one, so the web build still
/// pulled `dart:io` in through `asr_service.dart`.
library;
export 'asr_downloader_stub.dart'
    if (dart.library.io) 'asr_model_downloader.dart';
