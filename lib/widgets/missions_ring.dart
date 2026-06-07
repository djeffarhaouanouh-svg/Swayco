import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/missions_service.dart';
import '../theme/swayco_theme.dart';
import 'glass_panel.dart';

/// UI metadata for each mission. [titleKey]/[howKey] are i18n keys resolved at
/// build time; detection + reward live in [MissionsService].
class _MissionDef {
  const _MissionDef(this.key, this.titleKey, this.howKey, this.icon);
  final String key;
  final String titleKey;
  final String howKey;
  final IconData icon;
  String get title => AppStrings.t(titleKey);
  String get howTo => AppStrings.t(howKey);
}

const List<_MissionDef> _missions = [
  _MissionDef(
    'friend_request',
    'mission_friend_request',
    'mission_friend_request_how',
    Icons.person_add_alt_1_rounded,
  ),
  _MissionDef(
    'post_photo',
    'mission_post_photo',
    'mission_post_photo_how',
    Icons.add_a_photo_rounded,
  ),
  _MissionDef(
    'like_someone',
    'mission_like_someone',
    'mission_like_someone_how',
    Icons.favorite_rounded,
  ),
  _MissionDef(
    'first_message',
    'mission_first_message',
    'mission_first_message_how',
    Icons.send_rounded,
  ),
  _MissionDef(
    'add_interests',
    'mission_add_interests',
    'mission_add_interests_how',
    Icons.interests_rounded,
  ),
  _MissionDef(
    'receive_like',
    'mission_receive_like',
    'mission_receive_like_how',
    Icons.recommend_rounded,
  ),
];

/// The mission def for a stable [key] (or null).
_MissionDef? _missionFor(String? key) {
  for (final m in _missions) {
    if (m.key == key) return m;
  }
  return null;
}

/// Couples mission "sources" (where a reward originates — a photo grid, the bio
/// field …) with the ring "targets" it flies into, for [MissionCelebrationOverlay].
class MissionFx {
  MissionFx._();

  /// full-ring key → closure returning its 6 milestone centres in GLOBAL
  /// coordinates (empty when the ring isn't laid out / on-screen).
  static final Map<GlobalKey, List<Offset> Function()> rings = {};

  /// Pulsed with a ring key when the flying star reaches it → that ring pops.
  static final ValueNotifier<GlobalKey?> arrived = ValueNotifier<GlobalKey?>(
    null,
  );
}

/// The oval progress ring with 6 milestone dots. Arc + dots reflect
/// [MissionsService.state]; when [flyTarget] it registers as a fly-in target
/// and pops (grows) the moment a star reaches it.
class MissionsRing extends StatefulWidget {
  const MissionsRing({
    super.key,
    this.width = 120,
    this.height = 92,
    this.stroke = 9,
    this.dotRadius = 5,
    this.showCount = true,
    this.flyTarget = false,
  });

  final double width;
  final double height;
  final double stroke;
  final double dotRadius;
  final bool showCount;
  final bool flyTarget;

  @override
  State<MissionsRing> createState() => _MissionsRingState();
}

class _MissionsRingState extends State<MissionsRing>
    with SingleTickerProviderStateMixin {
  final GlobalKey _ringKey = GlobalKey();

  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  );
  late final Animation<double> _popScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 1.18,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 36,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.18,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.elasticOut)),
      weight: 64,
    ),
  ]).animate(_pop);

  @override
  void initState() {
    super.initState();
    if (widget.flyTarget) {
      MissionFx.rings[_ringKey] = _jalonsGlobal;
      MissionFx.arrived.addListener(_onArrived);
    }
  }

  @override
  void dispose() {
    if (widget.flyTarget) {
      MissionFx.rings.remove(_ringKey);
      MissionFx.arrived.removeListener(_onArrived);
    }
    _pop.dispose();
    super.dispose();
  }

  void _onArrived() {
    if (!mounted) return;
    if (MissionFx.arrived.value == _ringKey) _pop.forward(from: 0);
  }

  /// The six milestone centres in global coordinates (or empty if off-screen).
  List<Offset> _jalonsGlobal() {
    final box = _ringKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return const [];
    final pad = widget.stroke / 2 + widget.dotRadius + 4;
    final rect = Rect.fromLTWH(
      pad,
      pad,
      widget.width - pad * 2,
      widget.height - pad * 2,
    );
    final a = rect.width / 2;
    final b = rect.height / 2;
    final c = rect.center;
    final out = <Offset>[];
    for (var i = 1; i <= missionCount; i++) {
      final th = -math.pi / 2 + (i / missionCount) * 2 * math.pi;
      out.add(
        box.localToGlobal(
          Offset(c.dx + a * math.cos(th), c.dy + b * math.sin(th)),
        ),
      );
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: _ringKey,
      child: ValueListenableBuilder<MissionsState>(
        valueListenable: MissionsService.instance.state,
        builder: (context, st, _) {
          final frac = st.completed / missionCount;
          return AnimatedBuilder(
            animation: _pop,
            builder: (context, _) => SizedBox(
              width: widget.width,
              height: widget.height,
              child: Transform.scale(
                scale: _popScale.value,
                child: CustomPaint(
                  painter: _RingPainter(
                    fraction: frac,
                    completed: st.completed,
                    stroke: widget.stroke,
                    dotRadius: widget.dotRadius,
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
                                style: SCText.meta.copyWith(
                                  color: SC.textMuted,
                                ),
                              ),
                            ],
                          ),
                        )
                      : null,
                ),
              ),
            ),
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
  });

  final double fraction;
  final int completed;
  final double stroke;
  final double dotRadius;

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
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.completed != completed;
}

/// Full missions card for the profile: ring + a collapsible per-mission
/// checklist. Tap the header to unfold the list (dropdown).
class MissionsCard extends StatefulWidget {
  const MissionsCard({super.key, this.collapsible = true});

  /// When false the checklist is always open and the chevron is hidden — used
  /// in the Discover sheet (no dropdown there).
  final bool collapsible;

  @override
  State<MissionsCard> createState() => _MissionsCardState();
}

class _MissionsCardState extends State<MissionsCard> {
  late bool _expanded = !widget.collapsible;

  @override
  Widget build(BuildContext context) {
    final totalMin = missionTotalRewardSeconds ~/ 60;
    return ValueListenableBuilder<MissionsState>(
      valueListenable: MissionsService.instance.state,
      builder: (context, st, _) {
        return GlassPanel(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: widget.collapsible
                    ? () => setState(() => _expanded = !_expanded)
                    : null,
                borderRadius: BorderRadius.circular(12),
                child: Row(
                  children: [
                    const MissionsRing(
                      width: 116,
                      height: 96,
                      stroke: 9,
                      flyTarget: true,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            AppStrings.t('missions_title'),
                            style: SCText.h3.copyWith(color: SC.textPrimary),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            AppStrings.t(
                              'missions_subtitle',
                              args: {'min': '$totalMin'},
                            ),
                            style: SCText.preview.copyWith(
                              color: Colors.white.withValues(alpha: 0.85),
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
                              st.claimed
                                  ? '${AppStrings.t('missions_earned', args: {'min': '$totalMin'})} 🎉'
                                  : '🎁 ${AppStrings.t('missions_unlock', args: {'min': '$totalMin'})}',
                              style: SCText.accent,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.collapsible) ...[
                      const SizedBox(width: 6),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: SC.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: _expanded
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 12),
                          for (final m in _missions)
                            _MissionRow(def: m, done: st.isDone(m.key)),
                        ],
                      )
                    : const SizedBox(width: double.infinity),
              ),
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
                  done ? '${AppStrings.t('missions_done_short')} ✓' : def.howTo,
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
            Icon(
              Icons.circle_outlined,
              color: Colors.white.withValues(alpha: 0.18),
              size: 22,
            ),
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
        flyTarget: true,
      ),
    );
  }
}

/// The "X/6" missions score glued to the LEFT of the compact ring, with a
/// breathing cyan halo around BOTH so the user notices it. Tapping anywhere
/// opens the missions sheet (same as the ring alone).
class MissionsScoreRing extends StatefulWidget {
  const MissionsScoreRing({super.key});

  @override
  State<MissionsScoreRing> createState() => _MissionsScoreRingState();
}

class _MissionsScoreRingState extends State<MissionsScoreRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showMissionsSheet(context),
      child: AnimatedBuilder(
        animation: _glow,
        builder: (context, _) {
          final t = Curves.easeInOut.transform(_glow.value);
          final blur = 5 + 11 * t; // 5 → 16
          final alpha = 0.30 + 0.55 * t; // 0.30 → 0.85
          final glow = SC.accent.withValues(alpha: alpha);
          final glowSoft = SC.accent.withValues(alpha: alpha * 0.6);
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // X/6 with a breathing cyan halo (text shadows).
              ValueListenableBuilder<MissionsState>(
                valueListenable: MissionsService.instance.state,
                builder: (context, st, _) => Text(
                  '${st.completed}/$missionCount',
                  style: SCText.meta.copyWith(
                    color: SC.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    shadows: [
                      Shadow(color: glow, blurRadius: blur),
                      Shadow(color: glowSoft, blurRadius: blur * 1.7),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 5),
              // Ring with the same breathing cyan halo behind it.
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(color: glow, blurRadius: blur, spreadRadius: 0.5),
                    BoxShadow(color: glowSoft, blurRadius: blur * 1.7),
                  ],
                ),
                child: const MissionsRing(
                  width: 40,
                  height: 30,
                  stroke: 4.5,
                  dotRadius: 2.6,
                  showCount: false,
                  flyTarget: true,
                ),
              ),
            ],
          );
        },
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
          const Flexible(
            child: SingleChildScrollView(
              child: MissionsCard(collapsible: false),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Game-style global celebration. When a mission completes, a star flies FROM
/// the section that earned it (e.g. the posted photo) TO the nearest ring
/// milestone — and the ring pops as it lands. If the source or ring isn't
/// on-screen it falls back to a streak across the top. A "+N min" banner pops
/// in either way. Mounted once in RootShell, above everything.
class MissionCelebrationOverlay extends StatefulWidget {
  const MissionCelebrationOverlay({super.key});

  @override
  State<MissionCelebrationOverlay> createState() =>
      _MissionCelebrationOverlayState();
}

class _MissionCelebrationOverlayState extends State<MissionCelebrationOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1150),
      )..addStatusListener((s) {
        if (s == AnimationStatus.completed) {
          if (_targetKey != null) {
            // Pulse the ring (then reset so the next completion re-fires).
            MissionFx.arrived.value = _targetKey;
            MissionFx.arrived.value = null;
          }
          MissionsService.instance.consumeJustCompleted();
        }
      });

  Offset? _from; // reward source centre (null → streak)
  Offset? _to; // nearest jalon
  GlobalKey? _targetKey;
  String? _completedKey; // which mission just completed (drives the toast)

  MissionsService get _svc => MissionsService.instance;

  @override
  void initState() {
    super.initState();
    _svc.justCompleted.addListener(_onEvent);
  }

  @override
  void dispose() {
    _svc.justCompleted.removeListener(_onEvent);
    _c.dispose();
    super.dispose();
  }

  void _onEvent() {
    if (!mounted || _svc.justCompleted.value == null) return;
    final key = _svc.justCompleted.value!;
    _completedKey = key;
    // Brief beat so the screen can scroll the ring into view (the profile
    // ensures its missions card is visible) before we resolve positions and
    // fly — otherwise the target jalon could still be off-screen.
    Future.delayed(const Duration(milliseconds: 380), () {
      if (!mounted || _svc.justCompleted.value != key) return;
      // Always fly from the screen centre to the nearest visible jalon — no
      // matter the action or where the user is. If no ring is on-screen, _from
      // stays null and we fall back to the top streak.
      final center = MediaQuery.sizeOf(context).center(Offset.zero);
      final near = _nearestJalon(center);
      _from = near != null ? center : null;
      _to = near?.$2;
      _targetKey = near?.$1;
      _c.forward(from: 0);
    });
  }

  (GlobalKey, Offset)? _nearestJalon(Offset ref) {
    final size = MediaQuery.sizeOf(context);
    GlobalKey? bestKey;
    Offset? best;
    var bestD = double.infinity;
    MissionFx.rings.forEach((k, jalons) {
      for (final j in jalons()) {
        // Ignore rings that aren't actually on-screen (e.g. the Discover ring
        // while the user is on another tab — it's kept alive off-screen).
        if (j.dx < -24 ||
            j.dy < -24 ||
            j.dx > size.width + 24 ||
            j.dy > size.height + 24) {
          continue;
        }
        final d = (j - ref).distanceSquared;
        if (d < bestD) {
          bestD = d;
          best = j;
          bestKey = k;
        }
      }
    });
    if (best == null) return null;
    return (bestKey!, best!);
  }

  double _fade(double t) {
    if (t < 0.1) return t / 0.1;
    if (t > 0.9) return (1 - t) / 0.1;
    return 1.0;
  }

  Offset _quad(Offset p0, Offset p1, Offset p2, double t) {
    final u = 1 - t;
    return p0 * (u * u) + p1 * (2 * u * t) + p2 * (t * t);
  }

  Offset _starAt(double tt, Size size, double topInset) {
    final from = _from;
    final to = _to;
    if (from != null && to != null) {
      final e = Curves.easeInOutCubic.transform(tt.clamp(0.0, 1.0));
      final mid = Offset.lerp(from, to, 0.5)! + const Offset(0, -70);
      return _quad(from, mid, to, e);
    }
    final e = Curves.easeInOut.transform(tt.clamp(0.0, 1.0));
    return Offset.lerp(
      Offset(size.width + 60, topInset + 72),
      Offset(-60, topInset + 132),
      e,
    )!;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            if (!_c.isAnimating) return const SizedBox.expand();
            final size = MediaQuery.sizeOf(context);
            final topInset = MediaQuery.paddingOf(context).top;
            final t = _c.value;

            final star = _starAt(t, size, topInset);
            final prev = _starAt((t - 0.05).clamp(0.0, 1.0), size, topInset);
            final v = star - prev;
            final dist = v.distance;
            final dir = dist > 0.001 ? v / dist : const Offset(-1, 0.3);
            final tailStart = star - dir * 92;

            final inT = Curves.easeOutBack.transform(
              (t / 0.16).clamp(0.0, 1.0),
            );
            final outT =
                1 -
                Curves.easeIn.transform(((t - 0.84) / 0.16).clamp(0.0, 1.0));

            return SizedBox.expand(
              child: Stack(
                children: [
                  CustomPaint(
                    size: size,
                    painter: _StarPainter(
                      star: star,
                      tailStart: tailStart,
                      fade: _fade(t),
                    ),
                  ),
                  Positioned(
                    // Descends from above the screen down to just under the
                    // status bar (like the block toast), then slides back up.
                    top: -70 + (topInset + 80) * inT.clamp(0.0, 1.0),
                    left: 0,
                    right: 0,
                    child: Opacity(
                      opacity: inT.clamp(0.0, 1.0) * outT,
                      child: Center(
                        child: _MissionToast(completedKey: _completedKey),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Top toast that descends to announce a completed mission + the progress
/// ("✔ Poster une photo  3/6"), or the 15-min payout once all are done.
class _MissionToast extends StatelessWidget {
  const _MissionToast({required this.completedKey});
  final String? completedKey;

  @override
  Widget build(BuildContext context) {
    final st = MissionsService.instance.state.value;
    final totalMin = missionTotalRewardSeconds ~/ 60;
    final allDone = st.allDone;
    final def = _missionFor(completedKey);
    final title = allDone
        ? AppStrings.t('missions_all_done')
        : (def?.title ?? AppStrings.t('missions_title'));
    final trailing = allDone
        ? '+$totalMin min'
        : AppStrings.t(
            'missions_progress',
            args: {'done': '${st.completed}', 'total': '$missionCount'},
          );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width - 48,
      ),
      child: GlassPanel(
        borderRadius: 999,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        color: SC.accent.withValues(alpha: 0.18),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              allDone ? Icons.celebration_rounded : Icons.check_circle_rounded,
              color: SC.accent,
              size: 18,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SCText.name.copyWith(
                  color: SC.textPrimary,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(trailing, style: SCText.accent.copyWith(fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

class _StarPainter extends CustomPainter {
  _StarPainter({
    required this.star,
    required this.tailStart,
    required this.fade,
  });
  final Offset star;
  final Offset tailStart;
  final double fade;

  @override
  void paint(Canvas canvas, Size size) {
    if (fade <= 0) return;
    canvas.drawLine(
      tailStart,
      star,
      Paint()
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [
            SC.accent.withValues(alpha: 0.0),
            SC.accent.withValues(alpha: 0.75 * fade),
          ],
        ).createShader(Rect.fromPoints(tailStart, star)),
    );
    canvas.drawCircle(
      star,
      9,
      Paint()
        ..color = SC.accent.withValues(alpha: 0.5 * fade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawCircle(
      star,
      4,
      Paint()..color = Colors.white.withValues(alpha: fade),
    );
    final spark = Paint()
      ..color = Colors.white.withValues(alpha: fade)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(star.translate(-11, 0), star.translate(11, 0), spark);
    canvas.drawLine(star.translate(0, -11), star.translate(0, 11), spark);
  }

  @override
  bool shouldRepaint(_StarPainter old) =>
      old.star != star || old.fade != fade || old.tailStart != tailStart;
}
