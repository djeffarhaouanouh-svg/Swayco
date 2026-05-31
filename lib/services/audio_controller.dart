import 'dart:async';

import 'package:flutter/foundation.dart';

import '../translation/realtime_translation_port.dart';
import 'user_prefs.dart';

/// DIAGNOSTIC BUILD 6.1.2+8 — original AudioController wrapped LiveKit
/// (Hardware.instance, Room participants, RemoteAudioTrack volume) +
/// flutter_webrtc (rtc.Helper.setVolume). Both packages are removed
/// from the diagnostic build, so this file is replaced with a no-op
/// stub that keeps the public surface intact for any caller that
/// transitively imports it. Once the diagnostic build's behavior on
/// real devices proves out, `git revert` restores the real controller.

/// Possible audio output destinations as seen from the call screen.
enum AudioRoute { speaker, earpiece, wiredHeadset, bluetooth }

class AudioController extends ChangeNotifier {
  AudioController({
    required RealtimeTranslationPort translation,
  }) : _translation = translation;

  // ignore: unused_field
  final RealtimeTranslationPort _translation;

  AudioPrefs _prefs = const AudioPrefs(
    translatedVolume: 1.0,
    originalVolume: 1.0,
    duckingEnabled: true,
    speakerOn: true,
  );

  final AudioRoute _route = AudioRoute.speaker;
  final double _micLevel = 0;
  final bool _isDucking = false;
  bool _bound = false;

  double get translatedVolume => _prefs.translatedVolume;
  double get originalVolume => _prefs.originalVolume;
  bool get duckingEnabled => _prefs.duckingEnabled;
  bool get speakerOn => _prefs.speakerOn;
  AudioRoute get route => _route;
  double get micLevel => _micLevel;
  bool get isDucking => _isDucking;

  Future<void> bind(Object? room) async {
    _prefs = await UserPrefs.loadAudio();
    _bound = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _bound = false;
    super.dispose();
  }

  Future<void> setTranslatedVolume(double v) async {
    final clamped = v.clamp(0.0, 1.0);
    _prefs = _prefs.copyWith(translatedVolume: clamped);
    notifyListeners();
    unawaited(UserPrefs.saveAudio(_prefs));
  }

  Future<void> setOriginalVolume(double v) async {
    final clamped = v.clamp(0.0, 1.0);
    _prefs = _prefs.copyWith(originalVolume: clamped);
    notifyListeners();
    unawaited(UserPrefs.saveAudio(_prefs));
  }

  Future<void> setDuckingEnabled(bool enabled) async {
    _prefs = _prefs.copyWith(duckingEnabled: enabled);
    notifyListeners();
    unawaited(UserPrefs.saveAudio(_prefs));
  }

  Future<void> setSpeakerOn(bool on) async {
    _prefs = _prefs.copyWith(speakerOn: on);
    notifyListeners();
    unawaited(UserPrefs.saveAudio(_prefs));
  }

  void onTranslationSpeaking(bool speaking) {
    if (!_bound) return;
  }
}
