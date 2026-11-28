import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/auth_service.dart';
import '../services/friendly_error.dart';
import '../services/locations.dart';
import '../services/profile_api.dart';
import '../services/profile_views_api.dart';
import '../services/revenue_cat.dart';
import '../theme/swayco_theme.dart';
import '../widgets/load_failed_view.dart';
import '../widgets/popup_kit.dart' show popupDisplay;
import '../widgets/profile_info_card.dart' show countryNameForIso;
import '../widgets/profile_views_kit.dart';
import '../widgets/round_flag.dart';
import '../widgets/swayco_dialog.dart';
import 'chat_thread_screen.dart';
import 'paywall_screen.dart';
import 'profile_screen.dart';

/// « Vues du profil » : le total sur 7 ou 30 jours et la liste des visiteurs.
/// Gratuit : pays, ville et heure visibles, la personne est floutée. Pro : tout
/// est révélé.
class ProfileViewsScreen extends StatefulWidget {
  const ProfileViewsScreen({super.key});

  @override
  State<ProfileViewsScreen> createState() => _ProfileViewsScreenState();
}

class _ProfileViewsScreenState extends State<ProfileViewsScreen> {
  ProfileViewsData? _data;
  DateTime? _seenBefore;
  bool _failed = false;
  int _days = 7;

  /// Essai gratuit que la boutique accorde à CETTE personne, sinon `null`.
  int? _trialDays;

  @override
  void initState() {
    super.initState();
    _load();
    if (RevenueCat.isSupported) {
      RevenueCat.trialDaysOf(RevenueCat.proPackageId).then((d) {
        if (mounted) setState(() => _trialDays = d);
      });
    }
  }

  Future<void> _load() async {
    try {
      final seen = await ProfileViewsApi.lastSeen();
      final data = await ProfileViewsApi.load();
      await ProfileViewsApi.markSeen();
      if (!mounted) return;
      setState(() {
        _seenBefore ??= seen;
        _data = data;
        _failed = false;
      });
    } catch (e) {
      debugPrint('profile views load failed: $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  void _unlock() => showPaywallSheet(context, source: 'profile_views');

  void _openProfile(RemoteProfile p) => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => ProfileScreen(userId: p.id)),
      );

  void _openChat(RemoteProfile p) {
    final me = AuthService.currentUserId;
    if (me.isEmpty) return;
    final ids = [me, p.id]..sort();
    final name = p.displayName.trim();
    Navigator.of(context).push<void>(
      chatThreadRoute(
        builder: (_) => ChatThreadScreen(
          conversationId: 'dm-${ids[0]}-${ids[1]}',
          title: name.isEmpty ? AppStrings.t('profile_anonymous') : name,
          peerDeviceId: p.id,
        ),
      ),
    );
  }

  Future<void> _openSettings() async {
    final data = _data;
    if (data == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SettingsSheet(initial: data.settings),
    );
    if (mounted) await _load();
  }

  Color get _bg => SC.light ? const Color(0xFFF3F4F8) : SC.bg;

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final Widget body;
    if (_failed && data == null) {
      body = LoadFailedView(onRetry: _load);
    } else if (data == null) {
      body = Center(child: CircularProgressIndicator(color: SC.accentFg));
    } else if (!data.settings.history) {
      body = _off();
    } else {
      body = ValueListenableBuilder<bool>(
        valueListenable: RevenueCat.proActive,
        builder: (_, pro, _) => _content(data, pro),
      );
    }
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              children: [
                _header(),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Row(
        children: [
          _RoundIcon(
            icon: Icons.arrow_back_rounded,
            label: MaterialLocalizations.of(context).backButtonTooltip,
            onTap: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Text(
              AppStrings.t('profile_views_title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: popupDisplay(
                fontSize: 17,
                letterSpacing: -0.5,
                color: SC.textPrimary,
              ),
            ),
          ),
          _data == null
              ? const SizedBox(width: 40, height: 40)
              : _RoundIcon(
                  icon: Icons.tune_rounded,
                  label: AppStrings.t('profile_views_settings'),
                  onTap: _openSettings,
                ),
        ],
      ),
    );
  }

  /// Historique coupé : rien à lister, et la porte pour le rallumer.
  Widget _off() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility_off_outlined, size: 56, color: SC.textMuted),
            const SizedBox(height: 14),
            Text(
              AppStrings.t('profile_views_off'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: SC.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppStrings.t('profile_views_history_sub'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: SC.textPrimary.withValues(alpha: 0.7),
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 20),
            _YellowButton(
              icon: Icons.tune_rounded,
              label: AppStrings.t('profile_views_settings'),
              onTap: _openSettings,
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(ProfileViewsData data, bool pro) {
    final now = DateTime.now();
    final people = data.visitors(_days, now);
    final locked = !pro && people.isNotEmpty;
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    String groupOf(DateTime at) => !at.isBefore(today)
        ? 'profile_views_today'
        : (!at.isBefore(yesterday)
            ? 'profile_views_yesterday'
            : 'profile_views_earlier');

    final rows = <Widget>[];
    String? group;
    for (final v in people) {
      final g = groupOf(v.at);
      if (g != group) {
        group = g;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
          child: _Overline(AppStrings.t(g)),
        ));
      }
      rows.add(_VisitorRow(
        view: v,
        now: now,
        pro: pro,
        fresh: _seenBefore != null && v.at.isAfter(_seenBefore!),
        onTap: pro ? () => _openProfile(v.profile) : _unlock,
        onChat: () => _openChat(v.profile),
      ));
    }

    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return Stack(
      children: [
        RefreshIndicator(
          color: SC.accentFg,
          backgroundColor: SC.menu,
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              bottom: safeBottom + (locked ? 170 : 24),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                child: _PeriodTabs(
                  days: _days,
                  onChanged: (d) => setState(() => _days = d),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
                child: _StatsCard(
                  count: data.count(_days, now),
                  delta: data.deltaPercent(_days, now),
                  deltaKey: _days == 7
                      ? 'profile_views_delta_week'
                      : 'profile_views_delta_month',
                  bars: data.lastWeek(now),
                ),
              ),
              if (people.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 40, 28, 0),
                  child: Text(
                    AppStrings.t('profile_views_empty'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: SC.textPrimary.withValues(alpha: 0.7),
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ...rows,
            ],
          ),
        ),
        if (locked)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(18, 70, 18, safeBottom + 20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [_bg.withValues(alpha: 0), _bg],
                  stops: const [0, 0.55],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _YellowButton(
                    icon: Icons.workspace_premium_rounded,
                    label: AppStrings.t('profile_views_unlock'),
                    onTap: _unlock,
                    wide: true,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _trialDays == null
                        ? AppStrings.t('profile_views_pro')
                        : AppStrings.t('profile_views_pro_trial',
                            args: {'days': '$_trialDays'}),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: SC.textPrimary.withValues(alpha: 0.65),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: light ? Colors.white : const Color(0x1FFFFFFF),
            border: Border.all(
              color: light ? const Color(0x1F04123A) : const Color(0x2EFFFFFF),
              width: 1.2,
            ),
          ),
          child: Icon(icon, size: 22, color: SC.textPrimary),
        ),
      ),
    );
  }
}

class _Overline extends StatelessWidget {
  const _Overline(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: TextStyle(
          color: SC.textPrimary.withValues(alpha: 0.7),
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.4,
        ),
      );
}

/// « 7 jours / 30 jours », la même capsule que « Écrit / Vocal ».
class _PeriodTabs extends StatelessWidget {
  const _PeriodTabs({required this.days, required this.onChanged});

  final int days;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    Widget tab(int value, String key) {
      final selected = days == value;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? kViewsYellow : Colors.transparent,
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              AppStrings.t(key),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected
                    ? kViewsInk
                    : SC.textPrimary.withValues(alpha: 0.7),
                fontSize: 13,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: light ? Colors.white : const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(
          color: light ? const Color(0x1A04123A) : const Color(0x24FFFFFF),
        ),
      ),
      child: Row(
        children: [
          tab(7, 'profile_views_7d'),
          const SizedBox(width: 4),
          tab(30, 'profile_views_30d'),
        ],
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({
    required this.count,
    required this.delta,
    required this.deltaKey,
    required this.bars,
  });

  final int count;
  final int? delta;
  final String deltaKey;
  final List<int> bars;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    final peak = bars.fold<int>(0, (m, v) => v > m ? v : m);
    final d = delta;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: viewsCardDecoration(),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '$count',
                    style: popupDisplay(
                      fontSize: 44,
                      letterSpacing: -2,
                      height: 1,
                      color: SC.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                _Overline(AppStrings.t('profile_views_count_label')),
                if (d != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    AppStrings.t(deltaKey,
                        args: {'pct': '${d > 0 ? '+' : ''}$d'}),
                    style: TextStyle(
                      color: d < 0
                          ? const Color(0xFFFF6B6B)
                          : (light ? SC.accentFg : const Color(0xFF18DDEA)),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 6,
            child: SizedBox(
              height: 64,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final (i, v) in bars.indexed) ...[
                    if (i > 0) const SizedBox(width: 6),
                    Expanded(
                      child: Container(
                        // Un jour sans visite garde un trait.
                        height: peak == 0 ? 4 : 4 + 60 * v / peak,
                        decoration: BoxDecoration(
                          color: i == bars.length - 1
                              ? (light ? SC.accentFg : kViewsYellow)
                              : SC.textPrimary
                                  .withValues(alpha: light ? 0.16 : 0.28),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VisitorRow extends StatelessWidget {
  const _VisitorRow({
    required this.view,
    required this.now,
    required this.pro,
    required this.fresh,
    required this.onTap,
    required this.onChat,
  });

  final ProfileView view;
  final DateTime now;
  final bool pro;
  final bool fresh;
  final VoidCallback onTap;
  final VoidCallback onChat;

  String _ago() {
    final d = now.difference(view.at);
    if (d.inMinutes < 1) return AppStrings.t('profile_views_ago_now');
    if (d.inHours < 1) {
      return AppStrings.t('profile_views_ago_min',
          args: {'n': '${d.inMinutes}'});
    }
    if (d.inDays < 1) {
      return AppStrings.t('profile_views_ago_h', args: {'n': '${d.inHours}'});
    }
    return AppStrings.t('profile_views_ago_d', args: {'n': '${d.inDays}'});
  }

  @override
  Widget build(BuildContext context) {
    final p = view.profile;
    final country = p.country.trim();
    final city = p.city.trim();
    final iso = countryIso2For(country);
    final place = city.isNotEmpty
        ? city
        : (iso.isEmpty ? country : countryNameForIso(iso));
    final name = p.displayName.trim().isEmpty ? '—' : p.displayName.trim();
    final label = p.age != null ? '$name, ${p.age}' : name;
    final sub = [
      if (pro) ...[place, _ago()] else ...[_ago(), place],
    ].where((s) => s.isNotEmpty).join(' · ');
    final nameStyle = TextStyle(
      color: SC.textPrimary,
      fontSize: 15,
      fontWeight: FontWeight.w800,
    );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 50,
              height: 50,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  VisitorFace(profile: p, size: 50, blurred: !pro),
                  if (country.isNotEmpty)
                    Positioned(
                      right: -4,
                      bottom: -3,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: SC.light ? const Color(0xFFF3F4F8) : SC.bg,
                        ),
                        child: RoundFlag(
                          country: country,
                          language: p.language,
                          size: 18,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (pro)
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: nameStyle,
                          ),
                        ),
                        if (fresh) ...[
                          const SizedBox(width: 7),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: SC.light ? SC.accentFg : kViewsYellow,
                            ),
                          ),
                        ],
                      ],
                    )
                  else
                    // Un faux nom flouté : le vrai n'est jamais dessiné.
                    ExcludeSemantics(
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(
                          sigmaX: 5,
                          sigmaY: 5,
                          tileMode: TileMode.decal,
                        ),
                        child: Text('Swayco, 00', style: nameStyle),
                      ),
                    ),
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: SC.textPrimary.withValues(alpha: 0.7),
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (pro)
              Semantics(
                button: true,
                label: AppStrings.t('profile_views_chat'),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onChat,
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color:
                          SC.light ? Colors.white : const Color(0x1FFFFFFF),
                      border: Border.all(
                        color: SC.light
                            ? const Color(0x1F04123A)
                            : const Color(0x38FFFFFF),
                      ),
                    ),
                    child: Icon(Icons.chat_bubble_rounded,
                        size: 19, color: SC.textPrimary),
                  ),
                ),
              )
            else
              Icon(Icons.lock_rounded,
                  size: 20,
                  color: SC.textPrimary.withValues(alpha: 0.55)),
          ],
        ),
      ),
    );
  }
}

class _YellowButton extends StatelessWidget {
  const _YellowButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.wide = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 54,
        width: wide ? double.infinity : null,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: kViewsYellow,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Row(
          mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: kViewsInk),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: popupDisplay(fontSize: 14, color: kViewsInk),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// « Réglages des vues » : les deux interrupteurs et l'effacement.
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.initial});

  final ProfileViewSettings initial;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late ProfileViewSettings _s = widget.initial;
  bool _busy = false;
  String? _error;

  Future<void> _save(ProfileViewSettings next) async {
    if (_busy) return;
    final before = _s;
    setState(() {
      _s = next;
      _busy = true;
      _error = null;
    });
    try {
      await ProfileViewsApi.saveSettings(next);
    } catch (e) {
      debugPrint('profile view settings save: $e');
      if (mounted) {
        setState(() {
          _s = before;
          _error = friendlyError(e);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    if (_busy) return;
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('profile_views_clear'),
      body: AppStrings.t('profile_views_clear_confirm'),
      confirmLabel: AppStrings.t('profile_views_clear'),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ProfileViewsApi.clear();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      debugPrint('profile views clear: $e');
      if (mounted) {
        setState(() {
          _busy = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    return Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: light ? Colors.white : const Color(0xFF1A1B22),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(32)),
            border: Border(
              top: BorderSide(
                color:
                    light ? const Color(0x1404123A) : const Color(0x24FFFFFF),
              ),
            ),
          ),
          padding: EdgeInsets.fromLTRB(
              22, 12, 22, MediaQuery.paddingOf(context).bottom + 22),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 5,
                    decoration: BoxDecoration(
                      color: SC.textPrimary.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  AppStrings.t('profile_views_settings'),
                  style: popupDisplay(
                    fontSize: 20,
                    letterSpacing: -0.6,
                    color: SC.textPrimary,
                  ),
                ),
                const SizedBox(height: 16),
                _SettingRow(
                  title: AppStrings.t('profile_views_history'),
                  subtitle: AppStrings.t('profile_views_history_sub'),
                  value: _s.history,
                  onChanged: (v) =>
                      _save((history: v, notify: _s.notify)),
                ),
                const SizedBox(height: 12),
                _SettingRow(
                  title: AppStrings.t('profile_views_notify'),
                  subtitle: AppStrings.t('profile_views_notify_sub'),
                  value: _s.notify && _s.history,
                  // Sans historique, il n'y a rien à annoncer.
                  onChanged: _s.history
                      ? (v) => _save((history: _s.history, notify: v))
                      : null,
                ),
                const SizedBox(height: 10),
                InkWell(
                  onTap: _clear,
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.delete_outline_rounded,
                            size: 22, color: Color(0xFFFF6B6B)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            AppStrings.t('profile_views_clear'),
                            style: const TextStyle(
                              color: Color(0xFFFF6B6B),
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_error != null)
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Color(0xFFFF6B6B), fontSize: 12.5),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: light ? const Color(0xFFF3F4F8) : const Color(0x12FFFFFF),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: light ? const Color(0x1404123A) : const Color(0x1FFFFFFF),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: SC.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: SC.textPrimary.withValues(alpha: 0.7),
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: light ? Colors.white : kViewsInk,
            activeTrackColor: light ? SC.brandBlueDeep : kViewsYellow,
          ),
        ],
      ),
    );
  }
}
