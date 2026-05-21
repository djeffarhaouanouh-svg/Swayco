import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_settings.dart';
import '../services/app_strings.dart';
import '../services/auth_service.dart';
import '../services/block_api.dart';
import '../services/call_alert.dart';
import '../services/device_id.dart';
import '../services/notification_client.dart';
import '../services/profile_api.dart';
import '../services/stripe_api.dart';
import '../services/supabase_service.dart';
import '../theme/whatsapp_call_theme.dart';
import '../widgets/profile_avatar.dart';
import 'onboarding_screen.dart';

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
  static const _kSounds = AppSettings.kSounds;
  static const _kInAppSounds = AppSettings.kInAppSounds;
  static const _kHideOnline = AppSettings.kHideOnline;
  static const _kAutoTranslate = AppSettings.kAutoTranslate;
  static const _kAudioOutput = AppSettings.kAudioOutput;

  bool _busy = false;
  bool _push = true;
  bool _sounds = true;
  bool _inAppSounds = true;
  bool _hideOnline = false;
  bool _autoTranslate = false;
  String _audioOutput = 'speaker';

  String get _email => AuthService.currentEmail;
  // Real version + build, loaded from package_info_plus in initState.
  String _appVersion = '—';

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadVersion();
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
      _sounds = p.getBool(_kSounds) ?? true;
      _inAppSounds = p.getBool(_kInAppSounds) ?? true;
      // Local cache used for instant render — DB value below overrides.
      _hideOnline = p.getBool(_kHideOnline) ?? false;
      _autoTranslate = p.getBool(_kAutoTranslate) ?? false;
      _audioOutput = p.getString(_kAudioOutput) ?? 'speaker';
    });
    // Pull the canonical hide_online_status from Supabase so what's on
    // screen matches what other clients see.
    if (isSupabaseReady) {
      try {
        final uid = await DeviceId.getOrCreate();
        final remote = await ProfileApi.fetchById(uid);
        if (!mounted || remote == null) return;
        if (remote.hideOnlineStatus != _hideOnline) {
          setState(() => _hideOnline = remote.hideOnlineStatus);
          await _saveBool(_kHideOnline, remote.hideOnlineStatus);
        }
      } catch (_) {}
    }
  }

  Future<void> _setHideOnline(bool value) async {
    setState(() => _hideOnline = value);
    await _saveBool(_kHideOnline, value);
    final uid = await DeviceId.getOrCreate();
    final ok = await ProfileApi.updateHideOnlineStatus(
      userId: uid, hide: value,
    );
    if (!ok && mounted) {
      // Roll back the optimistic UI if the DB write failed.
      setState(() => _hideOnline = !value);
      await _saveBool(_kHideOnline, !value);
      _toast(AppStrings.t('settings_save_failed'));
    }
  }

  Future<void> _saveBool(String key, bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(key, value);
  }

  Future<void> _saveString(String key, String value) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, value);
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

  Future<void> _openLanguageEditor() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (ctx) => OnboardingScreen(
          editing: true,
          onCompleted: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
  }

  Future<void> _pickAudioOutput() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: WhatsAppCallTheme.bar,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  AppStrings.t('settings_audio_output'),
                  style: const TextStyle(
                    color: WhatsAppCallTheme.strongText,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            _AudioOutputOption(
              label: AppStrings.t('settings_audio_speaker'),
              icon: Icons.volume_up,
              value: 'speaker',
              selected: _audioOutput == 'speaker',
              onTap: () => Navigator.of(ctx).pop('speaker'),
            ),
            _AudioOutputOption(
              label: AppStrings.t('settings_audio_earpiece'),
              icon: Icons.hearing,
              value: 'earpiece',
              selected: _audioOutput == 'earpiece',
              onTap: () => Navigator.of(ctx).pop('earpiece'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (picked != null && picked != _audioOutput) {
      setState(() => _audioOutput = picked);
      await _saveString(_kAudioOutput, picked);
    }
  }

  void _openBlockedUsers() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const _BlockedUsersScreen()),
    );
  }

  /// Web: open the Stripe customer portal (cancel / change card / swap
  /// tier). Native: deep-link to the platform's subscription page — the
  /// stores require IAP subscriptions to be managed there.
  Future<void> _manageSubscription() async {
    if (kIsWeb) {
      setState(() => _busy = true);
      final url = await StripeApi.openPortal();
      if (!mounted) return;
      setState(() => _busy = false);
      if (url != null && url.isNotEmpty) {
        await _openExternal(url);
      } else {
        _toast(AppStrings.t('settings_subscription_appstore'));
      }
      return;
    }
    final storeUrl = defaultTargetPlatform == TargetPlatform.iOS
        ? 'https://apps.apple.com/account/subscriptions'
        : 'https://play.google.com/store/account/subscriptions';
    await _openExternal(storeUrl);
  }
  void _restorePurchases() => _toast(AppStrings.t('settings_restore_soon'));
  void _openHelp() => _openExternal('https://swayco.fr/help');
  void _contactSupport() => _openExternal('mailto:support@swayco.fr');
  void _openTerms() => _openExternal('https://swayco.fr/terms');
  void _openPrivacy() => _openExternal('https://swayco.fr/privacy');

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
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WhatsAppCallTheme.bar,
        title: Text(title,
            style: const TextStyle(color: WhatsAppCallTheme.strongText)),
        content: Text(body,
            style: const TextStyle(color: WhatsAppCallTheme.subtleText)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppStrings.t('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: destructive
                  ? const Color(0xFFE53935)
                  : WhatsAppCallTheme.accent,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: WhatsAppCallTheme.bar,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ───── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WhatsAppCallTheme.scaffold,
      appBar: AppBar(
        backgroundColor: WhatsAppCallTheme.scaffold,
        foregroundColor: WhatsAppCallTheme.strongText,
        elevation: 0,
        title: Text(
          AppStrings.t('settings_title'),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: _busy,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _SectionHeader(label: AppStrings.t('settings_section_account')),
              _SettingsCard(children: [
                _SettingsRow(
                  icon: Icons.alternate_email,
                  label: AppStrings.t('settings_email'),
                  trailing: _SubtleText(_email.isEmpty ? '—' : _email),
                ),
                _SettingsRow(
                  icon: Icons.lock_reset,
                  label: AppStrings.t('settings_change_password'),
                  onTap: _changePassword,
                ),
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
              ]),

              _SectionHeader(
                  label: AppStrings.t('settings_section_notifications')),
              _SettingsCard(children: [
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
                  icon: Icons.volume_up_outlined,
                  label: AppStrings.t('settings_sounds'),
                  value: _sounds,
                  onChanged: (v) {
                    setState(() => _sounds = v);
                    _saveBool(_kSounds, v);
                  },
                ),
                _SettingsToggleRow(
                  icon: Icons.music_note_outlined,
                  label: AppStrings.t('settings_in_app_sounds'),
                  value: _inAppSounds,
                  onChanged: (v) {
                    setState(() => _inAppSounds = v);
                    _saveBool(_kInAppSounds, v);
                    CallAlert.soundsEnabled = v;
                  },
                ),
              ]),

              _SectionHeader(label: AppStrings.t('settings_section_privacy')),
              _SettingsCard(children: [
                _SettingsRow(
                  icon: Icons.block,
                  label: AppStrings.t('settings_blocked'),
                  onTap: _openBlockedUsers,
                ),
                _SettingsToggleRow(
                  icon: Icons.visibility_off_outlined,
                  label: AppStrings.t('settings_hide_online'),
                  value: _hideOnline,
                  onChanged: _setHideOnline,
                ),
              ]),

              _SectionHeader(label: AppStrings.t('settings_section_lang')),
              _SettingsCard(children: [
                _SettingsRow(
                  icon: Icons.language,
                  label: AppStrings.t('settings_lang_interface'),
                  onTap: _openLanguageEditor,
                ),
                _SettingsToggleRow(
                  icon: Icons.translate,
                  label: AppStrings.t('settings_auto_translate'),
                  value: _autoTranslate,
                  onChanged: (v) {
                    setState(() => _autoTranslate = v);
                    _saveBool(_kAutoTranslate, v);
                  },
                ),
                _SettingsRow(
                  icon: Icons.speaker_outlined,
                  label: AppStrings.t('settings_audio_output'),
                  trailing: _SubtleText(
                    _audioOutput == 'speaker'
                        ? AppStrings.t('settings_audio_speaker')
                        : AppStrings.t('settings_audio_earpiece'),
                  ),
                  onTap: _pickAudioOutput,
                ),
              ]),

              _SectionHeader(
                  label: AppStrings.t('settings_section_subscription')),
              _SettingsCard(children: [
                _SettingsRow(
                  icon: Icons.workspace_premium_outlined,
                  label: AppStrings.t('settings_manage_sub'),
                  onTap: _manageSubscription,
                ),
                _SettingsRow(
                  icon: Icons.restart_alt,
                  label: AppStrings.t('settings_restore_purchase'),
                  onTap: _restorePurchases,
                ),
              ]),

              _SectionHeader(label: AppStrings.t('settings_section_help')),
              _SettingsCard(children: [
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
              ]),

              if (_busy) ...[
                const SizedBox(height: 20),
                const Center(
                  child: CircularProgressIndicator(
                      color: WhatsAppCallTheme.accent),
                ),
              ],
            ],
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
          color: WhatsAppCallTheme.subtleText,
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
        divided.add(Divider(
          height: 1,
          thickness: 1,
          indent: 52,
          color: Colors.white.withValues(alpha: 0.06),
        ));
      }
    }
    return Container(
      decoration: BoxDecoration(
        color: WhatsAppCallTheme.bar,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A3942)),
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
    final fg = color ?? WhatsAppCallTheme.strongText;
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
            if (trailing != null) ...[
              trailing!,
              const SizedBox(width: 8),
            ],
            if (onTap != null && trailing == null)
              const Icon(Icons.chevron_right,
                  color: WhatsAppCallTheme.subtleText, size: 22)
            else if (onTap != null)
              const Icon(Icons.chevron_right,
                  color: WhatsAppCallTheme.subtleText, size: 22),
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
            Icon(icon, size: 22, color: WhatsAppCallTheme.strongText),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: WhatsAppCallTheme.strongText,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: Colors.white,
              activeTrackColor: WhatsAppCallTheme.accent,
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
      style: const TextStyle(
        color: WhatsAppCallTheme.subtleText,
        fontSize: 13,
      ),
    );
  }
}

class _AudioOutputOption extends StatelessWidget {
  const _AudioOutputOption({
    required this.label,
    required this.icon,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final String value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: WhatsAppCallTheme.strongText),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: WhatsAppCallTheme.strongText,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (selected)
              const Icon(Icons.check, color: WhatsAppCallTheme.accent),
          ],
        ),
      ),
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WhatsAppCallTheme.bar,
        title: Text(
          AppStrings.t('blocked_unblock_title_q',
              args: {'name': p.displayName}),
          style: const TextStyle(color: WhatsAppCallTheme.strongText),
        ),
        content: Text(
          AppStrings.t('blocked_unblock_body'),
          style: const TextStyle(color: WhatsAppCallTheme.subtleText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppStrings.t('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: WhatsAppCallTheme.accent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppStrings.t('blocked_unblock_confirm')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await BlockApi.unblock(blockerId: _myId, blockedId: p.id);
      if (!mounted) return;
      setState(() => _blocked = _blocked.where((b) => b.id != p.id).toList());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppStrings.t('error_prefix', args: {'msg': '$e'})),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WhatsAppCallTheme.scaffold,
      appBar: AppBar(
        backgroundColor: WhatsAppCallTheme.scaffold,
        foregroundColor: WhatsAppCallTheme.strongText,
        elevation: 0,
        title: Text(
          AppStrings.t('blocked_title'),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                  color: WhatsAppCallTheme.accent),
            )
          : _blocked.isEmpty
              ? const _BlockedEmptyState()
              : RefreshIndicator(
                  color: WhatsAppCallTheme.accent,
                  backgroundColor: WhatsAppCallTheme.bar,
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: _blocked.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final p = _blocked[i];
                      return Container(
                        decoration: BoxDecoration(
                          color: WhatsAppCallTheme.bar,
                          borderRadius: BorderRadius.circular(14),
                          border:
                              Border.all(color: const Color(0xFF2A3942)),
                        ),
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        child: Row(
                          children: [
                            ProfileAvatar(
                              displayName: p.displayName,
                              avatarUrl: p.avatarUrl,
                              avatarColorHex: p.avatarColor,
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
                                      color: WhatsAppCallTheme.strongText,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (p.handle.isNotEmpty)
                                    Text(
                                      '@${p.handle}',
                                      style: const TextStyle(
                                        color: WhatsAppCallTheme.subtleText,
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
                                style: const TextStyle(
                                    color: WhatsAppCallTheme.accent),
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
            const Icon(Icons.block,
                size: 56, color: WhatsAppCallTheme.subtleText),
            const SizedBox(height: 14),
            Text(
              AppStrings.t('blocked_empty_title'),
              style: const TextStyle(
                color: WhatsAppCallTheme.strongText,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              AppStrings.t('blocked_empty_body'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: WhatsAppCallTheme.subtleText,
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
