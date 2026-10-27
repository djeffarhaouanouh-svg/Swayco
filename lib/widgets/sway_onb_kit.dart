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

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/persona_categories.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

/// Jetons de la direction 1e. Le cyan reste [SC.accent] du thème.
abstract final class SwayOnb {
  static const screenBg = Color(0xFF07080A);
  static const fieldBg = Color(0xFF0E1114);
  static const fieldBorder = Color(0xFF23282F);
  static const pinBg = Color(0xFF14171B);
  static const pinBorder = Color(0xFF2A2E33);
  static const rail = Color(0xFF1D2126);
  static const onAccent = SC.onAccent;
  static const muted = Color(0xFF8A939C);
  static const dim = Color(0xFF6D767F);

  /// Fond des étapes de l'onboarding (8c) : bleu franc en haut, cyan en bas.
  static const stepGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [SC.brandBlueDeep, SC.brandBlue, SC.brandCyan],
    stops: [0, .5, 1],
  );

  /// Surfaces posées sur [stepGradient].
  static const glassFill = Color(0x29FFFFFF);
  static const glassEdge = Color(0x47FFFFFF);
  static const onBlueSoft = Color(0xE6FFFFFF);
  static const hintOnWhite = Color(0xFF8A93A6);

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

  /// Sous-titres de l'onboarding (direction 8c) — seul endroit de l'app
  /// en Plus Jakarta Sans, le reste garde dmSans/bricolageGrotesque.
  static TextStyle body = GoogleFonts.plusJakartaSans(
    fontSize: 16,
    height: 1.5,
    fontWeight: FontWeight.w500,
    color: Colors.white,
  );

  static TextStyle field = GoogleFonts.dmSans(
    fontSize: 17,
    fontWeight: FontWeight.w500,
    color: SC.bgDeep,
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

/// Titre display avec le dernier mot dans une pastille jaune (« Bien·venue »).
/// Sur un mot unique, la coupe se fait au milieu, comme sur la maquette.
class SwayTitle extends StatelessWidget {
  const SwayTitle(this.text, {super.key, this.size = 52});

  final String text;
  final double size;

  (String, String) get _split {
    final t = text.trim();
    var i = t.lastIndexOf(' ');
    // « parles-tu ? » : la ponctuation isolée (espace fine française) reste
    // collée au mot qui la précède, dans la pastille.
    if (i > 0 && !RegExp(r'\p{L}', unicode: true).hasMatch(t.substring(i + 1))) {
      i = t.lastIndexOf(' ', i - 1);
    }
    if (i > 0) return ('${t.substring(0, i)} ', t.substring(i + 1));
    return (t.substring(0, t.length ~/ 2), t.substring(t.length ~/ 2));
  }

  @override
  Widget build(BuildContext context) {
    final (head, tail) = _split;
    final style = SwayOnb.display(size);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 4,
      children: [
        Text(head, style: style),
        DecoratedBox(
          decoration: BoxDecoration(
            color: SC.accent,
            borderRadius: BorderRadius.circular(size * 0.32),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: size * 0.16),
            child: Text(tail, style: style.copyWith(color: SC.onAccent)),
          ),
        ),
      ],
    );
  }
}

/// Barre carrousel : segments pleine largeur, l'actif en jaune.
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
                        ? Colors.white.withValues(alpha: 0.55)
                        : Colors.white.withValues(alpha: 0.28),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Champ 8c : fond blanc, repère bleu à gauche, anneau bleu au focus.
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(SwayOnb.radius),
        border: Border.all(
          color: focused ? SC.brandBlue : Colors.white,
          width: 1.5,
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: SC.brandBlue.withValues(alpha: 0.25),
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
              color: SC.brandBlue,
              borderRadius: BorderRadius.circular(99),
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
              cursorColor: SC.brandBlue,
              style: SwayOnb.field,
              decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: widget.hint,
                hintStyle: SwayOnb.field.copyWith(color: SwayOnb.hintOnWhite),
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

/// Bouton principal : pilule jaune pleine, libellé display foncé.
class SwayCta extends StatelessWidget {
  const SwayCta({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Icône posée avant le libellé (étape photo). Null = libellé seul.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      style: GoogleFonts.archivoBlack(fontSize: 17, letterSpacing: 0.2),
    );
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: SC.accent,
        foregroundColor: SC.onAccent,
        disabledBackgroundColor: Colors.white.withValues(alpha: 0.22),
        disabledForegroundColor: Colors.white.withValues(alpha: 0.6),
        minimumSize: const Size.fromHeight(SwayOnb.ctaHeight),
        shape: const StadiumBorder(),
        elevation: 0,
      ),
      // Avec icône, le tout rétrécit plutôt que de déborder (allemand, russe).
      child: icon == null
          ? text
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 22, color: SC.onAccent),
                  const SizedBox(width: 8),
                  text,
                ],
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
        foregroundColor: SwayOnb.onBlueSoft,
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

/// Ligne de sélection (langue / genre) : verre blanc sur le bleu, blanche
/// pleine avec coche jaune si choisie.
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
      color: selected ? Colors.white : SwayOnb.glassFill,
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
              color: selected ? Colors.white : SwayOnb.glassEdge,
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
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? SC.bgDeep : Colors.white,
                  ),
                ),
              ),
              if (selected)
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: SC.accent,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_rounded,
                      size: 14, color: SC.onAccent),
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

  // Genre de pastille : 0 = jaune, 1 = verre, 2 = bleu nuit.
  static const _pins = <(String, double, double, double, int)>[
    ('Hola', 46, -24, -8, 0),
    ('Ciao', 96, 999, 6, 1),
    ('こんにちは', 178, 34, -4, 1),
    ('Olá', 300, 999, 7, 2),
    ('Hallo', 360, 22, -5, 1),
  ];

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final (label, top, left, angle, kind) in _pins)
          Positioned(
            top: top,
            left: left == 999 ? null : left,
            right: left == 999 ? -14 : null,
            child: Transform.rotate(
              angle: angle * 3.14159 / 180,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 10),
                decoration: BoxDecoration(
                  color: switch (kind) {
                    0 => SC.accent,
                    2 => SC.bgDeep,
                    _ => SwayOnb.glassFill,
                  },
                  borderRadius: BorderRadius.circular(99),
                  border: kind == 1
                      ? Border.all(color: SwayOnb.glassEdge)
                      : null,
                ),
                child: Text(
                  label,
                  style: GoogleFonts.dmSans(
                    fontSize: 15,
                    fontWeight: kind == 1 ? FontWeight.w500 : FontWeight.w700,
                    color: kind == 0 ? SC.onAccent : Colors.white,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Coque du wizard : fond dégradé bleu → cyan + barre carrousel + PageView.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SC.brandBlueDeep,
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: SwayOnb.stepGradient),
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
  const _StepHead({
    required this.titleKey,
    required this.subtitleKey,
    this.hintKey,
    this.maxWidth = 310,
  });

  final String titleKey;
  final String subtitleKey;
  final String? hintKey;
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
        if (hintKey != null) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Text(
              AppStrings.t(hintKey!),
              style: SwayOnb.body.copyWith(
                fontSize: 13,
                height: 1.4,
                color: SwayOnb.onBlueSoft,
              ),
            ),
          ),
        ],
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
    // Pas de scroll : la page tient dans la hauteur donnée par le PageView.
    // SwayPins remplit tout le bas via l'Expanded — avant, un
    // SingleChildScrollView laissait défiler dans ce vide.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SwayOnb.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 44),
          const _StepHead(
            titleKey: 'onb_welcome_title',
            subtitleKey: 'onb_welcome_subtitle',
            hintKey: 'onb_welcome_hint',
            maxWidth: 290,
          ),
          const SizedBox(height: 32),
          SwayInput(
            controller: nameCtrl,
            hint: AppStrings.t('onb_first_name_hint'),
          ),
          const SizedBox(height: 16),
          SwayCta(label: AppStrings.t('onb_next'), onPressed: onNext),
          const Expanded(child: SwayPins()),
        ],
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
                    leading: _PickTile(
                      selected: selected == value,
                      child: Icon(
                        icon,
                        size: 20,
                        color: selected == value
                            ? SC.brandBlue
                            : Colors.white,
                      ),
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

/// "Qu'est-ce qui te définit le plus ?" — single choice among the 18
/// `kPersonaCategories`, as a 2-column grid of content-sized cards.
///
/// Everything scrolls as ONE page: title, every choice, then the buttons at
/// the very end. Picking a card slides down to them; tapping the picked card
/// again un-picks it ([onSelect] toggles) and the CTA disappears — only
/// "Retour" stays.
class SwayStepPersonaCategory extends StatefulWidget {
  const SwayStepPersonaCategory({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.onBack,
    required this.onFinish,
    this.finishLabelKey = 'onb_finish',
  });

  final String? selected;

  /// Called with the tapped label; the parent toggles (same label = un-pick).
  final ValueChanged<String> onSelect;
  final VoidCallback onBack;
  final VoidCallback onFinish;
  final String finishLabelKey;

  @override
  State<SwayStepPersonaCategory> createState() =>
      _SwayStepPersonaCategoryState();
}

class _SwayStepPersonaCategoryState extends State<SwayStepPersonaCategory> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _tap(String label) {
    final picking = widget.selected != label;
    widget.onSelect(label);
    if (!picking) return;
    // After the rebuild: the CTA has just appeared, so the end moved.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    const cats = kPersonaCategories;
    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(22, 30, 22, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SwayOnb.gutter - 22,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwayTitle(AppStrings.t('onb_persona_title'), size: 30),
                const SizedBox(height: 12),
                Text(
                  AppStrings.t('onb_persona_subtitle'),
                  style: SwayOnb.body,
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          // Two per row, both cards of a row as tall as the taller one.
          for (var i = 0; i < cats.length; i += 2) ...[
            if (i > 0) const SizedBox(height: 10),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var j = i; j < i + 2; j++) ...[
                    if (j > i) const SizedBox(width: 10),
                    Expanded(
                      child: j < cats.length
                          ? _PersonaCard(
                              category: cats[j],
                              selected: widget.selected == cats[j].label,
                              onTap: () => _tap(cats[j].label),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                SwayOnb.gutter - 22, 8, SwayOnb.gutter - 22, 40),
            child: Row(
              children: [
                SwayGhostButton(
                  label: AppStrings.t('onb_back'),
                  onPressed: widget.onBack,
                ),
                if (widget.selected != null) ...[
                  const SizedBox(width: 14),
                  Expanded(
                    child: SwayCta(
                      label: AppStrings.t(widget.finishLabelKey),
                      onPressed: widget.onFinish,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Où es-tu ?" — GPS auto-detect (primary row) or the manual country/city
/// picker (secondary link, and the fallback when detection fails). Mirrors
/// [SwayStepGender]'s shape: one main action row, footer CTA disabled until
/// a country is known.
class SwayStepLocation extends StatelessWidget {
  const SwayStepLocation({
    super.key,
    required this.country,
    required this.detecting,
    required this.onAutoDetect,
    required this.onManual,
    required this.onBack,
    required this.onFinish,
    this.finishLabelKey = 'onb_finish',
  });

  final String country;
  final bool detecting;
  final VoidCallback onAutoDetect;
  final VoidCallback onManual;
  final VoidCallback onBack;
  final VoidCallback onFinish;
  final String finishLabelKey;

  @override
  Widget build(BuildContext context) {
    final has = country.trim().isNotEmpty;
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
                  titleKey: 'onb_location_title',
                  subtitleKey: 'onb_location_subtitle',
                ),
                const SizedBox(height: 34),
                SwayPickRow(
                  height: 74,
                  leading: _PickTile(
                    selected: has,
                    child: detecting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            has ? (countryFlagFor(country) ?? '🌍') : '📍',
                            style: const TextStyle(fontSize: 20),
                          ),
                  ),
                  label:
                      has ? country : AppStrings.t('onb_location_autodetect'),
                  selected: has,
                  onTap: onAutoDetect,
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: onManual,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      AppStrings.t('onb_location_manual'),
                      style: const TextStyle(
                        color: SwayOnb.onBlueSoft,
                        decoration: TextDecoration.underline,
                        decorationColor: SwayOnb.onBlueSoft,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        _StepFooter(
          onBack: onBack,
          onFinish: has ? onFinish : null,
          finishLabelKey: finishLabelKey,
        ),
      ],
    );
  }
}

class _PersonaCard extends StatelessWidget {
  const _PersonaCard({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  final PersonaCategory category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Colors.white : SwayOnb.glassFill,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? Colors.white : SwayOnb.glassEdge,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(category.emoji,
                      style: const TextStyle(fontSize: 24, height: 1)),
                  const Spacer(),
                  if (selected)
                    Container(
                      width: 19,
                      height: 19,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: SC.accent,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.check_rounded,
                          size: 12, color: SC.onAccent),
                    )
                  else
                    Container(
                      width: 19,
                      height: 19,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: SwayOnb.glassEdge, width: 1.5),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 9),
              Text(
                personaCategoryLabel(category.label),
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: selected ? SC.bgDeep : Colors.white,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                personaCategoryExamples(category.label, category.examplesFr),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.dmSans(
                  fontSize: 12,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                  color: selected
                      ? SC.bgDeep.withValues(alpha: 0.65)
                      : SwayOnb.onBlueSoft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pastille d'icône en tête d'une [SwayPickRow] : bleu nuit translucide sur
/// le bleu, bleu très clair quand la ligne est choisie (fond blanc).
class _PickTile extends StatelessWidget {
  const _PickTile({required this.selected, required this.child});

  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected
            ? const Color(0xFFE6EEFF)
            : SC.bgDeep.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}

/// Dernière étape — la photo, facultative. Une carte aperçu (vide, puis la
/// photo choisie telle qu'elle sortira sur Discover), les avantages d'en avoir
/// une, des exemples de photos acceptées, et un bouton qui change de rôle :
/// « Ajouter une photo » sans photo, « Commencer » avec.
///
/// Le contenu défile (iPhone SE) ; le bouton reste en bas, toujours visible.
class SwayStepPhoto extends StatelessWidget {
  const SwayStepPhoto({
    super.key,
    required this.photo,
    required this.name,
    required this.country,
    required this.city,
    required this.onPick,
    required this.onSkip,
    required this.onBack,
    required this.onFinish,
    this.busy = false,
    this.finishLabelKey = 'onb_finish',
  });

  /// La photo recadrée, ou null tant que rien n'est choisi.
  final Uint8List? photo;

  /// Ce que la carte affichera sous la photo : prénom, pays (→ drapeau), ville.
  final String name;
  final String country;
  final String city;

  final VoidCallback onPick;
  final VoidCallback onSkip;
  final VoidCallback onBack;
  final VoidCallback onFinish;

  /// L'onboarding se termine (envoi de la photo en cours) : plus rien à toucher.
  final bool busy;

  /// Libellé du bouton quand une photo est choisie : « Commencer » à la fin,
  /// « Suivant » quand la vérification du profil vient ensuite.
  final String finishLabelKey;

  /// Les photos d'exemple, de la plus importante à la moins importante : c'est
  /// la dernière qu'on retire quand la place manque.
  static const _acceptedPhotos = <(String, String)>[
    ('assets/onboarding/photo_ok_1.jpg', 'onb_photo_ok_face'),
    ('assets/onboarding/photo_ok_2.jpg', 'onb_photo_ok_light'),
    ('assets/onboarding/photo_ok_3.jpg', 'onb_photo_ok_alone'),
  ];

  @override
  Widget build(BuildContext context) {
    final has = photo != null;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
                SwayOnb.gutter, 8, SwayOnb.gutter, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Les pages glissent à la main désactivées : sans ce bouton,
                // cette étape serait une impasse. Il occupe la place vide que
                // les autres étapes laissent au-dessus de leur titre (48).
                SizedBox(
                  height: 40,
                  child: Transform.translate(
                    offset: const Offset(-8, 0),
                    child: IconButton(
                      onPressed: busy ? null : onBack,
                      tooltip: AppStrings.t('onb_back'),
                      icon: const Icon(Icons.arrow_back_rounded),
                      color: SwayOnb.onBlueSoft,
                      style: IconButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(40, 40),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                ),
                SwayTitle(AppStrings.t('onb_photo_title'), size: 30),
                const SizedBox(height: 12),
                Text(
                  AppStrings.t('onb_photo_subtitle'),
                  style: SwayOnb.body.copyWith(fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    _PhotoPreviewCard(
                      photo: photo,
                      name: name,
                      country: country,
                      city: city,
                      onTap: busy ? null : onPick,
                    ),
                    const SizedBox(width: 16),
                    const Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _PhotoBenefit(
                            icon: Icons.favorite_rounded,
                            valueKey: 'onb_photo_benefit_likes_value',
                            legendKey: 'onb_photo_benefit_likes',
                          ),
                          SizedBox(height: 12),
                          _PhotoBenefit(
                            icon: Icons.chat_bubble_rounded,
                            valueKey: 'onb_photo_benefit_msgs_value',
                            legendKey: 'onb_photo_benefit_msgs',
                          ),
                          SizedBox(height: 12),
                          _PhotoBenefit(
                            icon: Icons.public_rounded,
                            valueKey: 'onb_photo_benefit_world_value',
                            legendKey: 'onb_photo_benefit_world',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  AppStrings.t('onb_photo_accepted'),
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: SC.accent,
                  ),
                ),
                const SizedBox(height: 9),
                // Trois vignettes avec leur légende (84 chacune, 12 d'air entre
                // elles) ne tiennent pas sur les tout petits téléphones : on en
                // retire une plutôt que de serrer ou de déborder.
                LayoutBuilder(
                  builder: (context, box) {
                    final roomForThree = box.maxWidth >= 3 * 84 + 2 * 12;
                    final shown = _acceptedPhotos.take(roomForThree ? 3 : 2);
                    return Row(
                      mainAxisAlignment: roomForThree
                          ? MainAxisAlignment.spaceBetween
                          : MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final (i, p) in shown.indexed) ...[
                          if (i > 0 && !roomForThree) const SizedBox(width: 24),
                          _AcceptedPhoto(asset: p.$1, labelKey: p.$2),
                        ],
                      ],
                    );
                  },
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
              SwayCta(
                icon: has ? null : Icons.photo_camera_rounded,
                label: AppStrings.t(has ? finishLabelKey : 'onb_photo_add'),
                onPressed: busy ? null : (has ? onFinish : onPick),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: busy ? null : (has ? onPick : onSkip),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white.withValues(alpha: 0.88),
                  minimumSize: const Size(0, 44),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  AppStrings.t(has ? 'onb_photo_change' : 'onb_photo_skip'),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// La carte aperçu 140×200 : un cadre pointillé avec « + photo » tant que rien
/// n'est choisi, puis la photo avec prénom, drapeau et lieu — comme la carte
/// Discover la montrera. Toucher la carte ouvre le sélecteur.
class _PhotoPreviewCard extends StatelessWidget {
  const _PhotoPreviewCard({
    required this.photo,
    required this.name,
    required this.country,
    required this.city,
    required this.onTap,
  });

  final Uint8List? photo;
  final String name;
  final String country;
  final String city;
  final VoidCallback? onTap;

  static const double _w = 140;
  static const double _h = 200;
  static const double _radius = 24;

  @override
  Widget build(BuildContext context) {
    final place = [country.trim(), city.trim()]
        .where((s) => s.isNotEmpty)
        .join(' · ');
    final flag = countryFlagFor(country.trim());
    final shade = Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: 90,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black.withValues(alpha: 0.65),
            ],
          ),
        ),
      ),
    );

    final Widget card;
    if (photo == null) {
      card = CustomPaint(
        foregroundPainter: _DashedRRectPainter(
          color: Colors.white.withValues(alpha: 0.55),
          radius: _radius,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(_radius),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_radius),
            child: Stack(
              fit: StackFit.expand,
              children: [
                shade,
                // Le squelette du nom et du lieu, que la photo remplira.
                Positioned(
                  left: 12,
                  bottom: 30,
                  child: _SkeletonBar(width: 64, height: 12, alpha: 0.4),
                ),
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _SkeletonBar(width: 50, height: 8, alpha: 0.3),
                ),
                Center(
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      color: SC.accent,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.add_a_photo_rounded,
                      size: 26,
                      color: SC.onAccent,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } else {
      card = Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_radius),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.6),
            width: 2,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x9904123A),
              blurRadius: 36,
              spreadRadius: -12,
              offset: Offset(0, 18),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_radius - 2),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(
                photo!,
                fit: BoxFit.cover,
                alignment: const Alignment(0, -0.55),
                gaplessPlayback: true,
              ),
              shade,
              Positioned(
                left: 12,
                right: 12,
                bottom: 30,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SwayOnb.display(17),
                      ),
                    ),
                    if (flag != null) ...[
                      const SizedBox(width: 6),
                      Text(flag, style: const TextStyle(fontSize: 13)),
                    ],
                  ],
                ),
              ),
              if (place.isNotEmpty)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Text(
                    place,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Semantics(
      button: true,
      label: AppStrings.t(
        photo == null ? 'onb_photo_add' : 'onb_photo_change',
      ),
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(width: _w, height: _h, child: card),
      ),
    );
  }
}

class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({
    required this.width,
    required this.height,
    required this.alpha,
  });

  final double width;
  final double height;
  final double alpha;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: alpha),
          borderRadius: BorderRadius.circular(99),
        ),
      );
}

/// Un rectangle arrondi en pointillés. Flutter n'a pas de bordure pointillée :
/// on découpe le contour en tirets.
class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;
  static const double strokeWidth = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    ).deflate(strokeWidth / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;
    const dash = 6.0, gap = 5.0;
    for (final metric in (Path()..addRRect(rrect)).computeMetrics()) {
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
  bool shouldRepaint(_DashedRRectPainter old) =>
      old.color != color || old.radius != radius;
}

/// Un avantage d'avoir une photo : pastille d'icône, valeur en jaune, légende.
/// La valeur est une clé de texte à part : le jour où l'on a de vrais chiffres
/// mesurés, on les met dans `app_strings.dart` sans toucher au code.
class _PhotoBenefit extends StatelessWidget {
  const _PhotoBenefit({
    required this.icon,
    required this.valueKey,
    required this.legendKey,
  });

  final IconData icon;
  final String valueKey;
  final String legendKey;

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
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Rétrécit plutôt que de déborder : « Mehr Nachrichten » est
              // bien plus long que « ×2 ».
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  AppStrings.t(valueKey),
                  maxLines: 1,
                  style: SwayOnb.display(19).copyWith(color: SC.accent),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                AppStrings.t(legendKey),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
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

/// Une vignette d'exemple de photo acceptée, avec sa coche verte. L'image
/// vient de `assets/onboarding/` (fournie par le produit) ; absente, un
/// dégradé gris avec un personnage tient la place.
class _AcceptedPhoto extends StatelessWidget {
  const _AcceptedPhoto({required this.asset, required this.labelKey});

  final String asset;
  final String labelKey;

  static const Color _ok = Color(0xFF22C55E);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.5),
                  width: 1.5,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16.5),
                child: Image.asset(
                  asset,
                  width: 63,
                  height: 63,
                  fit: BoxFit.cover,
                  alignment: const Alignment(0, -0.56),
                  errorBuilder: (_, _, _) => const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [SwayOnb.muted, SwayOnb.dim],
                      ),
                    ),
                    child: Center(
                      child: Icon(
                        Icons.person_rounded,
                        size: 34,
                        color: Color(0xBFFFFFFF),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: -6,
              top: -6,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: _ok,
                  shape: BoxShape.circle,
                  // Le liseré reprend la couleur du dégradé : la coche
                  // paraît découpée dans la vignette.
                  border: Border.all(color: SC.brandBlue, width: 2),
                ),
                child: const Icon(
                  Icons.check_rounded,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ConstrainedBox(
          // Trois légendes côte à côte doivent tenir dans la largeur utile
          // du plus petit téléphone (320 − 2 × 28 = 264) : 3 × 84 = 252.
          constraints: const BoxConstraints(maxWidth: 84),
          child: Text(
            AppStrings.t(labelKey),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 10.5,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: Colors.white.withValues(alpha: 0.9),
            ),
          ),
        ),
      ],
    );
  }
}

/// Pop-up « Tu es sûr ? » quand on passe l'étape photo sans photo. Renvoie
/// `true` pour « Ajouter une photo », `false` pour « Passer quand même », et
/// `null` si on la ferme en touchant à côté (il ne se passe alors rien).
///
/// [showSwaycoConfirm] ne convient pas : il n'a pas d'emoji et son fond est la
/// surface sombre des pop-ups ; ici, du verre posé sur le dégradé de
/// l'onboarding. Mêmes jetons ([PopupTokens]) et même bouton ([PopupButton]).
Future<bool?> showSwayPhotoSkipDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierColor: PopupTokens.scrim,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 44, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.4),
                width: 1.2,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '😢',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 38, height: 1),
                ),
                const SizedBox(height: 8),
                Text(
                  AppStrings.t('onb_photo_sure_title'),
                  textAlign: TextAlign.center,
                  style: SwayOnb.display(17),
                ),
                const SizedBox(height: 6),
                Text(
                  AppStrings.t('onb_photo_sure_body'),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 13,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                ),
                const SizedBox(height: 14),
                PopupButton(
                  label: AppStrings.t('onb_photo_sure_add'),
                  height: 44,
                  onPressed: () => Navigator.of(ctx).pop(true),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white.withValues(alpha: 0.85),
                    minimumSize: const Size(0, 40),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    AppStrings.t('onb_photo_sure_skip'),
                    textAlign: TextAlign.center,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
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
