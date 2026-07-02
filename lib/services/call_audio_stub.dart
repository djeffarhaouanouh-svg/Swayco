import 'dart:typed_data';

/// Native: no web-audio unlock needed; call_screen uses audioplayers directly.
void armCallAudio() {}
void armSpeechSynthesis() {}

Future<bool> playTranslatedMp3(Uint8List bytes) async => false;

bool get isTranslationPlaying => false;
void markTranslationPlaying({int textLength = 0}) {}
void markTranslationDone() {}
bool get isSendMuted => false;
void setSendMuted(bool v) {}
void registerCaptureContext(dynamic ctx) {}
