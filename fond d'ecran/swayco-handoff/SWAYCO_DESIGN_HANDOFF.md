# Swayco — Design Handoff (Flutter) · v2

> Direction : **Midnight** — fond mesh navy/violet/cyan, surfaces verre style Apple, accent cyan.
> Écrans : Messages, Discover, Chat.
> Polices : Bricolage Grotesque (titres) + DM Sans (corps).

---

## ⛔ À NE PAS FAIRE (vu dans la v1)

Erreurs constatées dans l'implémentation précédente — **à corriger absolument** :

1. ❌ Pas de mesh gradient → **OUI :** utiliser le PNG `assets/mesh_midnight_bg.png` en background (voir §3).
2. ❌ Liste de messages flat sans container → **OUI :** envelopper la liste dans un `GlassContainer` (blur + bg blanc 6% + border blanc 10%).
3. ❌ Bouton "Invite to a call" plein cyan → **OUI :** glass blanc 10% avec border blanche subtile. Le cyan est l'accent, pas la couleur du bouton principal.
4. ❌ Icônes téléphone/dots posées flat sur la ligne → **OUI :** chaque bouton icône est un cercle glass (38px, white 8%, border 12%).
5. ❌ Tab bar minuscule avec icône verte → **OUI :** pill large, glass blanc 8%, état actif = **fond blanc opaque + icône navy** (jamais d'autre couleur).
6. ❌ Titre "Messages" en sans-serif standard → **OUI :** Bricolage Grotesque 800, taille 38, letter-spacing -3%.

---

## 1. Assets à copier dans le projet

| Source | Destination Flutter |
|---|---|
| `mesh_midnight_bg.png` | `assets/images/mesh_midnight_bg.png` |

Dans `pubspec.yaml` :
```yaml
flutter:
  assets:
    - assets/images/mesh_midnight_bg.png

dependencies:
  flutter:
    sdk: flutter
  google_fonts: ^6.2.1
  cached_network_image: ^3.4.1
```

---

## 2. `lib/theme/swayco_theme.dart`

```dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Palette Midnight — navy + cyan + violet
class SC {
  static const bg               = Color(0xFF0A1024);

  // Accent cyan (utilisé ponctuellement : online dot, bouton mic, bulles sortantes, focus)
  static const accent           = Color(0xFF22D3EE);
  static const accentDeep       = Color(0xFF0891B2);

  // Text
  static const textPrimary      = Color(0xFFF5F7FF);
  static const textSecondary    = Color(0xB3F5F7FF); // 70%
  static const textMuted        = Color(0x80F5F7FF); // 50%

  // Surfaces glass
  static const glass            = Color(0x0FFFFFFF); // white 6%
  static const glassStrong      = Color(0x1AFFFFFF); // white 10%
  static const glassBorder      = Color(0x1AFFFFFF); // white 10%
  static const glassBorderStrong = Color(0x33FFFFFF); // white 20%

  // Bulle entrante (chat) — OPAQUE pas glass
  static const bubbleIn         = Color(0xFF1A2138);
  static const bubbleInBorder   = Color(0x14FFFFFF);

  // Avatars gradients (cycle par index)
  static const avatarGradients = <List<Color>>[
    [Color(0xFF60A5FA), Color(0xFF3B82F6)], // blue
    [Color(0xFFA78BFA), Color(0xFF7C3AED)], // violet
    [Color(0xFF67E8F9), Color(0xFF06B6D4)], // cyan
    [Color(0xFFF472B6), Color(0xFFDB2777)], // pink
    [Color(0xFF34D399), Color(0xFF059669)], // emerald
  ];
}

class SCText {
  static TextStyle h1 = GoogleFonts.bricolageGrotesque(
    fontSize: 38, fontWeight: FontWeight.w800,
    letterSpacing: -1.14, color: SC.textPrimary, height: 1,
  );
  static TextStyle h2 = GoogleFonts.bricolageGrotesque(
    fontSize: 22, fontWeight: FontWeight.w700,
    letterSpacing: -0.4, color: SC.textPrimary,
  );
  static TextStyle h3 = GoogleFonts.bricolageGrotesque(
    fontSize: 20, fontWeight: FontWeight.w700,
    letterSpacing: -0.4, color: SC.textPrimary, height: 1.1,
  );
  static TextStyle name = GoogleFonts.dmSans(
    fontSize: 16, fontWeight: FontWeight.w700, color: SC.textPrimary,
  );
  static TextStyle body = GoogleFonts.dmSans(
    fontSize: 15, fontWeight: FontWeight.w500, color: SC.textPrimary, height: 1.3,
  );
  static TextStyle preview = GoogleFonts.dmSans(
    fontSize: 12, fontWeight: FontWeight.w400, color: SC.textMuted,
  );
  static TextStyle meta = GoogleFonts.dmSans(
    fontSize: 11, fontWeight: FontWeight.w600, color: SC.textMuted,
  );
  static TextStyle button = GoogleFonts.dmSans(
    fontSize: 14, fontWeight: FontWeight.w800, color: SC.bg,
  );
  static TextStyle accent = GoogleFonts.dmSans(
    fontSize: 12, fontWeight: FontWeight.w700, color: SC.accent,
  );
}
```

---

## 3. `lib/widgets/mesh_background.dart` — utilise le PNG

```dart
import 'package:flutter/material.dart';
import '../theme/swayco_theme.dart';

/// Fond mesh midnight — applique le PNG, scale pour couvrir l'écran.
class MeshBackground extends StatelessWidget {
  final Widget child;
  const MeshBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: SC.bg,
        image: DecorationImage(
          image: AssetImage('assets/images/mesh_midnight_bg.png'),
          fit: BoxFit.cover,
        ),
      ),
      child: child,
    );
  }
}
```

> ⚠️ **Ne pas remplacer par des RadialGradient.** Le PNG est l'asset de référence — son aspect ne doit pas être recréé en code.

---

## 4. `lib/widgets/glass.dart` — composants verre

```dart
import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/swayco_theme.dart';

/// Conteneur "verre Apple"
class GlassContainer extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final Color? color;
  final Color? border;
  final List<BoxShadow>? boxShadow;

  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.padding,
    this.blur = 24,
    this.color,
    this.border,
    this.boxShadow,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: color ?? SC.glass,
            borderRadius: borderRadius,
            border: Border.all(color: border ?? SC.glassBorder, width: 1),
            boxShadow: boxShadow,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Bouton icône rond glass — toujours utiliser pour back/call/dots etc
class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  const GlassIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 38,
    this.iconSize = 18,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            width: size, height: size,
            decoration: BoxDecoration(
              color: SC.glassStrong,
              shape: BoxShape.circle,
              border: Border.all(color: SC.glassBorder),
            ),
            child: Icon(icon, color: SC.textPrimary, size: iconSize),
          ),
        ),
      ),
    );
  }
}

/// Avatar circulaire (photo ou gradient + initiale)
class SCAvatar extends StatelessWidget {
  final String? photoUrl;
  final String initial;
  final double size;
  final int gradientIndex;
  const SCAvatar({
    super.key,
    this.photoUrl,
    required this.initial,
    this.size = 46,
    this.gradientIndex = 0,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SC.avatarGradients[gradientIndex % SC.avatarGradients.length];
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        border: Border.all(color: SC.glassBorderStrong, width: 1.5),
      ),
      child: photoUrl != null
        ? ClipOval(child: Image.network(photoUrl!, fit: BoxFit.cover))
        : Center(
            child: Text(
              initial.toUpperCase(),
              style: TextStyle(
                color: SC.bg,
                fontWeight: FontWeight.w900,
                fontSize: size * 0.42,
              ),
            ),
          ),
    );
  }
}
```

---

## 5. `lib/widgets/glass_tab_bar.dart`

```dart
import 'package:flutter/material.dart';
import '../theme/swayco_theme.dart';
import 'glass.dart';

class GlassTabBar extends StatelessWidget {
  final int activeIndex;
  final void Function(int)? onTap;
  const GlassTabBar({super.key, required this.activeIndex, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
      child: GlassContainer(
        borderRadius: BorderRadius.circular(999),
        padding: const EdgeInsets.all(6),
        child: Row(
          children: [
            _tab(0, Icons.chat_bubble_outline_rounded),
            _tab(1, Icons.search_rounded),
            _tab(2, Icons.person_outline_rounded),
          ],
        ),
      ),
    );
  }

  Widget _tab(int i, IconData icon) {
    final active = activeIndex == i;
    return Expanded(
      child: GestureDetector(
        onTap: () => onTap?.call(i),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            // État actif : fond BLANC opaque + icône navy. PAS de vert, PAS de cyan ici.
            color: active ? SC.textPrimary : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Icon(
            icon,
            color: active ? SC.bg : SC.textMuted,
            size: 22,
          ),
        ),
      ),
    );
  }
}
```

---

## 6. `lib/screens/messages_screen.dart`

```dart
import 'package:flutter/material.dart';
import '../theme/swayco_theme.dart';
import '../widgets/mesh_background.dart';
import '../widgets/glass.dart';
import '../widgets/glass_tab_bar.dart';

class MessagesScreen extends StatelessWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // TODO: brancher sur le stream de conversations Supabase
    final convos = [
      _Convo('Alice', 'Vous : 👋', 'hier', 0),
      _Convo('Ines',  'Vous : 👋', 'jeu',  1),
      _Convo('Lenny', 'Vous : yeeees bro', '17/05', 2),
    ];

    return Scaffold(
      backgroundColor: SC.bg,
      extendBody: true,
      body: MeshBackground(
        child: SafeArea(
          child: Column(
            children: [
              // === TITRE ===
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 22),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Messages', style: SCText.h1),
                ),
              ),

              // === LISTE — DANS UN GLASS CONTAINER ===
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GlassContainer(
                  borderRadius: BorderRadius.circular(24),
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    children: [
                      for (final c in convos) _ConvoRow(convo: c),
                    ],
                  ),
                ),
              ),

              // === BOUTON INVITE — GLASS, PAS PLEIN ===
              Padding(
                padding: const EdgeInsets.all(18),
                child: SizedBox(
                  width: double.infinity,
                  child: GlassContainer(
                    borderRadius: BorderRadius.circular(22),
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    color: SC.glassStrong,           // white 10%
                    border: SC.glassBorderStrong,    // white 20%
                    blur: 20,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.videocam_rounded, color: SC.textPrimary, size: 22),
                        const SizedBox(width: 10),
                        Text('Invite to a call',
                          style: SCText.body.copyWith(fontWeight: FontWeight.w800, fontSize: 17),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const Spacer(),

              // === NAV BAR GLASS ===
              const GlassTabBar(activeIndex: 0),
            ],
          ),
        ),
      ),
    );
  }
}

class _Convo {
  final String name, preview, time;
  final int gradientIndex;
  _Convo(this.name, this.preview, this.time, this.gradientIndex);
}

class _ConvoRow extends StatelessWidget {
  final _Convo convo;
  const _ConvoRow({required this.convo});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          SCAvatar(initial: convo.name[0], gradientIndex: convo.gradientIndex, size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(convo.name, style: SCText.name),
                const SizedBox(height: 2),
                Text(convo.preview, style: SCText.preview),
              ],
            ),
          ),
          Text(convo.time, style: SCText.meta),
        ],
      ),
    );
  }
}
```

---

## 7. `lib/screens/discover_screen.dart`

```dart
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/swayco_theme.dart';
import '../widgets/mesh_background.dart';
import '../widgets/glass.dart';
import '../widgets/glass_tab_bar.dart';

class DiscoverScreen extends StatelessWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SC.bg,
      extendBody: true,
      body: MeshBackground(
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text('Discover', style: SCText.h1.copyWith(fontSize: 36)),
                    GlassContainer(
                      borderRadius: BorderRadius.circular(999),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.search_rounded, color: SC.textMuted, size: 16),
                          const SizedBox(width: 6),
                          Text('Search', style: SCText.preview),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Profile card
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // TODO: photo réelle
                        // CachedNetworkImage(imageUrl: profile.photoUrl, fit: BoxFit.cover),
                        Container(color: SC.bubbleIn),

                        // Gradient fade bas pour lisibilité
                        Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Color(0x99000000)],
                              stops: [0.4, 1.0],
                            ),
                          ),
                        ),

                        Positioned(
                          left: 22, right: 22, bottom: 22,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Alice',
                                      style: SCText.h1.copyWith(fontSize: 34, color: Colors.white),
                                    ),
                                    Text('22 · Paris 🇫🇷',
                                      style: SCText.preview.copyWith(color: Colors.white70, fontSize: 13),
                                    ),
                                    const SizedBox(height: 10),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(999),
                                      ),
                                      child: Text('Send 👋', style: SCText.button),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                width: 46, height: 46,
                                decoration: BoxDecoration(
                                  color: SC.glassStrong,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: SC.glassBorderStrong),
                                ),
                                child: const Icon(Icons.favorite_border, color: Colors.white, size: 20),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const Spacer(),
              const GlassTabBar(activeIndex: 1),
            ],
          ),
        ),
      ),
    );
  }
}
```

---

## 8. `lib/screens/chat_screen.dart`

```dart
import 'package:flutter/material.dart';
import '../theme/swayco_theme.dart';
import '../widgets/mesh_background.dart';
import '../widgets/glass.dart';

class ChatScreen extends StatefulWidget {
  final String contactName;
  const ChatScreen({super.key, this.contactName = 'Lenny'});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  bool translationOn = false;
  final _ctrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    // TODO: stream Supabase
    final messages = <_Msg>[
      _Msg.incoming('Y\'a quoi?', '05:48'),
      _Msg.incoming('Oui', '05:56'),
      _Msg.incoming('Oui', '05:56', continued: true),
      _Msg.incoming('Coucou', '06:12'),
      _Msg.incoming('Coucou', '06:12', continued: true),
      _Msg.incoming('Slt', '06:27'),
      _Msg.incoming('Slt', '06:32', continued: true),
      _Msg.outgoing('yeeees bro', '06:37'),
    ];

    return Scaffold(
      backgroundColor: SC.bg,
      extendBody: true,
      body: MeshBackground(
        child: SafeArea(
          child: Column(
            children: [
              _Header(name: widget.contactName),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: messages.length,
                  separatorBuilder: (_, i) {
                    final next = i + 1 < messages.length ? messages[i + 1] : messages[i];
                    return SizedBox(height: next.continued ? 4 : 10);
                  },
                  itemBuilder: (_, i) => _Bubble(msg: messages[i], senderName: widget.contactName),
                ),
              ),
              _InputBar(
                controller: _ctrl,
                translationOn: translationOn,
                onToggleTranslation: () => setState(() => translationOn = !translationOn),
                onSend: () {
                  // TODO: send via backend
                  _ctrl.clear();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Msg {
  final String text, time;
  final bool isOutgoing, continued;
  _Msg.incoming(this.text, this.time, {this.continued = false}) : isOutgoing = false;
  _Msg.outgoing(this.text, this.time, {this.continued = false}) : isOutgoing = true;
}

class _Header extends StatelessWidget {
  final String name;
  const _Header({required this.name});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      child: GlassContainer(
        borderRadius: BorderRadius.circular(22),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            GlassIconButton(
              icon: Icons.arrow_back_rounded,
              onTap: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 12),
            SCAvatar(initial: name[0], gradientIndex: 2, size: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: SCText.h3),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Container(
                        width: 6, height: 6,
                        decoration: BoxDecoration(
                          color: SC.accent, shape: BoxShape.circle,
                          boxShadow: [BoxShadow(color: SC.accent, blurRadius: 6)],
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text('en ligne', style: SCText.accent.copyWith(fontSize: 11)),
                    ],
                  ),
                ],
              ),
            ),
            GlassIconButton(icon: Icons.phone_rounded),
            const SizedBox(width: 8),
            GlassIconButton(icon: Icons.more_vert_rounded),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final _Msg msg;
  final String senderName;
  const _Bubble({required this.msg, required this.senderName});

  @override
  Widget build(BuildContext context) {
    final isOut = msg.isOutgoing;
    return Align(
      alignment: isOut ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          decoration: BoxDecoration(
            // ⚠️ BULLES OPAQUES — pas de BackdropFilter ici.
            color: isOut ? null : SC.bubbleIn,
            gradient: isOut ? const LinearGradient(
              colors: [Color(0xFF0891B2), Color(0xFF0E7490)],
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ) : null,
            border: Border.all(
              color: isOut ? const Color(0x6622D3EE) : SC.bubbleInBorder,
            ),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(isOut ? 20 : 8),
              topRight: Radius.circular(isOut ? 8 : 20),
              bottomLeft: const Radius.circular(20),
              bottomRight: const Radius.circular(20),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.35),
                blurRadius: 12, offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isOut && !msg.continued) ...[
                Text(senderName, style: SCText.accent),
                const SizedBox(height: 2),
              ],
              Text(
                msg.text,
                style: SCText.body.copyWith(color: Colors.white, fontSize: 15.5),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  msg.time,
                  style: SCText.preview.copyWith(
                    fontSize: 10.5,
                    color: Colors.white.withOpacity(isOut ? .7 : .45),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool translationOn;
  final VoidCallback onToggleTranslation;
  final VoidCallback onSend;
  const _InputBar({
    required this.controller,
    required this.translationOn,
    required this.onToggleTranslation,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 16),
      child: GlassContainer(
        borderRadius: BorderRadius.circular(30),
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Row(
          children: [
            const Icon(Icons.translate_rounded, color: SC.textMuted, size: 20),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onToggleTranslation,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 34, height: 20,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: translationOn ? SC.accent : SC.glassStrong,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: translationOn ? SC.accent : SC.glassBorder,
                  ),
                ),
                alignment: translationOn ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 14, height: 14,
                  decoration: BoxDecoration(
                    color: translationOn ? SC.bg : SC.textMuted,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: controller,
                style: SCText.body,
                cursorColor: SC.accent,
                decoration: InputDecoration(
                  hintText: 'Message',
                  hintStyle: SCText.body.copyWith(color: SC.textMuted),
                  border: InputBorder.none,
                  isCollapsed: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onSend,
              child: Container(
                width: 42, height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [Color(0xFF22D3EE), Color(0xFF0891B2)],
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(color: SC.accent.withOpacity(.5), blurRadius: 14, offset: const Offset(0, 6)),
                  ],
                ),
                child: const Icon(Icons.mic_rounded, color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

---

## 9. Setup global (`main.dart`)

```dart
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark, // iOS
    systemNavigationBarColor: Color(0xFF0A1024),
  ));
  runApp(const SwaycoApp());
}

class SwaycoApp extends StatelessWidget {
  const SwaycoApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        scaffoldBackgroundColor: SC.bg,
        brightness: Brightness.dark,
      ),
      home: const MessagesScreen(),
    );
  }
}
```

---

## 10. Points de wiring backend

| Fichier | Quoi remplacer |
|---|---|
| `messages_screen.dart` `final convos = [...]` | StreamBuilder sur conversations Supabase |
| `discover_screen.dart` `Container(color: SC.bubbleIn)` | `CachedNetworkImage(imageUrl: profile.photoUrl, fit: BoxFit.cover)` |
| `discover_screen.dart` champs `Alice`, `22 · Paris 🇫🇷` | Bind sur profil courant |
| `chat_screen.dart` `final messages = [...]` | Stream messages de la conversation |
| `chat_screen.dart` `onSend` | Service d'envoi (Supabase Realtime / Edge fn) |
| `chat_screen.dart` icons phone / dots / mic | Brancher actions existantes |

---

## 11. Checklist de validation visuelle

Quand Claude Code a fini, vérifie visuellement à l'œil :

- [ ] Le fond a **4 zones de couleur distinctes** (bleu en haut-gauche, violet haut-droit, cyan bas-droit, navy bas-gauche). Pas un seul glow.
- [ ] La liste des messages est **dans un rectangle arrondi avec un effet flou** (on voit le fond mesh à travers).
- [ ] Le bouton "Invite to a call" est **subtil et translucide**, pas un gros bouton plein cyan.
- [ ] Chaque icône téléphone / dots / back est **un petit cercle gris translucide**, pas une icône posée seule.
- [ ] La barre du bas est **un pill large avec effet flou**, état actif **rond blanc plein** avec icône navy à l'intérieur.
- [ ] Le titre "Messages" est en **police arrondie / chunky (Bricolage Grotesque)**, pas une sans-serif standard.
- [ ] Les avatars Alice / Ines / Lenny ont un **gradient** (bleu / violet / cyan), pas des aplats unis.
