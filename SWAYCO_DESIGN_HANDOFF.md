# Swayco — Design Handoff (Flutter)

> **Direction visuelle :** Midnight — fond mesh navy/violet/cyan, surfaces en verre style Apple, accent cyan.
> **Écrans inclus :** Messages, Discover, Chat (avec Lenny).
> **Police :** Bricolage Grotesque (titres) + DM Sans (corps).
>
> Ne touche pas au backend. Branche juste l'UI sur les modèles existants. Les `TODO:` indiquent les points de wiring.

---

## 1. Dependencies

Ajoute dans `pubspec.yaml` :

```yaml
dependencies:
  flutter:
    sdk: flutter
  google_fonts: ^6.2.1
  cached_network_image: ^3.4.1  # pour les photos de profil
```

Puis `flutter pub get`.

---

## 2. `lib/theme/swayco_theme.dart`

```dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Palette Midnight — navy profond + cyan + violet
class SC {
  // Backgrounds
  static const bg            = Color(0xFF0A1024); // base navy
  static const bgDeep        = Color(0xFF050817);

  // Mesh halo colors (utilisés dans MeshBackground)
  static const meshBlue      = Color(0xFF3B82F6); // top-left
  static const meshViolet    = Color(0xFF7C3AED); // top-right
  static const meshCyan      = Color(0xFF06B6D4); // bottom-right
  static const meshNavy      = Color(0xFF1E40AF); // bottom-left

  // Accent
  static const accent        = Color(0xFF22D3EE); // cyan-400
  static const accentDeep    = Color(0xFF0891B2);

  // Text
  static const textPrimary   = Color(0xFFF5F7FF);
  static const textSecondary = Color(0xB3F5F7FF); // 70%
  static const textMuted     = Color(0x80F5F7FF); // 50%

  // Surfaces
  static const bubbleIn      = Color(0xFF1A2138); // bulle entrante opaque
  static const bubbleInBorder = Color(0x14FFFFFF);

  // Glass
  static const glass         = Color(0x0FFFFFFF); // white 6%
  static const glassStrong   = Color(0x1AFFFFFF); // white 10%
  static const glassBorder   = Color(0x1AFFFFFF); // white 10%
  static const glassBorderStrong = Color(0x33FFFFFF); // white 20%

  // Avatars (gradients prédéfinis — randomiser sur first letter par ex.)
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
    fontSize: 36, fontWeight: FontWeight.w800,
    letterSpacing: -1.2, color: SC.textPrimary, height: 1.05,
  );
  static TextStyle h2 = GoogleFonts.bricolageGrotesque(
    fontSize: 22, fontWeight: FontWeight.w700,
    letterSpacing: -0.4, color: SC.textPrimary,
  );
  static TextStyle h3 = GoogleFonts.bricolageGrotesque(
    fontSize: 18, fontWeight: FontWeight.w700,
    letterSpacing: -0.2, color: SC.textPrimary,
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
    fontSize: 16, fontWeight: FontWeight.w800, color: SC.bg,
  );
  static TextStyle accent = GoogleFonts.dmSans(
    fontSize: 12, fontWeight: FontWeight.w700, color: SC.accent,
  );
}
```

---

## 3. `lib/widgets/mesh_background.dart`

Flutter n'a pas de mesh gradient natif → on stack 4 RadialGradient.

```dart
import 'package:flutter/material.dart';
import '../theme/swayco_theme.dart';

class MeshBackground extends StatelessWidget {
  final Widget child;
  const MeshBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: SC.bg,
      child: Stack(
        children: [
          // Halo top-left (blue)
          _halo(alignment: const Alignment(-1, -1), color: SC.meshBlue, radius: 0.9),
          // Halo top-right (violet)
          _halo(alignment: const Alignment(1, -1), color: SC.meshViolet, radius: 0.8),
          // Halo bottom-right (cyan)
          _halo(alignment: const Alignment(1, 1), color: SC.meshCyan, radius: 0.9),
          // Halo bottom-left (deep navy)
          _halo(alignment: const Alignment(-1, 1), color: SC.meshNavy, radius: 1.0),
          // Slight darken vignette for legibility
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                radius: 1.2,
                colors: [Colors.transparent, Color(0x33000000)],
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }

  Widget _halo({required Alignment alignment, required Color color, required double radius}) {
    return Align(
      alignment: alignment,
      child: FractionallySizedBox(
        widthFactor: radius,
        heightFactor: radius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              colors: [color.withOpacity(0.55), color.withOpacity(0)],
              stops: const [0.0, 1.0],
            ),
          ),
        ),
      ),
    );
  }
}
```

---

## 4. `lib/widgets/glass.dart`

Composants verre réutilisables.

```dart
import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/swayco_theme.dart';

/// Conteneur "verre Apple" — blur + bg semi-transparent + border subtile
class GlassContainer extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final Color? color;
  final Color? border;
  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.padding,
    this.blur = 24,
    this.color,
    this.border,
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
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Bouton icône rond en verre
class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  const GlassIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 40,
    this.iconSize = 20,
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

/// Avatar circulaire avec gradient (ou photo si fournie)
class SCAvatar extends StatelessWidget {
  final String? photoUrl;
  final String initial;
  final double size;
  final int gradientIndex;
  const SCAvatar({
    super.key,
    this.photoUrl,
    required this.initial,
    this.size = 48,
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
                fontSize: size * 0.4,
              ),
            ),
          ),
    );
  }
}
```

---

## 5. `lib/screens/messages_screen.dart`

```dart
import 'package:flutter/material.dart';
import '../theme/swayco_theme.dart';
import '../widgets/mesh_background.dart';
import '../widgets/glass.dart';

class MessagesScreen extends StatelessWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // TODO: remplacer par les vraies conversations depuis ton backend
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
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Messages', style: SCText.h1),
                ),
              ),

              // Liste verre
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

              // Invite to a call
              Padding(
                padding: const EdgeInsets.all(18),
                child: SizedBox(
                  width: double.infinity,
                  child: GlassContainer(
                    borderRadius: BorderRadius.circular(22),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    color: SC.glassStrong,
                    border: SC.glassBorderStrong,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.videocam_rounded, color: SC.textPrimary, size: 22),
                        const SizedBox(width: 10),
                        Text(
                          'Invite to a call',
                          style: SCText.body.copyWith(fontWeight: FontWeight.w800, fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const Spacer(),

              // Bottom nav glass
              const _GlassTabBar(activeIndex: 0),
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

class _GlassTabBar extends StatelessWidget {
  final int activeIndex;
  const _GlassTabBar({required this.activeIndex});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
      child: GlassContainer(
        borderRadius: BorderRadius.circular(999),
        padding: const EdgeInsets.all(6),
        child: Row(
          children: [
            _tab(icon: Icons.chat_bubble_outline_rounded, active: activeIndex == 0),
            _tab(icon: Icons.search_rounded,              active: activeIndex == 1),
            _tab(icon: Icons.person_outline_rounded,      active: activeIndex == 2),
          ],
        ),
      ),
    );
  }

  Widget _tab({required IconData icon, required bool active}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: active ? SC.textPrimary : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Icon(
          icon,
          color: active ? SC.bg : SC.textMuted,
          size: 22,
        ),
      ),
    );
  }
}
```

---

## 6. `lib/screens/discover_screen.dart`

```dart
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/swayco_theme.dart';
import '../widgets/mesh_background.dart';
import '../widgets/glass.dart';

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
              // Header row
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text('Discover', style: SCText.h1),
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
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: SC.glassBorderStrong, width: 1),
                        borderRadius: BorderRadius.circular(30),
                        boxShadow: [
                          BoxShadow(
                            color: SC.meshCyan.withOpacity(0.3),
                            blurRadius: 60, offset: const Offset(0, 30),
                          ),
                        ],
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // TODO: remplacer par CachedNetworkImage avec l'URL de la photo
                          // CachedNetworkImage(imageUrl: profile.photoUrl, fit: BoxFit.cover),
                          Container(color: SC.bubbleIn), // placeholder
                          // Gradient fade bas
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
                          // Name block
                          Positioned(
                            left: 22, right: 22, bottom: 22,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Alice',
                                        style: SCText.h1.copyWith(fontSize: 34, color: Colors.white),
                                      ),
                                      Text(
                                        '22 · Paris 🇫🇷',
                                        style: SCText.preview.copyWith(color: Colors.white70, fontSize: 13),
                                      ),
                                      const SizedBox(height: 10),
                                      // Send pill
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
                                // Heart button glass
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
              ),

              const Spacer(),

              // Bottom nav (re-use _GlassTabBar from messages_screen — extract to a shared file)
              const SizedBox.shrink(),
            ],
          ),
        ),
      ),
    );
  }
}
```

> ⚠️ **À factoriser :** extrais `_GlassTabBar` de `messages_screen.dart` vers `lib/widgets/glass_tab_bar.dart` et réutilise-la ici. Passe `activeIndex: 1` pour Discover.

---

## 7. `lib/screens/chat_screen.dart`

Bulles **opaques** (pas de glass) mais header + input + boutons en verre.

```dart
import 'package:flutter/material.dart';
import '../theme/swayco_theme.dart';
import '../widgets/mesh_background.dart';
import '../widgets/glass.dart';

class ChatScreen extends StatefulWidget {
  final String contactName; // ex: "Lenny"
  const ChatScreen({super.key, this.contactName = 'Lenny'});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  bool translationOn = false;

  @override
  Widget build(BuildContext context) {
    // TODO: remplacer par les vrais messages depuis ton backend
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
                    final next = messages[i + 1 < messages.length ? i + 1 : i];
                    return SizedBox(height: next.continued ? 4 : 10);
                  },
                  itemBuilder: (_, i) => _Bubble(msg: messages[i], senderName: widget.contactName),
                ),
              ),
              _InputBar(
                translationOn: translationOn,
                onToggleTranslation: () => setState(() => translationOn = !translationOn),
                onSend: (text) {
                  // TODO: send message via backend
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
            GlassIconButton(icon: Icons.phone_rounded, onTap: () {/* TODO: call */}),
            const SizedBox(width: 8),
            GlassIconButton(icon: Icons.more_vert_rounded, onTap: () {/* TODO: menu */}),
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
            // Bulles OPAQUES (pas de blur)
            color: isOut ? null : SC.bubbleIn,
            gradient: isOut ? const LinearGradient(
              colors: [Color(0xFF0891B2), Color(0xFF0E7490)],
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ) : null,
            border: Border.all(
              color: isOut ? SC.accent.withOpacity(.4) : SC.bubbleInBorder,
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
                style: SCText.body.copyWith(
                  color: Colors.white,
                  fontSize: 15.5,
                ),
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
  final bool translationOn;
  final VoidCallback onToggleTranslation;
  final void Function(String) onSend;
  const _InputBar({
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
            Icon(Icons.translate_rounded, color: SC.textMuted, size: 20),
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
                style: SCText.body,
                cursorColor: SC.accent,
                decoration: InputDecoration(
                  hintText: 'Message',
                  hintStyle: SCText.body.copyWith(color: SC.textMuted),
                  border: InputBorder.none,
                  isCollapsed: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
                onSubmitted: onSend,
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () {/* TODO: voice recording */},
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

## 8. Wiring — points de branchement avec le backend

Tout ce qui est marqué `TODO:` :

| Fichier | Ligne | À faire |
|---|---|---|
| `messages_screen.dart` | `final convos = [...]` | Remplacer par un `StreamBuilder`/`FutureBuilder` sur ton service de conversations Supabase. |
| `discover_screen.dart` | `Container(color: SC.bubbleIn)` | Remplacer par `CachedNetworkImage(imageUrl: profile.photoUrl, fit: BoxFit.cover)`. |
| `discover_screen.dart` | `Text('Alice')` etc | Binder sur le profil courant du stream. |
| `chat_screen.dart` | `final messages = [...]` | Brancher sur le stream de messages de la conversation. |
| `chat_screen.dart` | `onSubmitted: onSend` | Appeler ton service d'envoi (Supabase Realtime / Edge function). |
| `chat_screen.dart` | bouton phone / dots / mic | Brancher sur les actions existantes. |

---

## 9. Notes de finition

- **`SystemUiOverlayStyle`** : dans `main.dart`, force la status bar claire :
  ```dart
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark, // iOS
  ));
  ```
- **`MaterialApp`** : `theme: ThemeData(scaffoldBackgroundColor: SC.bg, brightness: Brightness.dark)`.
- **Hero / nav** : utilise `PageRouteBuilder` avec un fade léger entre Messages → Chat pour préserver l'ambiance.
- **Performance** : `BackdropFilter` coûte cher. Si tu vois des chutes de framerate sur Android bas de gamme, remplace `MeshBackground` par un PNG exporté et garde les `BackdropFilter` uniquement sur header / input / nav.

---

## 10. Checklist avant merge

- [ ] `flutter pub get` après ajout de `google_fonts` + `cached_network_image`
- [ ] `theme.dart` créé et importé partout (`SC.*`, `SCText.*`)
- [ ] `MeshBackground`, `GlassContainer`, `GlassIconButton`, `SCAvatar` dans `lib/widgets/`
- [ ] `_GlassTabBar` extrait en widget partagé
- [ ] 3 écrans (Messages, Discover, Chat) câblés au backend existant
- [ ] Status bar passée en mode clair
- [ ] Testé sur iPhone 13 + Pixel 5 (a minima)
