import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
// Not re-exported by livekit's barrel, but we need them to make LiveKit's own
// iOS audio-session config use mixWithOthers too (it otherwise overrides the
// AppDelegate's mix config when the call connects).
// ignore: implementation_imports
import 'package:livekit_client/src/support/native_audio.dart';
// ignore: implementation_imports
import 'package:livekit_client/src/track/audio_management.dart';

import '../translation/realtime_translation_port.dart';
import 'livekit_web_audio.dart';
import 'user_prefs.dart';

/// Possible audio output destinations as seen from the call screen.
/// On mobile, headset / Bluetooth are auto-routed by the OS — we only
/// surface them here for the visual indicator.
enum AudioRoute { speaker, earpiece, wiredHeadset, bluetooth }

/// Owns the per-call audio settings: translated-audio volume, ducking of
/// the original remote audio while the translation is hot, speakerphone
/// route, and a periodic mic VU sample. Persists user-controllable bits
/// to [UserPrefs] so they carry across calls.
class AudioController extends ChangeNotifier {
  AudioController({
    required RealtimeTranslationPort translation,
  }) : _translation = translation;

  final RealtimeTranslationPort _translation;
  Room? _room;

  AudioPrefs _prefs = const AudioPrefs(
    translatedVolume: 1.0,
    originalVolume: 1.0,
    duckingEnabled: true,
    speakerOn: true,
  );

  AudioRoute _route = AudioRoute.speaker;
  double _micLevel = 0;
  bool _isDucking = false;
  Timer? _duckRelease;
  Timer? _micTimer;
  StreamSubscription<List<MediaDevice>>? _deviceSub;
  bool _bound = false;

  /// Translated-audio volume in [0, 1]. User-controllable.
  double get translatedVolume => _prefs.translatedVolume;

  /// Original (LiveKit) remote-audio volume in [0, 1]. User-controllable.
  /// When ducking is engaged this baseline is multiplied by [_duckedLevel].
  double get originalVolume => _prefs.originalVolume;

  /// Whether the original (LiveKit) remote audio is auto-lowered while
  /// the translated audio is actually playing back.
  bool get duckingEnabled => _prefs.duckingEnabled;

  /// Whether the loudspeaker is routed (vs. earpiece). Ignored on
  /// desktop / web — only meaningful on iOS / Android.
  bool get speakerOn => _prefs.speakerOn;

  /// Current effective output route. On mobile, the OS auto-switches to
  /// wired headset / Bluetooth when one is connected — we surface that
  /// for UI but don't try to override it.
  AudioRoute get route => _route;

  /// Local microphone level in [0, 1], sampled periodically. Useful as
  /// a tiny VU-meter so the user can confirm they are captured.
  double get micLevel => _micLevel;

  /// Whether ducking is currently dampening the original audio.
  bool get isDucking => _isDucking;

  /// Wire up to a connected room. Loads persisted prefs, applies them
  /// to LiveKit + translation port, and starts the listeners that
  /// drive ducking + VU-meter + route detection.
  Future<void> bind(Room room) async {
    _room = room;
    // Make LiveKit's own iOS audio-session config use mixWithOthers too, so it
    // doesn't override the AppDelegate's mix config when the call connects.
    // BOTH configurators must agree for iOS to actually mix the two WebRTC
    // flows (LiveKit original + OpenAI translation) instead of silencing one.
    if (!kIsWeb) {
      onConfigureNativeAudio = (AudioTrackState state) async {
        final base = await defaultNativeAudioConfigurationFunc(state);
        if (base.appleAudioCategory == AppleAudioCategory.soloAmbient) {
          return base; // mixWithOthers is invalid for soloAmbient
        }
        return base.copyWith(
          appleAudioCategoryOptions: {
            ...?base.appleAudioCategoryOptions,
            AppleAudioCategoryOption.mixWithOthers,
          },
        );
      };
    }
    _prefs = await UserPrefs.loadAudio();

    await _applySpeaker(_prefs.speakerOn);
    await _applyTranslatedVolume(_prefs.translatedVolume);
    await _applyOriginalVolume(_prefs.originalVolume);
    _refreshRouteFromDevices();

    _deviceSub = Hardware.instance.onDeviceChange.stream.listen((_) {
      // Re-apply the speaker pref through `_applySpeaker` so that a
      // headset plugged in mid-call instantly takes over from the
      // loudspeaker (and unplugging falls back to the user's pref).
      unawaited(_applySpeaker(_prefs.speakerOn));
      _refreshRouteFromDevices();
    });
    _micTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      _sampleMicLevel();
    });
    _bound = true;
    notifyListeners();
  }

  /// Detach without persisting (prefs are saved on each setter).
  @override
  void dispose() {
    _bound = false;
    _duckRelease?.cancel();
    _micTimer?.cancel();
    unawaited(_deviceSub?.cancel());
    _deviceSub = null;
    _room = null;
    super.dispose();
  }

  Future<void> setTranslatedVolume(double v) async {
    final clamped = v.clamp(0.0, 1.0);
    if ((clamped - _prefs.translatedVolume).abs() < 1e-3) return;
    _prefs = _prefs.copyWith(translatedVolume: clamped);
    await _applyTranslatedVolume(clamped);
    notifyListeners();
    unawaited(UserPrefs.saveAudio(_prefs));
  }

  Future<void> setOriginalVolume(double v) async {
    final clamped = v.clamp(0.0, 1.0);
    if ((clamped - _prefs.originalVolume).abs() < 1e-3) return;
    _prefs = _prefs.copyWith(originalVolume: clamped);
    // If ducking is currently engaged, the active level depends on it.
    final live = _isDucking ? clamped * _duckedLevel : clamped;
    await _applyOriginalVolume(live);
    notifyListeners();
    unawaited(UserPrefs.saveAudio(_prefs));
  }

  Future<void> setDuckingEnabled(bool enabled) async {
    if (enabled == _prefs.duckingEnabled) return;
    _prefs = _prefs.copyWith(duckingEnabled: enabled);
    if (!enabled && _isDucking) {
      _isDucking = false;
      _duckRelease?.cancel();
      await _applyOriginalVolume(_prefs.originalVolume);
    }
    notifyListeners();
    unawaited(UserPrefs.saveAudio(_prefs));
  }

  Future<void> setSpeakerOn(bool on) async {
    if (on == _prefs.speakerOn) return;
    _prefs = _prefs.copyWith(speakerOn: on);
    await _applySpeaker(on);
    _refreshRouteFromDevices();
    notifyListeners();
    unawaited(UserPrefs.saveAudio(_prefs));
  }

  /// Called by the call screen whenever the translated audio starts or
  /// stops playing. Dampens the original remote audio for that window,
  /// with a small release delay so the short gaps between translated
  /// sentences don't make the volume flap.
  void onTranslationSpeaking(bool speaking) {
    if (!_bound) return;
    if (!_prefs.duckingEnabled) return;
    if (speaking) {
      _duckRelease?.cancel();
      if (!_isDucking) {
        _isDucking = true;
        unawaited(_applyOriginalVolume(_prefs.originalVolume * _duckedLevel));
        notifyListeners();
      }
    } else {
      _duckRelease?.cancel();
      _duckRelease = Timer(_duckReleaseDelay, () {
        if (!_bound) return;
        _isDucking = false;
        unawaited(_applyOriginalVolume(_prefs.originalVolume));
        notifyListeners();
      });
    }
  }

  // Duck the original remote audio to 25% (native) while the translation plays
  // so BOTH the real voice and the translation are audible at once. The
  // AppDelegate now sets WebRTC's iOS audio session to mixWithOthers, so the OS
  // MIXES the two WebRTC flows (LiveKit original + OpenAI translation) instead
  // of silencing one (the old FR↔AR arbitration bug, 41f699e) — the same thing
  // the browser already does on web. Web stays 0.0 (it already plays both; its
  // remote audio is driven through the DOM). The original returns to full level
  // [_duckReleaseDelay] after the translation stops.
  static double get _duckedLevel => kIsWeb ? 0.0 : 0.25;
  static const Duration _duckReleaseDelay = Duration(milliseconds: 1400);

  Future<void> _applyTranslatedVolume(double v) async {
    try {
      await _translation.setTranslatedAudioVolume(v);
    } catch (e) {
      debugPrint('AudioController: setTranslatedAudioVolume failed: $e');
    }
  }

  Future<void> _applyOriginalVolume(double v) async {
    // On web, LiveKit plays remote audio through its own hidden <audio>
    // elements, which rtc.Helper.setVolume cannot reach (it only sets a
    // bogus track constraint). Drive those DOM elements directly instead —
    // otherwise the original voice never ducks and bleeds through the
    // translation.
    if (kIsWeb) {
      applyLiveKitRemoteVolumeWeb(v);
      return;
    }
    final room = _room;
    if (room == null) return;
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.audioTrackPublications) {
        final t = pub.track;
        if (t is! RemoteAudioTrack) continue;
        try {
          await rtc.Helper.setVolume(v, t.mediaStreamTrack);
        } catch (e) {
          debugPrint('AudioController: setVolume on remote audio failed: $e');
        }
      }
    }
  }

  /// Apply the wanted speakerphone state, but **never** override the
  /// OS when a wired headset or Bluetooth headset is currently plugged
  /// in — users plug in headphones to use them, period. YouTube /
  /// FaceTime / WhatsApp all behave this way; calling
  /// setSpeakerphoneOn(true) here would silently route the audio out
  /// the loudspeaker even with AirPods in.
  Future<void> _applySpeaker(bool wantedSpeaker) async {
    try {
      final hasHeadset = await _hasHeadsetConnected();
      // If a headset is connected, force speaker off so the OS routes
      // to the headset. Otherwise honour the user's preference.
      final effective = hasHeadset ? false : wantedSpeaker;
      await Hardware.instance.setSpeakerphoneOn(effective);
    } catch (e) {
      debugPrint('AudioController: setSpeakerphoneOn failed: $e');
    }
  }

  Future<bool> _hasHeadsetConnected() async {
    try {
      final outs = await Hardware.instance.audioOutputs();
      for (final d in outs) {
        final l = d.label.toLowerCase();
        if (l.contains('bluetooth') ||
            l.contains('bt ') ||
            l.contains('airpods') ||
            l.contains('a2dp') ||
            l.contains('hands-free') ||
            l.contains('headset') ||
            l.contains('headphone') ||
            l.contains('earphone') ||
            l.contains('wired')) {
          return true;
        }
      }
    } catch (_) {
      // audioOutputs() not supported (older Android, web). Fall back
      // to "no headset known" so the user's pref still applies.
    }
    return false;
  }

  /// Best-effort: scan the output device list (when the platform
  /// exposes it) to detect a wired / Bluetooth headset. On mobile,
  /// the OS auto-routes — we just reflect that in the UI.
  Future<void> _refreshRouteFromDevices() async {
    AudioRoute next = _prefs.speakerOn ? AudioRoute.speaker : AudioRoute.earpiece;
    try {
      final outs = await Hardware.instance.audioOutputs();
      for (final d in outs) {
        final label = d.label.toLowerCase();
        if (label.contains('bluetooth') || label.contains('bt ') ||
            label.contains('airpods') || label.contains('a2dp') ||
            label.contains('hands-free')) {
          next = AudioRoute.bluetooth;
          break;
        }
        if (label.contains('headset') || label.contains('headphone') ||
            label.contains('earphone') || label.contains('wired')) {
          next = AudioRoute.wiredHeadset;
          break;
        }
      }
    } catch (_) {
      // enumerateDevices not supported on this platform — keep the
      // speaker/earpiece value derived from the preference.
    }
    if (next != _route) {
      _route = next;
      notifyListeners();
    }
  }

  Future<void> _sampleMicLevel() async {
    final room = _room;
    if (room == null) {
      if (_micLevel != 0) {
        _micLevel = 0;
        notifyListeners();
      }
      return;
    }
    final lp = room.localParticipant;
    if (lp == null) return;
    final level = lp.audioLevel;
    final smoothed = math.max(level, _micLevel * 0.7);
    if ((smoothed - _micLevel).abs() > 0.01) {
      _micLevel = smoothed;
      notifyListeners();
    }
  }
}
