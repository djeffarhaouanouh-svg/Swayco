import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/quiz_api.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

// Les éléments visuels du quiz du chat (handoff messages_groupes_quiz, partie
// C). Jaune / bleu nuit / dégradé bleu des maquettes ; la police reste celle de
// l'app.

const Color _kYellow = Color(0xFFF4FF1F);
const Color _kNavy = Color(0xFF04123A);
const Color _kBlue = Color(0xFF1F5EFF);
const Color _kBlueMid = Color(0xFF2B7FFF);
const Color _kCyan = Color(0xFF18DDEA);
const Color _kStopRed = Color(0xFFD93036);

Color get _card => SC.light ? Colors.white : const Color(0xFF2A2A2E);
Color get _ink => SC.light ? _kNavy : Colors.white;

// ── Choisir un thème (1b) ────────────────────────────────────────────────────

/// Le tiroir « Choisis un thème ». Rend le thème choisi, ou `surprise`.
Future<String?> showQuizThemeSheet(BuildContext context, String peerName) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _QuizThemeSheet(peerName: peerName),
  );
}

class _QuizThemeSheet extends StatelessWidget {
  const _QuizThemeSheet({required this.peerName});

  final String peerName;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    final bg = light ? const Color(0xFFF3F4F8) : const Color(0xFF1F1F24);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(18, 10, 18, 16 + bottom),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: _ink.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _TitleWithPill(),
          const SizedBox(height: 6),
          Text(
            AppStrings.t('quiz_pick_sub', args: {'name': peerName}),
            style: TextStyle(
              color: _ink.withValues(alpha: 0.7),
              fontSize: 13.5,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 16),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.12,
            children: [
              for (final t in QuizApi.themes)
                _ThemeTile(
                  theme: t,
                  onTap: () => Navigator.of(context).pop(t),
                ),
            ],
          ),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: () => Navigator.of(context).pop('surprise'),
            child: Container(
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _kYellow,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.shuffle_rounded, size: 20, color: _kNavy),
                  const SizedBox(width: 8),
                  Text(
                    AppStrings.t('quiz_surprise'),
                    style: const TextStyle(
                      color: _kNavy,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// « Choisis un thème », le mot « thème » sur une pastille jaune.
class _TitleWithPill extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final full = AppStrings.t('quiz_pick_title');
    final word = AppStrings.t('quiz_pick_word');
    final i = word.isEmpty ? -1 : full.toLowerCase().indexOf(word.toLowerCase());
    final style = popupDisplay(fontSize: 22, color: _ink);
    if (i < 0) return Text(full, style: style);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (i > 0) Text(full.substring(0, i), style: style),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 1),
          decoration: BoxDecoration(
            color: _kYellow,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            full.substring(i, i + word.length),
            style: popupDisplay(fontSize: 22, color: _kNavy),
          ),
        ),
        if (i + word.length < full.length)
          Text(full.substring(i + word.length), style: style),
      ],
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({required this.theme, required this.onTap});

  final String theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: (light ? _kNavy : Colors.white).withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: (light ? _kNavy : Colors.white).withValues(alpha: 0.12),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              QuizApi.themeEmoji[theme] ?? '❓',
              style: const TextStyle(fontSize: 34, height: 1),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  AppStrings.t('quiz_theme_$theme'),
                  style: TextStyle(
                    color: _ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  AppStrings.t('quiz_theme_sub_$theme'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _ink.withValues(alpha: 0.6),
                    fontSize: 11.5,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Contour qui tourne ───────────────────────────────────────────────────────

/// Le contour de 1,5 px en dégradé conique bleu. Il tourne en continu (4 s) tant
/// que [spinning] ; sinon il reste fixe, à faible opacité.
class QuizSpinBorder extends StatefulWidget {
  const QuizSpinBorder({
    super.key,
    required this.child,
    required this.radius,
    this.spinning = true,
  });

  final Widget child;
  final double radius;
  final bool spinning;

  @override
  State<QuizSpinBorder> createState() => _QuizSpinBorderState();
}

class _QuizSpinBorderState extends State<QuizSpinBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _c.repeat();
  }

  @override
  void didUpdateWidget(QuizSpinBorder old) {
    super.didUpdateWidget(old);
    if (widget.spinning && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.spinning && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inner = widget.radius - 1.5;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final a = widget.spinning ? 1.0 : 0.3;
        return Container(
          padding: const EdgeInsets.all(1.5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: SweepGradient(
              transform: GradientRotation(_c.value * 2 * math.pi),
              colors: [
                _kBlueMid.withValues(alpha: 0.15 * a),
                _kBlueMid.withValues(alpha: a),
                _kCyan.withValues(alpha: a),
                _kBlueMid.withValues(alpha: 0.15 * a),
              ],
              stops: const [0, 0.35, 0.7, 1],
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(inner),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

// ── Carte question (2a) ──────────────────────────────────────────────────────

class QuizQuestionCard extends StatelessWidget {
  const QuizQuestionCard({
    super.key,
    required this.theme,
    required this.index,
    required this.active,
    this.questionId = 0,
  });

  final String theme;

  /// La position dans le quiz (« QUESTION 2 »).
  final int index;

  /// Le numéro de la question dans le thème (0 = comme la position).
  final int questionId;

  /// La carte de la question en cours : seule à avoir le contour qui tourne.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final label = SC.light ? _kBlue : const Color(0xFF8FB5FF);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: QuizSpinBorder(
          radius: 22,
          spinning: active,
          child: Container(
            width: double.infinity,
            color: _card,
            padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      QuizApi.themeEmoji[theme] ?? '❓',
                      style: const TextStyle(fontSize: 15),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      AppStrings.t('quiz_label', args: {'n': '$index'}),
                      style: GoogleFonts.ibmPlexMono(
                        color: label,
                        fontSize: 11,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  QuizApi.questionText(theme, questionId > 0 ? questionId : index),
                  style: popupDisplay(
                    fontSize: 17,
                    height: 1.3,
                    letterSpacing: -0.3,
                    color: _ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Pastille d'attente (2b) ──────────────────────────────────────────────────

class QuizWaitingPill extends StatelessWidget {
  const QuizWaitingPill({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: _ink.withValues(alpha: 0.12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.hourglass_top_rounded, size: 16, color: _kYellow),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                style: TextStyle(
                  color: _ink,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Bouton « Question suivante » (2c) ───────────────────────────────────────

class QuizNextButton extends StatelessWidget {
  const QuizNextButton({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: GestureDetector(
          onTap: busy ? null : onTap,
          child: QuizSpinBorder(
            radius: 99,
            child: Container(
              color: _card,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: _ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.arrow_forward_rounded, size: 18, color: _ink),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Ligne système (3c / 3d) ─────────────────────────────────────────────────

class QuizSystemLine extends StatelessWidget {
  const QuizSystemLine({super.key, required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: _ink.withValues(alpha: 0.55)),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _ink.withValues(alpha: 0.55),
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Bandeau sous l'en-tête (3a) ─────────────────────────────────────────────

class QuizBanner extends StatelessWidget {
  const QuizBanner({super.key, required this.state, required this.onMenu});

  /// Hauteur réservée par la liste sous l'en-tête.
  static const double height = 46;

  final QuizState state;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
        child: Container(
          padding: const EdgeInsets.only(left: 14, right: 4),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: _ink.withValues(alpha: 0.10)),
          ),
          child: Row(
            children: [
              Text(
                QuizApi.themeEmoji[state.theme] ?? '❓',
                style: const TextStyle(fontSize: 15),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  AppStrings.t('quiz_banner', args: {
                    'theme': AppStrings.t('quiz_theme_${state.theme}'),
                    'n': '${state.index}',
                    'total': '${state.total}',
                  }),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onMenu,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(Icons.more_horiz_rounded, size: 22, color: _ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Le menu du bandeau : arrêter, ou changer de thème. Rend `stop` / `change`.
Future<String?> showQuizMenu(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final bottom = MediaQuery.paddingOf(ctx).bottom;
      Widget row(IconData icon, String text, Color color, String result) {
        return ListTile(
          leading: Icon(icon, color: color),
          title: Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          onTap: () => Navigator.of(ctx).pop(result),
        );
      }

      return Container(
        padding: EdgeInsets.fromLTRB(8, 10, 8, 8 + bottom),
        decoration: BoxDecoration(
          color: SC.light ? Colors.white : const Color(0xFF1F1F24),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            row(Icons.stop_circle_rounded, AppStrings.t('quiz_stop'),
                _kStopRed, 'stop'),
            row(Icons.swap_horiz_rounded, AppStrings.t('quiz_change_theme'),
                _ink, 'change'),
          ],
        ),
      );
    },
  );
}

/// « Arrêter le quiz ? » (3b). Rend vrai pour arrêter.
Future<bool> showQuizStopDialog(BuildContext context) async {
  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: SC.light ? Colors.white : const Color(0xFF1F1F24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              AppStrings.t('quiz_stop_title'),
              textAlign: TextAlign.center,
              style: popupDisplay(fontSize: 20, color: _ink),
            ),
            const SizedBox(height: 10),
            Text(
              AppStrings.t('quiz_stop_body'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _ink.withValues(alpha: 0.7),
                fontSize: 14,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: () => Navigator.of(ctx).pop(false),
              child: Container(
                height: 50,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _kYellow,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  AppStrings.t('quiz_continue'),
                  style: const TextStyle(
                    color: _kNavy,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => Navigator.of(ctx).pop(true),
              child: Container(
                height: 50,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: _kStopRed, width: 1.5),
                ),
                child: Text(
                  AppStrings.t('quiz_stop_confirm'),
                  style: const TextStyle(
                    color: _kStopRed,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  return res == true;
}
