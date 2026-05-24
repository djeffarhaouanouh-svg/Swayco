import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/auth_service.dart';
import '../services/device_id.dart';
import '../services/languages.dart';
import '../services/profile_api.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../theme/whatsapp_call_theme.dart';

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

  @override
  void dispose() {
    _pageController.dispose();
    _nameCtrl.dispose();
    _bioCtrl.dispose();
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
      }
    }
    if (!mounted) return;
    widget.onCompleted();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.editing) {
      return Scaffold(
        backgroundColor: WhatsAppCallTheme.scaffold,
        appBar: AppBar(
          title: Text(AppStrings.t('onb_profile_title')),
          backgroundColor: WhatsAppCallTheme.scaffold,
          foregroundColor: WhatsAppCallTheme.strongText,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _nameCtrl,
                  textCapitalization: TextCapitalization.words,
                  style: const TextStyle(color: WhatsAppCallTheme.strongText),
                  decoration: InputDecoration(
                    labelText: AppStrings.t('onb_first_name_label'),
                    // The label floats up because the controller is
                    // pre-populated by `_prefill`; the hint is only seen on
                    // a brand-new account that landed here directly.
                    hintText: AppStrings.t('onb_first_name_hint'),
                    prefixIcon: const Icon(Icons.badge_outlined,
                        color: WhatsAppCallTheme.subtleText),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _bioCtrl,
                  textCapitalization: TextCapitalization.sentences,
                  maxLength: profileBioMaxLength,
                  maxLines: 3,
                  minLines: 2,
                  style: const TextStyle(color: WhatsAppCallTheme.strongText),
                  decoration: InputDecoration(
                    labelText: 'Bio',
                    hintText: AppStrings.t('profile_bio_placeholder'),
                    prefixIcon: const Icon(Icons.short_text,
                        color: WhatsAppCallTheme.subtleText),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  AppStrings.t('onb_language_picker_label'),
                  style: const TextStyle(
                    color: WhatsAppCallTheme.strongText,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
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
                  child: Text(AppStrings.t('onb_save')),
                ),
              ],
            ),
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
        backgroundColor: WhatsAppCallTheme.scaffold,
        body: SafeArea(child: SizedBox.shrink()),
      );
    }

    final showGenderStep = !_genderAlreadySet;
    final nextOrFinishFromLanguage =
        showGenderStep ? _goToGenderStep : _finish;

    return Scaffold(
      backgroundColor: WhatsAppCallTheme.scaffold,
      body: SafeArea(
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
    return Material(
      color: WhatsAppCallTheme.scaffold,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.t(_titleKey),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              AppStrings.t(_subtitleKey),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
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
        color: active ? Colors.white : Colors.white.withValues(alpha: 0.35),
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: nameCtrl,
            textCapitalization: TextCapitalization.words,
            style: const TextStyle(color: WhatsAppCallTheme.strongText, fontSize: 16),
            decoration: InputDecoration(
              labelText: AppStrings.t('onb_first_name_label'),
              hintText: AppStrings.t('onb_first_name_hint'),
              prefixIcon: const Icon(Icons.badge_outlined, color: WhatsAppCallTheme.subtleText),
            ),
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: onNext,
            child: Text(AppStrings.t('onb_next')),
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
            style: const TextStyle(color: WhatsAppCallTheme.subtleText, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              TextButton(onPressed: onBack, child: Text(AppStrings.t('onb_back'))),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: onFinish,
                  child: Text(AppStrings.t(finishLabelKey)),
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
              TextButton(onPressed: onBack, child: Text(AppStrings.t('onb_back'))),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: selected == null ? null : onFinish,
                  child: Text(AppStrings.t('onb_finish')),
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
    final bg = selected ? WhatsAppCallTheme.accent : WhatsAppCallTheme.bar;
    final fg = selected ? Colors.white : WhatsAppCallTheme.strongText;
    final border = selected
        ? WhatsAppCallTheme.accent
        : Colors.white.withValues(alpha: 0.08);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: border, width: 1),
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
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              if (selected)
                const Icon(Icons.check_circle, color: Colors.white, size: 22),
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
    final bg = selected ? WhatsAppCallTheme.accent : WhatsAppCallTheme.bar;
    final border = selected ? WhatsAppCallTheme.accent : Colors.white.withValues(alpha: 0.08);
    final fg = selected ? Colors.white : WhatsAppCallTheme.strongText;
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
            border: Border.all(color: border, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(language.flag, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Text(
                language.label,
                style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
