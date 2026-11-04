import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_strings.dart';
import '../services/voice_clip.dart';
import '../services/voice_wave.dart';

/// Le point « pas encore écouté » d'un vocal reçu.
const Color kVoiceUnheardDot = Color(0xFF18DDEA);

/// Lecteur d'un message vocal dans une bulle de chat (maquette 1e) : bouton
/// lecture / pause, onde qui se remplit à mesure, durée. Toucher ou glisser sur
/// l'onde déplace la lecture. Un seul vocal joue à la fois dans toute l'app (en
/// lancer un arrête l'autre), et il s'arrête dès que la bulle disparaît
/// (quitter la conversation) ou que l'app passe en arrière-plan.
///
/// Le lecteur audio n'est créé qu'au premier appui : une conversation pleine de
/// vocaux n'ouvre aucune session audio tant qu'on n'en écoute pas.
class VoiceNotePlayer extends StatefulWidget {
  const VoiceNotePlayer({
    super.key,
    required this.url,
    required this.color,
    required this.messageId,
    required this.mine,
    this.durationMs = 0,
  });

  /// Adresse publique du fichier audio (`messages.audio_url`).
  final String url;

  /// Couleur du texte de la bulle : bouton, onde et durée s'y accordent.
  final Color color;

  /// Sert à dessiner l'onde (la même sur les deux téléphones) et à retenir
  /// que le vocal a été écouté.
  final String messageId;

  /// Mon vocal : pas de point « non écouté », autres teintes d'onde.
  final bool mine;

  /// `audio_duration_ms`, pour afficher la durée avant la 1re lecture. 0 =
  /// inconnue : elle apparaît quand le fichier s'ouvre.
  final int durationMs;

  /// Fabrique du lecteur audio. Les tests y mettent un faux lecteur.
  @visibleForTesting
  static VoiceClip Function() clipFactory = createVoiceClip;

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer>
    with WidgetsBindingObserver {
  /// Le vocal en cours de lecture, partout dans l'app.
  static _VoiceNotePlayerState? _active;

  static const int _bars = 26;

  VoiceClip? _player;
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _playing = false;
  bool _failed = false;

  /// Pourquoi la lecture a échoué (infobulle du bouton).
  String _error = '';
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;

  /// Un appui sur l'onde avant la 1re lecture : on démarre là.
  double? _pendingSeek;

  /// Vrai tant qu'on ne sait pas qu'il reste à écouter (évite un point qui
  /// clignote le temps de lire les préférences).
  bool _heard = true;

  late final List<double> _wave = voiceBars(widget.messageId, count: _bars);

  String get _heardKey => 'voice_heard_${widget.messageId}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!widget.mine) _loadHeard();
  }

  Future<void> _loadHeard() async {
    try {
      final p = await SharedPreferences.getInstance();
      final heard = p.getBool(_heardKey) ?? false;
      if (mounted && heard != _heard) setState(() => _heard = heard);
    } catch (_) {}
  }

  Future<void> _markHeard() async {
    if (widget.mine || _heard) return;
    setState(() => _heard = true);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_heardKey, true);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_stop());
  }

  Duration get _totalOrKnown => _total > Duration.zero
      ? _total
      : Duration(milliseconds: widget.durationMs);

  Future<void> _toggle() async {
    if (_failed) {
      setState(() {
        _failed = false;
        _error = '';
      });
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
      unawaited(_markHeard());
      var player = _player;
      if (player == null) {
        player = VoiceNotePlayer.clipFactory();
        _player = player;
        _subs.addAll([
          player.playing.listen((p) {
            if (mounted) setState(() => _playing = p);
          }),
          player.position.listen((p) {
            if (mounted) setState(() => _position = p);
          }),
          player.duration.listen((d) {
            if (mounted) setState(() => _total = d);
          }),
          player.completed.listen((_) {
            if (!mounted) return;
            setState(() {
              _playing = false;
              _position = Duration.zero;
            });
          }),
          player.errors.listen(_fail),
        ]);
        // Jamais d'attente infinie : sans réponse en 10 s, on le dit.
        await player.play(widget.url).timeout(const Duration(seconds: 10));
        final at = _pendingSeek;
        _pendingSeek = null;
        if (at != null && _totalOrKnown > Duration.zero) {
          await player.seek(_totalOrKnown * at);
        }
      } else if (_position > Duration.zero &&
          (_total == Duration.zero || _position < _total)) {
        await player.resume().timeout(const Duration(seconds: 10));
      } else {
        await player.play(widget.url).timeout(const Duration(seconds: 10));
      }
    } catch (e) {
      _fail('$e');
    }
  }

  /// La lecture n'a pas démarré (ou s'est arrêtée sur une erreur) : le bouton
  /// passe en erreur et dit pourquoi dans son infobulle.
  void _fail(String why) {
    debugPrint('voice player: $why');
    // Le motif brut, visible sans survol : c'est ce qui permet de dire POURQUOI
    // un vocal ne se lit pas (format non pris en charge, fichier vide, réseau…).
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(why)));
    }
    if (mounted) {
      setState(() {
        _failed = true;
        _playing = false;
        _error = why;
      });
    }
  }

  /// Un appui / un glissement sur l'onde : la lecture saute là.
  Future<void> _seekTo(double fraction) async {
    final f = fraction.clamp(0.0, 1.0);
    final player = _player;
    if (player == null) {
      _pendingSeek = f;
      await _toggle();
      return;
    }
    final total = _totalOrKnown;
    if (total == Duration.zero) return;
    final to = total * f;
    setState(() => _position = to);
    try {
      await player.seek(to);
      if (!_playing) await _toggle();
    } catch (_) {}
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
    WidgetsBinding.instance.removeObserver(this);
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

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    final total = _totalOrKnown;
    final progress = total.inMilliseconds > 0
        ? (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    // Pendant la lecture : le temps restant ; à l'arrêt : la durée totale (ou
    // rien tant qu'on ne la connaît pas).
    final label = total == Duration.zero
        ? ''
        : voiceClock(_playing ? total - _position : total);

    final played = c;
    final rest = widget.mine ? c.withValues(alpha: 0.42) : c.withValues(alpha: 0.6);

    return Semantics(
      container: true,
      label: '${AppStrings.t('voice_message')}, $label',
      // La ligne fait 44 pour que le bouton ait sa zone tactile ; le rond et
      // l'onde, eux, restent à 36 (la bulle retire 4 px de padding en haut et en
      // bas pour garder la hauteur de la maquette).
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            // Zone tactile de 44, rond de 36.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggle,
              child: Tooltip(
                // Une lecture qui échoue dit pourquoi (survol / appui long).
                message: _failed ? _error : '',
                child: SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.mine
                          ? Colors.white.withValues(alpha: 0.24)
                          : c.withValues(alpha: 0.14),
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
              ),
              ),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final w = box.maxWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => _seekTo(d.localPosition.dx / w),
                    onHorizontalDragUpdate: (d) =>
                        _seekTo(d.localPosition.dx / w),
                    child: SizedBox(
                      height: 36,
                      child: CustomPaint(
                        size: Size(w, 36),
                        painter: _WavePainter(
                          bars: _wave,
                          progress: progress,
                          played: played,
                          rest: rest,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: GoogleFonts.ibmPlexMono(
                color: c.withValues(alpha: 0.8),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (!widget.mine && !_heard)
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(left: 6),
                decoration: const BoxDecoration(
                  color: kVoiceUnheardDot,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 26 barres de 3 px, de 5 à 24 px de haut ; les barres déjà lues en pleine
/// couleur, les autres en teinte atténuée. L'écart s'ajuste à la largeur.
class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.bars,
    required this.progress,
    required this.played,
    required this.rest,
  });

  final List<double> bars;
  final double progress;
  final Color played;
  final Color rest;

  static const double _barW = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final n = bars.length;
    final gap = n > 1 ? ((size.width - n * _barW) / (n - 1)).clamp(2.0, 8.0) : 0.0;
    final total = n * _barW + (n - 1) * gap;
    final left = (size.width - total) / 2;
    final paint = Paint()..isAntiAlias = true;
    for (var i = 0; i < n; i++) {
      final h = 5 + 19 * bars[i];
      final x = left + i * (_barW + gap);
      final centre = (i + 0.5) / n;
      paint.color = centre <= progress ? played : rest;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - h) / 2, _barW, h),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.progress != progress ||
      old.played != played ||
      old.rest != rest ||
      old.bars != bars;
}
