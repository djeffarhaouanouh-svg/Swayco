// Design 4a — écran Messages (swaycø)
// Fichier autonome, aucune dépendance externe.
// Branche tes données réelles à la place des listes `_demoMatches` / `_demoChats`.

import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';

// ── Tokens du design ────────────────────────────────────────────────────────
class SwTokens {
  static const bg = Color(0xFF000000);
  static const surface = Color(0xFF121417);
  static const cyan = Color(0xFF24CCE6);
  static const cyanInk = Color(0xFF04191D);
  static const green = Color(0xFF3DDC84);
  static const amber = Color(0xFFF5C518);

  static const textPrimary = Color(0xFFFFFFFF);
  static const textBody = Color(0xFFE8EAEC);
  static const textMuted = Color(0xFFCFD3D6);
  static const textDim = Color(0xFF8A9096);
  static const textFaint = Color(0xFF5F656A);
  static const hairline = Color(0x12FFFFFF); // rgba(255,255,255,.07)

  static const mono = 'monospace';

  // Méta 11 px mono, lettres espacées (titres de section)
  static const sectionLabel = TextStyle(
    fontFamily: mono,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.1,
  );
  static const name = TextStyle(
    fontSize: 16.5,
    fontWeight: FontWeight.w600,
    height: 1.2,
    color: textPrimary,
  );
  static const nameRead = TextStyle(
    fontSize: 16.5,
    fontWeight: FontWeight.w500,
    height: 1.2,
    color: textMuted,
  );
  static const preview = TextStyle(fontSize: 14, height: 1.3);
  static const metaTime = TextStyle(
    fontFamily: mono,
    fontSize: 11.5,
    fontWeight: FontWeight.w600,
  );
}

// ── Modèles ─────────────────────────────────────────────────────────────────
class SwMatch {
  const SwMatch({required this.name, required this.photoUrl, this.seen = false});
  final String name;
  final String? photoUrl;
  final bool seen;
}

class SwChat {
  const SwChat({
    required this.name,
    required this.initial,
    required this.avatarColor,
    required this.avatarInk,
    required this.time,
    this.preview,
    this.fromMe = false,
    this.unread = 0,
    this.online = false,
    this.neverTalked = false,
  });

  final String name;
  final String initial;
  final Color avatarColor;
  final Color avatarInk;
  final String time;
  final String? preview;
  final bool fromMe;
  final int unread;
  final bool online;
  final bool neverTalked;
}

// ── Écran ───────────────────────────────────────────────────────────────────
class ChatScreen4A extends StatelessWidget {
  const ChatScreen4A({
    super.key,
    this.matches = _demoMatches,
    this.chats = _demoChats,
    this.onlineCount = 3,
    this.onOpenChat,
    this.onOpenProfile,
    this.onCall,
    this.onRefresh,
  });

  final List<SwMatch> matches;
  final List<SwChat> chats;
  final int onlineCount;
  final void Function(SwChat)? onOpenChat;
  final void Function(SwChat)? onOpenProfile;
  final void Function(SwChat)? onCall;
  final Future<void> Function()? onRefresh;

  int get _unreadChats => chats.where((c) => c.unread > 0).length;
  int get _unseenMatches => matches.where((m) => !m.seen).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SwTokens.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(onlineCount: onlineCount),
            Expanded(
              child: RefreshIndicator(
                color: SwTokens.cyan,
                backgroundColor: SwTokens.surface,
                onRefresh: onRefresh ?? () async {},
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 20, bottom: 12),
                      child: Text(
                        '$_unseenMatches NOUVEAUX MATCHS',
                        style: SwTokens.sectionLabel.copyWith(color: SwTokens.cyan),
                      ),
                    ),
                    _MatchRail(matches: matches),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 20),
                      child: Divider(height: 37, thickness: 1, color: SwTokens.hairline),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 20, bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text('MESSAGES',
                              style: SwTokens.sectionLabel
                                  .copyWith(color: Colors.white.withOpacity(.45))),
                          const SizedBox(width: 8),
                          Text('$_unreadChats non lus',
                              style: SwTokens.sectionLabel.copyWith(
                                  color: SwTokens.cyan, letterSpacing: 0)),
                        ],
                      ),
                    ),
                    for (final c in chats)
                      _ChatRow(
                        chat: c,
                        onTap: () => onOpenChat?.call(c),
                        onAvatarTap: () => onOpenProfile?.call(c),
                        onCall: () => onCall?.call(c),
                      ),
                    const SizedBox(height: 110),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      extendBody: true,
      bottomNavigationBar: const _GlassNav(likesBadge: 7),
    );
  }
}

// ── En-tête ─────────────────────────────────────────────────────────────────
class _Header extends StatelessWidget {
  const _Header({required this.onlineCount});
  final int onlineCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Logo — remplace par ton Image.asset si tu as le lettrage vectoriel.
          RichText(
            text: const TextSpan(
              style: TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
                color: SwTokens.textPrimary,
                height: 1,
              ),
              children: [
                TextSpan(text: 'swayc'),
                TextSpan(text: 'ø', style: TextStyle(color: SwTokens.cyan)),
              ],
            ),
          ),
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: SwTokens.surface,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                      color: SwTokens.green, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text('$onlineCount en ligne',
                    style: const TextStyle(
                        fontFamily: SwTokens.mono,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: SwTokens.textDim)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Rail des nouveaux matchs ────────────────────────────────────────────────
class _MatchRail extends StatelessWidget {
  const _MatchRail({required this.matches});
  final List<SwMatch> matches;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: matches.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (_, i) {
          final m = matches[i];
          final photo = ClipOval(
            child: m.photoUrl == null
                ? Container(color: const Color(0xFF1A1D20))
                : Image.network(m.photoUrl!, fit: BoxFit.cover),
          );
          return Opacity(
            opacity: m.seen ? .55 : 1,
            child: Column(
              children: [
                // Anneau cyan→vert = match pas encore vu
                Container(
                  width: 64,
                  height: 64,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: m.seen
                        ? null
                        : const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [SwTokens.cyan, SwTokens.green],
                          ),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: SwTokens.bg, width: 2),
                    ),
                    child: photo,
                  ),
                ),
                const SizedBox(height: 7),
                Text(m.name,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: m.seen ? SwTokens.textDim : SwTokens.textBody)),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ── Ligne de conversation ───────────────────────────────────────────────────
class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.chat,
    this.onTap,
    this.onAvatarTap,
    this.onCall,
  });

  final SwChat chat;
  final VoidCallback? onTap;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onCall;

  @override
  Widget build(BuildContext context) {
    final unread = chat.unread > 0;

    return InkWell(
      onTap: onTap,
      onLongPress: () => _showRowMenu(context, chat),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        // Non-lu : dégradé cyan qui s'éteint vers la droite
        decoration: unread
            ? BoxDecoration(
                gradient: LinearGradient(
                  colors: [SwTokens.cyan.withOpacity(.10), SwTokens.cyan.withOpacity(0)],
                ),
              )
            : null,
        child: Row(
          children: [
            GestureDetector(
              onTap: onAvatarTap,
              child: SizedBox(
                width: 52,
                height: 52,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                          color: chat.avatarColor, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: Text(chat.initial,
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: chat.avatarInk)),
                    ),
                    if (chat.online)
                      Positioned(
                        right: 1,
                        bottom: 1,
                        child: Container(
                          width: 13,
                          height: 13,
                          decoration: BoxDecoration(
                            color: SwTokens.green,
                            shape: BoxShape.circle,
                            border: Border.all(color: SwTokens.bg, width: 2.5),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(chat.name, style: unread ? SwTokens.name : SwTokens.nameRead),
                  const SizedBox(height: 4),
                  _previewLine(),
                ],
              ),
            ),
            const SizedBox(width: 12),
            unread ? _unreadTrailing() : _readTrailing(),
          ],
        ),
      ),
    );
  }

  Widget _previewLine() {
    if (chat.neverTalked) {
      return const Text('Vous ne vous êtes pas encore parlé',
          style: TextStyle(fontSize: 14, height: 1.3, color: SwTokens.textFaint));
    }
    final unread = chat.unread > 0;
    final body = chat.preview ?? '';
    return Text.rich(
      TextSpan(
        style: SwTokens.preview.copyWith(
            color: unread ? SwTokens.textBody : const Color(0xFF7D8388)),
        children: [
          if (chat.fromMe)
            const TextSpan(text: 'Vous : ', style: TextStyle(color: SwTokens.textFaint)),
          TextSpan(text: body),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _unreadTrailing() {
    final label = chat.unread > 99 ? '99+' : '${chat.unread}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(chat.time, style: SwTokens.metaTime.copyWith(color: SwTokens.cyan)),
        const SizedBox(height: 7),
        Container(
          constraints: const BoxConstraints(minWidth: 22),
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
              color: SwTokens.cyan, borderRadius: BorderRadius.circular(999)),
          alignment: Alignment.center,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: SwTokens.cyanInk)),
        ),
      ],
    );
  }

  // Fil lu : l'appel passe en bouton fantôme, il ne concurrence plus la ligne
  Widget _readTrailing() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!chat.neverTalked)
          Text(chat.time,
              style: SwTokens.metaTime
                  .copyWith(color: SwTokens.textFaint, fontWeight: FontWeight.w500)),
        if (!chat.neverTalked) const SizedBox(height: 7),
        GestureDetector(
          onTap: onCall,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(.14)),
            ),
            child: Icon(Icons.call_outlined, size: 16, color: Colors.white.withOpacity(.5)),
          ),
        ),
      ],
    );
  }

  void _showRowMenu(BuildContext context, SwChat chat) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SwTokens.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            _MenuItem(icon: Icons.notifications_off_outlined, label: 'Couper les appels'),
            _MenuItem(icon: Icons.block, label: 'Bloquer'),
            _MenuItem(icon: Icons.flag_outlined, label: 'Signaler'),
            _MenuItem(
                icon: Icons.delete_outline,
                label: 'Supprimer la conversation',
                danger: true),
            SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({required this.icon, required this.label, this.danger = false});
  final IconData icon;
  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFFF6B6B) : SwTokens.textBody;
    return ListTile(
      leading: Icon(icon, color: color, size: 20),
      title: Text(label,
          style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w500)),
      onTap: () => Navigator.of(context).pop(),
    );
  }
}

// ── Nav en verre ────────────────────────────────────────────────────────────
class _GlassNav extends StatelessWidget {
  const _GlassNav({this.index = 0, this.likesBadge = 0});
  final int index;
  final int likesBadge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 20, bottom: 26),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            height: 62,
            decoration: BoxDecoration(
              color: const Color(0xFF1C2024).withOpacity(.72),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withOpacity(.08)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _navItem(Icons.chat_bubble_outline, active: index == 0),
                _navItem(Icons.style_outlined, active: index == 1),
                _navItem(Icons.favorite_border, active: index == 2, badge: likesBadge),
                _navItem(Icons.person_outline, active: index == 3),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _navItem(IconData icon, {bool active = false, int badge = 0}) {
    final child = Icon(icon,
        size: 21, color: active ? SwTokens.cyan : Colors.white.withOpacity(.45));

    Widget body = active
        ? Container(
            width: 54,
            height: 40,
            decoration: BoxDecoration(
              color: SwTokens.cyan.withOpacity(.14),
              borderRadius: BorderRadius.circular(999),
            ),
            alignment: Alignment.center,
            child: child,
          )
        : child;

    if (badge > 0) {
      body = Stack(
        clipBehavior: Clip.none,
        children: [
          body,
          Positioned(
            top: -4,
            right: -7,
            child: Container(
              constraints: const BoxConstraints(minWidth: 17),
              height: 17,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: SwTokens.cyan,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0xFF1C2024), width: 2),
              ),
              alignment: Alignment.center,
              child: Text(badge > 99 ? '99+' : '$badge',
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: SwTokens.cyanInk)),
            ),
          ),
        ],
      );
    }
    return body;
  }
}

// ── Données de démo (à remplacer) ───────────────────────────────────────────
const _demoMatches = <SwMatch>[
  SwMatch(name: 'Nora', photoUrl: null),
  SwMatch(name: 'Yuki', photoUrl: null),
  SwMatch(name: 'Marco', photoUrl: null),
  SwMatch(name: 'Sam', photoUrl: null, seen: true),
  SwMatch(name: 'Léa', photoUrl: null, seen: true),
];

const _demoChats = <SwChat>[
  SwChat(
    name: 'Djeffar',
    initial: 'D',
    avatarColor: SwTokens.amber,
    avatarInk: Color(0xFF1A1400),
    time: '16:46',
    preview: 'Tu fais quoi ce week-end ?',
    unread: 3,
    online: true,
  ),
  SwChat(
    name: 'Ines',
    initial: 'I',
    avatarColor: SwTokens.amber,
    avatarInk: Color(0xFF1A1400),
    time: '11/06',
    preview: 'Fancy a call ?',
    unread: 1,
  ),
  SwChat(
    name: 'Alice',
    initial: 'A',
    avatarColor: Color(0xFF3B82F6),
    avatarInk: Color(0xFF04121F),
    time: '27/05',
    preview: 'Coucou !',
    fromMe: true,
  ),
  SwChat(
    name: 'Lenny',
    initial: 'L',
    avatarColor: Color(0xFF10B981),
    avatarInk: Color(0xFF03211A),
    time: '14/05',
    neverTalked: true,
    online: true,
  ),
];
