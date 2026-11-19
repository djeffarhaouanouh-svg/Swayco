import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/chat_api.dart' show isVideoUrl;
import '../services/official_api.dart';
import '../theme/swayco_theme.dart';
import '../widgets/chat_video.dart';
import '../widgets/official_guide.dart';
import '../widgets/popup_kit.dart';

/// La conversation du compte officiel Swayco (handoff messages_groupes_quiz,
/// partie B, écran 1b) : les messages de l'équipe en cartes, et à la place du
/// champ d'écriture une mention « Seule l'équipe Swayco peut écrire ici ».
/// Pas de bouton d'appel : on ne peut que lire.
class OfficialThreadScreen extends StatefulWidget {
  const OfficialThreadScreen({super.key, this.initial = const []});

  /// Les messages déjà connus de la liste (affichés avant la relecture).
  final List<OfficialPost> initial;

  @override
  State<OfficialThreadScreen> createState() => _OfficialThreadScreenState();
}

class _OfficialThreadScreenState extends State<OfficialThreadScreen> {
  late List<OfficialPost> _posts = widget.initial;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Ouvrir la conversation = tout avoir vu : la pastille s'éteint tout de
    // suite, sans attendre le réseau.
    await OfficialApi.markSeen();
    final posts = await OfficialApi.fetch();
    if (!mounted) return;
    setState(() => _posts = posts);
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
    return Scaffold(
      backgroundColor: SC.tabBg,
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(8, safe.top + 8, 16, 10),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.arrow_back_ios_new_rounded,
                      color: SC.textPrimary, size: 20),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
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
          ),
          Divider(height: 1, color: SC.stroke.withValues(alpha: 0.10)),
          Expanded(
            // Le guide d'accueil d'abord (message, exemple, message,
            // exemple…), puis les messages de l'équipe.
            child: ListView.builder(
              reverse: true,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              itemCount: officialGuide.length + _posts.length,
              itemBuilder: (ctx, i) {
                final index = officialGuide.length + _posts.length - 1 - i;
                if (index < officialGuide.length) {
                  final step = officialGuide[index];
                  return _OfficialCard(
                    title: step.titleKey == null
                        ? ''
                        : AppStrings.t(step.titleKey!),
                    body: AppStrings.t(step.bodyKey),
                    time: '',
                    extra: step.example?.call(ctx),
                  );
                }
                final p = _posts[index - officialGuide.length];
                return _OfficialCard(
                  title: p.title,
                  body: p.body,
                  time: _time(p.createdAt),
                  extra: p.mediaUrl.isEmpty ? null : _PostMedia(url: p.mediaUrl),
                );
              },
            ),
          ),
          Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(20, 14, 20, 14 + safe.bottom),
            decoration: BoxDecoration(
              color: SC.menu,
              border: Border(
                top: BorderSide(color: SC.stroke.withValues(alpha: 0.10)),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_rounded, size: 15, color: SC.textMuted),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    AppStrings.t('official_readonly'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: SC.textMuted, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
  });

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
                  Text(
                    title,
                    style: popupDisplay(
                      fontSize: 15,
                      height: 1.25,
                      color: SC.textPrimary,
                    ),
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
