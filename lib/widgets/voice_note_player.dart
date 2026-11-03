import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

/// Lecteur d'un message vocal dans une bulle de chat : bouton lecture / pause,
/// barre de progression, durée. Un seul vocal joue à la fois dans toute l'app
/// (en lancer un arrête l'autre), et il s'arrête dès que la bulle disparaît
/// (quitter la conversation, défilement qui la détruit).
///
/// Le lecteur n'est créé qu'au premier appui : une conversation pleine de vocaux
/// n'ouvre aucune session audio tant qu'on n'en écoute pas.
class VoiceNotePlayer extends StatefulWidget {
  const VoiceNotePlayer({super.key, required this.url, required this.color});

  /// Adresse publique du fichier audio (`messages.audio_url`).
  final String url;

  /// Couleur du texte de la bulle : bouton, barre et durée s'y accordent.
  final Color color;

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer> {
  /// Le vocal en cours de lecture, partout dans l'app.
  static _VoiceNotePlayerState? _active;

  AudioPlayer? _player;
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _playing = false;
  bool _failed = false;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;

  Future<void> _toggle() async {
    if (_failed) {
      setState(() => _failed = false);
    }
    try {
      if (_playing) {
        await _player?.pause();
        return;
      }
      // Un seul vocal à la fois.
      if (_active != null && _active != this) {
        unawaited(_active!._stop());
      }
      _active = this;
      var player = _player;
      if (player == null) {
        player = AudioPlayer();
        _player = player;
        _subs.addAll([
          player.onPlayerStateChanged.listen((s) {
            if (!mounted) return;
            setState(() => _playing = s == PlayerState.playing);
          }),
          player.onPositionChanged.listen((p) {
            if (mounted) setState(() => _position = p);
          }),
          player.onDurationChanged.listen((d) {
            if (mounted) setState(() => _total = d);
          }),
          player.onPlayerComplete.listen((_) {
            if (!mounted) return;
            setState(() {
              _playing = false;
              _position = Duration.zero;
            });
          }),
        ]);
        await player.play(UrlSource(widget.url));
      } else if (_position > Duration.zero && _position < _total) {
        await player.resume();
      } else {
        await player.play(UrlSource(widget.url));
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _stop() async {
    try {
      await _player?.stop();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _playing = false;
        _position = Duration.zero;
      });
    }
  }

  @override
  void dispose() {
    if (_active == this) _active = null;
    for (final s in _subs) {
      s.cancel();
    }
    final p = _player;
    if (p != null) {
      unawaited(p.stop().then((_) => p.dispose()).catchError((_) {}));
    }
    super.dispose();
  }

  static String _fmt(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    final progress = _total.inMilliseconds > 0
        ? (_position.inMilliseconds / _total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    // Pendant la lecture : le temps restant ; à l'arrêt : la durée totale (ou rien
    // tant que le fichier n'a pas été ouvert).
    final label = _total == Duration.zero
        ? ''
        : _fmt(_playing ? _total - _position : _total);

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 240),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.withValues(alpha: 0.16),
              ),
              child: Icon(
                _failed
                    ? Icons.error_outline_rounded
                    : _playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                size: 24,
                color: c,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 5,
                color: c,
                backgroundColor: c.withValues(alpha: 0.22),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 34,
            child: Text(
              label,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: c.withValues(alpha: 0.7),
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
