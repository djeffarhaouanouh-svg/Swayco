import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/voice_clip.dart';
import '../theme/swayco_theme.dart';

const Color _kInk = Color(0xFF04123A);
const Color _kBlue = Color(0xFF1F5EFF);

/// Hauteurs de la forme d'onde (statique), reprises de la maquette.
const List<double> _kBars = [
  8, 14, 10, 20, 13, 24, 16, 10, 18, 26, 14, 9, 17, 22, 12, 8, 14, 10, 18, 12,
];

/// Le lecteur d'une présentation vocale. [compact] : la petite pilule de la
/// carte Discover ; sinon celle du profil. Une seule joue à la fois.
class VoiceIntroPlayer extends StatefulWidget {
  const VoiceIntroPlayer({
    super.key,
    required this.url,
    required this.durationMs,
    this.compact = false,
  });

  final String url;
  final int durationMs;
  final bool compact;

  /// L'adresse en cours de lecture (`null` : silence) : sert à afficher la
  /// traduction pendant l'écoute.
  static final ValueNotifier<String?> playingUrl = ValueNotifier<String?>(null);

  /// Remplaçable dans les tests.
  static VoiceClip Function() clipFactory = createVoiceClip;

  static _VoiceIntroPlayerState? _active;

  /// Couper le son (changement de page, d'onglet).
  static void stopActive() => _active?._stop();

  @override
  State<VoiceIntroPlayer> createState() => _VoiceIntroPlayerState();
}

class _VoiceIntroPlayerState extends State<VoiceIntroPlayer>
    with WidgetsBindingObserver {
  VoiceClip? _clip;
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _playing = false;
  bool _paused = false;
  bool _failed = false;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(VoiceIntroPlayer old) {
    super.didUpdateWidget(old);
    // Un nouvel enregistrement : on repart de zéro.
    if (old.url != widget.url) _release();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _stop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _release();
    super.dispose();
  }

  void _release() {
    _announce(false);
    if (VoiceIntroPlayer._active == this) VoiceIntroPlayer._active = null;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    final clip = _clip;
    _clip = null;
    if (clip != null) unawaited(clip.dispose().catchError((_) {}));
    _playing = false;
    _paused = false;
    _failed = false;
    _position = Duration.zero;
    _total = Duration.zero;
  }

  void _announce(bool playing) {
    final notifier = VoiceIntroPlayer.playingUrl;
    final next = playing
        ? widget.url
        : (notifier.value == widget.url ? null : notifier.value);
    if (next == notifier.value) return;
    // Peut arriver pendant la destruction de l'écran.
    WidgetsBinding.instance.addPostFrameCallback((_) => notifier.value = next);
    WidgetsBinding.instance.scheduleFrame();
  }

  void _stop() {
    final clip = _clip;
    if (clip == null) return;
    unawaited(clip.stop().catchError((_) {}));
    _announce(false);
    if (mounted) {
      setState(() {
        _playing = false;
        _paused = false;
        _position = Duration.zero;
      });
    }
  }

  void _fail(Object why) {
    debugPrint('voice intro player: $why');
    _announce(false);
    if (mounted) {
      setState(() {
        _failed = true;
        _playing = false;
        _paused = false;
      });
    }
  }

  Future<void> _toggle() async {
    if (_failed) _release();
    try {
      if (_playing) {
        _paused = true;
        await _clip?.pause();
        return;
      }
      final other = VoiceIntroPlayer._active;
      if (other != null && other != this) other._stop();
      VoiceIntroPlayer._active = this;
      var clip = _clip;
      if (clip == null) {
        clip = VoiceIntroPlayer.clipFactory();
        _clip = clip;
        _subs.addAll([
          clip.playing.listen((playing) {
            if (!mounted) return;
            setState(() => _playing = playing);
            _announce(playing);
          }),
          clip.position.listen((p) {
            if (mounted) setState(() => _position = p);
          }),
          clip.duration.listen((d) {
            if (mounted) setState(() => _total = d);
          }),
          clip.completed.listen((_) {
            if (!mounted) return;
            _announce(false);
            setState(() {
              _playing = false;
              _paused = false;
              _position = Duration.zero;
            });
          }),
          clip.errors.listen(_fail),
        ]);
      }
      if (_paused) {
        _paused = false;
        await clip.resume().timeout(const Duration(seconds: 10));
      } else {
        await clip.play(widget.url).timeout(const Duration(seconds: 10));
      }
    } catch (e) {
      _fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    final compact = widget.compact;
    final total = _total > Duration.zero
        ? _total
        : Duration(milliseconds: widget.durationMs);
    final progress = total.inMilliseconds <= 0
        ? 0.0
        : (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    // Au repos : la durée ; pendant l'écoute : où on en est.
    final shown = _position > Duration.zero ? _position : total;
    final time = '${shown.inMinutes}:'
        '${(shown.inSeconds % 60).toString().padLeft(2, '0')}';
    final playedColor = compact
        ? (light ? const Color(0x8004123A) : Colors.white)
        : (light ? _kBlue : Colors.white);
    final restColor = compact
        ? (light ? const Color(0x3304123A) : const Color(0x66FFFFFF))
        : (light ? const Color(0x3304123A) : const Color(0x59FFFFFF));
    final button = compact ? 30.0 : 38.0;
    return Semantics(
      button: true,
      label: AppStrings.t('voice_intro_play'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: Container(
          height: compact ? 38 : 52,
          padding: EdgeInsets.fromLTRB(
              compact ? 4 : 7, 0, compact ? 10 : 18, 0),
          decoration: BoxDecoration(
            color: light
                ? const Color(0x0D04123A)
                : (compact
                    ? const Color(0x14FFFFFF)
                    : const Color(0x80060812)),
            borderRadius: BorderRadius.circular(99),
            border: Border.all(
              color: light ? const Color(0x1A04123A) : const Color(0x24FFFFFF),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: button,
                height: button,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: compact
                      ? const LinearGradient(
                          colors: [_kBlue, Color(0xFF18DDEA)])
                      : null,
                  color: compact ? null : (light ? _kInk : Colors.white),
                ),
                child: Icon(
                  _failed
                      ? Icons.refresh_rounded
                      : (_playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded),
                  size: compact ? 20 : 24,
                  color: compact || light ? Colors.white : _kInk,
                ),
              ),
              SizedBox(width: compact ? 8 : 12),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    // Autant de barres que la place en accepte.
                    final barWidth = compact ? 2.5 : 3.0;
                    final count = (box.maxWidth / (barWidth + 2))
                        .floor()
                        .clamp(1, _kBars.length);
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (var i = 0; i < count; i++)
                          Container(
                            width: barWidth,
                            height: _kBars[i] * (compact ? 0.85 : 1),
                            decoration: BoxDecoration(
                              color: (i + 0.5) / count <= progress
                                  ? playedColor
                                  : restColor,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
              SizedBox(width: compact ? 6 : 12),
              Text(
                time,
                style: GoogleFonts.ibmPlexMono(
                  fontSize: compact ? 10 : 11,
                  fontWeight: FontWeight.w600,
                  color: (light ? _kInk : Colors.white).withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
