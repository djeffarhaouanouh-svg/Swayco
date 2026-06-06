import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/missions_service.dart';
import '../theme/swayco_theme.dart';
import 'glass.dart';

/// UI metadata for each mission key (label + how-to + icon). The detection and
/// reward live in [MissionsService]; this is purely presentation.
class _MissionDef {
  const _MissionDef(this.key, this.title, this.howTo, this.icon);
  final String key;
  final String title;
  final String howTo;
  final IconData icon;
}

const List<_MissionDef> _missions = [
  _MissionDef(
    'friend_request',
    'Faire une demande d\'ami',
    'Ajoute quelqu\'un depuis son profil',
    Icons.person_add_alt_1_rounded,
  ),
  _MissionDef(
    'post_photo',
    'Poster une photo',
    'Ajoute une photo à ta galerie',
    Icons.add_a_photo_rounded,
  ),
  _MissionDef(
    'like_someone',
    'Liker quelqu\'un',
    'Mets un cœur sur une photo',
    Icons.favorite_rounded,
  ),
  _MissionDef(
    'first_message',
    'Envoyer un premier message',
    'Écris à quelqu\'un dans le chat',
    Icons.send_rounded,
  ),
  _MissionDef(
    'fill_bio',
    'Remplir sa bio',
    'Décris-toi en quelques mots',
    Icons.edit_note_rounded,
  ),
  _MissionDef(
    'add_interests',
    'Ajouter 3 intérêts',
    'Choisis au moins 3 centres d\'intérêt',
    Icons.interests_rounded,
  ),
];

double _lerpDouble(double a, double b, double t) => a + (b - a) * t;

/// The oval progress ring with 6 milestone dots. When a mission completes
/// (signalled by [MissionsService.justCompleted]) a "shooting star" sweeps
/// along the oval from the previous tip to the new one, growing the fill.
class MissionsRing extends StatefulWidget {
  const MissionsRing({
    super.key,
    this.width = 120,
    this.height = 92,
    this.stroke = 9,
    this.dotRadius = 5,
    this.showCount = true,
  });

  final double width;
  final double height;
  final double stroke;
  final double dotRadius;
  final bool showCount;

  @override
  State<MissionsRing> createState() => _MissionsRingState();
}

class _MissionsRingState extends State<MissionsRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _star = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  late final CurvedAnimation _starCurve = CurvedAnimation(
    parent: _star,
    curve: Curves.easeInOutCubic,
  );

  double _fromFrac = 0;
  double _toFrac = 0;

  MissionsService get _svc => MissionsService.instance;

  @override
  void initState() {
    super.initState();
    final frac = _svc.state.value.completed / missionCount;
    _fromFrac = frac;
    _toFrac = frac;
    _svc.justCompleted.addListener(_onCelebrate);
  }

  void _onCelebrate() {
    if (!mounted) return;
    final key = _svc.justCompleted.value;
    if (key == null) return;
    final completed = _svc.state.value.completed;
    _fromFrac = (completed - 1).clamp(0, missionCount) / missionCount;
    _toFrac = completed / missionCount;
    _star.forward(from: 0);
    _svc.consumeJustCompleted();
  }

  @override
  void dispose() {
    _svc.justCompleted.removeListener(_onCelebrate);
    _starCurve.dispose();
    _star.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<MissionsState>(
        valueListenable: _svc.state,
        builder: (context, st, _) {
          final restFrac = st.completed / missionCount;
          return AnimatedBuilder(
            animation: _starCurve,
            builder: (context, _) {
              final animating = _star.isAnimating;
              final frac = animating
                  ? _lerpDouble(_fromFrac, _toFrac, _starCurve.value)
                  : restFrac;
              return SizedBox(
                width: widget.width,
                height: widget.height,
                child: CustomPaint(
                  painter: _RingPainter(
                    fraction: frac,
                    completed: st.completed,
                    stroke: widget.stroke,
                    dotRadius: widget.dotRadius,
                    starFraction: animating ? frac : null,
                  ),
                  child: widget.showCount
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${st.completed}/$missionCount',
                                style: SCText.h3.copyWith(
                                  color: SC.textPrimary,
                                  fontSize: 19,
                                ),
                              ),
                              Text(
                                'missions',
                                style: SCText.meta.copyWith(color: SC.textMuted),
                              ),
                            ],
                          ),
                        )
                      : null,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.fraction,
    required this.completed,
    required this.stroke,
    required this.dotRadius,
    this.starFraction,
  });

  final double fraction;
  final int completed;
  final double stroke;
  final double dotRadius;
  final double? starFraction;

  static const double _start = -math.pi / 2; // 12 o'clock
  static const double _tau = math.pi * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final pad = stroke / 2 + dotRadius + 4;
    final rect = Rect.fromLTWH(
      pad,
      pad,
      size.width - pad * 2,
      size.height - pad * 2,
    );
    if (rect.width <= 0 || rect.height <= 0) return;
    final a = rect.width / 2;
    final b = rect.height / 2;
    final c = rect.center;

    Offset pt(double frac) {
      final theta = _start + frac * _tau;
      return Offset(c.dx + a * math.cos(theta), c.dy + b * math.sin(theta));
    }

    // Track — dim full oval.
    canvas.drawArc(
      rect,
      _start,
      _tau,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.10),
    );

    // Filled arc — accent, deep → bright.
    final f = fraction.clamp(0.0, 1.0);
    if (f > 0) {
      canvas.drawArc(
        rect,
        _start,
        f * _tau,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..shader = SweepGradient(
            colors: const [SC.accentDeep, SC.accent, SC.accent],
            stops: const [0.0, 0.55, 1.0],
            transform: const GradientRotation(_start),
          ).createShader(rect),
      );
    }

    // Six milestone dots at i·60° from the top. Lit when i ≤ completed.
    for (var i = 1; i <= missionCount; i++) {
      final lit = i <= completed;
      final p = pt(i / missionCount);
      if (lit) {
        canvas.drawCircle(
          p,
          dotRadius + 2,
          Paint()..color = SC.accent.withValues(alpha: 0.25),
        );
      }
      canvas.drawCircle(
        p,
        dotRadius,
        Paint()..color = lit ? SC.accent : const Color(0xFF2A3350),
      );
      if (lit && dotRadius > 2) {
        canvas.drawCircle(
          p,
          dotRadius - 1.5,
          Paint()..color = Colors.white.withValues(alpha: 0.9),
        );
      }
    }

    // Shooting star at the arc tip while the sweep animates.
    final sf = starFraction;
    if (sf != null) {
      final head = pt(sf);
      canvas.drawCircle(
        head,
        dotRadius + 7,
        Paint()
          ..color = SC.accent.withValues(alpha: 0.55)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawCircle(head, dotRadius + 1.5, Paint()..color = Colors.white);
      final spark = Paint()
        ..color = Colors.white
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round;
      final s = dotRadius + 6;
      canvas.drawLine(head.translate(-s, 0), head.translate(s, 0), spark);
      canvas.drawLine(head.translate(0, -s), head.translate(0, s), spark);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction ||
      old.completed != completed ||
      old.starFraction != starFraction;
}

/// Full missions card for the profile: ring + per-mission checklist with the
/// "how to" hint and the minutes reward.
class MissionsCard extends StatelessWidget {
  const MissionsCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MissionsState>(
      valueListenable: MissionsService.instance.state,
      builder: (context, st, _) {
        final earnedMin = (st.completed * missionRewardSeconds) ~/ 60;
        final allDone = st.completed == missionCount;
        return GlassContainer(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const MissionsRing(width: 116, height: 96, stroke: 9),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Tes missions',
                          style: SCText.h3.copyWith(color: SC.textPrimary),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Complète-les pour gagner des minutes d\'appel gratuites.',
                          style: SCText.preview.copyWith(
                            color: SC.textMuted,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: SC.accent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            allDone
                                ? 'Tout est complété 🎉  +$earnedMin min'
                                : '+$earnedMin min gagnées',
                            style: SCText.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              for (final m in _missions)
                _MissionRow(def: m, done: st.isDone(m.key)),
            ],
          ),
        );
      },
    );
  }
}

class _MissionRow extends StatelessWidget {
  const _MissionRow({required this.def, required this.done});
  final _MissionDef def;
  final bool done;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done
                  ? SC.accent.withValues(alpha: 0.18)
                  : Colors.white.withValues(alpha: 0.06),
              border: Border.all(
                color: done ? SC.accent : Colors.white.withValues(alpha: 0.12),
              ),
            ),
            child: Icon(
              def.icon,
              size: 17,
              color: done ? SC.accent : SC.textMuted,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  def.title,
                  style: SCText.name.copyWith(
                    color: done
                        ? SC.textPrimary
                        : SC.textPrimary.withValues(alpha: 0.85),
                    fontSize: 14,
                  ),
                ),
                Text(
                  done ? 'Fait ✓' : def.howTo,
                  style: SCText.preview.copyWith(
                    color: done ? SC.accent : SC.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (done)
            const Icon(Icons.check_circle_rounded, color: SC.accent, size: 22)
          else
            Text('+${missionRewardSeconds ~/ 60} min', style: SCText.accent),
        ],
      ),
    );
  }
}

/// Compact ring for the Discover header (next to the search bar). Tapping it
/// opens the full missions sheet.
class MissionsRingCompact extends StatelessWidget {
  const MissionsRingCompact({super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showMissionsSheet(context),
      child: const MissionsRing(
        width: 40,
        height: 30,
        stroke: 4.5,
        dotRadius: 2.6,
        showCount: false,
      ),
    );
  }
}

/// Bottom sheet wrapping [MissionsCard] — used from the Discover compact ring.
Future<void> showMissionsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Flexible(child: SingleChildScrollView(child: MissionsCard())),
        ],
      ),
    ),
  );
}
