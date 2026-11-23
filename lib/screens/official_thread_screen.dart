import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/analytics.dart';
import '../services/app_strings.dart';
import '../services/call_launcher.dart';
import '../services/chat_api.dart' show ChatApi, isVideoUrl;
import '../services/device_id.dart';
import '../services/friendly_error.dart';
import '../services/official_api.dart';
import '../theme/swayco_theme.dart';
import '../widgets/chat_video.dart';
import '../widgets/official_guide.dart';
import '../widgets/popup_kit.dart';

/// Le fond des conversations (le même que chat_thread_screen : SC.bg).
Color get _kThreadBg => SC.bg;

/// Opacité du fond derrière le header et la barre d'écriture — mêmes valeurs
/// que les autres conversations (chat_thread_screen) : le header et le footer
/// sont des calques posés SUR la liste, fondus dans le fond.
const double _kChromeSolid = 0.92;
const double _kChromeFade = 40;
const double _kFooterFade = 190;

LinearGradient _chromeGradient({required double solid, required bool top}) {
  final f = solid / (solid + _kChromeFade);
  final tail = 1 - f;
  final c = _kThreadBg;
  return LinearGradient(
    begin: top ? Alignment.topCenter : Alignment.bottomCenter,
    end: top ? Alignment.bottomCenter : Alignment.topCenter,
    stops: [0, f, f + tail * 0.25, f + tail * 0.5, f + tail * 0.75, 1],
    colors: [
      c.withValues(alpha: _kChromeSolid),
      c.withValues(alpha: _kChromeSolid),
      c.withValues(alpha: _kChromeSolid * 0.78),
      c.withValues(alpha: _kChromeSolid * 0.45),
      c.withValues(alpha: _kChromeSolid * 0.15),
      c.withValues(alpha: 0),
    ],
  );
}

/// La conversation du compte officiel Swayco (handoff messages_groupes_quiz,
/// partie B, écran 1b) : le guide et les messages de l'équipe en cartes. On peut
/// aussi écrire à l'équipe : ces messages sont enregistrés en base (table
/// `official_messages`) et lus depuis le back-office. Pas de bouton d'appel.
class OfficialThreadScreen extends StatefulWidget {
  const OfficialThreadScreen({super.key, this.initial = const []});

  /// Les messages déjà connus de la liste (affichés avant la relecture).
  final List<OfficialPost> initial;

  @override
  State<OfficialThreadScreen> createState() => _OfficialThreadScreenState();
}

class _OfficialThreadScreenState extends State<OfficialThreadScreen> {
  late List<OfficialPost> _posts = widget.initial;
  List<OfficialPost> _mine = const [];
  final _ctrl = TextEditingController();
  String _myId = '';
  String _myName = '';
  bool _sending = false;

  // Le guide d'accueil est affiché EN ENTIER dès l'ouverture : la personne
  // défile à son rythme, et chaque exemple animé (traduction, vidéo) ne se joue
  // que quand elle arrive dessus (voir OnVisible).
  final int _revealed = officialGuide.length;
  final bool _animating = false;

  /// La barre d'écriture, mesurée : la liste lui laisse sa place en bas (elle
  /// grandit avec un texte sur plusieurs lignes).
  final GlobalKey _composerKey = GlobalKey();
  double _composerH = 66;

  void _measureComposer() {
    final box = _composerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    if ((box.size.height - _composerH).abs() > 0.5) {
      setState(() => _composerH = box.size.height);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    unawaited(OfficialApi.markGuideDone());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }
  /// Messages de l'équipe et les miens, mêlés par date.
  List<OfficialPost> get _items =>
      [..._posts, ..._mine]..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  Future<void> _load() async {
    // Ouvrir la conversation = tout avoir vu : la pastille s'éteint tout de
    // suite, sans attendre le réseau.
    await OfficialApi.markSeen();
    _myId = await DeviceId.getOrCreate();
    try {
      _myName = (await CallLauncher.resolveMyIdentity()).name;
    } catch (_) {}
    final results = await Future.wait([
      OfficialApi.fetch(),
      OfficialApi.fetchMine(_myId),
    ]);
    if (!mounted) return;
    setState(() {
      _posts = results[0];
      // Un envoi en cours n'est pas effacé par une relecture qui l'a devancé.
      _mine = results[1];
    });
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending || _myId.isEmpty) return;
    setState(() => _sending = true);
    _ctrl.clear();
    final optimistic = OfficialPost(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      title: '',
      body: text,
      createdAt: DateTime.now(),
      mine: true,
    );
    setState(() => _mine = [..._mine, optimistic]);
    try {
      await OfficialApi.send(meId: _myId, name: _myName, body: text);
      Analytics.track('official_message_sent');
    } catch (e) {
      if (!mounted) return;
      // Pas parti : on retire la bulle et on rend le texte au champ.
      setState(() => _mine = [
            for (final m in _mine)
              if (m.id != optimistic.id) m,
          ]);
      _ctrl.text = text;
      // Limite de 5 messages par jour (déclencheur en base, migration 0095).
      final limited = e.toString().contains('official_rate_limited');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          limited ? AppStrings.t('official_limit') : friendlyError(e),
        ),
      ));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Une PHOTO ou une VIDÉO pour l'équipe (pas de GIF). Elle part tout de suite et
  /// compte dans la limite de 3 messages par jour.
  Future<void> _attach() async {
    if (_sending || _myId.isEmpty) return;
    final XFile? file;
    try {
      file = await ImagePicker().pickMedia(
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
    } catch (_) {
      return;
    }
    if (file == null) return;
    final lower = file.name.toLowerCase();
    final isGif = lower.endsWith('.gif');
    if (isGif) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.t('official_no_gif'))),
        );
      }
      return;
    }
    final isVideo = (file.mimeType ?? '').startsWith('video/') ||
        isVideoUrl(file.name);
    if (isVideo && await file.length() > ChatApi.maxVideoBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.t('chat_video_too_big'))),
        );
      }
      return;
    }
    setState(() => _sending = true);
    try {
      final Uint8List bytes = await file.readAsBytes();
      final String ext;
      final String type;
      if (isVideo) {
        final mov = lower.endsWith('.mov');
        ext = mov ? 'mov' : 'mp4';
        type = mov ? 'video/quicktime' : 'video/mp4';
      } else if (lower.endsWith('.png')) {
        ext = 'png';
        type = 'image/png';
      } else {
        ext = 'jpg';
        type = 'image/jpeg';
      }
      final url = await OfficialApi.sendMedia(
        meId: _myId,
        name: _myName,
        bytes: bytes,
        extension: ext,
        contentType: type,
      );
      Analytics.track('official_message_sent', props: {'type': isVideo ? 'video' : 'photo'});
      if (!mounted) return;
      setState(() => _mine = [
            ..._mine,
            OfficialPost(
              id: 'local-${DateTime.now().microsecondsSinceEpoch}',
              title: '',
              body: '',
              createdAt: DateTime.now(),
              mediaUrl: url,
              mine: true,
            ),
          ]);
    } catch (e) {
      if (!mounted) return;
      final limited = e.toString().contains('official_rate_limited');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          limited ? AppStrings.t('official_limit') : friendlyError(e),
        ),
      ));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _time(DateTime dt) {
    final now = DateTime.now();
    final hm = '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return hm;
    }
    return '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')} · $hm';
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measureComposer();
    });
    // Hauteur du header : la marge haute, la rangée (48) et l'air dessous.
    final headerH = safe.top + 8 + 48 + 10;
    final header = Padding(
      padding: EdgeInsets.fromLTRB(8, safe.top + 8, 16, 10),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back_ios_new_rounded,
                color: SC.textPrimary, size: 20),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          // L'icône de l'app, en photo de profil (ronde, comme les autres).
          ClipOval(
            child: Image.asset(
              'assets/icon-app.png',
              width: 42,
              height: 42,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Swayco',
                      style: popupDisplay(
                        fontSize: 18,
                        color: SC.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.verified_rounded,
                        size: 17, color: SC.accentFg),
                  ],
                ),
                Text(
                  '${AppStrings.t('official_team')} · '
                  '${AppStrings.t('official_account')}',
                  style: TextStyle(
                    color: SC.textMuted,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return Scaffold(
      backgroundColor: _kThreadBg,
      // Comme les autres conversations : la liste occupe TOUT l'écran ; header
      // et footer sont des calques posés dessus, fondus dans le fond. Au
      // défilement, les messages passent dessous et s'y dissolvent.
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => FocusScope.of(context).unfocus(),
              // Le guide d'accueil d'abord (message, exemple, message,
              // exemple…), puis les messages de l'équipe.
              // Une colonne dans un défilement inversé (le bas = le plus récent) :
              // tous les messages arrivés sont construits d'emblée, aucun n'attend
              // qu'on défile pour apparaître.
              child: SingleChildScrollView(
                reverse: true,
                padding: EdgeInsets.fromLTRB(16, headerH + 8, 16, _composerH + 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Pendant l'arrivée du guide, seuls les messages déjà arrivés
                    // sont là ; les annonces de l'équipe viennent après.
                    for (var index = 0; index < _revealed; index++)
                      _Arrival(
                        key: ValueKey('guide-$index'),
                        // Seul le DERNIER arrivé s'anime (fondu + montée).
                        animate: _animating && index == _revealed - 1,
                        child: _OfficialCard(
                          title: officialGuide[index].titleKey == null
                              ? ''
                              : AppStrings.t(officialGuide[index].titleKey!),
                          body: AppStrings.t(officialGuide[index].bodyKey),
                          time: '',
                          icon: officialGuide[index].icon,
                          extra: officialGuide[index].example?.call(context),
                        ),
                      ),
                    if (!_animating)
                      for (final p in _items)
                        if (p.mine)
                          _MyBubble(
                            text: p.body,
                            mediaUrl: p.mediaUrl,
                            time: _time(p.createdAt),
                          )
                        else
                          _OfficialCard(
                            title: p.title,
                            body: p.body,
                            time: _time(p.createdAt),
                            extra: p.mediaUrl.isEmpty
                                ? null
                                : _PostMedia(url: p.mediaUrl),
                          ),
                  ],
                ),
              ),
            ),
          ),
          // ── Header : fond constant derrière le titre, puis un fondu doux de
          //    40 px sous lui (comme les autres conversations). ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: headerH + _kChromeFade,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: _chromeGradient(solid: headerH, top: true),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: _kChromeFade),
                  child: header,
                ),
              ],
            ),
          ),
          // ── Footer : fondu haut derrière la barre. Transparent en haut, fond
          //    PLEIN à 66 % de la hauteur : les messages s'effacent avant
          //    d'arriver au champ (comme les autres conversations). ──
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                height: _kFooterFade + safe.bottom * 0.4,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [_kThreadBg.withValues(alpha: 0), _kThreadBg],
                    stops: const [0, 0.66],
                  ),
                ),
              ),
            ),
          ),
          // Le champ d'écriture, posé SUR la conversation : les gens peuvent
          // écrire à l'équipe.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              key: _composerKey,
              padding: EdgeInsets.fromLTRB(12, 8, 12, 10 + safe.bottom),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Photo ou vidéo (pas de GIF).
                  GestureDetector(
                    onTap: _sending ? null : _attach,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: SC.menu,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.add_rounded, color: SC.textPrimary),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: SC.fill.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(
                            color: SC.stroke.withValues(alpha: 0.16)),
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: TextField(
                          controller: _ctrl,
                          minLines: 1,
                          maxLines: 5,
                          maxLength: 4000,
                          textCapitalization: TextCapitalization.sentences,
                          cursorColor: SC.accentFg,
                          style: TextStyle(color: SC.textPrimary),
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            counterText: '',
                            hintText: AppStrings.t('official_write_hint'),
                            hintStyle: TextStyle(color: SC.fgA(0.5)),
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _ctrl.text.trim().isEmpty || _sending ? null : _send,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: _ctrl.text.trim().isEmpty
                            ? SC.menu
                            : const Color(0xFFF4FF1F),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.arrow_upward_rounded,
                        color: _ctrl.text.trim().isEmpty
                            ? SC.textMuted
                            : const Color(0xFF04123A),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mon message à l'équipe : une bulle à droite, au dégradé de la marque.
class _MyBubble extends StatelessWidget {
  const _MyBubble({required this.text, required this.time, this.mediaUrl = ''});

  final String text;
  final String mediaUrl;
  final String time;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.78,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  gradient: SC.brandGradient,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (text.isNotEmpty)
                      Text(
                        text,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          height: 1.3,
                        ),
                      ),
                    if (mediaUrl.isNotEmpty) _PostMedia(url: mediaUrl),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 3, right: 6),
                child: Text(
                  time,
                  style: GoogleFonts.ibmPlexMono(
                    color: SC.textMuted,
                    fontSize: 10,
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

/// L'arrivée d'un message : un fondu et une petite montée, une seule fois, quand
/// il vient d'arriver (le guide qui s'égrène message après message).
class _Arrival extends StatelessWidget {
  const _Arrival({super.key, required this.animate, required this.child});

  final bool animate;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!animate) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      builder: (context, v, c) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * 18), child: c),
      ),
      child: child,
    );
  }
}

/// L'exemple d'un message de l'équipe : un GIF / une image (animée si GIF), ou
/// une vidéo qui s'ouvre au toucher.
class _PostMedia extends StatelessWidget {
  const _PostMedia({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final child = isVideoUrl(url)
        ? const ChatVideoTile()
        : ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.network(
              url,
              fit: BoxFit.cover,
              width: double.infinity,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: isVideoUrl(url)
          ? GestureDetector(
              onTap: () => showChatVideo(context, url),
              child: child,
            )
          : child,
    );
  }
}

class _OfficialCard extends StatelessWidget {
  const _OfficialCard({
    required this.title,
    required this.body,
    required this.time,
    this.extra,
    this.icon = '',
  });

  /// L'emoji devant le titre ('' = aucun).
  final String icon;

  final String title;
  final String body;
  final String time;

  /// L'exemple sous le texte (maquette du guide, ou média d'un message).
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            decoration: BoxDecoration(
              color: light ? Colors.white : const Color(0xFF1F1F24),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: SC.stroke.withValues(alpha: 0.12),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title.isNotEmpty) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (icon.isNotEmpty) ...[
                        Text(icon, style: const TextStyle(fontSize: 28, height: 1)),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Text(
                          title,
                          style: popupDisplay(
                            fontSize: 20,
                            height: 1.2,
                            color: SC.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                ],
                SelectableText(
                  body,
                  style: TextStyle(
                    color: SC.textPrimary,
                    fontSize: 14.5,
                    height: 1.4,
                  ),
                ),
                // L'exemple, juste sous le message.
                ?extra,
                if (time.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    time,
                    style: GoogleFonts.ibmPlexMono(
                      color: SC.textMuted,
                      fontSize: 10.5,
                    ),
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
