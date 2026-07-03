import 'dart:typed_data';

import 'call_audio_stub.dart'
    if (dart.library.js_interop) 'call_audio_web.dart' as impl;

/// Arm web audio inside a user gesture (the Accept-call button) so WebKit lets
/// us play incoming translations. No-op on native.
void armCallAudio() => impl.armCallAudio();

/// Unlock speechSynthesis (FlutterTts web) inside a user-gesture so iOS
/// Safari allows subsequent non-gesture TTS calls.
void armSpeechSynthesis() => impl.armSpeechSynthesis();

/// Wake speechSynthesis if the browser auto-paused it — call before every
/// FlutterTts.speak() on web so the TTS actually plays. No-op on native.
void resumeSpeechSynthesisIfPaused() => impl.resumeSpeechSynthesisIfPaused();

/// Play an mp3 through the unlocked web element. Returns false on native / on
/// failure, so the caller falls back to audioplayers.
Future<bool> playTranslatedMp3(Uint8List bytes) => impl.playTranslatedMp3(bytes);

/// True while a translation is playing (web). Lets the mic streamer go
/// half-duplex so it doesn't re-capture our own playback.
bool get isTranslationPlaying => impl.isTranslationPlaying;

void markTranslationPlaying({int textLength = 0}) =>
    impl.markTranslationPlaying(textLength: textLength);
void markTranslationDone() => impl.markTranslationDone();

/// Sync the mic mute state to SEND — when mic is off, SEND stops streaming.
bool get isSendMuted => impl.isSendMuted;
void setSendMuted(bool v) => impl.setSendMuted(v);

/// Register the ScriptProcessor AudioContext so markTranslationPlaying can
/// suspend it (physically stopping capture) during TTS playback.
// ignore: avoid_dynamic_calls
void registerCaptureContext(dynamic ctx) => impl.registerCaptureContext(ctx);
