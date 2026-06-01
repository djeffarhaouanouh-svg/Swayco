import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/auth_service.dart';
import '../services/device_id.dart';
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/profile_api.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../theme/swayco_theme.dart';
import '../widgets/glass.dart';
import '../widgets/mesh_background.dart';

/// First-run flow: first name + the user's own spoken language (stored locally).
/// The remote participant's language is discovered from their LiveKit metadata
/// at call time — no manual entry needed.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.onCompleted,
    this.editing = false,
  });

  final VoidCallback onCompleted;

  /// When true, opened from settings to update profile (does not flip onboarding flag off).
  final bool editing;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageController = PageController();
  final _nameCtrl = TextEditingController();
  final _bioCtrl = TextEditingController();
  final _countryCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  String? _selectedLang;
  /// `m` / `f` / `x` or null. Asked once on the gender step right after
  /// language. Skipped entirely on subsequent runs (see [_genderAlreadySet]).
  String? _selectedGender;
  /// True after [_prefill] has read SharedPreferences. While false, the
  /// gender step is hidden from the page count so the dots / total stays
  /// stable when the answer becomes known.
  bool _prefillDone = false;
  /// Set in [_prefill] from [UserPrefs.isGenderSet]. When true the gender
  /// page is omitted from the flow ("Une fois choisi, plus s'afficher").
  bool _genderAlreadySet = false;
  int _page = 0;

  /// Total pages shown in this run. Welcome (0) + Language (1) + optionally
  /// Gender (2), so 3 on first-ever onboarding and 2 once gender is known.
  int get _pageCount => 2 + (_genderAlreadySet ? 0 : 1);

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  /// Local UserPrefs first (instant), then — in editing mode — overlay with
  /// the latest Supabase row so the field reflects what other users see, not
  /// just what was last typed on this device.
  Future<void> _prefill() async {
    final snap = await UserPrefs.loadProfile();
    final genderAlready = await UserPrefs.isGenderSet();
    if (!mounted) return;
    if (snap != null) {
      setState(() {
        _nameCtrl.text = snap.firstName;
        final stored = snap.sourceLang.trim();
        if (stored.isNotEmpty && findLanguageByCode(stored) != null) {
          _selectedLang = findLanguageByCode(stored)!.code;
        }
        if (snap.gender == 'm' || snap.gender == 'f' || snap.gender == 'x') {
          _selectedGender = snap.gender;
        }
      });
    }
    if (mounted) {
      setState(() {
        _genderAlreadySet = genderAlready;
        _prefillDone = true;
      });
    }
    if (!widget.editing || !isSupabaseReady) return;
    try {
      final uid = await DeviceId.getOrCreate();
      final remote = await ProfileApi.fetchById(uid);
      if (!mounted || remote == null) return;
      setState(() {
        if (remote.displayName.trim().isNotEmpty) {
          _nameCtrl.text = remote.displayName;
        }
        if (remote.bio.isNotEmpty) {
          _bioCtrl.text = remote.bio;
        }
        if (remote.country.isNotEmpty) {
          _countryCtrl.text = remote.country;
        }
        if (remote.city.isNotEmpty) {
          _cityCtrl.text = remote.city;
        }
        if (remote.language.trim().isNotEmpty &&
            findLanguageByCode(remote.language) != null) {
          _selectedLang = remote.language;
        }
      });
    } catch (_) {}
  }

  /// Flip the UI to the newly chosen language immediately, even while the
  /// user is still on the language picker, so the "Save / Get started"
  /// button label updates in real time.
  void _onLanguageSelected(String code) {
    AppStrings.setFromCode(code);
    setState(() => _selectedLang = code);
  }

  /// Opens the cascading country → city picker and stores the result in the
  /// (hidden) country / city controllers so [_finish] persists them.
  Future<void> _openLocationPicker() async {
    final result = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _LocationPickerSheet(
        initialCountry: _countryCtrl.text.trim(),
        initialCity: _cityCtrl.text.trim(),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _countryCtrl.text = result.$1;
      _cityCtrl.text = result.$2;
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _nameCtrl.dispose();
    _bioCtrl.dispose();
    _countryCtrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('onb_need_name'))),
      );
      return;
    }
    if (_selectedLang == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('onb_need_language'))),
      );
      return;
    }
    // Only enforce the gender pick on first run (when the step is actually
    // shown). In editing mode + on later sessions, [_genderAlreadySet] is
    // true and we accept whatever was saved before (or none).
    if (!widget.editing && !_genderAlreadySet && _selectedGender == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('onb_need_gender'))),
      );
      return;
    }
    final genderToSave = _selectedGender ?? '';
    await UserPrefs.completeOnboarding(
      firstName: name,
      sourceLang: _selectedLang!,
      // Other person's language is now discovered live from their metadata.
      targetLang: '',
      gender: genderToSave,
    );
    // Make the rest of the app speak the user's chosen language right away.
    AppStrings.setFromCode(_selectedLang!);
    // Only push to Supabase if we already have an auth user — otherwise
    // the FK `profiles.id REFERENCES auth.users(id)` would fail. The
    // initial onboarding runs pre-login by design; the upsert happens
    // post-signin from `main.dart::_hydrateAuthedSession`.
    if (AuthService.isAuthenticated) {
      final deviceId = await DeviceId.getOrCreate();
      await ProfileApi.upsertMyProfile(
        deviceId: deviceId,
        displayName: name,
        language: _selectedLang!,
        gender: genderToSave,
      );
      // Bio is only edited via this screen in editing mode (the first-run
      // welcome flow keeps the form to name + language). Persist it
      // separately because upsertMyProfile doesn't carry the bio column.
      if (widget.editing) {
        await ProfileApi.updateMyBio(
          userId: deviceId,
          bio: _bioCtrl.text.trim(),
        );
        await ProfileApi.updateMyLocation(
          userId: deviceId,
          country: _countryCtrl.text.trim(),
          city: _cityCtrl.text.trim(),
        );
      }
    }
    if (!mounted) return;
    widget.onCompleted();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.editing) {
      // Solid near-black background to match the rest of the app (the
      // profile screen et al.), instead of the navy mesh — glass header
      // bar with the back button + title, glass inputs with cyan focus,
      // and a SC.accent "Save" pill.
      return Scaffold(
        backgroundColor: const Color(0xFF0E0E0E),
        body: SafeArea(
            child: Column(
              children: [
                // Header matching the rest of the app: a big left-aligned
                // SCText.h1 title (same font as Discover / Chat / Messages),
                // preceded by a plain back button.
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 20, 4),
                  child: Row(
                    children: [
                      GlassIconButton(
                        icon: Icons.arrow_back_rounded,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          AppStrings.t('onb_profile_title'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: SCText.h1,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _GlassTextField(
                          controller: _nameCtrl,
                          textCapitalization: TextCapitalization.words,
                          label: AppStrings.t('onb_first_name_label'),
                          hint: AppStrings.t('onb_first_name_hint'),
                          icon: Icons.badge_outlined,
                        ),
                        const SizedBox(height: 14),
                        _GlassTextField(
                          controller: _bioCtrl,
                          textCapitalization: TextCapitalization.sentences,
                          maxLength: profileBioMaxLength,
                          minLines: 2,
                          maxLines: 3,
                          label: 'Bio',
                          hint: AppStrings.t('profile_bio_placeholder'),
                          icon: Icons.short_text,
                          alignLabelWithHint: true,
                        ),
                        const SizedBox(height: 14),
                        // Single field: tap to pick country → then city.
                        _GlassSelectField(
                          icon: Icons.public,
                          label: AppStrings.t('onb_location_label'),
                          hint: AppStrings.t('onb_location_hint'),
                          value: [_cityCtrl.text.trim(), _countryCtrl.text.trim()]
                              .where((s) => s.isNotEmpty)
                              .join(', '),
                          onTap: _openLocationPicker,
                        ),
                        const SizedBox(height: 22),
                        Text(
                          AppStrings.t('onb_language_picker_label'),
                          style: SCText.body.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _LanguageGrid(
                          selected: _selectedLang,
                          onSelect: _onLanguageSelected,
                        ),
                        const SizedBox(height: 28),
                        FilledButton(
                          onPressed: _finish,
                          style: FilledButton.styleFrom(
                            backgroundColor: SC.accent,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(50),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: Text(
                            AppStrings.t('onb_save'),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      );
    }

    // While [_prefill] hasn't finished reading SharedPreferences, hold the
    // wizard with a blank scaffold. Otherwise the gender step would briefly
    // flash in before [_genderAlreadySet] resolves to true on returning
    // users. Cheap — _prefill is a single SharedPreferences read.
    if (!_prefillDone) {
      return const Scaffold(
        backgroundColor: SC.bg,
        body: SafeArea(child: SizedBox.shrink()),
      );
    }

    final showGenderStep = !_genderAlreadySet;
    final nextOrFinishFromLanguage =
        showGenderStep ? _goToGenderStep : _finish;

    return Scaffold(
      backgroundColor: SC.bg,
      body: MeshBackground(
        child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _OnboardingHeader(page: _page, pageCount: _pageCount),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  _StepWelcome(
                    nameCtrl: _nameCtrl,
                    onNext: () {
                      if (_nameCtrl.text.trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(AppStrings.t('onb_need_name'))),
                        );
                        return;
                      }
                      _pageController.nextPage(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                      );
                    },
                  ),
                  _StepLanguage(
                    selected: _selectedLang,
                    onSelect: _onLanguageSelected,
                    onBack: () => _pageController.previousPage(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                    ),
                    onFinish: nextOrFinishFromLanguage,
                    finishLabelKey:
                        showGenderStep ? 'onb_next' : 'onb_finish',
                  ),
                  if (showGenderStep)
                    _StepGender(
                      selected: _selectedGender,
                      onSelect: (g) => setState(() => _selectedGender = g),
                      onBack: () => _pageController.previousPage(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                      ),
                      onFinish: _finish,
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

  void _goToGenderStep() {
    if (_selectedLang == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('onb_need_language'))),
      );
      return;
    }
    _pageController.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }
}

class _OnboardingHeader extends StatelessWidget {
  const _OnboardingHeader({required this.page, required this.pageCount});

  final int page;
  final int pageCount;

  String get _titleKey {
    switch (page) {
      case 0:
        return 'onb_welcome_title';
      case 1:
        return 'onb_language_title';
      default:
        return 'onb_gender_title';
    }
  }

  String get _subtitleKey {
    switch (page) {
      case 0:
        return 'onb_welcome_subtitle';
      case 1:
        return 'onb_language_subtitle';
      default:
        return 'onb_gender_subtitle';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.t(_titleKey),
            style: SCText.h2.copyWith(fontSize: 26),
          ),
          const SizedBox(height: 6),
          Text(
            AppStrings.t(_subtitleKey),
            style: const TextStyle(
              color: SC.textSecondary,
              fontSize: 14,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              for (var i = 0; i < pageCount; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                _Dot(active: i == page),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: active ? 22 : 8,
      height: 8,
      decoration: BoxDecoration(
        color: active
            ? SC.accent
            : Colors.white.withValues(alpha: 0.30),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

class _StepWelcome extends StatelessWidget {
  const _StepWelcome({
    required this.nameCtrl,
    required this.onNext,
  });

  final TextEditingController nameCtrl;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GlassTextField(
            controller: nameCtrl,
            textCapitalization: TextCapitalization.words,
            label: AppStrings.t('onb_first_name_label'),
            hint: AppStrings.t('onb_first_name_hint'),
            icon: Icons.badge_outlined,
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: onNext,
            style: FilledButton.styleFrom(
              backgroundColor: SC.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(
              AppStrings.t('onb_next'),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepLanguage extends StatelessWidget {
  const _StepLanguage({
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

  /// AppStrings key for the right-hand CTA. Defaults to "Commencer"; when
  /// the gender step follows, the parent passes `onb_next` instead.
  final String finishLabelKey;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _LanguageGrid(selected: selected, onSelect: onSelect),
          const SizedBox(height: 12),
          Text(
            AppStrings.t('onb_translation_help'),
            style: const TextStyle(
              color: SC.textMuted, fontSize: 13, height: 1.4,
            ),
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              TextButton(
                onPressed: onBack,
                style: TextButton.styleFrom(
                  foregroundColor: SC.textMuted,
                ),
                child: Text(AppStrings.t('onb_back')),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: onFinish,
                  style: FilledButton.styleFrom(
                    backgroundColor: SC.accent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    AppStrings.t(finishLabelKey),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StepGender extends StatelessWidget {
  const _StepGender({
    required this.selected,
    required this.onSelect,
    required this.onBack,
    required this.onFinish,
  });

  /// `m` / `f` / `x` or null (nothing picked yet).
  final String? selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onBack;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GenderOption(
            value: 'f',
            label: AppStrings.t('onb_gender_female'),
            icon: Icons.female,
            selected: selected == 'f',
            onTap: () => onSelect('f'),
          ),
          const SizedBox(height: 10),
          _GenderOption(
            value: 'm',
            label: AppStrings.t('onb_gender_male'),
            icon: Icons.male,
            selected: selected == 'm',
            onTap: () => onSelect('m'),
          ),
          const SizedBox(height: 10),
          _GenderOption(
            value: 'x',
            label: AppStrings.t('onb_gender_neutral'),
            icon: Icons.transgender,
            selected: selected == 'x',
            onTap: () => onSelect('x'),
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              TextButton(
                onPressed: onBack,
                style: TextButton.styleFrom(foregroundColor: SC.textMuted),
                child: Text(AppStrings.t('onb_back')),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: selected == null ? null : onFinish,
                  style: FilledButton.styleFrom(
                    backgroundColor: SC.accent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    AppStrings.t('onb_finish'),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GenderOption extends StatelessWidget {
  const _GenderOption({
    required this.value,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String value;
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? SC.accent.withValues(alpha: 0.18) : SC.bubbleIn;
    final fg = selected ? SC.accent : SC.textPrimary;
    final border = selected ? SC.accent : SC.glassBorder;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: fg, size: 22),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 16,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const Spacer(),
              if (selected)
                const Icon(Icons.check_circle, color: SC.accent, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

class _LanguageGrid extends StatelessWidget {
  const _LanguageGrid({required this.selected, required this.onSelect});

  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final lang in supportedLanguages)
          _LanguageChip(
            language: lang,
            selected: lang.code == selected,
            onTap: () => onSelect(lang.code),
          ),
      ],
    );
  }
}

class _LanguageChip extends StatelessWidget {
  const _LanguageChip({
    required this.language,
    required this.selected,
    required this.onTap,
  });

  final AppLanguage language;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? SC.accent.withValues(alpha: 0.18) : SC.bubbleIn;
    final borderColor = selected ? SC.accent : SC.glassBorder;
    final fg = selected ? SC.accent : SC.textPrimary;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: borderColor,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(language.flag, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Text(
                language.label,
                style: TextStyle(
                  color: fg,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Glass-styled text field matching the Swayco Midnight DA — used by
/// the "Your profile" edit form. Wraps a [TextField] so the
/// surrounding screen doesn't have to repeat the border / fill /
/// cursor configuration each time.
class _GlassTextField extends StatelessWidget {
  const _GlassTextField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.textCapitalization = TextCapitalization.none,
    this.maxLength,
    this.minLines,
    this.maxLines = 1,
    this.alignLabelWithHint = false,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final TextCapitalization textCapitalization;
  final int? maxLength;
  final int? minLines;
  final int? maxLines;
  final bool alignLabelWithHint;

  @override
  Widget build(BuildContext context) {
    return TextSelectionTheme(
      data: TextSelectionThemeData(
        cursorColor: SC.accent,
        selectionColor: SC.accent.withValues(alpha: 0.35),
        selectionHandleColor: SC.accent,
      ),
      child: TextField(
        controller: controller,
        textCapitalization: textCapitalization,
        maxLength: maxLength,
        minLines: minLines,
        maxLines: maxLines,
        cursorColor: SC.accent,
        style: const TextStyle(color: SC.textPrimary, fontSize: 15),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: SC.textMuted),
          floatingLabelStyle: const TextStyle(color: SC.accent),
          hintText: hint,
          hintStyle: const TextStyle(color: SC.textMuted),
          prefixIcon: Icon(icon, color: SC.textMuted),
          filled: true,
          fillColor: SC.bubbleIn,
          alignLabelWithHint: alignLabelWithHint,
          counterStyle: const TextStyle(color: SC.textMuted),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: SC.glassBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: SC.glassBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: SC.accent, width: 1.5),
          ),
        ),
      ),
    );
  }
}

/// A read-only, tappable field styled like [_GlassTextField] — shows a label
/// + the current [value] (or [hint] when empty) and a chevron. Used for the
/// country/city location picker.
class _GlassSelectField extends StatelessWidget {
  const _GlassSelectField({
    required this.icon,
    required this.label,
    required this.hint,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String hint;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasValue = value.trim().isNotEmpty;
    return Material(
      color: SC.bubbleIn,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: SC.glassBorder),
          ),
          child: Row(
            children: [
              Icon(icon, color: SC.textMuted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: hasValue ? SC.accent : SC.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hasValue ? value : hint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: hasValue ? SC.textPrimary : SC.textMuted,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.keyboard_arrow_down_rounded, color: SC.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two-step picker: choose a country (searchable list with flags), then a
/// city from that country's curated list — with an always-present "Autre
/// ville…" free-text field for anything not listed. Pops a `(country, city)`
/// record.
class _LocationPickerSheet extends StatefulWidget {
  const _LocationPickerSheet({
    required this.initialCountry,
    required this.initialCity,
  });
  final String initialCountry;
  final String initialCity;
  @override
  State<_LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<_LocationPickerSheet> {
  Country? _country;
  bool _onCityStep = false;
  String _search = '';
  final TextEditingController _otherCityCtrl = TextEditingController();

  @override
  void dispose() {
    _otherCityCtrl.dispose();
    super.dispose();
  }

  void _pickCountry(Country c) {
    setState(() {
      _country = c;
      _onCityStep = true;
      _otherCityCtrl.text =
          c.name == widget.initialCountry ? widget.initialCity : '';
    });
  }

  void _commitCity(String city) {
    final c = _country;
    if (c == null) return;
    Navigator.of(context).pop((c.name, city.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) => Container(
        decoration: const BoxDecoration(
          color: SC.bubbleIn,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: SC.textMuted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
              child: Row(
                children: [
                  if (_onCityStep)
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded,
                          color: SC.textPrimary),
                      onPressed: () => setState(() => _onCityStep = false),
                    )
                  else
                    const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _onCityStep
                          ? '${_country!.flag}  ${_country!.name}'
                          : AppStrings.t('onb_location_label'),
                      style: const TextStyle(
                        color: SC.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _onCityStep
                  ? _buildCityList(scrollController)
                  : _buildCountryList(scrollController),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCountryList(ScrollController sc) {
    final q = _search.trim().toLowerCase();
    final list = q.isEmpty
        ? kCountries
        : kCountries
            .where((c) => c.name.toLowerCase().contains(q))
            .toList(growable: false);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: TextField(
            autofocus: false,
            cursorColor: SC.accent,
            onChanged: (v) => setState(() => _search = v),
            style: const TextStyle(color: SC.textPrimary, fontSize: 15),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, color: SC.textMuted),
              hintText: AppStrings.t('loc_search_country'),
              hintStyle: const TextStyle(color: SC.textMuted),
              filled: true,
              fillColor: SC.bg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: SC.glassBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: SC.glassBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: SC.accent, width: 1.5),
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: sc,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final c = list[i];
              return ListTile(
                leading: Text(c.flag, style: const TextStyle(fontSize: 22)),
                title: Text(
                  c.name,
                  style: const TextStyle(
                      color: SC.textPrimary, fontWeight: FontWeight.w600),
                ),
                trailing: const Icon(Icons.chevron_right, color: SC.textMuted),
                onTap: () => _pickCountry(c),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCityList(ScrollController sc) {
    final cities = _country?.cities ?? const <String>[];
    return ListView(
      controller: sc,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        // Always-present free-text fallback for unlisted cities.
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _otherCityCtrl,
                textCapitalization: TextCapitalization.words,
                cursorColor: SC.accent,
                style: const TextStyle(color: SC.textPrimary, fontSize: 15),
                onSubmitted: (v) {
                  if (v.trim().isNotEmpty) _commitCity(v);
                },
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon:
                      const Icon(Icons.edit_location_alt_outlined,
                          color: SC.textMuted),
                  hintText: AppStrings.t('loc_other_city_hint'),
                  hintStyle: const TextStyle(color: SC.textMuted),
                  filled: true,
                  fillColor: SC.bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: SC.glassBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: SC.glassBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: SC.accent, width: 1.5),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              style: IconButton.styleFrom(
                backgroundColor: SC.accent,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.check_rounded),
              onPressed: () {
                final v = _otherCityCtrl.text.trim();
                if (v.isNotEmpty) _commitCity(v);
              },
            ),
          ],
        ),
        if (cities.isNotEmpty) const SizedBox(height: 8),
        for (final city in cities)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text(
              city,
              style: const TextStyle(
                  color: SC.textPrimary, fontWeight: FontWeight.w600),
            ),
            trailing: city == widget.initialCity &&
                    _country?.name == widget.initialCountry
                ? const Icon(Icons.check_rounded, color: SC.accent)
                : null,
            onTap: () => _commitCity(city),
          ),
      ],
    );
  }
}
