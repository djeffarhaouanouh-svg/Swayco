import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_settings.dart';
import '../services/app_strings.dart';
import '../services/auth_service.dart';
import '../services/block_api.dart';
import '../services/device_id.dart';
import '../services/ios_callkit.dart';
import '../services/languages.dart';
import '../services/notification_client.dart';
import '../services/profile_api.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../theme/swayco_theme.dart';
import '../widgets/location_picker_sheet.dart';
import '../widgets/wheel_picker_sheet.dart';
import '../widgets/mesh_background.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/swayco_dialog.dart';
import 'liked_photos_screen.dart';

/// Hosts every secondary account-level action that doesn't belong on the
/// main profile view: account management, notification toggles, privacy,
/// language & translation prefs, subscription, help/legal. Keeps the
/// Profile tab focused on identity (avatar / bio / stats).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Toggle preferences are stored in SharedPreferences. Keys are namespaced
  // so they don't collide with the existing UserPrefs keys.
  static const _kPush = AppSettings.kPush;
  static const _kHideOnline = AppSettings.kHideOnline;
  static const _kHideFromCountry = AppSettings.kHideFromCountry;

  bool _busy = false;
  bool _push = true;
  bool _emailNotifs = true;
  bool _hideOnline = false;
  bool _hideFromCountry = false;
  // My profile — used to render the translation-credits card (moved here
  // from the profile screen).
  RemoteProfile? _profile;

  // '' means "not chosen yet" — calls fall back to the interface language
  // (see UserPrefs.loadCallSpokenLang / resolveSpokenLanguage).
  String _callLang = '';
  String get _callLangLabel {
    if (_callLang.isEmpty) return AppStrings.t('settings_call_lang_default');
    return findLanguageByCode(_callLang)?.label ?? _callLang.toUpperCase();
  }

  String get _email => AuthService.currentEmail;
  // Real version + build, loaded from package_info_plus in initState.
  String _appVersion = '—';

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadVersion();
    UserPrefs.loadCallSpokenLang().then((saved) {
      if (mounted) setState(() => _callLang = saved.lang);
    });
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _appVersion = '${info.version} (${info.buildNumber})');
    } catch (_) {
      // Leave the placeholder if the platform channel is unavailable.
    }
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _push = p.getBool(_kPush) ?? true;
      // Local cache used for instant render — DB value below overrides.
      _hideOnline = p.getBool(_kHideOnline) ?? false;
      _hideFromCountry = p.getBool(_kHideFromCountry) ?? false;
    });
    // Pull the canonical hide_online_status from Supabase so what's on
    // screen matches what other clients see.
    if (isSupabaseReady) {
      try {
        final uid = await DeviceId.getOrCreate();
        final remote = await ProfileApi.fetchById(uid);
        if (!mounted || remote == null) return;
        setState(() {
          _profile = remote;
          _emailNotifs = remote.emailNotifications;
        });
        if (remote.hideOnlineStatus != _hideOnline) {
          setState(() => _hideOnline = remote.hideOnlineStatus);
          // Le notifier AUSSI, pas seulement le disque : c'est lui que les
          // écrans consultent pour peindre les pastilles. Sans ça, la
          // réconciliation ne prenait effet qu'au lancement suivant.
          await AppSettings.adoptAccountHideOnline(remote.hideOnlineStatus);
        }
      } catch (_) {}
    }
  }

  Future<void> _setHideOnline(bool value) async {
    setState(() => _hideOnline = value);
    await _saveBool(_kHideOnline, value);
    // Push the new value into the live in-memory notifier so every
    // screen rendering presence (chat list, chat thread, own profile)
    // hides peers' online dots immediately — the rule is reciprocal:
    // if I'm hiding from the network I don't see anyone else either.
    AppSettings.hideOnlineLocal.value = value;
    final uid = await DeviceId.getOrCreate();
    final ok = await ProfileApi.updateHideOnlineStatus(
      userId: uid,
      hide: value,
    );
    if (!ok && mounted) {
      // Roll back the optimistic UI if the DB write failed.
      setState(() => _hideOnline = !value);
      await _saveBool(_kHideOnline, !value);
      AppSettings.hideOnlineLocal.value = !value;
      _toast(AppStrings.t('settings_save_failed'));
    }
  }

  /// Toggle re-engagement emails. Source of truth is the remote profile column
  /// the backend reads, so this writes straight to Supabase (optimistic, with
  /// rollback on failure).
  Future<void> _setEmailNotifs(bool value) async {
    setState(() => _emailNotifs = value);
    final uid = await DeviceId.getOrCreate();
    final ok = await ProfileApi.updateEmailNotifications(
      userId: uid,
      enabled: value,
    );
    if (!ok && mounted) {
      setState(() => _emailNotifs = !value);
      _toast(AppStrings.t('settings_save_failed'));
    }
  }

  Future<void> _setHideFromCountry(bool value) async {
    setState(() => _hideFromCountry = value);
    await _saveBool(_kHideFromCountry, value);
    final uid = await DeviceId.getOrCreate();
    final ok = await ProfileApi.updateHideFromCountry(userId: uid, hide: value);
    if (!ok && mounted) {
      setState(() => _hideFromCountry = !value);
      await _saveBool(_kHideFromCountry, !value);
      _toast(AppStrings.t('settings_save_failed'));
    }
  }

  Future<void> _saveBool(String key, bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(key, value);
  }

  /// Register or drop the push transport target when the user flips the
  /// Push toggle. No-op on platforms where the notification client is a
  /// stub (web, or native before FCM is wired).
  Future<void> _applyPushPref(bool enabled) async {
    final uid = await DeviceId.getOrCreate();
    if (enabled) {
      await NotificationClient.register(uid);
    } else {
      await NotificationClient.unregister(uid);
    }
  }

  // ───── Actions ─────────────────────────────────────────────────────────

  /// Same rename rule as the inline editor on the Profile tab: once every
  /// [profileNameChangeCooldown] (the DB trigger from migration 0044 is the
  /// real guard — this is just the friendly front door that says how long
  /// is left instead of a generic failed save).
  Future<void> _editName() async {
    final uid = await DeviceId.getOrCreate();
    if (uid.isEmpty || !mounted) return;
    final current = _profile?.displayName ?? '';
    final changedAt = _profile?.nameChangedAt;
    if (changedAt != null) {
      final elapsed = DateTime.now().difference(changedAt);
      if (elapsed < profileNameChangeCooldown) {
        final remaining = profileNameChangeCooldown - elapsed;
        final daysLeft = (remaining.inDays + 1)
            .clamp(1, profileNameChangeCooldown.inDays);
        _toast(AppStrings.t('name_change_cooldown', args: {'days': '$daysLeft'}));
        return;
      }
    }
    final ctrl = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _TextPromptDialog(
        title: AppStrings.t('settings_first_name'),
        controller: ctrl,
        maxLength: profileNameMaxLength,
      ),
    );
    ctrl.dispose();
    if (result == null || !mounted) return;
    final trimmed = result.trim();
    if (trimmed.isEmpty || trimmed == current) return;
    setState(() => _busy = true);
    final saved = await ProfileApi.updateMyName(userId: uid, name: trimmed);
    if (!mounted) return;
    setState(() => _busy = false);
    if (saved == null) {
      _toast(AppStrings.t('save_failed'));
      return;
    }
    setState(() => _profile = _profile?.copyWith(
          displayName: saved,
          nameChangedAt: DateTime.now(),
        ));
  }

  Future<void> _editCity() async {
    final uid = await DeviceId.getOrCreate();
    if (uid.isEmpty || !mounted) return;
    final result = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => LocationPickerSheet(
        initialCountry: _profile?.country ?? '',
        initialCity: _profile?.city ?? '',
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    final ok = await ProfileApi.updateMyLocation(
      userId: uid,
      country: result.$1,
      city: result.$2,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      _toast(AppStrings.t('save_failed'));
      return;
    }
    setState(
      () => _profile = _profile?.copyWith(country: result.$1, city: result.$2),
    );
  }

  Future<void> _changePassword() async {
    if (_email.isEmpty) {
      _toast(AppStrings.t('settings_email_not_found'));
      return;
    }
    final ok = await _confirm(
      title: AppStrings.t('settings_change_password'),
      body: AppStrings.t('settings_change_pwd_body', args: {'email': _email}),
      confirmLabel: AppStrings.t('settings_change_pwd_confirm'),
      destructive: false,
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await AuthService.resetPassword(_email);
      if (!mounted) return;
      _toast(AppStrings.t('settings_email_sent'));
    } catch (e) {
      if (!mounted) return;
      _toast(AppStrings.t('error_prefix', args: {'msg': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    final ok = await _confirm(
      title: AppStrings.t('profile_signout_confirm_title'),
      body: AppStrings.t('profile_signout_confirm_body'),
      confirmLabel: AppStrings.t('profile_signout'),
      destructive: false,
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      // Push targets are per-DEVICE. Leaving them behind means this handset
      // keeps ringing for the account we're leaving — including for calls
      // placed from this very phone by the next account signed in here.
      final uid = await DeviceId.getOrCreate();
      await NotificationClient.unregister(uid);
      await IosCallKit.unregisterToken(uid);
      await AuthService.signOut();
    } catch (e) {
      if (!mounted) return;
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    final ok = await _confirm(
      title: AppStrings.t('settings_delete_title'),
      body: AppStrings.t('settings_delete_body'),
      confirmLabel: AppStrings.t('settings_delete_confirm'),
      destructive: true,
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final uid = await DeviceId.getOrCreate();
      // 1. Drop the user's push targets so the FCM token / web push
      //    subscription doesn't outlive the account.
      await NotificationClient.unregister(uid);
      await IosCallKit.unregisterToken(uid);
      // 2. Wipe the legacy local profile copy.
      await ProfileApi.deleteMyProfile(uid);
      // 3. Server-side wipe via the SECURITY DEFINER RPC: deletes the
      //    row in auth.users and cascades to every public.* table that
      //    references it. Required by App Store §5.1.1(v) +
      //    Play Store UGC rules — partial deletes (just the profile)
      //    aren't acceptable.
      if (isSupabaseReady) {
        await Supabase.instance.client.rpc('delete_my_account');
      }
      // 4. Sign out locally so the app reroutes to the login screen.
      await AuthService.signOut();
    } catch (e) {
      if (!mounted) return;
      _toast(AppStrings.t('error_prefix', args: {'msg': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Interface-language picker — la même roulette que la taille : une liste
  /// à format imposé, drapeau + nom dans la langue elle-même.
  Future<void> _openLanguagePicker() async {
    final current = AppStrings.currentBcp47.value;
    final langs = supportedLanguages;
    final start = langs.indexWhere((l) => l.code == current);
    final picked = await showWheelPicker(
      context: context,
      title: AppStrings.t('settings_lang_interface'),
      emoji: '🌍',
      labels: [for (final l in langs) '${l.flag}  ${l.label}'],
      initialIndex: start < 0 ? 0 : start,
    );
    if (picked == null) return;
    final code = langs[picked].code;
    if (code != current) await _setInterfaceLanguage(code);
  }

  /// Apply + persist the chosen UI language. The app's locale follows the
  /// profile's `language`, so we set it live, cache it locally and push it to
  /// Supabase so it sticks across cold boots.
  Future<void> _setInterfaceLanguage(String code) async {
    AppStrings.setFromCode(code);
    await UserPrefs.setSourceLang(code);
    final profile = _profile;
    if (profile != null &&
        profile.displayName.trim().isNotEmpty &&
        AuthService.isAuthenticated) {
      final uid = await DeviceId.getOrCreate();
      await ProfileApi.upsertMyProfile(
        deviceId: uid,
        displayName: profile.displayName,
        language: code,
        gender: profile.gender,
      );
    }
    if (!mounted) return;
    setState(() => _profile = _profile?.copyWith(language: code));
  }

  /// Distinct from the interface language: what you speak/get transcribed
  /// as ON A CALL (UserPrefs.keyCallSpokenLang). Local-only — someone can
  /// run calls in a language without rewriting their account. Previously
  /// only settable mid-call; this is the same UserPrefs field, just
  /// reachable before the first call too.
  Future<void> _openCallLanguagePicker() async {
    final saved = await UserPrefs.loadCallSpokenLang();
    if (!mounted) return;
    final current =
        saved.lang.isNotEmpty ? saved.lang : AppStrings.currentBcp47.value;
    final langs = supportedLanguages;
    final start = langs.indexWhere((l) => l.code == current);
    final picked = await showWheelPicker(
      context: context,
      title: AppStrings.t('settings_section_call_lang'),
      emoji: '🗣️',
      labels: [for (final l in langs) '${l.flag}  ${l.label}'],
      initialIndex: start < 0 ? 0 : start,
    );
    if (picked == null || !mounted) return;
    final code = langs[picked].code;
    await UserPrefs.saveCallSpokenLang(code, dontAsk: saved.dontAsk);
    if (mounted) setState(() => _callLang = code);
  }

  void _openBlockedUsers() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const _BlockedUsersScreen()),
    );
  }

  void _openLikedPhotos() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const LikedPhotosScreen()),
    );
  }

  void _openHelp() => _openExternal('https://www.swayco.fr/help');
  void _contactSupport() => _openExternal('mailto:support@swayco.fr');
  void _openTerms() => _openExternal('https://www.swayco.fr/terms');
  void _openPrivacy() => _openExternal('https://www.swayco.fr/privacy');

  /// Try to open [url] in the device browser (or mail client for
  /// `mailto:` URLs). Falls back to a toast if the device can't handle
  /// the URI — never crashes.
  Future<void> _openExternal(String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      _toast(url);
    }
  }

  // ───── Helpers ─────────────────────────────────────────────────────────

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
    required bool destructive,
  }) {
    return showSwaycoConfirm(
      context: context,
      title: title,
      body: body,
      confirmLabel: confirmLabel,
      destructive: destructive,
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: SC.menu,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ───── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SC.bg,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: SC.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text(AppStrings.t('settings_title'), style: SCText.h3),
      ),
      body: MeshBackground(
        child: SafeArea(
          child: AbsorbPointer(
            absorbing: _busy,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _SectionHeader(label: AppStrings.t('settings_section_lang')),
                _SettingsCard(
                  children: [
                    _SettingsRow(
                      icon: Icons.language,
                      label: AppStrings.t('settings_lang_interface'),
                      trailing: _SubtleText(
                        findLanguageByCode(AppStrings.currentBcp47.value)
                                ?.label ??
                            AppStrings.currentBcp47.value.toUpperCase(),
                      ),
                      onTap: _openLanguagePicker,
                    ),
                  ],
                ),

                _SectionHeader(
                  label: AppStrings.t('settings_section_call_lang'),
                ),
                _SettingsCard(
                  children: [
                    _SettingsRow(
                      icon: Icons.call_outlined,
                      label: AppStrings.t('call_language'),
                      trailing: _SubtleText(_callLangLabel),
                      onTap: _openCallLanguagePicker,
                    ),
                  ],
                ),

                _SectionHeader(label: AppStrings.t('settings_section_account')),
                _SettingsCard(
                  children: [
                    _SettingsRow(
                      icon: Icons.alternate_email,
                      label: AppStrings.t('settings_email'),
                      trailing: _SubtleText(_email.isEmpty ? '—' : _email),
                    ),
                    _SettingsRow(
                      icon: Icons.badge_outlined,
                      label: AppStrings.t('settings_first_name'),
                      trailing: _SubtleText(
                        _profile?.displayName.trim().isNotEmpty ?? false
                            ? _profile!.displayName.trim()
                            : '—',
                      ),
                      onTap: _editName,
                    ),
                    _SettingsRow(
                      icon: Icons.location_city_outlined,
                      label: AppStrings.t('settings_city'),
                      trailing: _SubtleText(
                        _profile?.city.trim().isNotEmpty ?? false
                            ? _profile!.city.trim()
                            : '—',
                      ),
                      onTap: _editCity,
                    ),
                    _SettingsRow(
                      icon: Icons.lock_reset,
                      label: AppStrings.t('settings_change_password'),
                      onTap: _changePassword,
                    ),
                  ],
                ),

                _SectionHeader(
                  label: AppStrings.t('settings_section_notifications'),
                ),
                _SettingsCard(
                  children: [
                    _SettingsToggleRow(
                      icon: Icons.notifications_active_outlined,
                      label: AppStrings.t('settings_push'),
                      value: _push,
                      onChanged: (v) {
                        setState(() => _push = v);
                        _saveBool(_kPush, v);
                        _applyPushPref(v);
                      },
                    ),
                    _SettingsToggleRow(
                      icon: Icons.alternate_email,
                      label: AppStrings.t('settings_email_notifs'),
                      value: _emailNotifs,
                      onChanged: _setEmailNotifs,
                    ),
                  ],
                ),

                _SectionHeader(label: AppStrings.t('settings_section_privacy')),
                _SettingsCard(
                  children: [
                    _SettingsRow(
                      icon: Icons.block,
                      label: AppStrings.t('settings_blocked'),
                      onTap: _openBlockedUsers,
                    ),
                    _SettingsRow(
                      icon: Icons.favorite_border,
                      label: AppStrings.t('settings_liked_photos'),
                      onTap: _openLikedPhotos,
                    ),
                    _SettingsToggleRow(
                      icon: Icons.visibility_off_outlined,
                      label: AppStrings.t('settings_hide_online'),
                      value: _hideOnline,
                      onChanged: _setHideOnline,
                    ),
                    _SettingsToggleRow(
                      icon: Icons.public_off_outlined,
                      label: AppStrings.t('settings_hide_from_country'),
                      value: _hideFromCountry,
                      onChanged: _setHideFromCountry,
                    ),
                  ],
                ),

                _SectionHeader(label: AppStrings.t('settings_section_help')),
                _SettingsCard(
                  children: [
                    _SettingsRow(
                      icon: Icons.help_outline,
                      label: AppStrings.t('settings_help_faq'),
                      onTap: _openHelp,
                    ),
                    _SettingsRow(
                      icon: Icons.mail_outline,
                      label: AppStrings.t('settings_contact'),
                      onTap: _contactSupport,
                    ),
                    _SettingsRow(
                      icon: Icons.gavel_outlined,
                      label: AppStrings.t('settings_terms'),
                      onTap: _openTerms,
                    ),
                    _SettingsRow(
                      icon: Icons.privacy_tip_outlined,
                      label: AppStrings.t('settings_privacy'),
                      onTap: _openPrivacy,
                    ),
                    _SettingsRow(
                      icon: Icons.info_outline,
                      label: AppStrings.t('settings_version'),
                      trailing: _SubtleText(_appVersion),
                    ),
                  ],
                ),

                // Destructive actions — kept at the very bottom.
                const SizedBox(height: 8),
                _SettingsCard(
                  children: [
                    _SettingsRow(
                      icon: Icons.logout,
                      label: AppStrings.t('profile_signout'),
                      color: const Color(0xFFE53935),
                      onTap: _signOut,
                    ),
                    _SettingsRow(
                      icon: Icons.delete_forever,
                      label: AppStrings.t('settings_delete_account'),
                      color: const Color(0xFFE53935),
                      onTap: _deleteAccount,
                    ),
                  ],
                ),

                if (_busy) ...[
                  const SizedBox(height: 20),
                  const Center(
                    child: CircularProgressIndicator(color: SC.accent),
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

// ───── Section header / cards / rows ────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 8),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: SC.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final divided = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      divided.add(children[i]);
      if (i != children.length - 1) {
        divided.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: 52,
            color: Colors.white.withValues(alpha: 0.06),
          ),
        );
      }
    }
    return Container(
      decoration: BoxDecoration(
        color: SC.glassStrong,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: SC.glassBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: divided),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.label,
    this.color,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color? color;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = color ?? SC.textPrimary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 22, color: fg),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (trailing != null) ...[trailing!, const SizedBox(width: 8)],
            if (onTap != null && trailing == null)
              const Icon(Icons.chevron_right, color: SC.textMuted, size: 22)
            else if (onTap != null)
              const Icon(Icons.chevron_right, color: SC.textMuted, size: 22),
          ],
        ),
      ),
    );
  }
}

class _SettingsToggleRow extends StatelessWidget {
  const _SettingsToggleRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 22, color: SC.textPrimary),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: SC.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: Colors.white,
              activeTrackColor: SC.accent,
            ),
          ],
        ),
      ),
    );
  }
}

class _SubtleText extends StatelessWidget {
  const _SubtleText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: SC.textMuted, fontSize: 13),
    );
  }
}

// ───── Blocked-users sub-screen ─────────────────────────────────────────

class _BlockedUsersScreen extends StatefulWidget {
  const _BlockedUsersScreen();

  @override
  State<_BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<_BlockedUsersScreen> {
  bool _loading = true;
  String _myId = '';
  List<RemoteProfile> _blocked = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final uid = await DeviceId.getOrCreate();
    final list = await BlockApi.fetchMyBlockedProfiles(uid);
    if (!mounted) return;
    setState(() {
      _myId = uid;
      _blocked = list;
      _loading = false;
    });
  }

  Future<void> _unblock(RemoteProfile p) async {
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t(
        'blocked_unblock_title_q',
        args: {'name': p.displayName},
      ),
      body: AppStrings.t('blocked_unblock_body'),
      confirmLabel: AppStrings.t('blocked_unblock_confirm'),
      destructive: false,
    );
    if (ok != true) return;
    try {
      await BlockApi.unblock(blockerId: _myId, blockedId: p.id);
      if (!mounted) return;
      setState(() => _blocked = _blocked.where((b) => b.id != p.id).toList());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.t('error_prefix', args: {'msg': '$e'})),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SC.bg,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: SC.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text(AppStrings.t('blocked_title'), style: SCText.h3),
      ),
      body: MeshBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: SC.accent))
            : _blocked.isEmpty
            ? const _BlockedEmptyState()
            : RefreshIndicator(
                color: SC.accent,
                backgroundColor: SC.menu,
                onRefresh: _load,
                child: ListView.separated(
                  // extendBodyBehindAppBar puts the body (and this list) at
                  // y=0, behind the status bar + transparent AppBar. Without
                  // this inset the first row renders under the clock and the
                  // "Débloquer" button lands in the status-bar/notch area —
                  // so the tap never reaches it.
                  padding: EdgeInsets.fromLTRB(
                    16,
                    MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
                    16,
                    24,
                  ),
                  itemCount: _blocked.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final p = _blocked[i];
                    return Container(
                      decoration: BoxDecoration(
                        color: SC.glassStrong,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: SC.glassBorder),
                      ),
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      child: Row(
                        children: [
                          ProfileAvatar(
                            displayName: p.displayName,
                            avatarUrl: p.avatarUrl,
                            size: 40,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  p.displayName.isEmpty ? '—' : p.displayName,
                                  style: const TextStyle(
                                    color: SC.textPrimary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (p.handle.isNotEmpty)
                                  Text(
                                    '@${p.handle}',
                                    style: const TextStyle(
                                      color: SC.textMuted,
                                      fontSize: 12,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: () => _unblock(p),
                            child: Text(
                              AppStrings.t('unblock'),
                              style: const TextStyle(color: SC.accent),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}

class _BlockedEmptyState extends StatelessWidget {
  const _BlockedEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.block, size: 56, color: SC.textMuted),
            const SizedBox(height: 14),
            Text(
              AppStrings.t('blocked_empty_title'),
              style: const TextStyle(
                color: SC.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              AppStrings.t('blocked_empty_body'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SC.textMuted,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Minimal single-line text prompt — used for the first-name edit in
/// Settings. There's no existing "ask for a short string" dialog to reuse
/// (swayco_dialog.dart only has confirm/cancel); this stays local rather
/// than growing that file for one field.
class _TextPromptDialog extends StatelessWidget {
  const _TextPromptDialog({
    required this.title,
    required this.controller,
    required this.maxLength,
  });

  final String title;
  final TextEditingController controller;
  final int maxLength;

  static const _fieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(14)),
    borderSide: BorderSide(color: SC.glassBorder),
  );

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: SC.bubbleIn,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: SC.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: maxLength,
              textCapitalization: TextCapitalization.words,
              cursorColor: SC.accent,
              style: const TextStyle(color: SC.textPrimary, fontSize: 15),
              decoration: InputDecoration(
                filled: true,
                fillColor: SC.bg,
                counterStyle: const TextStyle(color: SC.textMuted),
                border: _fieldBorder,
                enabledBorder: _fieldBorder,
                focusedBorder: _fieldBorder.copyWith(
                  borderSide: const BorderSide(color: SC.accent, width: 1.5),
                ),
              ),
              onSubmitted: (v) => Navigator.of(context).pop(v),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      AppStrings.t('cancel'),
                      style: const TextStyle(color: SC.textMuted),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: SC.accent),
                    onPressed: () =>
                        Navigator.of(context).pop(controller.text),
                    child: Text(AppStrings.t('save')),
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
