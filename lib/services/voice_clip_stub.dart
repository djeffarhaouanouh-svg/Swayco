import 'package:audioplayers/audioplayers.dart';

import 'voice_clip_base.dart';

/// Mobile / bureau : `audioplayers`.
VoiceClip createVoiceClip() => _AudioPlayersClip();

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
  Stream<String> get errors => _p.onLog.where(
        (m) => RegExp(r'error|fail|exception|invalid|unsupported|cannot|could not',
                caseSensitive: false)
            .hasMatch(m),
      );

  @override
  Future<void> play(String url) => _p.play(UrlSource(url));

  @override
  Future<void> pause() => _p.pause();

  @override
  Future<void> resume() => _p.resume();

  @override
  Future<void> seek(Duration to) => _p.seek(to);

  @override
  Future<void> stop() => _p.stop();

  @override
  Future<void> dispose() => _p.dispose();
}
