import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/chat_api.dart';
import '../theme/swayco_theme.dart';
import 'glass_panel.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Répondre à un message (chat) : bandeau au-dessus du champ, citation dans la
// bulle, glissement vers la droite, menu de l'appui long.
// Les widgets ne connaissent que des données déjà résolues (nom, texte) : la
// logique (qui est cité, où est l'original) reste dans chat_thread_screen.dart.
// ─────────────────────────────────────────────────────────────────────────────

/// Le message cité est un GIF (Giphy) plutôt qu'une photo : l'étiquette change.
bool isGifUrl(String url) {
  final l = url.toLowerCase();
  return l.contains('giphy.') || l.split('?').first.endsWith('.gif');
}

/// `m:ss` ; `0:00` quand la durée est inconnue.
String voiceDuration(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Les 14 barres de la mini-onde d'un vocal cité (2 px, de 4 à 14 de haut).
class _MiniWave extends StatelessWidget {
  const _MiniWave({required this.color});

  final Color color;

  static const _heights = [6, 10, 5, 13, 8, 14, 6, 11, 4, 12, 7, 9, 5, 10];

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (final h in _heights)
          Container(
            width: 2,
            height: h.toDouble(),
            margin: const EdgeInsets.only(right: 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
      ],
    );
  }
}

/// La vignette 36 × 36 d'une photo / d'un GIF cité.
class _QuoteThumb extends StatelessWidget {
  const _QuoteThumb({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 36,
        height: 36,
        child: Image.network(
          url,
          fit: BoxFit.cover,
          cacheWidth: 72,
          errorBuilder: (_, _, _) => ColoredBox(
            color: SC.fgA(0.12),
            child: Icon(Icons.photo_outlined, size: 18, color: SC.fgA(0.5)),
          ),
        ),
      ),
    );
  }
}

/// La « ligne 2 » d'une citation : ce que dit le message cité, selon sa nature
/// (texte, vocal, photo / GIF, supprimé, ou en cours de chargement).
class _QuoteLine extends StatelessWidget {
  const _QuoteLine({
    required this.quoted,
    required this.missing,
    required this.text,
    required this.color,
    required this.fontSize,
    required this.maxLines,
    required this.iconColor,
    required this.barColor,
  });

  final ChatMessage? quoted;
  final bool missing;
  final String text;
  final Color color;
  final double fontSize;
  final int maxLines;
  final Color iconColor;
  final Color barColor;

  @override
  Widget build(BuildContext context) {
    final q = quoted;
    if (missing) {
      return Text(
        AppStrings.t('chat_quote_deleted'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color.withValues(alpha: 0.55 / 0.9),
          fontSize: fontSize,
          fontStyle: FontStyle.italic,
          height: 1.3,
        ),
      );
    }
    if (q == null) {
      // Chargement : deux traits gris, comme le squelette d'une transcription.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final f in const [1.0, 0.6])
            Padding(
              padding: EdgeInsets.only(top: f == 1.0 ? 2 : 5),
              child: FractionallySizedBox(
                widthFactor: f,
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: barColor.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
        ],
      );
    }
    if (q.isVoice) {
      return Row(
        children: [
          Icon(Icons.mic_rounded, size: 17, color: iconColor),
          const SizedBox(width: 6),
          _MiniWave(color: barColor),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '${AppStrings.t('voice_message')} · ${voiceDuration(q.audioDurationMs)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.ibmPlexMono(fontSize: 11.5, color: color),
            ),
          ),
        ],
      );
    }
    if (q.isImage && text.trim().isEmpty) {
      return Row(
        children: [
          Icon(Icons.photo_outlined, size: 17, color: iconColor),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              isGifUrl(q.imageUrl) ? 'GIF' : AppStrings.t('chat_reply_photo'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: fontSize, height: 1.3),
            ),
          ),
        ],
      );
    }
    return Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: color, fontSize: fontSize, height: 1.3),
    );
  }
}

/// Bandeau « RÉPONDRE À AIKO 🇯🇵 » posé au-dessus du champ d'écriture, avec
/// l'extrait du message cité et une croix pour annuler.
class ReplyBar extends StatelessWidget {
  const ReplyBar({
    super.key,
    required this.message,
    required this.label,
    required this.text,
    required this.onCancel,
  });

  /// Le message auquel je réponds.
  final ChatMessage message;

  /// « RÉPONDRE À {PRÉNOM} {drapeau} » (déjà en majuscules).
  final String label;

  /// Ce que je lis du message cité (traduit s'il est étranger).
  final String text;

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    // Le jaune est illisible sur blanc : en clair, le bleu de marque.
    final accent = SC.accentFg;
    final line2 = SC.fg.withValues(alpha: light ? 0.75 : 0.8);
    final hasThumb = message.isImage;
    return GlassPanel(
      borderRadius: 22,
      color: light ? const Color(0xB3FFFFFF) : null,
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(
        children: [
          Icon(Icons.reply_rounded, size: 22, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 11,
                    letterSpacing: 0.5,
                    color: accent,
                  ),
                ),
                const SizedBox(height: 2),
                _QuoteLine(
                  quoted: message,
                  missing: false,
                  text: text,
                  color: line2,
                  fontSize: 13.5,
                  maxLines: 1,
                  iconColor: SC.fg.withValues(alpha: light ? 0.7 : 0.85),
                  barColor: SC.fg.withValues(alpha: light ? 0.45 : 0.6),
                ),
              ],
            ),
          ),
          if (hasThumb) ...[
            const SizedBox(width: 8),
            _QuoteThumb(url: message.imageUrl),
          ],
          const SizedBox(width: 8),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onCancel,
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: light
                    ? SC.bgDeep.withValues(alpha: 0.08)
                    : Colors.white.withValues(alpha: 0.14),
              ),
              child: Icon(Icons.close_rounded, size: 18, color: SC.fg),
            ),
          ),
        ],
      ),
    );
  }
}

/// La citation DANS une bulle : prénom (+ drapeau), puis le message cité.
/// Envoyée = fond bleu foncé translucide, prénom en jaune ; reçue = fond neutre.
class QuoteBlock extends StatelessWidget {
  const QuoteBlock({
    super.key,
    required this.mine,
    required this.name,
    required this.quoted,
    required this.missing,
    required this.text,
    required this.onTap,
  });

  /// La bulle qui porte la citation est la mienne.
  final bool mine;

  /// « AIKO 🇯🇵 » ou « MOI », déjà en majuscules.
  final String name;

  final ChatMessage? quoted;
  final bool missing;
  final String text;

  /// Toucher la citation remonte à l'original (null = sans effet).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color nameColor;
    final Color textColor;
    if (mine) {
      bg = const Color(0x5904123A); // rgba(4,18,58,.35)
      nameColor = SC.accent;
      textColor = Colors.white.withValues(alpha: 0.9);
    } else {
      bg = SC.light
          ? SC.textPrimary.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.22);
      nameColor = SC.accentFg;
      textColor = SC.msgInText.withValues(alpha: 0.8);
    }
    final q = quoted;
    final thumb = q != null && q.isImage;
    return GestureDetector(
      onTap: missing ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(13),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 10.5,
                      letterSpacing: 0.5,
                      color: nameColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  _QuoteLine(
                    quoted: q,
                    missing: missing,
                    text: text,
                    color: textColor,
                    fontSize: 13,
                    maxLines: 2,
                    iconColor: textColor,
                    barColor: textColor.withValues(alpha: mine ? 0.75 : 0.6),
                  ),
                ],
              ),
            ),
            if (thumb) ...[
              const SizedBox(width: 8),
              _QuoteThumb(url: q.imageUrl),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Glissement vers la droite ────────────────────────────────────────────────

/// Un glissement HORIZONTAL qui ne prend la main que vers la DROITE, et pas
/// depuis le bord gauche de l'écran. Vers la gauche il se retire de l'arène :
/// c'est la page du chat qui se ferme au doigt (balayage vers la gauche), un
/// simple GestureDetector lui volerait ce geste. Le bord gauche (24 px) reste
/// au retour arrière d'iOS.
class _RightDragRecognizer extends HorizontalDragGestureRecognizer {
  _RightDragRecognizer({super.debugOwner});

  static const double _edgeDeadZone = 24;

  Offset? _down;
  bool _claimed = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (event.position.dx < _edgeDeadZone) return;
    _down = event.position;
    _claimed = false;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    final down = _down;
    if (!_claimed && event is PointerMoveEvent && down != null) {
      if (event.position.dx - down.dx < -6) {
        resolvePointer(event.pointer, GestureDisposition.rejected);
        return;
      }
    }
    super.handleEvent(event);
  }

  @override
  void acceptGesture(int pointer) {
    _claimed = true;
    super.acceptGesture(pointer);
  }
}

/// Enveloppe une bulle : la tirer vers la droite fait apparaître une icône
/// « répondre » à gauche ; au-delà de 64 px elle passe au jaune (un retour
/// haptique) et relâcher déclenche [onReply]. La bulle revient en 220 ms.
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({
    super.key,
    required this.enabled,
    required this.onReply,
    required this.child,
  });

  final bool enabled;
  final VoidCallback onReply;
  final Widget child;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  static const double _threshold = 64;
  static const double _maxShift = 96;

  // Créé dans initState : un `late final` paresseux n'existerait pas encore si
  // le glissement est désactivé, et naîtrait au dispose (ancêtre introuvable).
  late final AnimationController _back;

  @override
  void initState() {
    super.initState();
    _back = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(_onBack);
  }

  /// Distance brute du doigt, puis déplacement visuel (avec résistance).
  double _raw = 0;
  double _x = 0;
  double _from = 0;
  bool _armed = false;

  double _shiftFor(double raw) {
    final x = raw <= _threshold ? raw : _threshold + (raw - _threshold) * 0.25;
    return math.min(x, _maxShift);
  }

  void _onBack() {
    final t = Curves.easeOutBack.transform(_back.value);
    setState(() => _x = _from * (1 - t));
  }

  void _start(DragStartDetails _) {
    _back.stop();
    _raw = _x;
    _armed = _x >= _threshold;
  }

  void _update(DragUpdateDetails d) {
    _raw = math.max(0, _raw + d.delta.dx);
    final x = _shiftFor(_raw);
    final armed = x >= _threshold;
    if (armed && !_armed) HapticFeedback.selectionClick();
    _armed = armed;
    setState(() => _x = x);
  }

  void _release({required bool fire}) {
    final fired = fire && _x >= _threshold;
    _from = _x;
    _raw = 0;
    _armed = false;
    _back.forward(from: 0);
    if (fired) widget.onReply();
  }

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final p = (_x / _threshold).clamp(0.0, 1.0);
    final armed = _x >= _threshold;
    final light = SC.light;
    final size = armed ? 40.0 : 38.0;
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        _RightDragRecognizer:
            GestureRecognizerFactoryWithHandlers<_RightDragRecognizer>(
          () => _RightDragRecognizer(debugOwner: this),
          (r) {
            r.onStart = _start;
            r.onUpdate = _update;
            r.onEnd = (_) => _release(fire: true);
            r.onCancel = () => _release(fire: false);
          },
        ),
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (_x > 0.5)
            Positioned(
              left: 6,
              top: 0,
              bottom: 0,
              child: Center(
                child: Opacity(
                  opacity: (0.75 + 0.25 * p).clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: 0.82 + 0.18 * p,
                    child: Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: armed
                            ? SC.accent
                            : (light
                                ? Colors.white.withValues(alpha: 0.85)
                                : Colors.white.withValues(alpha: 0.13)),
                        border: armed
                            ? null
                            : Border.all(
                                color: light
                                    ? SC.brandBlueDeep.withValues(alpha: 0.30)
                                    : Colors.white.withValues(alpha: 0.28),
                                width: 1.2,
                              ),
                        boxShadow: armed
                            ? [
                                BoxShadow(
                                  color: SC.accent.withValues(alpha: 0.18),
                                  spreadRadius: 6,
                                ),
                                BoxShadow(
                                  color: SC.accent.withValues(alpha: 0.35),
                                  blurRadius: 22,
                                  offset: const Offset(0, 8),
                                ),
                              ]
                            : null,
                      ),
                      child: Icon(
                        Icons.reply_rounded,
                        size: armed ? 23 : 22,
                        color: armed
                            ? SC.onAccent
                            : (light ? SC.bgDeep : Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Transform.translate(offset: Offset(_x, 0), child: widget.child),
        ],
      ),
    );
  }
}

// ── Menu de l'appui long ─────────────────────────────────────────────────────

enum ChatMenuKind { reply, normal, danger }

class ChatMenuItem {
  const ChatMenuItem({
    required this.label,
    required this.icon,
    required this.onTap,
    this.kind = ChatMenuKind.normal,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final ChatMenuKind kind;
}

/// Le menu sous la bulle : Répondre, Voir l'original, Copier, Supprimer ou
/// Signaler. Verre blanc 14 % (sombre) / blanc 85 % (clair).
class ChatActionMenu extends StatelessWidget {
  const ChatActionMenu({super.key, required this.items});

  static const double width = 236;
  static const double rowHeight = 50;

  /// Hauteur de la liste telle qu'elle sera dessinée (pour la placer).
  static double heightFor(int count) => rowHeight * count + (count - 1);

  final List<ChatMenuItem> items;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    final danger = light ? const Color(0xFFE5484D) : const Color(0xFFFF6B6B);
    final sep = light
        ? SC.brandBlueDeep.withValues(alpha: 0.14)
        : Colors.white.withValues(alpha: 0.12);
    // Dans un Overlay : sans Material, le texte hériterait du soulignement jaune.
    return Material(
      type: MaterialType.transparency,
      child: ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          width: width,
          decoration: BoxDecoration(
            color: light
                ? Colors.white.withValues(alpha: 0.85)
                : Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: light
                  ? SC.brandBlueDeep.withValues(alpha: 0.20)
                  : Colors.white.withValues(alpha: 0.24),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: light
                    ? SC.bgDeep.withValues(alpha: 0.35)
                    : Colors.black.withValues(alpha: 0.45),
                blurRadius: 40,
                spreadRadius: light ? -12 : 0,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) Container(height: 1, color: sep),
                _row(items[i], danger),
              ],
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _row(ChatMenuItem it, Color danger) {
    final reply = it.kind == ChatMenuKind.reply;
    final isDanger = it.kind == ChatMenuKind.danger;
    final color = reply ? SC.accentFg : (isDanger ? danger : SC.textPrimary);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: it.onTap,
      child: Container(
        height: rowHeight,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: reply
            ? (SC.light
                ? SC.brandBlueDeep.withValues(alpha: 0.10)
                : SC.accent.withValues(alpha: 0.12))
            : null,
        child: Row(
          children: [
            Expanded(
              child: Text(
                it.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 15,
                  fontWeight: reply ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ),
            Icon(it.icon, size: 22, color: color),
          ],
        ),
      ),
    );
  }
}

/// Le voile derrière le menu : flou 10 et teinte sombre / claire, avec un TROU
/// à l'emplacement de la bulle — elle reste nette, « soulevée » au-dessus.
class MenuVeil extends StatelessWidget {
  const MenuVeil({super.key, required this.hole, required this.onTap});

  final Rect hole;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ClipPath(
          clipper: _HoleClipper(hole),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: ColoredBox(
              color: SC.light
                  ? const Color(0x9EECF1FC) // #ECF1FC à 62 %
                  : const Color(0x8C050814), // #050814 à 55 %
            ),
          ),
        ),
      ),
    );
  }
}

class _HoleClipper extends CustomClipper<Path> {
  _HoleClipper(this.hole);

  final Rect hole;

  @override
  Path getClip(Size size) {
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(hole, const Radius.circular(20)));
  }

  @override
  bool shouldReclip(_HoleClipper old) => old.hole != hole;
}
