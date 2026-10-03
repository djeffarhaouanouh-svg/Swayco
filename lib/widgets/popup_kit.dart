import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/swayco_theme.dart';

/// Kit commun à toutes les pop-ups Swayco (direction 8c).
/// Surface sombre, voile de dégradé en haut, pastille en dégradé,
/// boutons pilule empilés (jaune plein + verre).
/// Titles and primary labels: the app's display face (Archivo Black, the
/// onboarding's) rather than the handoff's Unbounded. It ships a single
/// weight, so [fontWeight] is accepted and ignored — no faux-bold.
TextStyle popupDisplay({
  double? fontSize,
  FontWeight? fontWeight,
  double? letterSpacing,
  double? height,
  Color? color,
}) =>
    GoogleFonts.archivoBlack(
      fontSize: fontSize,
      letterSpacing: letterSpacing,
      height: height,
      color: color,
    );

/// Couleurs des pop-ups. Sombre / Noir : le #16161B d'avant. Clair (17d) : fond
/// blanc, encre #04123A, halo bleu en haut. Lues à l'affichage ([SC.light]) :
/// aucune valeur en dur dans les pop-ups.
abstract final class PopupTokens {
  static Color get surface =>
      SC.light ? const Color(0xFFFFFFFF) : const Color(0xFF16161B);
  static Color get border =>
      SC.light ? const Color(0x261F5EFF) : const Color(0x1FFFFFFF);
  static Color get ghost =>
      SC.light ? const Color(0x0F1F5EFF) : const Color(0x14FFFFFF);
  static Color get ghostBorder =>
      SC.light ? const Color(0x331F5EFF) : const Color(0x29FFFFFF);
  static const danger = Color(0xFFEF4444);
  static const radius = 28.0;

  /// Texte / icône / trait posé sur le fond d'une pop-up : encre en clair.
  static Color get ink =>
      SC.light ? const Color(0xFF04123A) : Colors.white;

  /// Texte secondaire (≈ alpha .6) et texte de corps (72–78 %).
  static Color get inkSecondary =>
      SC.light ? const Color(0xFF5A6890) : Colors.white.withValues(alpha: 0.6);
  static Color get inkMuted =>
      SC.light ? const Color(0xFF8A94B0) : Colors.white.withValues(alpha: 0.45);
  static Color get textBody => SC.light
      ? const Color(0xFF04123A).withValues(alpha: 0.78)
      : Colors.white.withValues(alpha: 0.72);

  /// Poignée des feuilles.
  static Color get handle =>
      SC.light ? const Color(0x381F5EFF) : Colors.white.withValues(alpha: 0.22);

  /// Fond de la carte : blanc pur en clair, dégradé sombre sinon.
  static List<Color> get gradient => SC.light
      ? const [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0xFFFFFFFF)]
      : const [Color(0xFF1A2040), Color(0xFF16161E), Color(0xFF131318)];

  /// Ombre de la carte (pas pour une feuille).
  static BoxShadow get shadow => SC.light
      ? const BoxShadow(
          color: Color(0x4D1F5EFF),
          blurRadius: 50,
          spreadRadius: -14,
          offset: Offset(0, 22),
        )
      : BoxShadow(
          color: Colors.black.withValues(alpha: 0.6),
          blurRadius: 60,
          offset: const Offset(0, 24),
        );

  /// Voile derrière une pop-up : bleu nuit en clair.
  static Color get scrim =>
      SC.light ? const Color(0x4D04123A) : Colors.black.withValues(alpha: 0.55);
}

/// Fond d'une pop-up. [sheet] = coins arrondis en haut seulement.
class PopupSurface extends StatelessWidget {
  const PopupSurface({
    super.key,
    required this.child,
    this.sheet = false,
    this.danger = false,
    this.washHeight = 120,
  });

  final Widget child;
  final bool sheet;
  final bool danger;
  final double washHeight;

  @override
  Widget build(BuildContext context) {
    final radius = sheet
        ? const BorderRadius.vertical(top: Radius.circular(PopupTokens.radius))
        : BorderRadius.circular(PopupTokens.radius);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: PopupTokens.gradient,
          stops: const [0, 0.5, 1],
        ),
        borderRadius: radius,
        border: Border.all(color: PopupTokens.border),
        boxShadow: sheet ? null : [PopupTokens.shadow],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: washHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.topCenter,
                    radius: 1.1,
                    colors: danger
                        ? [
                            PopupTokens.danger
                                .withValues(alpha: SC.light ? 0.16 : 0.5),
                            PopupTokens.danger
                                .withValues(alpha: SC.light ? 0.05 : 0.1),
                            PopupTokens.danger.withValues(alpha: 0),
                          ]
                        : [
                            SC.brandBlue
                                .withValues(alpha: SC.light ? 0.22 : 0.6),
                            SC.brandCyan
                                .withValues(alpha: SC.light ? 0.10 : 0.14),
                            SC.brandBlueDeep.withValues(alpha: 0),
                          ],
                    stops: const [0, 0.42, 0.75],
                  ),
                ),
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }
}

/// Barre de saisie en haut des feuilles.
class PopupHandle extends StatelessWidget {
  const PopupHandle({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: PopupTokens.handle,
          borderRadius: BorderRadius.circular(999),
        ),
      );
}

/// Pastille ronde : dégradé de marque, ou rouge si [danger].
class PopupBadge extends StatelessWidget {
  const PopupBadge({
    super.key,
    required this.icon,
    this.danger = false,
    this.size = 56,
  });

  final IconData icon;
  final bool danger;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: danger ? PopupTokens.danger : null,
          gradient: danger ? null : SC.brandGradient,
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.5),
      );
}

/// Titre Unbounded ; le dernier mot est posé sur une pastille jaune.
class PopupTitle extends StatelessWidget {
  const PopupTitle(
    this.text, {
    super.key,
    this.fontSize = 19,
    this.textAlign = TextAlign.center,
    this.highlightLast = true,
  });

  final String text;
  final double fontSize;
  final TextAlign textAlign;
  final bool highlightLast;

  @override
  Widget build(BuildContext context) {
    final style = popupDisplay(
      fontSize: fontSize,
      fontWeight: FontWeight.w800,
      letterSpacing: -fontSize * 0.03,
      height: 1.18,
      color: PopupTokens.ink,
    );
    final i = text.lastIndexOf(' ');
    if (!highlightLast || i < 0) {
      return Text(text, textAlign: textAlign, style: style);
    }
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: '${text.substring(0, i)} '),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: SC.accent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                text.substring(i + 1),
                style: style.copyWith(color: SC.onAccent),
              ),
            ),
          ),
        ],
      ),
      textAlign: textAlign,
    );
  }
}

/// Texte de corps des pop-ups.
class PopupBody extends StatelessWidget {
  const PopupBody(this.text, {super.key, this.textAlign = TextAlign.center});
  final String text;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) => Text(
        text,
        textAlign: textAlign,
        style: SCText.subtitle.copyWith(
          fontSize: 14,
          height: 1.45,
          color: PopupTokens.textBody,
        ),
      );
}

/// Bouton principal : pilule jaune (ou rouge si [danger]).
class PopupButton extends StatelessWidget {
  const PopupButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.danger = false,
    this.busy = false,
    this.height = 52,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool danger;
  final bool busy;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fg = danger ? Colors.white : SC.onAccent;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: danger ? PopupTokens.danger : SC.accent,
          foregroundColor: fg,
          disabledBackgroundColor:
              (danger ? PopupTokens.danger : SC.accent).withValues(alpha: 0.6),
          shape: const StadiumBorder(),
        ),
        child: busy
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2, color: fg),
              )
            : Text(
                label,
                style: popupDisplay(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
      ),
    );
  }
}

/// Bouton secondaire : pilule en verre.
class PopupGhostButton extends StatelessWidget {
  const PopupGhostButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = 48,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: PopupTokens.ghost,
          foregroundColor: PopupTokens.ink,
          side: BorderSide(color: PopupTokens.ghostBorder),
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: PopupTokens.ink),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: SCText.subtitle.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: PopupTokens.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

