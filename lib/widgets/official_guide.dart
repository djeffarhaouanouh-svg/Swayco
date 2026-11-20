import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';
import 'chat_list_extras.dart';
import 'chat_quiz.dart';
import 'chat_video.dart';

/// La vidéo de démonstration de l'appel traduit, hébergée dans le stockage
/// (bucket public `avatars`, dossier `guide/`). On peut REMPLACER le fichier à
/// ce chemin à tout moment : l'app lit l'adresse, pas le contenu — aucun
/// nouveau build nécessaire pour changer la vidéo.
const String kGuideCallDemoUrl =
    'https://rhxenzcdnfvpgjjefztx.supabase.co/storage/v1/object/public/avatars/guide/call_demo.mp4';

// Le guide d'accueil du compte officiel Swayco : une suite de messages qui
// expliquent l'app, chacun suivi d'un EXEMPLE dessiné juste en dessous
// (message, exemple, message, exemple…). Les textes viennent d'AppStrings, donc
// chacun les lit dans sa langue ; les exemples sont des maquettes sans texte
// traduisible (de vrais extraits de l'app, eux, passent par `media_url`).

const Color _kYellow = Color(0xFFF4FF1F);
const Color _kNavy = Color(0xFF04123A);

/// Une étape du guide : un titre, un texte, et l'exemple qui le illustre.
class OfficialGuideStep {
  const OfficialGuideStep({
    required this.titleKey,
    required this.bodyKey,
    this.example,
  });

  final String? titleKey;
  final String bodyKey;

  /// L'exemple posé sous le message (null = message seul, comme l'accueil).
  final WidgetBuilder? example;
}

/// Les étapes, dans l'ordre où elles arrivent dans la conversation.
final List<OfficialGuideStep> officialGuide = [
  const OfficialGuideStep(titleKey: null, bodyKey: 'official_guide_welcome'),
  OfficialGuideStep(
    titleKey: 'official_guide_t1',
    bodyKey: 'official_guide_b1',
    example: (_) => const _ExampleTranslation(),
  ),
  OfficialGuideStep(
    titleKey: 'official_guide_t2',
    bodyKey: 'official_guide_b2',
    example: (_) => const _ExampleCall(),
  ),
  OfficialGuideStep(
    titleKey: 'official_guide_t3',
    bodyKey: 'official_guide_b3',
    example: (_) => const _ExampleVoice(),
  ),
  OfficialGuideStep(
    titleKey: 'official_guide_t6',
    bodyKey: 'official_guide_b6',
    example: (_) => const _ExampleGlobe(),
  ),
  OfficialGuideStep(
    titleKey: 'official_guide_t4',
    bodyKey: 'official_guide_b4',
    example: (_) => const QuizQuestionCard(
      theme: 'travel',
      index: 1,
      active: true,
    ),
  ),
  OfficialGuideStep(
    titleKey: 'official_guide_t5',
    bodyKey: 'official_guide_b5',
    example: (_) => const _ExampleGroup(),
  ),
  OfficialGuideStep(
    titleKey: 'official_guide_t7',
    bodyKey: 'official_guide_b7',
    // La vraie carte « Invite tes amis » : la toucher ouvre le partage.
    example: (context) => InviteFriendsCard(
      onShare: () => shareSwayco(context),
    ),
  ),
];

/// Étape « globe » — la bulle « Filtrer » sur la photo, puis le globe 3D avec
/// ses bulles de pays.
class _ExampleGlobe extends StatelessWidget {
  const _ExampleGlobe();

  Widget _label(String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(
          t,
          style: const TextStyle(
            color: _kNavy,
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return _ExampleFrame(
      child: SizedBox(
        height: 150,
        child: Row(
          children: [
            // La carte Discover avec sa bulle « Filtrer ».
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF7A4DFF), Color(0xFF18DDEA)],
                    ),
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 9, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.28),
                            borderRadius: BorderRadius.circular(99),
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.6)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.public_rounded,
                                  size: 13, color: Colors.white),
                              const SizedBox(width: 4),
                              Text(
                                AppStrings.t('globe_filter_cta'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 8,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _circle(Icons.close_rounded, Colors.white),
                            const SizedBox(width: 12),
                            _circle(Icons.favorite_rounded, const Color(0xFFFF5C8A)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.arrow_forward_rounded,
                  color: _ink.withValues(alpha: 0.4)),
            ),
            // Le globe 3D et ses bulles de pays.
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            center: Alignment(-0.35, -0.4),
                            radius: 0.95,
                            colors: [Color(0xFF3F8CFF), Color(0xFF0B1A5C)],
                          ),
                        ),
                        child: Center(
                          child: Icon(
                            Icons.public_rounded,
                            size: 92,
                            color: Colors.white.withValues(alpha: 0.22),
                          ),
                        ),
                      ),
                      Positioned(top: 14, left: -4, child: _label('FR')),
                      Positioned(top: 52, right: -6, child: _label('DE')),
                      Positioned(bottom: 18, left: 6, child: _label('JP')),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _circle(IconData icon, Color color) => Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.22),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 17, color: color),
      );
}

Color get _panel => SC.light ? const Color(0xFFF3F4F8) : const Color(0xFF14141A);
Color get _ink => SC.light ? _kNavy : Colors.white;

/// Un cadre commun : l'exemple est un encart arrondi sous le message.
class _ExampleFrame extends StatelessWidget {
  const _ExampleFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _ink.withValues(alpha: 0.08)),
      ),
      child: child,
    );
  }
}

Widget _bubble(String text, {required bool mine, String? translated}) {
  return Align(
    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 230),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: mine ? null : (SC.light ? Colors.white : const Color(0xFF2F333B)),
        gradient: mine ? SC.brandGradient : null,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            translated ?? text,
            style: TextStyle(
              color: mine ? Colors.white : _ink,
              fontSize: 14,
            ),
          ),
          if (translated != null) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.translate_rounded,
                    size: 11, color: _ink.withValues(alpha: 0.5)),
                const SizedBox(width: 4),
                Text(
                  text,
                  style: TextStyle(
                    color: _ink.withValues(alpha: 0.5),
                    fontSize: 11.5,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

/// Étape 1 — deux bulles : une reçue, traduite, et ma réponse.
class _ExampleTranslation extends StatelessWidget {
  const _ExampleTranslation();

  @override
  Widget build(BuildContext context) {
    return _ExampleFrame(
      child: Column(
        children: [
          _bubble('こんにちは！元気？ 🇯🇵', mine: false, translated: 'Hello! How are you? 🇯🇵'),
          const SizedBox(height: 8),
          _bubble('Great, thanks! 😊', mine: true),
        ],
      ),
    );
  }
}

/// Étape 2 — un mini écran d'appel : visage, sous-titre d'origine et traduction.
class _ExampleCall extends StatelessWidget {
  const _ExampleCall();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showChatVideo(context, kGuideCallDemoUrl),
      child: _ExampleFrame(
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1B2250), Color(0xFF0B0E22)],
              ),
            ),
            child: Stack(
              children: [
                Align(
                  alignment: const Alignment(0, -0.35),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 58,
                        height: 58,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.14),
                          border: Border.all(color: Colors.white38, width: 1.5),
                        ),
                        child: const Text('🇯🇵', style: TextStyle(fontSize: 28)),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Aiko',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 10,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _caption('こんにちは！元気？', Colors.white.withValues(alpha: 0.18),
                          Colors.white70, 12),
                      const SizedBox(height: 5),
                      _caption('Hello! How are you?', _kYellow, _kNavy, 13.5),
                    ],
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.translate_rounded,
                            size: 11, color: Colors.white70),
                        SizedBox(width: 4),
                        Text('LIVE',
                            style: TextStyle(
                                color: Colors.white70,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8)),
                      ],
                    ),
                  ),
                ),
                // Le bouton lecture : toucher l'exemple ouvre la VRAIE vidéo de
                // démonstration de l'appel traduit.
                Positioned.fill(
                  child: Center(
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withValues(alpha: 0.45),
                        border: Border.all(color: Colors.white70, width: 1.5),
                      ),
                      child: const Icon(Icons.play_arrow_rounded,
                          color: Colors.white, size: 36),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _caption(String text, Color bg, Color fg, double size) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(
          text,
          style: TextStyle(color: fg, fontSize: size, fontWeight: FontWeight.w700),
        ),
      );
}

/// Étape 3 — un vocal : lecture, onde, durée, et sa traduction dessous.
class _ExampleVoice extends StatelessWidget {
  const _ExampleVoice();

  @override
  Widget build(BuildContext context) {
    const bars = [6.0, 12.0, 18.0, 10.0, 22.0, 14.0, 8.0, 20.0, 16.0, 9.0, 13.0, 7.0];
    return _ExampleFrame(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 250),
          padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
          decoration: BoxDecoration(
            color: SC.light ? Colors.white : const Color(0xFF2F333B),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: const BoxDecoration(
                      color: _kYellow,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.play_arrow_rounded,
                        color: _kNavy, size: 24),
                  ),
                  const SizedBox(width: 10),
                  for (final h in bars)
                    Container(
                      width: 3,
                      height: h,
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      decoration: BoxDecoration(
                        color: _ink.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  const SizedBox(width: 10),
                  Text('0:07',
                      style: TextStyle(
                          color: _ink.withValues(alpha: 0.6), fontSize: 12)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Hi! Are you free this weekend? 🌴',
                style: TextStyle(color: _ink, fontSize: 13.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Étape 5 — le « + » jaune et une ligne de groupe.
class _ExampleGroup extends StatelessWidget {
  const _ExampleGroup();

  @override
  Widget build(BuildContext context) {
    return _ExampleFrame(
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _kYellow,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _kYellow.withValues(alpha: 0.35),
                  blurRadius: 14,
                  spreadRadius: -2,
                ),
              ],
            ),
            child: const Icon(Icons.add_rounded, color: _kNavy, size: 26),
          ),
          const SizedBox(width: 10),
          Icon(Icons.arrow_forward_rounded, color: _ink.withValues(alpha: 0.4)),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: SC.light ? Colors.white : const Color(0xFF2F333B),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _ink.withValues(alpha: 0.1),
                    ),
                    child: const Center(
                      child: Text('🌍', style: TextStyle(fontSize: 20)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Friends 🌍',
                          style: TextStyle(
                            color: _ink,
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          '🇧🇷 🇪🇸 🇯🇵 🇫🇷',
                          style: TextStyle(
                            color: _ink.withValues(alpha: 0.6),
                            fontSize: 12.5,
                          ),
                        ),
                      ],
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

/// Texte du guide pour l'aperçu de la liste.
String officialGuideWelcome() => AppStrings.t('official_guide_welcome');
