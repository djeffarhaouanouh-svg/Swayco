import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';
import 'chat_list_extras.dart';
import 'chat_quiz.dart';
import 'chat_video.dart';
import 'viewport_trigger.dart';
import '../services/voice_heard.dart';
import 'voice_note_player.dart';

/// La vidéo de démonstration de l'appel traduit, hébergée dans le stockage
/// (bucket public `avatars`, dossier `guide/`). On peut REMPLACER le fichier à
/// ce chemin à tout moment : l'app lit l'adresse, pas le contenu — aucun
/// nouveau build nécessaire pour changer la vidéo.
/// La vidéo du globe 3D (Découvrir → Filtrer), même dossier, même principe :
/// remplaçable sans build.
const String kGuideGlobeDemoUrl =
    'https://rhxenzcdnfvpgjjefztx.supabase.co/storage/v1/object/public/avatars/guide/globe_demo.mp4';

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
    // L'exemple : le VRAI message vocal de l'équipe qui présente la fonction.
    example: (_) => const _WelcomeVoice(),
  ),
  OfficialGuideStep(
    titleKey: 'official_guide_t6',
    bodyKey: 'official_guide_b6',
    // La VRAIE vidéo du globe (6 s) : sa première image, un bouton lecture.
    example: (_) => const _ExampleFrame(
      child: VideoPreviewTile(url: kGuideGlobeDemoUrl),
    ),
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
    // Dans un encart arrondi, comme les autres exemples (la ligne de la liste,
    // seule, serait une bande plate collée au message).
    example: (context) => _ExampleFrame(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: InviteFriendsCard(onShare: () => shareSwayco(context)),
      ),
    ),
  ),
];

/// Le message vocal de bienvenue de l'équipe, présenté comme un VOCAL NORMAL du
/// chat : une bulle reçue, le lecteur en blanc dedans, et la transcription
/// qui apparaît quand on appuie sur LECTURE (dans la langue de l'interface),
/// sans bouton pour la refermer. Anglais pour tout le monde ; FRANÇAIS pour les comptes dont
/// l'interface est en anglais. Les deux fichiers sont dans le stockage
/// (`guide/`) et peuvent être remplacés sans nouveau build.
class _WelcomeVoice extends StatefulWidget {
  const _WelcomeVoice();

  static const _base =
      'https://rhxenzcdnfvpgjjefztx.supabase.co/storage/v1/object/public/avatars/guide/';

  @override
  State<_WelcomeVoice> createState() => _WelcomeVoiceState();
}

class _WelcomeVoiceState extends State<_WelcomeVoice> {
  bool _open = false;

  /// Comme dans le chat : un vocal reçu PAS ENCORE ÉCOUTÉ est dans une bulle
  /// BLANCHE (texte foncé, point cyan sur le lecteur) ; une fois écouté, la bulle
  /// passe au gris habituel. Le numéro 2 repart d'un vocal « jamais écouté ».
  bool _heard = true;
  String _id = '';

  String _voiceId() {
    final ui = AppStrings.currentBcp47.value.trim().toLowerCase();
    final english = ui == 'en' || ui.startsWith('en-') || ui.startsWith('en_');
    return 'guide-welcome-v2-${english ? 'fr' : 'en'}';
  }

  void _syncHeard() {
    final h = VoiceHeard.cached(_id);
    if (h != null && h != _heard && mounted) setState(() => _heard = h);
  }

  @override
  void initState() {
    super.initState();
    _id = _voiceId();
    _heard = VoiceHeard.cached(_id) ?? true;
    VoiceHeard.changed.addListener(_syncHeard);
    unawaited(VoiceHeard.isHeard(_id));
  }

  @override
  void dispose() {
    VoiceHeard.changed.removeListener(_syncHeard);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui = AppStrings.currentBcp47.value.trim().toLowerCase();
    final english = ui == 'en' || ui.startsWith('en-') || ui.startsWith('en_');
    final url = '${_WelcomeVoice._base}${english ? 'welcome_fr' : 'welcome_en'}.mp3';
    // Le texte du vocal dans la langue de L'INTERFACE de l'utilisateur.
    final text = AppStrings.t('guide_voice_text');
    // Les couleurs d'un vocal reçu dans le chat : bulle grise (blanche en clair),
    // lecteur et texte en blanc (encre en clair).
    final bubble = !_heard ? Colors.white : SC.msgInBg;
    final fg = !_heard ? SC.onAccent : SC.msgInText;
    return _ExampleFrame(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipOval(
            child: Image.asset(
              'assets/icon-app.png',
              width: 36,
              height: 36,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
              decoration: BoxDecoration(
                color: bubble,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  VoiceNotePlayer(
                    url: url,
                    color: fg,
                    messageId: _id,
                    mine: false,
                    // La transcription apparaît quand on appuie sur LECTURE, et
                    // reste (pas de bouton pour la refermer).
                    onPlay: () {
                      if (!_open) setState(() => _open = true);
                    },
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topLeft,
                    child: _open
                        ? Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(top: 6),
                            padding: const EdgeInsets.only(top: 9),
                            decoration: BoxDecoration(
                              border: Border(
                                top: BorderSide(
                                  color: fg.withValues(alpha: 0.12),
                                ),
                              ),
                            ),
                            child: Text(
                              text,
                              style: TextStyle(
                                color: fg.withValues(alpha: 0.88),
                                fontSize: 14,
                                height: 1.4,
                              ),
                            ),
                          )
                        : const SizedBox(width: double.infinity, height: 0),
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

/// Étape 1 — une petite scène qui se joue : le message arrive dans la langue de
/// l'autre (japonais), puis il SE TRADUIT sous les yeux (le texte se fond en
/// français/anglais et l'original passe en petit dessous), puis ma réponse
/// arrive. Rien ne bouge de place : la hauteur est réservée d'emblée.
class _ExampleTranslation extends StatefulWidget {
  const _ExampleTranslation();

  @override
  State<_ExampleTranslation> createState() => _ExampleTranslationState();
}

class _ExampleTranslationState extends State<_ExampleTranslation> {
  bool _received = false;
  bool _translated = false;
  bool _reply = false;
  final List<Timer> _timers = [];

  bool _started = false;

  /// La scène ne démarre que quand la personne ARRIVE dessus (voir [OnVisible]).
  void _start() {
    if (_started || !mounted) return;
    _started = true;
    void at(int ms, VoidCallback f) =>
        _timers.add(Timer(Duration(milliseconds: ms), () {
          if (mounted) setState(f);
        }));
    at(450, () => _received = true);
    at(1900, () => _translated = true);
    // La réponse se fait attendre : le temps de LIRE la traduction.
    at(5200, () => _reply = true);
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    super.dispose();
  }

  Widget _appear(bool shown, Widget child, {double dy = 14}) =>
      AnimatedSlide(
        offset: shown ? Offset.zero : Offset(0, dy / 40),
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: shown ? 1 : 0,
          duration: const Duration(milliseconds: 380),
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final bubbleColor = SC.light ? Colors.white : const Color(0xFF2F333B);
    return OnVisible(
      onVisible: _start,
      child: _ExampleFrame(
      child: SizedBox(
        height: 122,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _appear(
              _received,
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 230),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Le texte : le japonais, qui se fond en traduction.
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 450),
                        child: Text(
                          _translated
                              ? 'Hello! How are you? 🇯🇵'
                              : 'こんにちは！元気？ 🇯🇵',
                          key: ValueKey(_translated),
                          style: TextStyle(color: _ink, fontSize: 14),
                        ),
                      ),
                      // « L'original » apparaît dessous, une fois traduit.
                      AnimatedSize(
                        duration: const Duration(milliseconds: 380),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topLeft,
                        child: _translated
                            ? Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.translate_rounded,
                                        size: 11,
                                        color: _ink.withValues(alpha: 0.5)),
                                    const SizedBox(width: 4),
                                    Text(
                                      'こんにちは！元気？ 🇯🇵',
                                      style: TextStyle(
                                        color: _ink.withValues(alpha: 0.5),
                                        fontSize: 11.5,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : const SizedBox(width: 0, height: 0),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _appear(_reply, _bubble('Great, thanks! 😊', mine: true)),
          ],
        ),
      ),
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
