import 'dart:async';
import 'dart:typed_data';

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
import '../widgets/group_avatar.dart';
import '../widgets/popup_kit.dart';
import 'chat_thread_screen.dart';
import 'profile_screen.dart';

// Les groupes (handoff implementation_groupes_v1) : nouveau groupe (1b),
// infos du groupe (2a), menu d'un membre (2b), confirmation de retrait (2c).
// La conversation (1c) est la vraie page de chat, en mode groupe
// (chat_thread_screen.dart). Valeurs de la maquette, sombre : jaune #F4FF1F,
// bleu nuit #04123A, fond #0E0E0E, texte #F5F7FF, rouge #EF4444.

const Color _kYellow = Color(0xFFF4FF1F);
const Color _kNavy = Color(0xFF04123A);
const Color _kText = Color(0xFFF5F7FF);
const Color _kRed = Color(0xFFEF4444);
const Color _kRedText = Color(0xFFFF8A8A);

const LinearGradient _kBrand = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF1F5EFF), Color(0xFF2B7FFF), Color(0xFF18DDEA)],
  stops: [0, 0.55, 1],
);

/// Le fond des feuilles : dégradé #1A2040 → #16161E → #131318, bord blanc 12 %.
BoxDecoration _sheetDecoration({double radius = 32}) => BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF1A2040), Color(0xFF16161E), Color(0xFF131318)],
        stops: [0, 0.4, 1],
      ),
      borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
    );

TextStyle _unbounded(double size, {double ls = -0.04}) =>
    popupDisplay(fontSize: size, letterSpacing: ls * size, color: _kText);

String _first(RemoteProfile p) {
  final n = p.displayName.trim();
  if (n.isNotEmpty) return n.split(RegExp(r'\s+')).first;
  return p.handle.isNotEmpty ? '@${p.handle}' : AppStrings.t('chat_no_name');
}

String _flagOf(RemoteProfile? p) =>
    p == null ? '' : (countryFlagFor(p.country) ?? '');

String _countryLine(RemoteProfile p) =>
    p.country.isEmpty ? '' : '${_flagOf(p)} ${p.country}'.trim();

Widget _poignee() => Center(
      child: Container(
        width: 38,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(9),
        ),
      ),
    );

/// Une personne : rond 46 (ou [size]) avec sa photo.
Widget _face(RemoteProfile p, double size) =>
    GroupAvatar(members: [p], size: size);

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
    barrierColor: const Color(0x99040A1E),
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
    barrierColor: const Color(0x99040A1E),
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
  final List<String> _picked = [];
  bool _busy = false;
  Uint8List? _photo;
  bool _photoPng = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Choisit la photo du groupe (optionnelle) ; elle part après la création.
  Future<void> _pickPhoto() async {
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        _photo = bytes;
        _photoPng = file.name.toLowerCase().endsWith('.png');
      });
    } catch (_) {}
  }

  bool get _ready =>
      _picked.isNotEmpty && (widget.addOnly || _name.text.trim().isNotEmpty);

  void _toggle(String id) => setState(() {
        if (!_picked.remove(id)) _picked.add(id);
      });

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
      // La photo choisie : au mieux, un échec n'annule pas le groupe.
      if (_photo != null && id.isNotEmpty) {
        try {
          await GroupApi.setPhoto(
            id,
            _photo!,
            contentType: _photoPng ? 'image/png' : 'image/jpeg',
          );
        } catch (_) {}
      }
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
    final mq = MediaQuery.of(context);
    final byId = {for (final p in widget.friends) p.id: p};
    final picked = [for (final id in _picked) ?byId[id]];
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Container(
        height: mq.size.height * 0.86,
        padding: EdgeInsets.fromLTRB(22, 12, 22, 0 + mq.padding.bottom),
        decoration: _sheetDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _poignee(),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  AppStrings.t(
                    widget.addOnly ? 'group_add_title' : 'group_new_title',
                  ),
                  style: _unbounded(22),
                ),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.10),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (!widget.addOnly)
              Container(
                height: 56,
                padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
                ),
                child: Row(
                  children: [
                    // Le rond photo du groupe : dégradé de la marque et
                    // appareil photo ; la photo choisie le remplace.
                    GestureDetector(
                      onTap: _pickPhoto,
                      child: Container(
                        width: 40,
                        height: 40,
                        clipBehavior: Clip.antiAlias,
                        decoration: const BoxDecoration(
                          gradient: _kBrand,
                          shape: BoxShape.circle,
                        ),
                        child: _photo != null
                            ? Image.memory(_photo!, fit: BoxFit.cover)
                            : const Icon(Icons.photo_camera_rounded,
                                color: Colors.white, size: 20),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _name,
                        maxLength: 60,
                        onChanged: (_) => setState(() {}),
                        textCapitalization: TextCapitalization.sentences,
                        cursorColor: _kYellow,
                        style: const TextStyle(color: _kText, fontSize: 15),
                        decoration: InputDecoration(
                          counterText: '',
                          hintText: AppStrings.t('group_name_hint'),
                          hintStyle: TextStyle(
                            color: _kText.withValues(alpha: 0.55),
                            fontSize: 15,
                          ),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (picked.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in picked)
                    GestureDetector(
                      onTap: () => _toggle(p.id),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
                        decoration: BoxDecoration(
                          color: _kYellow.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(
                              color: _kYellow.withValues(alpha: 0.5)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _face(p, 24),
                            const SizedBox(width: 6),
                            Text(
                              _first(p),
                              style: const TextStyle(
                                color: _kYellow,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(Icons.close_rounded,
                                size: 14, color: _kYellow),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                AppStrings.t(
                  'group_selected',
                  args: {'n': '${picked.length}'},
                ).toUpperCase(),
                style: TextStyle(
                  color: _kText.withValues(alpha: 0.55),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ],
            const SizedBox(height: 6),
            Expanded(
              child: widget.friends.isEmpty
                  ? Center(
                      child: Text(
                        AppStrings.t('group_no_contacts'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: _kText.withValues(alpha: 0.6)),
                      ),
                    )
                  : ListView.builder(
                      itemCount: widget.friends.length,
                      itemBuilder: (_, i) {
                        final p = widget.friends[i];
                        final on = _picked.contains(p.id);
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _toggle(p.id),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                _face(p, 46),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        p.displayName.isEmpty
                                            ? _first(p)
                                            : p.displayName,
                                        style: const TextStyle(
                                          color: _kText,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 15,
                                        ),
                                      ),
                                      if (p.country.isNotEmpty)
                                        Text(
                                          _countryLine(p),
                                          style: TextStyle(
                                            color: _kText.withValues(alpha: 0.55),
                                            fontSize: 12.5,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                Container(
                                  width: 26,
                                  height: 26,
                                  decoration: BoxDecoration(
                                    color: on ? _kYellow : null,
                                    shape: BoxShape.circle,
                                    border: on
                                        ? null
                                        : Border.all(
                                            color: Colors.white
                                                .withValues(alpha: 0.3),
                                            width: 1.8,
                                          ),
                                  ),
                                  child: on
                                      ? const Icon(Icons.check_rounded,
                                          size: 18, color: _kNavy)
                                      : null,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 34),
              child: GestureDetector(
                onTap: _ready && !_busy ? _submit : null,
                child: Opacity(
                  opacity: _ready ? 1 : 0.4,
                  child: Container(
                    height: 64,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _kYellow,
                      borderRadius: BorderRadius.circular(99),
                      boxShadow: [
                        BoxShadow(
                          color: _kYellow.withValues(alpha: 0.55),
                          blurRadius: 28,
                          spreadRadius: -10,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
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
                            style: popupDisplay(fontSize: 15, color: _kNavy),
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
// Infos du groupe (2a), menu d'un membre (2b), confirmation de retrait (2c)
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
  bool _photoBusy = false;

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
    try {
      await GroupApi.setMuted(_group.id, !_muted);
      await _reload();
    } catch (_) {}
  }

  Future<void> _leave() async {
    final ok = await _confirm(
      title: AppStrings.t('group_leave_q'),
      body: AppStrings.t('group_leave_body'),
      confirmLabel: AppStrings.t('group_leave'),
    );
    if (!ok) return;
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

  /// 2c — la confirmation : avatar + pastille rouge ✕, titre, texte, bouton
  /// rouge et « Annuler ». [face] = la personne concernée (retrait), sinon
  /// une confirmation simple sans visage.
  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
    RemoteProfile? face,
  }) async {
    final res = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0xB3040A1E),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF1A2040), Color(0xFF16161E)],
            ),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x99000000),
                blurRadius: 60,
                offset: Offset(0, 30),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (face != null)
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _face(face, 72),
                    Positioned(
                      right: -6,
                      bottom: -4,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: _kRed,
                          shape: BoxShape.circle,
                          border:
                              Border.all(color: const Color(0xFF1A2040), width: 3),
                        ),
                        child: const Icon(Icons.close_rounded,
                            size: 17, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: _unbounded(20).copyWith(height: 1.2),
              ),
              const SizedBox(height: 12),
              Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _kText.withValues(alpha: 0.7),
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: () => Navigator.of(ctx).pop(true),
                child: Container(
                  height: 54,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _kRed,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    confirmLabel,
                    style: popupDisplay(fontSize: 14, color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: () => Navigator.of(ctx).pop(false),
                child: Container(
                  height: 50,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                  ),
                  child: Text(
                    AppStrings.t('cancel'),
                    style: const TextStyle(
                      color: _kText,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return res == true;
  }

  /// 2b — le menu d'un membre.
  Future<void> _memberMenu(RemoteProfile p, GroupMember m) async {
    Widget row(IconData icon, String text, String result, {Color? color}) {
      final c = color ?? _kText;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(result),
        child: SizedBox(
          height: 58,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                Icon(icon, size: 24, color: color ?? Colors.white),
                const SizedBox(width: 14),
                Text(
                  text,
                  style: TextStyle(
                    color: c,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final divider = Container(
      height: 1,
      color: Colors.white.withValues(alpha: 0.10),
    );
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x99040A1E),
      builder: (ctx) => Container(
        padding: EdgeInsets.fromLTRB(
          22,
          12,
          22,
          38 + MediaQuery.paddingOf(ctx).bottom * 0.4,
        ),
        decoration: _sheetDecoration(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _poignee(),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 14),
              child: Row(
                children: [
                  _face(p, 52),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_first(p), style: _unbounded(17, ls: -0.02)),
                        if (p.country.isNotEmpty)
                          Text(
                            _countryLine(p),
                            style: TextStyle(
                              color: _kText.withValues(alpha: 0.55),
                              fontSize: 12.5,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            divider,
            row(Icons.person_rounded, AppStrings.t('group_view_profile'),
                'profile'),
            row(Icons.chat_bubble_rounded, AppStrings.t('group_send_message'),
                'dm'),
            if (!m.admin)
              row(Icons.workspace_premium_rounded,
                  AppStrings.t('group_make_admin'), 'admin'),
            divider,
            row(Icons.person_remove_rounded, AppStrings.t('group_remove'),
                'remove',
                color: _kRedText),
          ],
        ),
      ),
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
    final ok = await _confirm(
      title: AppStrings.t('group_remove_q', args: {'name': _first(p)}),
      body: AppStrings.t('group_remove_body'),
      confirmLabel: AppStrings.t('group_remove_confirm'),
      face: p,
    );
    if (!ok) return;
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
      backgroundColor: const Color(0xFF0E0E0E),
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.only(top: safe.top + 68, bottom: 120 + safe.bottom),
            children: [
              // La photo du groupe : un toucher pour la changer.
              Padding(
                padding: const EdgeInsets.only(top: 14, bottom: 18),
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: _changePhoto,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          GroupAvatar(
                            members: members,
                            size: 92,
                            photoUrl: _group.photoUrl,
                          ),
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: _kYellow,
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: const Color(0xFF0E0E0E), width: 2.5),
                              ),
                              child: _photoBusy
                                  ? const Padding(
                                      padding: EdgeInsets.all(7),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: _kNavy,
                                      ),
                                    )
                                  : const Icon(Icons.photo_camera_rounded,
                                      size: 15, color: _kNavy),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      _group.name,
                      textAlign: TextAlign.center,
                      style: _unbounded(21, ls: -0.03),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      AppStrings.t('group_members_count',
                          args: {'n': '${_group.members.length}'}),
                      style: TextStyle(
                        color: _kText.withValues(alpha: 0.6),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: _add,
                        child: Container(
                          height: 48,
                          decoration: BoxDecoration(
                            gradient: _kBrand,
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.person_add_rounded,
                                  size: 19, color: Colors.white),
                              const SizedBox(width: 8),
                              Text(
                                AppStrings.t('group_add'),
                                style: popupDisplay(
                                    fontSize: 13, color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GestureDetector(
                        onTap: _toggleMute,
                        child: Container(
                          height: 48,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(99),
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.2),
                                width: 1.2),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                _muted
                                    ? Icons.notifications_active_rounded
                                    : Icons.notifications_off_rounded,
                                size: 19,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                AppStrings.t(
                                    _muted ? 'group_unmute' : 'group_mute'),
                                style: popupDisplay(
                                    fontSize: 13, color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 6),
                child: Text(
                  AppStrings.t('group_members_label').toUpperCase(),
                  style: TextStyle(
                    color: _kText.withValues(alpha: 0.55),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
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
            ],
          ),
          // L'en-tête : retour + « Infos du groupe » centré.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(14, safe.top + 8, 14, 8),
              color: const Color(0xFF0E0E0E),
              child: SizedBox(
                height: 44,
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.of(context).maybePop(),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.13),
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.22),
                              width: 1.2),
                        ),
                        child: const Icon(Icons.arrow_back_rounded,
                            color: _kText, size: 22),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        AppStrings.t('group_info_title'),
                        textAlign: TextAlign.center,
                        style: _unbounded(16, ls: -0.02),
                      ),
                    ),
                    const SizedBox(width: 44),
                  ],
                ),
              ),
            ),
          ),
          // « Quitter le groupe » : en bas, contour rouge.
          Positioned(
            left: 18,
            right: 18,
            bottom: 36 + safe.bottom * 0.5,
            child: GestureDetector(
              onTap: _leave,
              child: Container(
                height: 56,
                decoration: BoxDecoration(
                  color: _kRed.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(
                      color: _kRed.withValues(alpha: 0.55), width: 1.2),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.logout_rounded,
                        size: 20, color: _kRedText),
                    const SizedBox(width: 8),
                    Text(
                      AppStrings.t('group_leave'),
                      style: popupDisplay(fontSize: 14, color: _kRedText),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
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
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          _face(profile, 46),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isMe
                      ? AppStrings.t('group_you')
                      : (profile.displayName.isEmpty
                          ? _first(profile)
                          : profile.displayName),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _kText,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                // « Toi » → « Admin » ; les autres → drapeau et pays.
                if (isMe && admin)
                  Text(
                    AppStrings.t('group_admin'),
                    style: TextStyle(
                      color: _kText.withValues(alpha: 0.55),
                      fontSize: 12.5,
                    ),
                  )
                else if (profile.country.isNotEmpty)
                  Text(
                    _countryLine(profile),
                    style: TextStyle(
                      color: _kText.withValues(alpha: 0.55),
                      fontSize: 12.5,
                    ),
                  ),
              ],
            ),
          ),
          if (admin)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: _kYellow,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                AppStrings.t('group_admin'),
                style: GoogleFonts.plusJakartaSans(
                  color: _kNavy,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          if (onMenu != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onMenu,
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(
                  Icons.more_horiz_rounded,
                  size: 24,
                  color: _kText.withValues(alpha: 0.7),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
