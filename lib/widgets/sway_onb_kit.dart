// ─────────────────────────────────────────────────────────────────────────────
// sway_onb_kit.dart — direction "1e" (halos + surligneur cyan + pins)
//
// Où le mettre :  lib/widgets/sway_onb_kit.dart
// Dépendances :   déjà dans le projet (google_fonts, app_strings, languages,
//                 swayco_theme). Aucune nouvelle dépendance pubspec.
//
// ── PATCH 1 — lib/screens/onboarding_screen.dart ────────────────────────────
// 1. ajouter :        import '../widgets/sway_onb_kit.dart';
// 2. dans build(), remplacer le bloc `return Scaffold(... MeshBackground ...)`
//    du premier lancement par :
//
//      return SwayOnbShell(
//        page: _page,
//        pageCount: _pageCount,
//        controller: _pageController,
//        onPageChanged: (i) => setState(() => _page = i),
//        pages: [
//          SwayStepWelcome(
//            nameCtrl: _nameCtrl,
//            onNext: () {
//              if (_nameCtrl.text.trim().isEmpty) {
//                ScaffoldMessenger.of(context).showSnackBar(
//                  SnackBar(content: Text(AppStrings.t('onb_need_name'))));
//                return;
//              }
//              _next();
//            },
//          ),
//          SwayStepLanguage(
//            selected: _selectedLang,
//            onSelect: _onLanguageSelected,
//            onBack: _back,
//            onFinish: _goFromLanguage,
//            finishLabelKey: showGenderStep ? 'onb_next' : 'onb_finish',
//          ),
//          if (showGenderStep)
//            SwayStepGender(
//              selected: _selectedGender,
//              onSelect: (g) => setState(() => _selectedGender = g),
//              onBack: _back,
//              onFinish: _finish,
//            ),
//        ],
//      );
//
// 3. les anciennes classes privées _OnboardingHeader, _Dot, _StepWelcome,
//    _StepLanguage, _StepGender, _GenderOption deviennent inutilisées :
//    supprimables. GARDER _GlassTextField / _GlassSelectField / _RewardField /
//    _LanguageGrid : le mode `editing` (profil) s'en sert encore.
//    Toute la logique (_prefill, _finish, UserPrefs, ProfileApi, AsrService)
//    reste inchangée.
//
// ── PATCH 2 — lib/screens/login_screen.dart ─────────────────────────────────
// 1. ajouter :        import '../widgets/sway_onb_kit.dart';
// 2. remplacer le `Text(...)` du titre (SCText.h1.copyWith(fontSize: 32)) par :
//
//      SwayTitle(isSignUp
//          ? AppStrings.t('login_title_signup')
//          : AppStrings.t('login_title_signin')),
//
// 3. envelopper le contenu pour récupérer les halos : dans le body, remplacer
//    `child: Column(children: [ _LoginHero(...), SafeArea(...) ])` par
//    `child: SwayHalo(preset: SwayHaloPreset.login, child: Column(...))`.
//    Le _LoginHero (assets/bienvenue.jpg) est conservé tel quel.
// 4. champs email / mot de passe : remplacer les deux TextField par
//    SwayInput(controller: _emailCtrl, hint: AppStrings.t('login_email_hint'))
//    et SwayInput(controller: _passwordCtrl, obscure: !_showPassword,
//                 hint: AppStrings.t('login_password_label'),
//                 trailing: <ton IconButton œil>)
//    puis le FilledButton principal par SwayCta(label: ..., onPressed: ...).
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/languages.dart';
import '../theme/swayco_theme.dart';

/// Jetons de la direction 1e. Le cyan reste [SC.accent] du thème.
abstract final class SwayOnb {
  static const screenBg = Color(0xFF07080A);
  static const fieldBg = Color(0xFF0E1114);
  static const fieldBorder = Color(0xFF23282F);
  static const pinBg = Color(0xFF14171B);
  static const pinBorder = Color(0xFF2A2E33);
  static const rail = Color(0xFF1D2126);
  static const onAccent = Color(0xFF04252B);
  static const muted = Color(0xFF8A939C);
  static const dim = Color(0xFF6D767F);

  static const haloCyan = Color(0xFF22D6EA);
  static const haloBlue = Color(0xFF3B4CFF);
  static const haloPink = Color(0xFFE052A0);

  static const radius = 18.0;
  static const ctaHeight = 62.0;
  static const gutter = 28.0;

  static TextStyle display(double size) => GoogleFonts.archivoBlack(
    fontSize: size,
    height: 0.94,
    letterSpacing: -size * 0.04,
    color: Colors.white,
  );

  static TextStyle body = GoogleFonts.dmSans(
    fontSize: 16,
    height: 1.5,
    fontWeight: FontWeight.w500,
    color: muted,
  );

  static TextStyle field = GoogleFonts.dmSans(
    fontSize: 17,
    fontWeight: FontWeight.w500,
    color: Colors.white,
  );
}

enum SwayHaloPreset { welcome, language, gender, login }

/// Fond noir + 3 halos flous. Remplace MeshBackground sur les écrans d'entrée.
class SwayHalo extends StatelessWidget {
  const SwayHalo({super.key, required this.child, this.preset = SwayHaloPreset.welcome});

  final Widget child;
  final SwayHaloPreset preset;

  List<_Halo> get _halos {
    switch (preset) {
      case SwayHaloPreset.welcome:
        return const [
          _Halo(SwayOnb.haloCyan, .24, 420, top: -170, left: -110),
          _Halo(SwayOnb.haloBlue, .20, 320, top: 40, right: -150),
          _Halo(SwayOnb.haloPink, .12, 310, bottom: -120, left: -60),
        ];
      case SwayHaloPreset.language:
        return const [
          _Halo(SwayOnb.haloBlue, .22, 420, top: -170, right: -130),
          _Halo(SwayOnb.haloCyan, .20, 320, top: 90, left: -150),
          _Halo(SwayOnb.haloPink, .12, 330, bottom: -140, right: -70),
        ];
      case SwayHaloPreset.gender:
        return const [
          _Halo(SwayOnb.haloPink, .16, 420, top: -170, left: -110),
          _Halo(SwayOnb.haloCyan, .20, 320, top: 60, right: -150),
          _Halo(SwayOnb.haloBlue, .20, 330, bottom: -130, left: -40),
        ];
      case SwayHaloPreset.login:
        return const [
          _Halo(SwayOnb.haloBlue, .20, 320, top: 200, right: -140),
          _Halo(SwayOnb.haloPink, .13, 330, bottom: -130, left: -70),
          _Halo(SwayOnb.haloCyan, .16, 300, bottom: -80, right: -60),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: SwayOnb.screenBg,
      child: Stack(
        children: [
          ClipRect(
            child: Stack(children: [for (final h in _halos) h]),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

class _Halo extends StatelessWidget {
  const _Halo(this.color, this.opacity, this.size,
      {this.top, this.left, this.right, this.bottom});

  final Color color;
  final double opacity;
  final double size;
  final double? top, left, right, bottom;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 45, sigmaY: 45),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: opacity),
          ),
        ),
      ),
    );
  }
}

/// Titre display avec le dernier mot surligné en cyan (« BIEN·VENUE »).
/// Sur un mot unique, la coupe se fait au milieu, comme sur la maquette.
class SwayTitle extends StatelessWidget {
  const SwayTitle(this.text, {super.key, this.size = 52});

  final String text;
  final double size;

  (String, String) get _split {
    final t = text.trim();
    final i = t.lastIndexOf(' ');
    if (i > 0) return ('${t.substring(0, i)} ', t.substring(i + 1));
    return (t.substring(0, t.length ~/ 2), t.substring(t.length ~/ 2));
  }

  @override
  Widget build(BuildContext context) {
    final (head, tail) = _split;
    final style = SwayOnb.display(size);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(head.toUpperCase(), style: style),
        DecoratedBox(
          decoration: BoxDecoration(
            color: SC.accent,
            boxShadow: [
              BoxShadow(
                color: SC.accent.withValues(alpha: 0.6),
                blurRadius: 32,
                spreadRadius: -4,
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              tail.toUpperCase(),
              style: style.copyWith(color: SwayOnb.onAccent),
            ),
          ),
        ),
      ],
    );
  }
}

/// Barre carrousel : segments pleine largeur, l'actif glow en cyan.
class SwayStepBar extends StatelessWidget {
  const SwayStepBar({super.key, required this.index, required this.count});

  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(99),
                color: i == index
                    ? SC.accent
                    : i < index
                        ? SC.accent.withValues(alpha: 0.35)
                        : SwayOnb.rail,
                boxShadow: i == index
                    ? [
                        BoxShadow(
                          color: SC.accent.withValues(alpha: 0.67),
                          blurRadius: 14,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Champ 1e : fond très sombre, repère cyan à gauche, bord cyan au focus.
class SwayInput extends StatefulWidget {
  const SwayInput({
    super.key,
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.trailing,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.words,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final Widget? trailing;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final bool enabled;

  @override
  State<SwayInput> createState() => _SwayInputState();
}

class _SwayInputState extends State<SwayInput> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: 64,
      decoration: BoxDecoration(
        color: SwayOnb.fieldBg,
        borderRadius: BorderRadius.circular(SwayOnb.radius),
        border: Border.all(
          color: focused ? SC.accent : SwayOnb.fieldBorder,
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: SC.accent.withValues(alpha: 0.12),
                  blurRadius: 0,
                  spreadRadius: 4,
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          const SizedBox(width: 20),
          Container(
            width: 3,
            height: 22,
            decoration: BoxDecoration(
              color: SC.accent,
              borderRadius: BorderRadius.circular(99),
              boxShadow: [
                BoxShadow(
                  color: SC.accent.withValues(alpha: 0.8),
                  blurRadius: 12,
                ),
              ],
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              enabled: widget.enabled,
              obscureText: widget.obscure,
              keyboardType: widget.keyboardType,
              textCapitalization: widget.textCapitalization,
              cursorColor: SC.accent,
              style: SwayOnb.field,
              decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: widget.hint,
                hintStyle: SwayOnb.field.copyWith(color: const Color(0xFF5A646E)),
              ),
            ),
          ),
          if (widget.trailing != null) widget.trailing!,
          const SizedBox(width: 18),
        ],
      ),
    );
  }
}

/// Bouton principal : cyan plein, libellé display, lueur discrète.
class SwayCta extends StatelessWidget {
  const SwayCta({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final off = onPressed == null;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(SwayOnb.radius),
        boxShadow: off
            ? null
            : [
                BoxShadow(
                  color: SC.accent.withValues(alpha: 0.45),
                  blurRadius: 22,
                  spreadRadius: -14,
                  offset: const Offset(0, 8),
                ),
              ],
      ),
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: off ? const Color(0xFF101317) : SC.accent,
          foregroundColor: off ? const Color(0xFF4E5862) : SwayOnb.onAccent,
          disabledBackgroundColor: const Color(0xFF101317),
          disabledForegroundColor: const Color(0xFF4E5862),
          minimumSize: const Size.fromHeight(SwayOnb.ctaHeight),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SwayOnb.radius),
            side: off
                ? const BorderSide(color: Color(0xFF1C2026))
                : BorderSide.none,
          ),
        ),
        child: Text(
          label.toUpperCase(),
          style: GoogleFonts.archivoBlack(fontSize: 17, letterSpacing: 0.2),
        ),
      ),
    );
  }
}

class SwayGhostButton extends StatelessWidget {
  const SwayGhostButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: SwayOnb.dim,
        minimumSize: const Size(0, SwayOnb.ctaHeight),
        padding: const EdgeInsets.symmetric(horizontal: 24),
      ),
      child: Text(
        label,
        style: GoogleFonts.dmSans(fontSize: 16, fontWeight: FontWeight.w500),
      ),
    );
  }
}

/// Ligne de sélection (langue / genre) : carte sombre, bord cyan si choisie.
class SwayPickRow extends StatelessWidget {
  const SwayPickRow({
    super.key,
    required this.leading,
    required this.label,
    required this.selected,
    required this.onTap,
    this.height = 62,
  });

  final Widget leading;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SwayOnb.fieldBg,
      borderRadius: BorderRadius.circular(SwayOnb.radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(SwayOnb.radius),
        onTap: onTap,
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SwayOnb.radius),
            border: Border.all(
              color: selected ? SC.accent : SwayOnb.fieldBorder,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.dmSans(
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFFE6EBEF),
                  ),
                ),
              ),
              if (selected)
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: SC.accent,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_rounded,
                      size: 14, color: SwayOnb.onAccent),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Les pins « Hola / Ciao / こんにちは » du bas de l'écran Bienvenue.
class SwayPins extends StatelessWidget {
  const SwayPins({super.key});

  static const _pins = <(String, double, double, double, bool)>[
    ('Hola', 46, -24, -8, true),
    ('Ciao', 96, 999, 6, false),
    ('こんにちは', 178, 34, -4, false),
    ('Olá', 300, 999, 7, false),
    ('Hallo', 360, 22, -5, false),
  ];

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final (label, top, left, angle, accent) in _pins)
          Positioned(
            top: top,
            left: left == 999 ? null : left,
            right: left == 999 ? -14 : null,
            child: Transform.rotate(
              angle: angle * 3.14159 / 180,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 10),
                decoration: BoxDecoration(
                  color: accent ? SC.accent : SwayOnb.pinBg,
                  borderRadius: BorderRadius.circular(99),
                  border: accent
                      ? null
                      : Border.all(color: SwayOnb.pinBorder),
                  boxShadow: accent
                      ? [
                          BoxShadow(
                            color: SC.accent.withValues(alpha: 0.7),
                            blurRadius: 30,
                            spreadRadius: -8,
                            offset: const Offset(0, 10),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  label,
                  style: GoogleFonts.dmSans(
                    fontSize: 15,
                    fontWeight: accent ? FontWeight.w700 : FontWeight.w500,
                    color: accent ? SwayOnb.onAccent : const Color(0xFFA9B2BA),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Coque du wizard : halos par étape + barre carrousel + PageView.
class SwayOnbShell extends StatelessWidget {
  const SwayOnbShell({
    super.key,
    required this.page,
    required this.pageCount,
    required this.controller,
    required this.onPageChanged,
    required this.pages,
  });

  final int page;
  final int pageCount;
  final PageController controller;
  final ValueChanged<int> onPageChanged;
  final List<Widget> pages;

  SwayHaloPreset get _preset => switch (page) {
        0 => SwayHaloPreset.welcome,
        1 => SwayHaloPreset.language,
        _ => SwayHaloPreset.gender,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SwayOnb.screenBg,
      body: SwayHalo(
        preset: _preset,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    SwayOnb.gutter, 26, SwayOnb.gutter, 0),
                child: SwayStepBar(index: page, count: pageCount),
              ),
              Expanded(
                child: PageView(
                  controller: controller,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: onPageChanged,
                  children: pages,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// En-tête de contenu commun aux 3 étapes : titre surligné + sous-titre.
class _StepHead extends StatelessWidget {
  const _StepHead({required this.titleKey, required this.subtitleKey, this.maxWidth = 310});

  final String titleKey;
  final String subtitleKey;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwayTitle(AppStrings.t(titleKey)),
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Text(AppStrings.t(subtitleKey), style: SwayOnb.body),
        ),
      ],
    );
  }
}

/// Étape 1 — prénom. Champ et bouton remontés sous le titre, pins en bas.
class SwayStepWelcome extends StatelessWidget {
  const SwayStepWelcome({super.key, required this.nameCtrl, required this.onNext});

  final TextEditingController nameCtrl;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: SwayOnb.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 48),
                const _StepHead(
                  titleKey: 'onb_welcome_title',
                  subtitleKey: 'onb_welcome_subtitle',
                  maxWidth: 290,
                ),
                const SizedBox(height: 34),
                SwayInput(
                  controller: nameCtrl,
                  hint: AppStrings.t('onb_first_name_hint'),
                ),
                const SizedBox(height: 16),
                SwayCta(label: AppStrings.t('onb_next'), onPressed: onNext),
                const Expanded(child: SwayPins()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Étape 2 — langue parlée. Liste à la place du menu déroulant.
class SwayStepLanguage extends StatelessWidget {
  const SwayStepLanguage({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.onBack,
    required this.onFinish,
    this.finishLabelKey = 'onb_finish',
  });

  final String? selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onBack;
  final VoidCallback onFinish;
  final String finishLabelKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
                SwayOnb.gutter, 48, SwayOnb.gutter, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _StepHead(
                  titleKey: 'onb_language_title',
                  subtitleKey: 'onb_language_subtitle',
                ),
                const SizedBox(height: 30),
                for (final lang in supportedLanguages) ...[
                  SwayPickRow(
                    leading: Text(lang.flag, style: const TextStyle(fontSize: 24)),
                    label: lang.label,
                    selected: selected == lang.code,
                    onTap: () => onSelect(lang.code),
                  ),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 6),
                Text(
                  AppStrings.t('onb_translation_help'),
                  style: SwayOnb.body.copyWith(fontSize: 14),
                ),
              ],
            ),
          ),
        ),
        _StepFooter(
          onBack: onBack,
          onFinish: onFinish,
          finishLabelKey: finishLabelKey,
        ),
      ],
    );
  }
}

/// Étape 3 — genre grammatical. « Commencer » reste éteint sans choix.
class SwayStepGender extends StatelessWidget {
  const SwayStepGender({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.onBack,
    required this.onFinish,
    this.finishLabelKey = 'onb_finish',
  });

  final String? selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onBack;
  final VoidCallback onFinish;
  final String finishLabelKey;

  static const _options = <(String, IconData, String)>[
    ('f', Icons.female, 'onb_gender_female'),
    ('m', Icons.male, 'onb_gender_male'),
    ('x', Icons.transgender, 'onb_gender_neutral'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
                SwayOnb.gutter, 48, SwayOnb.gutter, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _StepHead(
                  titleKey: 'onb_gender_title',
                  subtitleKey: 'onb_gender_subtitle',
                ),
                const SizedBox(height: 34),
                for (final (value, icon, key) in _options) ...[
                  SwayPickRow(
                    height: 74,
                    leading: Container(
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFF16191D),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(icon, color: SC.accent, size: 20),
                    ),
                    label: AppStrings.t(key),
                    selected: selected == value,
                    onTap: () => onSelect(value),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ),
        _StepFooter(
          onBack: onBack,
          onFinish: selected == null ? null : onFinish,
          finishLabelKey: finishLabelKey,
        ),
      ],
    );
  }
}

class _StepFooter extends StatelessWidget {
  const _StepFooter({
    required this.onBack,
    required this.onFinish,
    required this.finishLabelKey,
  });

  final VoidCallback onBack;
  final VoidCallback? onFinish;
  final String finishLabelKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          SwayOnb.gutter, 8, SwayOnb.gutter, 40),
      child: Row(
        children: [
          SwayGhostButton(label: AppStrings.t('onb_back'), onPressed: onBack),
          const SizedBox(width: 14),
          Expanded(
            child: SwayCta(
              label: AppStrings.t(finishLabelKey),
              onPressed: onFinish,
            ),
          ),
        ],
      ),
    );
  }
}
