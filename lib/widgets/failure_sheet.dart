import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

/// Les écrans d'échec (handoff « Échecs » 8c) : UNE feuille du bas pour dire ce
/// qui s'est passé, si de l'argent a été débité, et quoi faire — à la place des
/// SnackBars d'une ligne.
enum FailureTone { red, blue, yellow, grey }

/// Ouvre la feuille d'échec. Chaque bouton ferme la feuille PUIS appelle son
/// callback. Rouge (`tone: red`) = erreur réelle seulement : un léger retour
/// haptique accompagne alors l'ouverture.
Future<void> showFailureSheet(
  BuildContext context, {
  required IconData icon,
  required FailureTone tone,
  required String title,
  required String body,
  required String primaryLabel,
  required VoidCallback onPrimary,
  IconData? primaryIcon,
  String? secondaryLabel,
  VoidCallback? onSecondary,
  String? linkLabel,
  VoidCallback? onLink,
  String? chipLabel,
  Widget? leading,

  /// Détail technique (appui long sur le titre) — utile en TestFlight.
  String? technicalDetail,
}) {
  if (tone == FailureTone.red) HapticFeedback.mediumImpact();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: SC.light ? const Color(0x4D04123A) : const Color(0x99040A1E),
    builder: (ctx) => _FailureSheet(
      icon: icon,
      tone: tone,
      title: title,
      body: body,
      primaryLabel: primaryLabel,
      onPrimary: onPrimary,
      primaryIcon: primaryIcon,
      secondaryLabel: secondaryLabel,
      onSecondary: onSecondary,
      linkLabel: linkLabel,
      onLink: onLink,
      chipLabel: chipLabel,
      leading: leading,
      technicalDetail: technicalDetail,
    ),
  );
}

/// « Photo non envoyée » : la même feuille pour les 9 envois de photo.
/// Ne montre JAMAIS l'erreur brute (elle part dans le journal de debug).
Future<void> showUploadFailedSheet(
  BuildContext context, {
  required VoidCallback onRetry,
  VoidCallback? onPickOther,
  Object? error,
  Uint8List? photoBytes,
}) {
  if (error != null) debugPrint('upload failed: $error');
  return showFailureSheet(
    context,
    icon: Icons.priority_high_rounded,
    tone: FailureTone.red,
    title: AppStrings.t('fail_upload_title'),
    body: AppStrings.t('fail_upload_body'),
    primaryLabel: AppStrings.t('fail_upload_retry'),
    primaryIcon: Icons.refresh_rounded,
    onPrimary: onRetry,
    secondaryLabel: onPickOther == null ? null : AppStrings.t('fail_upload_other'),
    onSecondary: onPickOther,
    leading: photoBytes == null ? null : _PhotoThumb(bytes: photoBytes),
  );
}

class _PhotoThumb extends StatelessWidget {
  const _PhotoThumb({required this.bytes});
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 108,
      height: 120,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: Container(
              width: 96,
              height: 120,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: PopupTokens.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.memory(bytes, fit: BoxFit.cover),
            ),
          ),
          Positioned(
            right: 0,
            top: -6,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: PopupTokens.danger,
                shape: BoxShape.circle,
                border: Border.all(color: PopupTokens.surface, width: 3),
              ),
              child: const Icon(Icons.priority_high_rounded,
                  color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

class _FailureSheet extends StatefulWidget {
  const _FailureSheet({
    required this.icon,
    required this.tone,
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimary,
    this.primaryIcon,
    this.secondaryLabel,
    this.onSecondary,
    this.linkLabel,
    this.onLink,
    this.chipLabel,
    this.leading,
    this.technicalDetail,
  });

  final IconData icon;
  final FailureTone tone;
  final String title;
  final String body;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final IconData? primaryIcon;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final String? linkLabel;
  final VoidCallback? onLink;
  final String? chipLabel;
  final Widget? leading;
  final String? technicalDetail;

  @override
  State<_FailureSheet> createState() => _FailureSheetState();
}

class _FailureSheetState extends State<_FailureSheet> {
  bool _showDetail = false;

  ({Color fill, Color border, Color icon}) get _ring {
    final light = SC.light;
    switch (widget.tone) {
      case FailureTone.red:
        return light
            ? (
                fill: const Color(0xFFD92D20).withValues(alpha: 0.10),
                border: const Color(0xFFD92D20).withValues(alpha: 0.4),
                icon: const Color(0xFFD92D20),
              )
            : (
                fill: const Color(0xFFFF4538).withValues(alpha: 0.14),
                border: const Color(0xFFFF4538).withValues(alpha: 0.5),
                icon: const Color(0xFFFF6A5E),
              );
      case FailureTone.blue:
        return light
            ? (
                fill: const Color(0xFF2B7FFF).withValues(alpha: 0.10),
                border: const Color(0xFF1F5EFF).withValues(alpha: 0.4),
                icon: SC.brandBlue,
              )
            : (
                fill: const Color(0xFF1F5EFF).withValues(alpha: 0.2),
                border: const Color(0xFF18DDEA).withValues(alpha: 0.5),
                icon: const Color(0xFF18DDEA),
              );
      case FailureTone.yellow:
        return light
            ? (fill: SC.accent, border: SC.accent, icon: SC.onAccent)
            : (
                fill: const Color(0xFFF4FF1F).withValues(alpha: 0.12),
                border: const Color(0xFFF4FF1F).withValues(alpha: 0.45),
                icon: SC.accent,
              );
      case FailureTone.grey:
        return light
            ? (
                fill: PopupTokens.ghost,
                border: PopupTokens.ghostBorder,
                icon: PopupTokens.ink,
              )
            : (
                fill: Colors.white.withValues(alpha: 0.06),
                border: Colors.white.withValues(alpha: 0.2),
                icon: Colors.white.withValues(alpha: 0.92),
              );
    }
  }

  void _run(VoidCallback? cb) {
    Navigator.of(context).pop();
    cb?.call();
  }

  @override
  Widget build(BuildContext context) {
    final ring = _ring;
    return PopupSurface(
      sheet: true,
      washHeight: 170,
      danger: widget.tone == FailureTone.red,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 14),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const PopupHandle(),
                const SizedBox(height: 8),
                widget.leading ??
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: ring.fill,
                        border: Border.all(color: ring.border, width: 1.2),
                      ),
                      child: Icon(widget.icon, size: 40, color: ring.icon),
                    ),
                if (widget.chipLabel != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF4ADE80).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(
                          color: const Color(0xFF4ADE80).withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check_circle_rounded,
                            size: 16, color: Color(0xFF4ADE80)),
                        const SizedBox(width: 6),
                        Text(
                          widget.chipLabel!,
                          style: const TextStyle(
                            color: Color(0xFF4ADE80),
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                GestureDetector(
                  onLongPress: widget.technicalDetail == null
                      ? null
                      : () => setState(() => _showDetail = !_showDetail),
                  child: Text(
                    widget.title,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: popupDisplay(
                      fontSize: 26,
                      letterSpacing: -0.78,
                      height: 1.15,
                      color: PopupTokens.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 310),
                  child: Text(
                    widget.body,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      height: 1.5,
                      color: PopupTokens.textBody,
                    ),
                  ),
                ),
                if (_showDetail && widget.technicalDetail != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    widget.technicalDetail!,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.robotoMono(
                      fontSize: 11,
                      color: PopupTokens.ink.withValues(alpha: 0.5),
                    ),
                  ),
                ],
                const SizedBox(height: 26),
                SizedBox(
                  height: 56,
                  width: double.infinity,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(99),
                      boxShadow: SC.light
                          ? null
                          : [
                              BoxShadow(
                                color: const Color(0xFFF4FF1F)
                                    .withValues(alpha: 0.22),
                                blurRadius: 24,
                                offset: const Offset(0, 8),
                              ),
                            ],
                    ),
                    child: FilledButton(
                      onPressed: () => _run(widget.onPrimary),
                      style: FilledButton.styleFrom(
                        backgroundColor: SC.accent,
                        foregroundColor: SC.onAccent,
                        shape: const StadiumBorder(),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.primaryIcon != null) ...[
                              Icon(widget.primaryIcon, size: 22),
                              const SizedBox(width: 8),
                            ],
                            Text(
                              widget.primaryLabel,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.secondaryLabel != null) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 52,
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => _run(widget.onSecondary),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: PopupTokens.ghost,
                        foregroundColor: PopupTokens.ink,
                        side: BorderSide(color: PopupTokens.ghostBorder),
                        shape: const StadiumBorder(),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          widget.secondaryLabel!,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: PopupTokens.ink,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                if (widget.linkLabel != null) ...[
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: () => _run(widget.onLink),
                    child: Text(
                      widget.linkLabel!,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.underline,
                        color: PopupTokens.ink.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
