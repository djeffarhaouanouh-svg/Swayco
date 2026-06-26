import 'dart:typed_data';

import 'call_audio_stub.dart'
    if (dart.library.js_interop) 'call_audio_web.dart' as impl;

/// Arm web audio inside a user gesture (the Accept-call button) so WebKit lets
/// us play incoming translations. No-op on native.
void armCallAudio() => impl.armCallAudio();

/// Play an mp3 through the unlocked web element. Returns false on native / on
/// failure, so the caller falls back to audioplayers.
Future<bool> playTranslatedMp3(Uint8List bytes) => impl.playTranslatedMp3(bytes);
