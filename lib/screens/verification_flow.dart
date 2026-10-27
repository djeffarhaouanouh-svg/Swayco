import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/app_strings.dart';
import '../services/profile_api.dart';
import '../services/user_prefs.dart';
import '../theme/swayco_theme.dart';
import '../widgets/sway_onb_kit.dart';

/// Un geste à faire sur le selfie, et l'emoji qui le montre. La CLÉ voyage avec
/// le selfie : c'est ce que le validateur doit retrouver sur la photo.
class VerificationGesture {
  const VerificationGesture(this.key, this.emoji);

  final String key;
  final String emoji;

  static const all = <VerificationGesture>[
    VerificationGesture('gesture_thumb_left', '👍'),
    VerificationGesture('gesture_peace_right', '✌️'),
    VerificationGesture('gesture_hand_chin', '🤔'),
    VerificationGesture('gesture_wave', '👋'),
    VerificationGesture('gesture_point_up', '☝️'),
    VerificationGesture('gesture_ok', '👌'),
  ];

  static VerificationGesture? _last;

  /// Un geste au hasard, jamais le même deux fois de suite.
  static VerificationGesture next([math.Random? rng]) {
    final pool = [
      for (final g in all)
        if (g.key != _last?.key) g,
    ];
    final pick = pool[(rng ?? math.Random()).nextInt(pool.length)];
    _last = pick;
    return pick;
  }

  /// Pour les tests : repart de zéro.
  @visibleForTesting
  static void resetForTest() => _last = null;
}

/// Le selfie pris, avec le geste qui était demandé.
class VerificationShot {
  const VerificationShot(this.bytes, this.gesture);

  final Uint8List bytes;
  final VerificationGesture gesture;
}

enum _Stage { intro, sending, sent }

/// La vérification du profil : un selfie avec un geste imposé, comparé aux
/// photos du profil par l'équipe (panneau admin). Trois temps — l'intro, la
/// prise de vue (un écran plein, ouvert par-dessus), puis « envoyé ».
///
/// Un widget de page, sans coque : l'onboarding le pose dans son [SwayOnbShell] ;
/// le profil pourra le poser dans la sienne. [onSkip] à null masque « Passer ».
class VerificationFlow extends StatefulWidget {
  const VerificationFlow({
    super.key,
    required this.onDone,
    this.onSkip,
    this.doneLabelKey = 'onb_finish',
    this.onSent,
    this.capture,
    this.submit,
  });

  /// Fin du parcours, depuis l'écran « envoyé ».
  final VoidCallback onDone;

  /// La demande est partie (ou une autre attendait déjà) : l'écran « envoyé »
  /// vient de s'afficher. Pour qui sort autrement que par [onDone].
  final VoidCallback? onSent;

  /// « Passer » : rien n'est envoyé. Null = pas de bouton.
  final VoidCallback? onSkip;

  /// Clé du texte du bouton de l'écran « envoyé ».
  final String doneLabelKey;

  /// Couture de test : remplace l'écran de prise de vue.
  final Future<VerificationShot?> Function(BuildContext context)? capture;

  /// Couture de test : remplace l'envoi. `false` = une demande attend déjà.
  final Future<bool> Function(Uint8List bytes, String gesture)? submit;

  @override
  State<VerificationFlow> createState() => _VerificationFlowState();
}

class _VerificationFlowState extends State<VerificationFlow> {
  _Stage _stage = _Stage.intro;

  Future<void> _start() async {
    if (_stage != _Stage.intro) return;
    final shot = await (widget.capture ?? VerificationCaptureScreen.open)(context);
    if (shot == null || !mounted) return;
    setState(() => _stage = _Stage.sending);
    try {
      await (widget.submit ?? _defaultSubmit)(shot.bytes, shot.gesture.key);
      // Envoyé, ou déjà en attente : dans les deux cas, la demande existe.
      await UserPrefs.setVerificationSent();
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() => _stage = _Stage.sent);
      widget.onSent?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _stage = _Stage.intro);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.t('upload_failed', args: {'msg': '$e'})),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  static Future<bool> _defaultSubmit(Uint8List bytes, String gesture) {
    // Le recadrage JPEG de image_picker ; un PNG garde son étiquette.
    final isPng = bytes.length > 1 && bytes[0] == 0x89 && bytes[1] == 0x50;
    return ProfileApi.submitVerification(
      bytes: bytes,
      gesture: gesture,
      contentType: isPng ? 'image/png' : 'image/jpeg',
    );
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.intro:
        return _Intro(onStart: _start, onSkip: widget.onSkip);
      case _Stage.sending:
        return const Center(
          child: CircularProgressIndicator(color: Colors.white),
        );
      case _Stage.sent:
        return _Sent(
          doneLabelKey: widget.doneLabelKey,
          onDone: widget.onDone,
        );
    }
  }
}

/// La vérification ouverte HORS onboarding (les réglages) : la même
/// [VerificationFlow] sur le dégradé de l'onboarding, avec une croix pour
/// sortir. Rend `true` quand une demande est partie ou attendait déjà — que
/// l'on sorte par le bouton « Fermer », la croix ou le retour du système.
class VerificationScreen extends StatefulWidget {
  const VerificationScreen({super.key, this.capture, this.submit});

  /// Coutures de test, passées telles quelles à [VerificationFlow].
  final Future<VerificationShot?> Function(BuildContext context)? capture;
  final Future<bool> Function(Uint8List bytes, String gesture)? submit;

  static Future<bool?> open(BuildContext context) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const VerificationScreen()),
    );
  }

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  bool _sent = false;

  void _close() => Navigator.of(context).pop(_sent);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Le retour du système passe aussi par [_close] : l'appelant doit
      // savoir si une demande est partie.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: SC.brandBlueDeep,
        body: DecoratedBox(
          decoration: const BoxDecoration(gradient: SwayOnb.stepGradient),
          child: SafeArea(
            child: Stack(
              children: [
                VerificationFlow(
                  onDone: _close,
                  doneLabelKey: 'verif_close',
                  onSent: () => _sent = true,
                  capture: widget.capture,
                  submit: widget.submit,
                ),
                // Dans la marge vide au-dessus du titre (48).
                Positioned(
                  left: 14,
                  top: 4,
                  child: _GlassCloseButton(onTap: _close),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Le rond de verre avec une croix.
class _GlassCloseButton extends StatelessWidget {
  const _GlassCloseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.16),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.3),
            width: 1.2,
          ),
        ),
        child: const Icon(Icons.close_rounded, size: 22, color: Colors.white),
      ),
    );
  }
}

/// 2a — l'intro : les trois temps, « Commencer », et « Passer » en bleu.
class _Intro extends StatelessWidget {
  const _Intro({required this.onStart, required this.onSkip});

  final VoidCallback onStart;
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
                SwayOnb.gutter, 48, SwayOnb.gutter, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwayTitle(AppStrings.t('verif_intro_title'), size: 30),
                const SizedBox(height: 12),
                Text(
                  AppStrings.t('verif_intro_sub'),
                  style: SwayOnb.body.copyWith(fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 26),
                const _VerifStep(
                  icon: Icons.waving_hand_rounded,
                  titleKey: 'verif_step1_t',
                  subKey: 'verif_step1_s',
                  number: 1,
                ),
                const SizedBox(height: 16),
                const _VerifStep(
                  icon: Icons.photo_camera_rounded,
                  titleKey: 'verif_step2_t',
                  subKey: 'verif_step2_s',
                  number: 2,
                ),
                const SizedBox(height: 16),
                const _VerifStep(
                  icon: Icons.how_to_reg_rounded,
                  titleKey: 'verif_step3_t',
                  subKey: 'verif_step3_s',
                  number: 3,
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              SwayOnb.gutter, 8, SwayOnb.gutter, 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // « Commencer » en bleu Swayco plein (#1F5EFF), « Passer » en
              // jaune : les couleurs de l'ancienne paire, échangées.
              SizedBox(
                height: SwayOnb.ctaHeight,
                child: TextButton(
                  onPressed: onStart,
                  style: TextButton.styleFrom(
                    backgroundColor: SC.brandBlueDeep,
                    foregroundColor: Colors.white,
                    shape: StadiumBorder(
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.45),
                        width: 1.5,
                      ),
                    ),
                    shadowColor: const Color(0x8004123A),
                    elevation: 6,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.photo_camera_rounded, size: 22),
                        const SizedBox(width: 8),
                        Text(
                          AppStrings.t('verif_start'),
                          style: GoogleFonts.archivoBlack(
                            fontSize: 17,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (onSkip != null) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: onSkip,
                    style: FilledButton.styleFrom(
                      backgroundColor: SC.accent,
                      foregroundColor: SC.onAccent,
                      shape: const StadiumBorder(),
                      elevation: 0,
                    ),
                    child: Text(
                      AppStrings.t('verif_skip'),
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Une ligne de l'intro : tuile d'icône, titre numéroté, légende.
class _VerifStep extends StatelessWidget {
  const _VerifStep({
    required this.icon,
    required this.titleKey,
    required this.subKey,
    required this.number,
  });

  final IconData icon;
  final String titleKey;
  final String subKey;
  final int number;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
          ),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$number. ${AppStrings.t(titleKey)}',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 14,
                  height: 1.2,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                AppStrings.t(subKey),
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12,
                  height: 1.2,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 2c — envoyé : le sablier, ce qui se passe maintenant, et la sortie.
class _Sent extends StatelessWidget {
  const _Sent({required this.doneLabelKey, required this.onDone});

  final String doneLabelKey;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: SwayOnb.gutter),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 120,
                    height: 120,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.35),
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                        const Positioned.fill(
                          child: Padding(
                            padding: EdgeInsets.all(14),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: SC.accent,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.hourglass_top_rounded,
                                size: 48,
                                color: SC.onAccent,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    AppStrings.t('verif_sent_title'),
                    textAlign: TextAlign.center,
                    style: SwayOnb.display(25),
                  ),
                  const SizedBox(height: 18),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Text(
                      AppStrings.t('verif_sent_body'),
                      textAlign: TextAlign.center,
                      style: SwayOnb.body.copyWith(fontSize: 14.5, height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              SwayOnb.gutter, 8, SwayOnb.gutter, 40),
          child: SwayCta(
            label: AppStrings.t(doneLabelKey),
            onPressed: onDone,
          ),
        ),
      ],
    );
  }
}

/// 2b — la prise de vue. L'appareil natif s'ouvre par-dessus (`image_picker`,
/// pas de paquet `camera`) : ce qu'on peut faire de mieux est d'expliquer AVANT —
/// le geste en grand, l'ovale où placer le visage — puis un bouton de
/// déclenchement qui ouvre la caméra frontale.
///
/// Pop avec un [VerificationShot], ou null quand on revient par la croix.
class VerificationCaptureScreen extends StatefulWidget {
  const VerificationCaptureScreen({super.key});

  static Future<VerificationShot?> open(BuildContext context) {
    return Navigator.of(context).push<VerificationShot>(
      MaterialPageRoute<VerificationShot>(
        fullscreenDialog: true,
        builder: (_) => const VerificationCaptureScreen(),
      ),
    );
  }

  @override
  State<VerificationCaptureScreen> createState() =>
      _VerificationCaptureScreenState();
}

class _VerificationCaptureScreenState extends State<VerificationCaptureScreen> {
  /// Tiré à l'ouverture, enregistré avec le selfie.
  late final VerificationGesture _gesture = VerificationGesture.next();
  bool _busy = false;
  bool _denied = false;

  Future<void> _shoot() async {
    if (_busy) return;
    _busy = true;
    try {
      // Le web n'a pas de permission à demander d'avance : le navigateur la
      // demande lui-même à l'ouverture de la caméra.
      if (!kIsWeb) {
        final cam = await Permission.camera.request();
        if (!cam.isGranted) {
          if (mounted) setState(() => _denied = true);
          return;
        }
      }
      final file = await ImagePicker().pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 1280,
        imageQuality: 85,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      Navigator.of(context).pop(VerificationShot(bytes, _gesture));
    } on PlatformException catch (e) {
      if (!mounted) return;
      // Les deux plateformes remontent un refus de caméra sous ce code.
      if (e.code == 'camera_access_denied') {
        setState(() => _denied = true);
      } else {
        _fail(e);
      }
    } catch (e) {
      if (mounted) _fail(e);
    } finally {
      _busy = false;
    }
  }

  void _fail(Object e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppStrings.t('upload_failed', args: {'msg': '$e'})),
        duration: const Duration(seconds: 8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SC.brandBlueDeep,
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: SwayOnb.stepGradient),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _GlassCloseButton(onTap: () => Navigator.of(context).pop()),
                    Text(
                      AppStrings.t('verif_gesture'),
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 40),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _GesturePill(gesture: _gesture),
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: SizedBox(
                      width: 230,
                      height: 300,
                      child: CustomPaint(
                        painter: _DashedOvalPainter(
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 30),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_denied)
                      _CameraDenied(onSettings: openAppSettings)
                    else
                      Text(
                        AppStrings.t('verif_frame_hint'),
                        textAlign: TextAlign.center,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          shadows: const [
                            Shadow(color: Color(0x99000000), blurRadius: 8),
                          ],
                        ),
                      ),
                    const SizedBox(height: 14),
                    Semantics(
                      button: true,
                      label: AppStrings.t('verif_step2_t'),
                      child: GestureDetector(
                        onTap: _shoot,
                        child: Container(
                          width: 76,
                          height: 76,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 4),
                          ),
                          child: Container(
                            width: 58,
                            height: 58,
                            decoration: const BoxDecoration(
                              color: SC.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Le geste à faire, en grand : une pastille jaune, l'emoji puis le texte.
class _GesturePill extends StatelessWidget {
  const _GesturePill({required this.gesture});

  final VerificationGesture gesture;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: SC.accent,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(gesture.emoji, style: const TextStyle(fontSize: 26, height: 1)),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  AppStrings.t(gesture.key),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: SwayOnb.display(15).copyWith(
                    color: SC.onAccent,
                    height: 1.1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Caméra refusée : un message clair et un lien vers les réglages — le refus
/// est définitif tant que l'utilisateur n'y retourne pas.
class _CameraDenied extends StatelessWidget {
  const _CameraDenied({required this.onSettings});

  final Future<bool> Function() onSettings;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          AppStrings.t('verif_camera_denied'),
          textAlign: TextAlign.center,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        TextButton(
          onPressed: onSettings,
          style: TextButton.styleFrom(
            foregroundColor: SC.accent,
            minimumSize: const Size(0, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            AppStrings.t('verif_open_settings'),
            style: GoogleFonts.plusJakartaSans(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              decoration: TextDecoration.underline,
              decorationColor: SC.accent,
            ),
          ),
        ),
      ],
    );
  }
}

/// L'ovale pointillé où placer le visage.
class _DashedOvalPainter extends CustomPainter {
  const _DashedOvalPainter({required this.color});

  final Color color;

  static const double _stroke = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addOval((Offset.zero & size).deflate(_stroke / 2));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    const dash = 10.0, gap = 8.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + dash, metric.length)),
          paint,
        );
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedOvalPainter old) => old.color != color;
}
