import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/languages.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart' show popupDisplay;

/// La pop-up « On ne te comprend pas » de l'appel (handoff `popup_langue_ecoute`).
///
/// Elle dit que c'est le RÉGLAGE de langue d'écoute qui ne correspond pas à ce
/// que la personne parle (et pas une panne), avec la langue réglée en pastille
/// dans la phrase. Renvoie `true` pour « Changer la langue » (bouton ou pastille),
/// `false` pour « C'est la bonne », `null` si on touche en dehors (= la bonne).
///
/// Un widget à part : les autres `showSwaycoNotice` ne bougent pas.
Future<bool?> showSwaycoLanguageCheck({
  required BuildContext context,
  required String languageCode,
}) {
  final lang = findCallLanguageByCode(languageCode);
  final rtl = AppStrings.currentBcp47.value == 'ar';
  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '',
    barrierColor: const Color(0xB3040A1E),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, _, _) => _LanguageCheckCard(
      langLabel: lang?.label ?? languageCode.toUpperCase(),
      countryCode: lang?.countryCode ?? '',
      rtl: rtl,
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final a = CurvedAnimation(
        parent: anim,
        curve: Curves.easeOut,
        reverseCurve: Curves.easeIn,
      );
      return FadeTransition(
        opacity: a,
        child: AnimatedBuilder(
          animation: a,
          builder: (_, c) => Transform.translate(
            offset: Offset(0, 8 * (1 - a.value)),
            child: c,
          ),
          child: child,
        ),
      );
    },
  );
}

const Color _kYellow = Color(0xFFF4FF1F);
const Color _kNavy = Color(0xFF04123A);
const Color _kCyan = Color(0xFF18DDEA);

class _LanguageCheckCard extends StatelessWidget {
  const _LanguageCheckCard({
    required this.langLabel,
    required this.countryCode,
    required this.rtl,
  });

  final String langLabel;
  final String countryCode;
  final bool rtl;

  @override
  Widget build(BuildContext context) {
    final code = AppStrings.currentBcp47.value;
    // Titre : 20 px (18 en russe, 22 en arabe). Texte : arabe en Noto Sans Arabic.
    final titleStyle = code == 'ar'
        ? GoogleFonts.notoKufiArabic(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            height: 1.22,
            color: Colors.white,
          )
        : popupDisplay(
            fontSize: code == 'ru' ? 18 : 20,
            letterSpacing: -0.6,
            height: 1.22,
            color: Colors.white,
          );
    final bodyStyle = (code == 'ar'
            ? GoogleFonts.notoSansArabic(fontWeight: FontWeight.w500)
            : GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w500))
        .copyWith(
      fontSize: 14,
      height: 1.6,
      color: const Color(0xCCF5F7FF),
    );

    final raw = AppStrings.t('call_lang_check_body');
    final parts = raw.split('{lang}');
    final spans = <InlineSpan>[
      TextSpan(text: parts.first),
      if (parts.length > 1) ...[
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: _LangChip(
              label: langLabel,
              countryCode: countryCode,
              onTap: () => Navigator.of(context).pop(true),
            ),
          ),
        ),
        TextSpan(text: parts.sublist(1).join('{lang}')),
      ],
    ];

    return Directionality(
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      child: Center(
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 28),
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            decoration: BoxDecoration(
              gradient: SC.callSurface,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x80000000),
                  blurRadius: 60,
                  offset: Offset(0, 24),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF1F5EFF), _kCyan],
                      ),
                    ),
                    child: const Icon(
                      Icons.mic_rounded,
                      size: 28,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  AppStrings.t('call_lang_check_title'),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
                const SizedBox(height: 10),
                Text.rich(
                  TextSpan(children: spans),
                  textAlign: TextAlign.center,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: bodyStyle,
                ),
                const SizedBox(height: 20),
                _PopupBtn(
                  label: AppStrings.t('call_lang_check_change'),
                  primary: true,
                  onTap: () => Navigator.of(context).pop(true),
                ),
                const SizedBox(height: 10),
                _PopupBtn(
                  label: AppStrings.t('call_lang_check_keep'),
                  primary: false,
                  onTap: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// La pastille de langue dans la phrase : drapeau rond 18, nom, chevron « roue
/// qui défile ». Un tap = « Changer la langue ».
class _LangChip extends StatefulWidget {
  const _LangChip({
    required this.label,
    required this.countryCode,
    required this.onTap,
  });

  final String label;
  final String countryCode;
  final VoidCallback onTap;

  @override
  State<_LangChip> createState() => _LangChipState();
}

class _LangChipState extends State<_LangChip> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 90),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: _kCyan.withValues(alpha: _down ? 0.30 : 0.14),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: _down ? _kCyan : _kCyan.withValues(alpha: 0.45),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.countryCode.isNotEmpty) ...[
                CountryFlag.fromCountryCode(
                  widget.countryCode,
                  theme: const ImageTheme(
                    width: 18,
                    height: 18,
                    shape: Circle(),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                widget.label,
                maxLines: 1,
                softWrap: false,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(Icons.unfold_more_rounded, size: 18, color: _kCyan),
            ],
          ),
        ),
      ),
    );
  }
}

class _PopupBtn extends StatefulWidget {
  const _PopupBtn({
    required this.label,
    required this.primary,
    required this.onTap,
  });

  final String label;
  final bool primary;
  final VoidCallback onTap;

  @override
  State<_PopupBtn> createState() => _PopupBtnState();
}

class _PopupBtnState extends State<_PopupBtn> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final primary = widget.primary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 90),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: primary
                ? (_down ? const Color(0xFFD7E218) : _kYellow)
                : (_down
                    ? Colors.white.withValues(alpha: 0.10)
                    : Colors.transparent),
            borderRadius: BorderRadius.circular(999),
            border: primary
                ? null
                : Border.all(
                    color: Colors.white.withValues(alpha: _down ? 0.50 : 0.28),
                    width: 1.5,
                  ),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: primary ? _kNavy : Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}