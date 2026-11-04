import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'swayco_sounds.dart';
import 'voice_clip_base.dart';

/// Mobile / bureau : `audioplayers`.
VoiceClip createVoiceClip() => _AudioPlayersClip();

/// `onLog` mélange infos et erreurs : sur iPhone il émet à chaque changement
/// d'état (« player status: AVPlayerItemStatus(rawValue: 1), change: … » =
/// prêt à lire). Seuls les vrais messages d'erreur comptent ; un échec de
/// `play()` lui-même est attrapé par le widget.
bool isRealPlayerError(String m) => RegExp(
      r'error|fail|exception|invalid|unsupported|cannot|could not',
      caseSensitive: false,
    ).hasMatch(m);

class _AudioPlayersClip implements VoiceClip {
  final AudioPlayer _p = AudioPlayer();

  @override
  Stream<bool> get playing =>
      _p.onPlayerStateChanged.map((s) => s == PlayerState.playing);

  @override
  Stream<Duration> get position => _p.onPositionChanged;

  @override
  Stream<Duration> get duration => _p.onDurationChanged;

  @override
  Stream<void> get completed => _p.onPlayerComplete;

  /// `onLog` mélange infos et erreurs : sur iPhone il émet à chaque changement
  /// d'état (« player status: AVPlayerItemStatus(rawValue: 1) » = prêt à lire).
  /// Seuls les vrais messages d'erreur passent ; un échec de `play()` lui-même
  /// est déjà attrapé par le widget.
  @override
  Stream<String> get errors => _p.onLog.where(isRealPlayerError);

  /// Où sort le son. Sans ça le lecteur HÉRITE de la session audio de l'app : à
  /// l'ouverture elle est réglée pour les appels (`playAndRecord`, mode
  /// `videoChat`, AppDelegate) — le son part alors dans l'écouteur, quasi
  /// inaudible — ou en « ambient » après un bip de l'app, qui obéit à
  /// l'interrupteur silencieux. Un vocal se joue comme de la musique :
  /// `playback`, haut-parleur, même en silencieux.
  ///
  /// Pendant un appel on ne touche à RIEN : WebRTC possède la session (voir
  /// SwaycoSounds), la reconfigurer coupe la voix de l'appel.
  Future<void> _routeToSpeaker() async {
    if (SwaycoSounds.callActive) return;
    try {
      await _p.setAudioContext(
        AudioContext(
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playback,
            options: const {},
          ),
          android: const AudioContextAndroid(
            contentType: AndroidContentType.speech,
            usageType: AndroidUsageType.media,
            audioFocus: AndroidAudioFocus.gain,
          ),
        ),
      );
      await _p.setVolume(1.0);
    } catch (e) {
      debugPrint('voice clip audio context failed: $e');
    }
  }

  @override
  Future<void> play(String url) async {
    await _routeToSpeaker();
    await _p.play(UrlSource(url));
  }

  @override
  Future<void> pause() => _p.pause();

  @override
  Future<void> resume() async {
    await _routeToSpeaker();
    await _p.resume();
  }

  @override
  Future<void> seek(Duration to) => _p.seek(to);

  @override
  Future<void> stop() => _p.stop();

  @override
  Future<void> dispose() => _p.dispose();
}
