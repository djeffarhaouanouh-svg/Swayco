import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/activity_signal.dart';
import '../services/app_strings.dart';
import '../services/muted_calls.dart';
import '../services/peer_local_time.dart';
import '../services/presence_service.dart';
import '../services/profile_api.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart' show popupDisplay;
import 'profile_avatar.dart' show ProfileAvatar, profileFlagIso;

// Handoff « messages_bulles » : la rangée « Friends » de la page Messages (les
// amis EN LIGNE), les états d'activité sur la bulle et le menu d'appui long.

const Color _kYellow = Color(0xFFF4FF1F);
const Color _kNavy = Color(0xFF04123A);
const Color _kOrange = Color(0xFFFF9F43);
const Color _kRed = Color(0xFFFF6B6B);
const double _kBubble = 58;

/// La rangée de bulles : titre « Friends » + compteur, puis les amis en ligne.
/// Une personne qui se connecte entre en PREMIÈRE place (les autres glissent),
/// une qui se déconnecte sort en fondu. Rien du tout quand personne n'est là.
class OnlineBubblesRow extends StatefulWidget {
  const OnlineBubblesRow({
    super.key,
    required this.friends,
    this.lastTalk = const {},
    required this.myId,
    required this.onMessage,
    required this.onCall,
    required this.onProfile,
    required this.onToggleMute,
    required this.onBlockReport,
  });

  /// Tous mes amis : la rangée garde ceux qui sont en ligne ([isPeerOnline]).
  final List<RemoteProfile> friends;

  /// Date du dernier message échangé avec chaque ami (id → date) : classe les
  /// amis hors ligne.
  final Map<String, DateTime> lastTalk;
  final String myId;
  final void Function(RemoteProfile) onMessage;
  final void Function(RemoteProfile) onCall;
  final void Function(RemoteProfile) onProfile;
  final void Function(RemoteProfile) onToggleMute;
  final void Function(RemoteProfile) onBlockReport;

  @override
  State<OnlineBubblesRow> createState() => _OnlineBubblesRowState();
}

class _OnlineBubblesRowState extends State<OnlineBubblesRow> {
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  late final List<RemoteProfile> _shown = _initial();

  List<RemoteProfile> _initial() {
    final online = [for (final p in _ordered(widget.friends)) if (isPeerOnline(p)) p];
    final offline = [for (final p in widget.friends) if (!isPeerOnline(p)) p]
      ..sort((a, b) => (b.lastSeen ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(a.lastSeen ?? DateTime.fromMillisecondsSinceEpoch(0)));
    return [...online, ...offline];
  }

  /// TOUS mes amis : les personnes EN LIGNE d'abord (connexion la plus récente
  /// en tête), puis les autres, dans l'ordre de leur dernier passage.
  static List<RemoteProfile> _ordered(List<RemoteProfile> all) {
    DateTime seen(RemoteProfile p) =>
        p.lastSeen ?? DateTime.fromMillisecondsSinceEpoch(0);
    final out = [...all];
    out.sort((a, b) {
      final oa = isPeerOnline(a);
      final ob = isPeerOnline(b);
      if (oa != ob) return oa ? -1 : 1;
      return seen(b).compareTo(seen(a));
    });
    return out;
  }

  /// Ceux qui étaient en ligne au dernier tour : sert à repérer qui VIENT de se
  /// connecter (il passe devant) sans que le simple battement de présence
  /// (last_seen rafraîchi toutes les 90 s) ne mélange l'ordre des autres.
  late Set<String> _onlineIds = {
    for (final p in widget.friends)
      if (isPeerOnline(p)) p.id,
  };

  int get _onlineCount => _shown.where(isPeerOnline).length;

  @override
  void didUpdateWidget(OnlineBubblesRow old) {
    super.didUpdateWidget(old);
    final base = _ordered(widget.friends);
    final nowOnline = {for (final p in base) if (isPeerOnline(p)) p.id};
    final justArrived = nowOnline.difference(_onlineIds);
    // Devant : ceux qui viennent d'arriver (le plus récent d'abord). Puis ceux
    // déjà là, dans l'ordre où ils étaient. Enfin les hors ligne.
    final pos = {for (var i = 0; i < _shown.length; i++) _shown[i].id: i};
    final arrived = [for (final p in base) if (justArrived.contains(p.id)) p];
    final stayed = [
      for (final p in base)
        if (nowOnline.contains(p.id) && !justArrived.contains(p.id)) p,
    ]..sort((a, b) => (pos[a.id] ?? 1 << 30).compareTo(pos[b.id] ?? 1 << 30));
    // Hors ligne : par dernière connexion (la plus récente d'abord).
    final offline = [for (final p in base) if (!nowOnline.contains(p.id)) p]
      ..sort((a, b) => (b.lastSeen ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(a.lastSeen ?? DateTime.fromMillisecondsSinceEpoch(0)));
    final target = [...arrived, ...stayed, ...offline];
    _onlineIds = nowOnline;
    final byId = {for (final p in target) p.id: p};

    // Plus mes amis : fondu, la file se referme.
    for (var i = _shown.length - 1; i >= 0; i--) {
      final gone = _shown[i];
      if (byId.containsKey(gone.id)) continue;
      _shown.removeAt(i);
      _listKey.currentState?.removeItem(
        i,
        (ctx, anim) => FadeTransition(
          opacity: anim,
          child: SizeTransition(
            axis: Axis.horizontal,
            sizeFactor: anim,
            child: _slot(gone),
          ),
        ),
        duration: const Duration(milliseconds: 200),
      );
    }
    // Remet chacun à sa place. Quelqu'un qui se connecte (ou qui part) change
    // de place : il glisse à sa nouvelle position (280 ms), les autres se
    // décalent d'un cran.
    for (var i = 0; i < target.length; i++) {
      final want = target[i];
      if (i < _shown.length && _shown[i].id == want.id) {
        _shown[i] = want; // profil rafraîchi (heure, ville…)
        continue;
      }
      final j = _shown.indexWhere((p) => p.id == want.id);
      if (j >= 0) {
        final moved = _shown.removeAt(j);
        _listKey.currentState?.removeItem(
          j,
          (ctx, anim) => _slot(moved),
          duration: Duration.zero,
        );
      }
      _shown.insert(i, want);
      _listKey.currentState?.insertItem(
        i,
        duration: const Duration(milliseconds: 280),
      );
    }
    setState(() {});
  }
  Widget _slot(RemoteProfile p) => Padding(
        padding: const EdgeInsets.only(right: 10),
        child: _Bubble(
          key: ValueKey('bubble-${p.id}'),
          profile: p,
          myId: widget.myId,
          onTap: () => widget.onMessage(p),
          onLongPress: (rect) => _openMenu(p, rect),
        ),
      );

  void _openMenu(RemoteProfile p, Rect rect) {
    HapticFeedback.mediumImpact();
    Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 180),
        reverseTransitionDuration: const Duration(milliseconds: 140),
        pageBuilder: (ctx, anim, _) => _BubbleMenu(
          profile: p,
          myId: widget.myId,
          rect: rect,
          animation: anim,
          onMessage: widget.onMessage,
          onCall: widget.onCall,
          onProfile: widget.onProfile,
          onToggleMute: widget.onToggleMute,
          onBlockReport: widget.onBlockReport,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Même style que les titres de section de la page.
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                AppStrings.t('friends_section').toUpperCase(),
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.1,
                  color: SC.fg.withValues(alpha: 0.45),
                ),
              ),
              if (_onlineCount > 0) const SizedBox(width: 8),
              if (_onlineCount > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: SC.accent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$_onlineCount',
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: SC.onAccent,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_shown.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
            child: Text(
              AppStrings.t('friends_none_online'),
              style: TextStyle(
                color: SC.fg.withValues(alpha: 0.5),
                fontSize: 14,
              ),
            ),
          )
        else
        SizedBox(
          height: _kBubble + 6 + 16 + 20,
          child: AnimatedList(
            key: _listKey,
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            // Marge en bout de file et en haut : le dernier drapeau / badge ne
            // doit jamais être rogné par le bord de la liste.
            padding: const EdgeInsets.fromLTRB(8, 6, 24, 6),
            initialItemCount: _shown.length,
            itemBuilder: (ctx, i, anim) {
              if (i >= _shown.length) return const SizedBox.shrink();
              return FadeTransition(
                opacity: anim,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.8, end: 1).animate(
                    CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                  ),
                  child: SizeTransition(
                    axis: Axis.horizontal,
                    sizeFactor: CurvedAnimation(
                      parent: anim,
                      curve: Curves.easeOutCubic,
                    ),
                    child: _slot(_shown[i]),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }
}

/// Une bulle : photo ronde, drapeau, badge d'activité, heure locale dessous.
class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.profile,
    required this.myId,
    required this.onTap,
    required this.onLongPress,
  });

  final RemoteProfile profile;
  final String myId;
  final VoidCallback onTap;
  final void Function(Rect globalRect) onLongPress;

  @override
  Widget build(BuildContext context) {
    final photoKey = GlobalKey();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: () {
        final box = photoKey.currentContext?.findRenderObject() as RenderBox?;
        if (box == null || !box.attached) return;
        final topLeft = box.localToGlobal(Offset.zero);
        onLongPress(topLeft & box.size);
      },
      child: SizedBox(
        width: _kBubble + 12,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 4),
            ValueListenableBuilder<int>(
              valueListenable: ActivitySignal.revision,
              builder: (_, _, _) => BubbleFace(
                key: photoKey,
                profile: profile,
                activity: ActivitySignal.of(profile.id, myId),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(height: 16, child: _LocalClock(profile: profile)),
          ],
        ),
      ),
    );
  }
}

/// L'heure locale de l'ami sous sa bulle, seulement s'il a été vu dans les 24
/// dernières heures. Elle se met à jour TOUTE SEULE (toutes les 15 s) : avant,
/// elle ne se recalculait que quand la page se redessinait, et restait figée.
class _LocalClock extends StatefulWidget {
  const _LocalClock({required this.profile});

  final RemoteProfile profile;

  @override
  State<_LocalClock> createState() => _LocalClockState();
}

class _LocalClockState extends State<_LocalClock> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
      const Duration(seconds: 15),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final seen = p.lastSeen;
    final recent = seen != null &&
        DateTime.now().difference(seen) < const Duration(hours: 24);
    final clock = recent
        ? resolvePeerLocalTime(city: p.city, country: p.country)
        : null;
    return Text(
      clock?.hhmm ?? '',
      maxLines: 1,
      style: GoogleFonts.ibmPlexMono(
        fontSize: 11,
        color: SC.fg.withValues(alpha: 0.65),
      ),
    );
  }
}

/// La photo + le drapeau + le badge d'état : réutilisée par la rangée et par la
/// bulle soulevée du menu.
class BubbleFace extends StatelessWidget {
  const BubbleFace({
    super.key,
    required this.profile,
    required this.activity,
    this.ring = false,
  });

  final RemoteProfile profile;
  final PeerActivity? activity;

  /// Anneau blanc 2 px (90 %) de la bulle soulevée.
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final iso = profileFlagIso(
      country: profile.country,
      language: profile.language,
    );
    final popular = profile.isPro || profile.isPlus;
    // La photo, ou à défaut la lettre du prénom sur une couleur (comme partout
    // ailleurs dans l'app) : jamais un rond gris vide.
    Widget photo({double size = _kBubble}) => ProfileAvatar(
          displayName: profile.displayName.isNotEmpty
              ? profile.displayName
              : profile.handle,
          avatarUrl: profile.avatarUrl,
          fallbackUrl: profile.fallbackPhotoUrl,
          size: size,
        );
    return SizedBox(
      width: _kBubble,
      height: _kBubble,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (popular)
            // Profil Pro / Plus : l'anneau jaune autour de la PHOTO seule (jamais
            // autour du drapeau), liseré de la couleur du fond, lueur discrète.
            Container(
              width: _kBubble,
              height: _kBubble,
              padding: const EdgeInsets.all(_kBubble * 0.04),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: SC.bg,
                border: Border.all(color: _kYellow, width: _kBubble * 0.05),
                boxShadow: [
                  BoxShadow(
                    color: _kYellow.withValues(alpha: 0.16),
                    blurRadius: _kBubble * 0.16,
                  ),
                ],
              ),
              child: ClipOval(child: photo(size: _kBubble * 0.82)),
            )
          else
            Container(
              width: _kBubble,
              height: _kBubble,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF3A3A40),
                border: ring
                    ? Border.all(
                        color: Colors.white.withValues(alpha: 0.9),
                        width: 2,
                      )
                    : null,
                boxShadow: ring
                    ? const [
                        BoxShadow(
                          color: Color(0x8C000000),
                          blurRadius: 34,
                          offset: Offset(0, 14),
                        ),
                      ]
                    : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: photo(),
            ),          if (iso.isNotEmpty)
            Positioned(
              right: -4,
              bottom: -3,
              child: Container(
                width: 24,
                height: 24,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: SC.bg,
                  shape: BoxShape.circle,
                ),
                child: ClipOval(
                  child: Image.network(
                    'https://flagcdn.com/w80/${iso.toLowerCase()}.png',
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const ColoredBox(color: Color(0xFFE5E7EB)),
                  ),
                ),
              ),
            ),
          if (activity != null)
            Positioned(
              left: activity == PeerActivity.typing ? -2 : -4,
              top: activity == PeerActivity.typing ? -8 : -3,
              child: ActivityBadge(kind: activity!),
            ),
        ],
      ),
    );
  }
}

/// Le badge d'état : appel (téléphone qui tremble 3 fois), écrit (3 points qui
/// rebondissent), Discover (œil qui s'ouvre et se ferme).
class ActivityBadge extends StatelessWidget {
  const ActivityBadge({super.key, required this.kind});

  final PeerActivity kind;

  @override
  Widget build(BuildContext context) {
    final border = Border.all(color: SC.bg, width: 2);
    switch (kind) {
      case PeerActivity.call:
        return Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: _kYellow,
            shape: BoxShape.circle,
            border: border,
          ),
          child: const Center(child: _ShakingPhone()),
        );
      case PeerActivity.typing:
        return Container(
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: border,
          ),
          child: const Center(child: _BouncingDots()),
        );
      case PeerActivity.discover:
        return Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: border,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1F5EFF), Color(0xFF18DDEA)],
            ),
          ),
          child: const Center(child: _BlinkingEye()),
        );
    }
  }
}

/// Le téléphone : 3 secousses puis il reste immobile (jamais en boucle). Il
/// retremble quand le badge est recréé (l'état « appel » commence, ou le menu
/// s'ouvre) et pas avant.
class _ShakingPhone extends StatefulWidget {
  const _ShakingPhone();

  @override
  State<_ShakingPhone> createState() => _ShakingPhoneState();
}

class _ShakingPhoneState extends State<_ShakingPhone>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3300),
  );

  static double _r(double deg) => deg * math.pi / 180;

  late final Animation<double> _angle = TweenSequence<double>([
    for (var i = 0; i < 3; i++) ...[
      TweenSequenceItem(tween: Tween(begin: 0.0, end: _r(-16)), weight: 10),
      TweenSequenceItem(tween: Tween(begin: _r(-16), end: _r(14)), weight: 10),
      TweenSequenceItem(tween: Tween(begin: _r(14), end: _r(-14)), weight: 10),
      TweenSequenceItem(tween: Tween(begin: _r(-14), end: _r(12)), weight: 10),
      TweenSequenceItem(tween: Tween(begin: _r(12), end: _r(-8)), weight: 10),
      TweenSequenceItem(tween: Tween(begin: _r(-8), end: 0.0), weight: 10),
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 4),
    ],
  ]).animate(_shake);

  @override
  void initState() {
    super.initState();
    _shake.forward(from: 0);
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _angle,
        builder: (_, child) => Transform.rotate(angle: _angle.value, child: child),
        child: const Icon(Icons.call_rounded, size: 14, color: _kNavy),
      );
}

/// Trois points, en boucle : cycle 1,2 s, décalés de 0,18 s.
class _BouncingDots extends StatefulWidget {
  const _BouncingDots();

  @override
  State<_BouncingDots> createState() => _BouncingDotsState();
}

class _BouncingDotsState extends State<_BouncingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 3),
              _dot(i),
            ],
          ],
        ),
      );

  Widget _dot(int i) {
    // Phase propre à chaque point (0 / 0,18 / 0,36 s sur 1,2 s).
    final t = ((_c.value - i * 0.18 / 1.2) % 1.0 + 1.0) % 1.0;
    // Monte de 3 px et passe de 35 % à 100 % sur la première moitié du cycle.
    final k = t < 0.5 ? math.sin(t / 0.5 * math.pi / 2) : math.cos((t - 0.5) / 0.5 * math.pi / 2);
    return Transform.translate(
      offset: Offset(0, -3 * k),
      child: Container(
        width: 4,
        height: 4,
        decoration: BoxDecoration(
          color: _kNavy.withValues(alpha: 0.35 + 0.65 * k),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// L'œil : ouvert / fermé en boucle (cycle 2,6 s), il ne se déplace pas.
class _BlinkingEye extends StatefulWidget {
  const _BlinkingEye();

  @override
  State<_BlinkingEye> createState() => _BlinkingEyeState();
}

class _BlinkingEyeState extends State<_BlinkingEye>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  // Ouvert 0 → 38 %, se ferme jusqu'à 50 % (scaleY 1 → 0,08), se rouvre à 62 %.
  late final Animation<double> _scaleY = TweenSequence<double>([
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 38),
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 0.08).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 12,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 0.08, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 12,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 38),
  ]).animate(_c);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _scaleY,
        builder: (_, child) => Transform.scale(scaleY: _scaleY.value, child: child),
        child: const Icon(Icons.visibility_rounded, size: 14, color: Colors.white),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Menu d'appui long
// ─────────────────────────────────────────────────────────────────────────────

class _BubbleMenu extends StatelessWidget {
  const _BubbleMenu({
    required this.profile,
    required this.myId,
    required this.rect,
    required this.animation,
    required this.onMessage,
    required this.onCall,
    required this.onProfile,
    required this.onToggleMute,
    required this.onBlockReport,
  });

  final RemoteProfile profile;
  final String myId;
  final Rect rect;
  final Animation<double> animation;
  final void Function(RemoteProfile) onMessage;
  final void Function(RemoteProfile) onCall;
  final void Function(RemoteProfile) onProfile;
  final void Function(RemoteProfile) onToggleMute;
  final void Function(RemoteProfile) onBlockReport;

  static const double _cardW = 300;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final lifted = CurvedAnimation(parent: animation, curve: Curves.easeOutBack);
    final cardIn = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    final cardW = math.min(_cardW, size.width - 36);

    // La carte : ≈ 40 px sous le bord bas de la bulle soulevée (×1,5).
    final liftedBottom = rect.center.dy + rect.height * 1.5 / 2;
    const cardH = 380.0;
    var top = liftedBottom + 36;
    final maxTop = size.height - pad.bottom - cardH - 12;
    if (top > maxTop) top = math.max(pad.top + 12, maxTop);

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // Fond : flou 14 + voile 62 %. Un tap dehors ferme.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).pop(),
              child: FadeTransition(
                opacity: animation,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: ColoredBox(
                    color: const Color(0xFF060810).withValues(alpha: 0.62),
                  ),
                ),
              ),
            ),
          ),
          // La bulle soulevée, à sa place, à l'échelle 1,5.
          Positioned(
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: rect.height,
            child: IgnorePointer(
              child: ScaleTransition(
                scale: Tween<double>(begin: 1, end: 1.5).animate(lifted),
                child: BubbleFace(
                  profile: profile,
                  ring: true,
                  activity: ActivitySignal.of(profile.id, myId),
                ),
              ),
            ),
          ),
          Positioned(
            left: 18,
            top: top,
            width: cardW,
            child: FadeTransition(
              opacity: cardIn,
              child: AnimatedBuilder(
                animation: cardIn,
                builder: (_, child) => Transform.translate(
                  offset: Offset(0, 8 * (1 - cardIn.value)),
                  child: child,
                ),
                child: _card(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context) {
    final name = profile.displayName.trim().isEmpty
        ? (profile.handle.isEmpty ? '—' : '@${profile.handle}')
        : profile.displayName.trim();
    final clock = resolvePeerLocalTime(
      city: profile.city,
      country: profile.country,
    );
    final place = profile.city.trim().isNotEmpty
        ? profile.city.trim()
        : profile.country.trim();
    void act(void Function(RemoteProfile) f) {
      Navigator.of(context).pop();
      f(profile);
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xEB20222C),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        boxShadow: const [
          BoxShadow(color: Color(0x80000000), blurRadius: 60, offset: Offset(0, 24)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: popupDisplay(fontSize: 17, color: Colors.white),
                      ),
                    ),
                    // Profil Pro / Plus : le badge, à 10 px du prénom.
                    if (profile.isPro || profile.isPlus) ...[
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: _kYellow,
                          borderRadius: BorderRadius.circular(999),
                          boxShadow: [
                            BoxShadow(
                              color: _kYellow.withValues(alpha: 0.3),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: Text(
                          AppStrings.t('paywall_popular').toUpperCase(),
                          style: const TextStyle(
                            color: _kNavy,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (place.isNotEmpty || clock != null) ...[
                  const SizedBox(height: 4),
                  Text.rich(
                    TextSpan(
                      children: [
                        if (place.isNotEmpty)
                          TextSpan(
                            text: place,
                            style: const TextStyle(color: _kOrange),
                          ),
                        if (place.isNotEmpty && clock != null)
                          TextSpan(
                            text: ' · ',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.65),
                            ),
                          ),
                        if (clock != null)
                          TextSpan(
                            text: clock.hhmm,
                            style: const TextStyle(color: _kOrange),
                          ),
                      ],
                    ),
                    style: GoogleFonts.ibmPlexMono(fontSize: 11),
                  ),
                ],
                ValueListenableBuilder<int>(
                  valueListenable: ActivitySignal.revision,
                  builder: (_, _, _) {
                    final kind = ActivitySignal.of(profile.id, myId);
                    if (kind == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: _StatePill(kind: kind),
                    );
                  },
                ),
              ],
            ),
          ),
          _MenuRow(
            icon: Icons.chat_bubble_outline_rounded,
            label: AppStrings.t('bubble_send'),
            onTap: () => act(onMessage),
          ),
          _MenuRow(
            icon: Icons.call_outlined,
            label: AppStrings.t('bubble_call'),
            onTap: () => act(onCall),
          ),
          _MenuRow(
            icon: Icons.person_outline_rounded,
            label: AppStrings.t('bubble_profile'),
            onTap: () => act(onProfile),
          ),
          ValueListenableBuilder<Set<String>>(
            valueListenable: MutedCalls.ids,
            builder: (_, muted, _) {
              final isMuted = muted.contains(profile.id);
              return _MenuRow(
                icon: isMuted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
                label: AppStrings.t(isMuted ? 'calls_unmute' : 'calls_mute'),
                onTap: () => act(onToggleMute),
              );
            },
          ),
          _MenuRow(
            icon: Icons.block_rounded,
            label: AppStrings.t('bubble_block_report'),
            color: _kRed,
            onTap: () => act(onBlockReport),
          ),
        ],
      ),
    );
  }
}

/// La pastille « ce que la personne fait » (hauteur 30, texte 13 / 800).
class _StatePill extends StatelessWidget {
  const _StatePill({required this.kind});

  final PeerActivity kind;

  @override
  Widget build(BuildContext context) {
    final (String text, Color? bg, Gradient? grad, Color fg) = switch (kind) {
      PeerActivity.call => (
          AppStrings.t('activity_call'),
          _kYellow,
          null,
          _kNavy,
        ),
      PeerActivity.typing => (
          AppStrings.t('activity_typing'),
          Colors.white,
          null,
          _kNavy,
        ),
      PeerActivity.discover => (
          AppStrings.t('activity_discover'),
          null,
          const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1F5EFF), Color(0xFF18DDEA)],
          ),
          Colors.white,
        ),
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(minHeight: 30),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          gradient: grad,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ActivityBadgeMini(kind: kind, color: fg),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                text,
                style: TextStyle(
                  color: fg,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// La petite icône de la pastille d'état (sans son rond).
class ActivityBadgeMini extends StatelessWidget {
  const ActivityBadgeMini({super.key, required this.kind, required this.color});

  final PeerActivity kind;
  final Color color;

  @override
  Widget build(BuildContext context) => switch (kind) {
        PeerActivity.call => const _ShakingPhone(),
        PeerActivity.typing => const _BouncingDots(),
        PeerActivity.discover => const _BlinkingEye(),
      };
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
