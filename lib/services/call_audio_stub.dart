import 'dart:typed_data';

/// Native: no web-audio unlock needed; call_screen uses audioplayers directly.
void armCallAudio() {}

Future<bool> playTranslatedMp3(Uint8List bytes) async => false;

bool get isTranslationPlaying => false;
