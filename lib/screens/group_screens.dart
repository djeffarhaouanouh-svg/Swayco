import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../services/analytics.dart';
import '../services/app_strings.dart';
import '../services/friendly_error.dart';
import '../services/friendship_api.dart';
import '../services/group_api.dart';
import '../services/locations.dart';
import '../services/profile_api.dart';
import '../theme/swayco_theme.dart';
import '../widgets/group_avatar.dart';
import '../widgets/popup_kit.dart';
import '../widgets/swayco_dialog.dart';
import 'chat_thread_screen.dart';
import 'profile_screen.dart';

// Les groupes de discussion (handoff messages_groupes_quiz, partie A) :
// nouveau groupe (1b), conversation (1c), infos (2a), retirer un membre
// (2b / 2c). Les couleurs et les formes suivent le handoff ; la police reste
// celle de l'app.

const Color _kYellow = Color(0xFFF4FF1F);
const Color _kNavy = Color(0xFF04123A);
const Color _kRed = Color(0xFFD93036);

String _first(RemoteProfile p) {
  final n = p.displayName.trim();
  if (n.isNotEmpty) return n.split(RegExp(r'\s+')).first;
  return p.handle.isNotEmpty ? '@${p.handle}' : AppStrings.t('chat_no_name');
}

String _flagOf(RemoteProfile? p) =>
    p == null ? '' : (countryFlagFor(p.country) ?? '');

/// « 🇧🇷 🇪🇸 🇯🇵 » : les drapeaux des pays présents dans le groupe.
String _flagsLine(Iterable<RemoteProfile> members) {
  final seen = <String>[];
  for (final p in members) {
    final f = countryFlagFor(p.country);
    if (f != null && !seen.contains(f)) seen.add(f);
    if (seen.length >= 5) break;
  }
  return seen.join(' ');
}



// ─────────────────────────────────────────────────────────────────────────────
// Nouveau groupe (1b)
// ─────────────────────────────────────────────────────────────────────────────

/// Le tiroir « Nouveau groupe ». Rend l'id du groupe créé, ou null.
Future<String?> showNewGroupSheet(
  BuildContext context, {
  required List<RemoteProfile> friends,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PickMembersSheet(friends: friends),
  );
}

/// « Ajouter » depuis les infos du groupe : le même sélecteur, sans nom.
/// Rend les ids choisis.
Future<List<String>?> showAddMembersSheet(
  BuildContext context, {
  required List<RemoteProfile> candidates,
}) {
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PickMembersSheet(friends: candidates, addOnly: true),
  );
}

class _PickMembersSheet extends StatefulWidget {
  const _PickMembersSheet({required this.friends, this.addOnly = false});

  final List<RemoteProfile> friends;
  final bool addOnly;

  @override
  State<_PickMembersSheet> createState() => _PickMembersSheetState();
}

class _PickMembersSheetState extends State<_PickMembersSheet> {
  final _name = TextEditingController();
  final Set<String> _picked = {};
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _ready =>
      _picked.isNotEmpty && (widget.addOnly || _name.text.trim().isNotEmpty);

  Future<void> _submit() async {
    if (!_ready || _busy) return;
    if (widget.addOnly) {
      Navigator.of(context).pop(_picked.toList());
      return;
    }
    setState(() => _busy = true);
    try {
      final id = await GroupApi.create(
        name: _name.text.trim(),
        memberIds: _picked.toList(),
      );
      Analytics.track('group_created', props: {'members': _picked.length + 1});
      if (mounted) Navigator.of(context).pop(id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    final bg = light ? const Color(0xFFF3F4F8) : const Color(0xFF1F1F24);
    final ink = light ? _kNavy : Colors.white;
    final mq = MediaQuery.of(context);
    final picked = [
      for (final p in widget.friends)
        if (_picked.contains(p.id)) p,
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Container(
        height: mq.size.height * 0.86,
        padding: EdgeInsets.fromLTRB(18, 10, 18, 14 + mq.padding.bottom),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: ink.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              AppStrings.t(
                widget.addOnly ? 'group_add_title' : 'group_new_title',
              ),
              style: popupDisplay(fontSize: 22, color: ink),
            ),
            const SizedBox(height: 14),
            if (!widget.addOnly)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: ink.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: ink.withValues(alpha: 0.12)),
                ),
                child: TextField(
                  controller: _name,
                  maxLength: 60,
                  onChanged: (_) => setState(() {}),
                  textCapitalization: TextCapitalization.sentences,
                  cursorColor: ink,
                  style: TextStyle(color: ink, fontSize: 16),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: AppStrings.t('group_name_hint'),
                    hintStyle: TextStyle(color: ink.withValues(alpha: 0.5)),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            if (picked.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                AppStrings.t(
                  'group_selected',
                  args: {'n': '${picked.length}'},
                ).toUpperCase(),
                style: GoogleFonts.ibmPlexMono(
                  color: ink.withValues(alpha: 0.6),
                  fontSize: 11,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final p in picked)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GestureDetector(
                          onTap: () => setState(() => _picked.remove(p.id)),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: _kYellow,
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Row(
                              children: [
                                Text(
                                  _first(p),
                                  style: const TextStyle(
                                    color: _kNavy,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                const Icon(Icons.close_rounded,
                                    size: 14, color: _kNavy),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: widget.friends.isEmpty
                  ? Center(
                      child: Text(
                        AppStrings.t('group_no_contacts'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: ink.withValues(alpha: 0.6)),
                      ),
                    )
                  : ListView.builder(
                      itemCount: widget.friends.length,
                      itemBuilder: (_, i) {
                        final p = widget.friends[i];
                        final on = _picked.contains(p.id);
                        return InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => setState(() {
                            if (on) {
                              _picked.remove(p.id);
                            } else {
                              _picked.add(p.id);
                            }
                          }),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                GroupAvatar(members: [p], size: 44),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        p.displayName.isEmpty
                                            ? _first(p)
                                            : p.displayName,
                                        style: TextStyle(
                                          color: ink,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 15,
                                        ),
                                      ),
                                      if (p.country.isNotEmpty)
                                        Text(
                                          '${_flagOf(p)} ${p.country}'.trim(),
                                          style: TextStyle(
                                            color: ink.withValues(alpha: 0.6),
                                            fontSize: 12.5,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  on
                                      ? Icons.check_circle_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  color: on ? _kYellow : ink.withValues(alpha: 0.3),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: _ready && !_busy ? _submit : null,
              child: Opacity(
                opacity: _ready ? 1 : 0.4,
                child: Container(
                  height: 54,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _kYellow,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _kNavy,
                          ),
                        )
                      : Text(
                          widget.addOnly
                              ? AppStrings.t(
                                  'group_add_cta',
                                  args: {'n': '${_picked.length}'},
                                )
                              : AppStrings.t(
                                  'group_create_cta',
                                  args: {'n': '${_picked.length}'},
                                ),
                          style: const TextStyle(
                            color: _kNavy,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Infos du groupe (2a) et retirer un membre (2b / 2c)
// ─────────────────────────────────────────────────────────────────────────────

class GroupInfoScreen extends StatefulWidget {
  const GroupInfoScreen({
    super.key,
    required this.group,
    required this.profiles,
    required this.myId,
  });

  final ChatGroup group;
  final Map<String, RemoteProfile> profiles;
  final String myId;

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  late ChatGroup _group = widget.group;
  late Map<String, RemoteProfile> _profiles = widget.profiles;

  bool get _iAmAdmin => _group.isAdmin(widget.myId);
  bool get _muted => _group.memberOf(widget.myId)?.muted ?? false;

  Future<void> _reload() async {
    final g = await GroupApi.fetchOne(widget.myId, _group.id);
    if (!mounted || g == null) return;
    final ps = await ProfileApi.fetchByIds([for (final m in g.members) m.userId]);
    if (!mounted) return;
    setState(() {
      _group = g;
      _profiles = {..._profiles, for (final p in ps) p.id: p};
    });
  }

  bool _photoBusy = false;

  /// Change la photo du groupe (n'importe quel membre).
  Future<void> _changePhoto() async {
    if (_photoBusy) return;
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (file == null || !mounted) return;
      setState(() => _photoBusy = true);
      final bytes = await file.readAsBytes();
      await GroupApi.setPhoto(
        _group.id,
        bytes,
        contentType: file.name.toLowerCase().endsWith('.png')
            ? 'image/png'
            : 'image/jpeg',
      );
      Analytics.track('group_photo_changed');
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  Future<void> _add() async {
    List<RemoteProfile> friends;
    try {
      final rows = await FriendshipApi.fetchMatchesNewestFirst(widget.myId);
      friends = [for (final r in rows) r.profile];
    } catch (_) {
      friends = const [];
    }
    final already = {for (final m in _group.members) m.userId};
    final candidates = [
      for (final p in friends)
        if (!already.contains(p.id)) p,
    ];
    if (!mounted) return;
    final ids = await showAddMembersSheet(context, candidates: candidates);
    if (ids == null || ids.isEmpty) return;
    try {
      await GroupApi.addMembers(_group.id, ids);
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  Future<void> _toggleMute() async {
    final next = !_muted;
    try {
      await GroupApi.setMuted(_group.id, next);
      await _reload();
    } catch (_) {}
  }

  Future<void> _leave() async {
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('group_leave_q'),
      body: AppStrings.t('group_leave_body'),
      confirmLabel: AppStrings.t('group_leave'),
    );
    if (ok != true) return;
    try {
      await GroupApi.leave(_group.id);
      Analytics.track('group_left');
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  Future<void> _memberMenu(RemoteProfile p, GroupMember m) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final bottom = MediaQuery.paddingOf(ctx).bottom;
        Widget row(IconData icon, String text, String result, {Color? color}) {
          final c = color ?? SC.textPrimary;
          return ListTile(
            leading: Icon(icon, color: c),
            title: Text(text,
                style: TextStyle(color: c, fontWeight: FontWeight.w700)),
            onTap: () => Navigator.of(ctx).pop(result),
          );
        }

        return Container(
          padding: EdgeInsets.fromLTRB(8, 10, 8, 8 + bottom),
          decoration: BoxDecoration(
            color: SC.light ? Colors.white : const Color(0xFF1F1F24),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              row(Icons.person_rounded, AppStrings.t('group_view_profile'),
                  'profile'),
              row(Icons.chat_bubble_rounded, AppStrings.t('group_send_message'),
                  'dm'),
              if (!m.admin)
                row(Icons.shield_rounded, AppStrings.t('group_make_admin'),
                    'admin'),
              row(Icons.person_remove_rounded, AppStrings.t('group_remove'),
                  'remove',
                  color: _kRed),
            ],
          ),
        );
      },
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'profile':
        await Navigator.of(context).push<void>(MaterialPageRoute<void>(
          builder: (_) => ProfileScreen(userId: p.id),
        ));
      case 'dm':
        final ids = [widget.myId, p.id]..sort();
        await Navigator.of(context).push<void>(chatThreadRoute(
          builder: (_) => ChatThreadScreen(
            conversationId: 'dm-${ids[0]}-${ids[1]}',
            title: p.displayName.isNotEmpty ? p.displayName : _first(p),
            peerDeviceId: p.id,
          ),
        ));
      case 'admin':
        try {
          await GroupApi.makeAdmin(_group.id, p.id);
          await _reload();
        } catch (_) {}
      case 'remove':
        await _confirmRemove(p);
    }
  }

  /// 2c — « Retirer Lucas ? ».
  Future<void> _confirmRemove(RemoteProfile p) async {
    final name = _first(p);
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('group_remove_q', args: {'name': name}),
      body: AppStrings.t('group_remove_body'),
      confirmLabel: AppStrings.t('group_remove_confirm'),
    );
    if (ok != true) return;
    try {
      await GroupApi.removeMember(_group.id, p.id);
      Analytics.track('group_member_removed');
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final members = [
      for (final m in _group.members)
        if (_profiles[m.userId] != null) _profiles[m.userId]!,
    ];
    return Scaffold(
      backgroundColor: SC.tabBg,
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, safe.top + 8, 20, 24 + safe.bottom),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              padding: EdgeInsets.zero,
              icon: Icon(Icons.arrow_back_ios_new_rounded,
                  color: SC.textPrimary, size: 20),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          // La photo du groupe : un toucher pour la changer.
          Center(
            child: GestureDetector(
              onTap: _changePhoto,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  GroupAvatar(
                    members: members,
                    size: 96,
                    photoUrl: _group.photoUrl,
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: _kYellow,
                        shape: BoxShape.circle,
                        border: Border.all(color: SC.tabBg, width: 2.5),
                      ),
                      child: _photoBusy
                          ? const Padding(
                              padding: EdgeInsets.all(8),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _kNavy,
                              ),
                            )
                          : const Icon(Icons.photo_camera_rounded,
                              size: 16, color: _kNavy),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            _group.name,
            textAlign: TextAlign.center,
            style: popupDisplay(fontSize: 22, color: SC.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            '${AppStrings.t('group_members_count', args: {
                  'n': '${_group.members.length}'
                })} · ${_flagsLine(members)}'
                .trim(),
            textAlign: TextAlign.center,
            style: TextStyle(color: SC.textMuted, fontSize: 13.5),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _InfoButton(
                  icon: Icons.person_add_alt_1_rounded,
                  label: AppStrings.t('group_add'),
                  onTap: _add,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _InfoButton(
                  icon: _muted
                      ? Icons.notifications_off_rounded
                      : Icons.notifications_none_rounded,
                  label: AppStrings.t(_muted ? 'group_unmute' : 'group_mute'),
                  onTap: _toggleMute,
                  active: _muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            AppStrings.t('group_members_label').toUpperCase(),
            style: GoogleFonts.ibmPlexMono(
              color: SC.textMuted,
              fontSize: 11,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          for (final m in _group.members)
            if (_profiles[m.userId] case final p?)
              _MemberRow(
                profile: p,
                admin: m.admin,
                isMe: m.userId == widget.myId,
                // Le ⋯ n'apparaît que pour l'admin, jamais sur lui-même.
                onMenu: _iAmAdmin && m.userId != widget.myId
                    ? () => _memberMenu(p, m)
                    : null,
              ),
          const SizedBox(height: 22),
          GestureDetector(
            onTap: _leave,
            child: Container(
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: _kRed, width: 1.5),
              ),
              child: Text(
                AppStrings.t('group_leave'),
                style: const TextStyle(
                  color: _kRed,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoButton extends StatelessWidget {
  const _InfoButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 50,
        decoration: BoxDecoration(
          color: active ? _kYellow : SC.menu,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: SC.stroke.withValues(alpha: 0.14)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 19, color: active ? _kNavy : SC.textPrimary),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: active ? _kNavy : SC.textPrimary,
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.profile,
    required this.admin,
    required this.isMe,
    required this.onMenu,
  });

  final RemoteProfile profile;
  final bool admin;
  final bool isMe;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final flag = _flagOf(profile);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          GroupAvatar(members: [profile], size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        isMe
                            ? AppStrings.t('group_you')
                            : (profile.displayName.isEmpty
                                ? _first(profile)
                                : profile.displayName),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: SC.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    if (admin) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: _kYellow,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          AppStrings.t('group_admin'),
                          style: const TextStyle(
                            color: _kNavy,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (profile.country.isNotEmpty)
                  Text(
                    '$flag ${profile.country}'.trim(),
                    style: TextStyle(color: SC.textMuted, fontSize: 12.5),
                  ),
              ],
            ),
          ),
          if (onMenu != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onMenu,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(Icons.more_horiz_rounded, color: SC.textPrimary),
              ),
            ),
        ],
      ),
    );
  }
}
