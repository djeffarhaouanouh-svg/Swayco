// swayco_call_promo.dart — carte "traduction dans les appels", montrée une
// seule fois au-dessus du composer, à la toute première ouverture d'une
// conversation.
//
// L'anneau reprend les 7 teintes de l'orbe de traduction de l'appel
// (_TranslationOrb / _OrbPainter, call_screen.dart) : le même langage visuel
// d'un écran à l'autre.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import 'profile_avatar.dart';

const List<Color> kCallPromoOrbColors = [
  Color(0xFFFF0080),
  Color(0xFFFF8C00),
  Color(0xFFFFEF00),
  Color(0xFF00FF87),
  Color(0xFF00BFFF),
  Color(0xFF7C3AED),
  Color(0xFFFF0080), // boucle sans couture
];

/// Petite phrase de démo (question + réponse) par langue parlée, pour animer
/// l'aller-retour de traduction. Couvre les langues proposées par
/// [kAllLanguages] (languages.dart) — repli sur l'anglais pour un code
/// inconnu.
const Map<String, (String, String)> _kDemoGreeting = {
  'fr': ('Salut, ça va ?', 'Oui, ça va, et toi ?'),
  'en': ('Hey, how\'s it going?', 'I\'m good, and you?'),
  'es': ('Hola, ¿qué tal?', 'Bien, ¿y tú?'),
  'de': ('Hey, wie geht\'s?', 'Gut, und dir?'),
  'it': ('Ciao, come va?', 'Bene, e tu?'),
  'pt': ('Oi, tudo bem?', 'Tudo bem, e você?'),
  'nl': ('Hé, hoe gaat het?', 'Goed, en met jou?'),
  'ar': ('مرحبًا، كيف حالك؟', 'بخير، وأنت؟'),
  'ru': ('Привет, как дела?', 'Хорошо, а у тебя?'),
  'zh': ('嗨，你好吗？', '挺好的，你呢？'),
  'ja': ('こんにちは、元気？', 'うん、元気！君は？'),
  'ko': ('안녕, 잘 지내?', '응, 잘 지내! 너는?'),
  'pl': ('Cześć, jak leci?', 'Dobrze, a u ciebie?'),
  'tr': ('Selam, nasılsın?', 'İyiyim, sen nasılsın?'),
  'uk': ('Привіт, як справи?', 'Добре, а в тебе?'),
  'hi': ('अरे, कैसे हो?', 'मैं ठीक हूँ, तुम बताओ?'),
};

(String, String) _greetingFor(String bcp47) {
  final code = bcp47.trim().toLowerCase();
  return _kDemoGreeting[code] ?? _kDemoGreeting['en']!;
}

class SwaycoCallPromo extends StatefulWidget {
  const SwaycoCallPromo({
    super.key,
    required this.calleeName,
    required this.myLang,
    required this.peerLang,
    this.myAvatarUrl = '',
    this.myName = '',
    this.peerAvatarUrl = '',
    this.peerName = '',
    this.onCall,
    this.onDismiss,
  });

  final String calleeName;

  /// Codes BCP-47 courts (ex. 'fr', 'ja') — pilotent à la fois les bulles de
  /// démo et les étiquettes FR / JA sous les avatars.
  final String myLang;
  final String peerLang;

  /// PDP (photo de profil) de chaque côté — vide replie sur l'initiale
  /// colorée de [ProfileAvatar], jamais sur une silhouette générique.
  final String myAvatarUrl;
  final String myName;
  final String peerAvatarUrl;
  final String peerName;

  final VoidCallback? onCall;
  final VoidCallback? onDismiss;

  @override
  State<SwaycoCallPromo> createState() => _SwaycoCallPromoState();
}

class _SwaycoCallPromoState extends State<SwaycoCallPromo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 7000),
  )..repeat();

  /// Verrouille la croix / « Pas maintenant » jusqu'à ce qu'un cycle complet
  /// se soit joué (aller ET retour de la traduction) — impossible de sortir
  /// avant d'avoir vu la démo en entier.
  bool _locked = true;

  @override
  void initState() {
    super.initState();
    Future.delayed(_c.duration!, () {
      if (mounted) setState(() => _locked = false);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _tryDismiss() {
    if (_locked) return;
    widget.onDismiss?.call();
  }

  // Interpolation linéaire sur une liste de (position 0..1, valeur).
  static double _stops(double t, List<List<double>> kf) {
    if (t <= kf.first[0]) return kf.first[1];
    for (var i = 0; i < kf.length - 1; i++) {
      final a = kf[i], b = kf[i + 1];
      if (t >= a[0] && t <= b[0]) {
        final span = b[0] - a[0];
        final k = span == 0 ? 0.0 : (t - a[0]) / span;
        return a[1] + (b[1] - a[1]) * Curves.easeInOut.transform(k);
      }
    }
    return kf.last[1];
  }

  // Impulsion (parle / entend) autour d'un instant donné.
  static double _pulse(double t, double start, double peak, double end) {
    if (t < start || t > end) return 0.28;
    final v = t < peak
        ? (t - start) / (peak - start)
        : 1 - (t - peak) / (end - peak);
    return 0.28 + 0.72 * v.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final (sourceText, replyTranslated) = _greetingFor(widget.myLang);
    final (replyText, sourceTranslated) = _greetingFor(widget.peerLang);
    final leftLabel = widget.myLang.trim().isEmpty
        ? ''
        : widget.myLang.trim().toUpperCase();
    final rightLabel = widget.peerLang.trim().isEmpty
        ? ''
        : widget.peerLang.trim().toUpperCase();

    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;

        // Traduction : pic à 24 % (aller) et 72 % (retour).
        final orbScale = 1 +
            0.35 * (_pulse(t, 0.16, 0.24, 0.34) - 0.28) / 0.72 +
            0.35 * (_pulse(t, 0.64, 0.72, 0.82) - 0.28) / 0.72;
        final glow = 0.16 +
            0.18 *
                (((_pulse(t, 0.16, 0.24, 0.40) - 0.28) / 0.72) +
                        ((_pulse(t, 0.64, 0.72, 0.88) - 0.28) / 0.72))
                    .clamp(0.0, 1.0);

        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF1F2226)),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF101114), Color(0xFF08080A)],
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              // Lueur diffuse aux couleurs de l'orbe, jusqu'aux bords.
              Positioned(
                top: -106,
                left: 0,
                right: 0,
                child: Center(
                  child: Opacity(
                    opacity: glow,
                    child: ImageFiltered(
                      imageFilter:
                          ui.ImageFilter.blur(sigmaX: 48, sigmaY: 48),
                      child: Container(
                        width: 340,
                        height: 340,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: SweepGradient(colors: kCallPromoOrbColors),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 128,
                      child: _stage(
                        t,
                        orbScale,
                        leftLabel: leftLabel,
                        rightLabel: rightLabel,
                        sourceText: sourceText,
                        sourceTranslated: sourceTranslated,
                        replyText: replyText,
                        replyTranslated: replyTranslated,
                        leftAvatarUrl: widget.myAvatarUrl,
                        leftName: widget.myName,
                        rightAvatarUrl: widget.peerAvatarUrl,
                        rightName: widget.peerName,
                      ),
                    ),
                    const SizedBox(height: 6),
                    RichText(
                      text: TextSpan(
                        style: const TextStyle(
                          color: Color(0xFF9AA0A8),
                          fontSize: 12,
                          height: 1.3,
                        ),
                        children: [
                          TextSpan(
                              text: '${AppStrings.t('call_promo_speak_normally')} '),
                          TextSpan(
                            text: AppStrings.t('call_promo_swayco_translates'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    _callButton(),
                    const SizedBox(height: 8),
                    AnimatedOpacity(
                      opacity: _locked ? 0.35 : 1,
                      duration: const Duration(milliseconds: 200),
                      child: GestureDetector(
                        onTap: _tryDismiss,
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 9, horizontal: 16),
                          child: Text(
                            AppStrings.t('call_promo_not_now'),
                            style: const TextStyle(
                                color: Color(0xFF8A8F96), fontSize: 13.5),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Croix dans l'angle — inerte tant que le cycle complet n'est
              // pas joué : impossible de fuir la démo avant la fin.
              Positioned(
                top: 0,
                right: 0,
                child: AnimatedOpacity(
                  opacity: _locked ? 0.35 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: GestureDetector(
                    onTap: _tryDismiss,
                    child: Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: Color(0xFF17181B),
                        borderRadius: BorderRadius.only(
                          topRight: Radius.circular(20),
                          bottomLeft: Radius.circular(14),
                        ),
                      ),
                      child: const Icon(Icons.close,
                          size: 17, color: Color(0xFF9AA0A8)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _stage(
    double t,
    double orbScale, {
    required String leftLabel,
    required String rightLabel,
    required String sourceText,
    required String sourceTranslated,
    required String replyText,
    required String replyTranslated,
    required String leftAvatarUrl,
    required String leftName,
    required String rightAvatarUrl,
    required String rightName,
  }) {
    // Aller : moi -> orbe -> pair (0 % → 48 %)
    final frX = _stops(t, [
      [0.00, -76],
      [0.08, -76],
      [0.20, -10],
      [0.24, 0],
      [0.28, 10],
      [0.42, 76],
      [1.00, 76],
    ]);
    final frOp = _stops(t, [
      [0.03, 0],
      [0.08, 1],
      [0.42, 1],
      [0.48, 0],
      [1.00, 0],
    ]);
    final frSc = _stops(t, [
      [0.08, 1],
      [0.20, 1],
      [0.24, 0.72],
      [0.28, 1],
      [1.00, 1],
    ]);
    // Retour : pair -> orbe -> moi (51 % → 96 %)
    final jpX = _stops(t, [
      [0.00, 76],
      [0.56, 76],
      [0.68, 10],
      [0.72, 0],
      [0.76, -10],
      [0.90, -76],
      [1.00, -76],
    ]);
    final jpOp = _stops(t, [
      [0.51, 0],
      [0.56, 1],
      [0.90, 1],
      [0.96, 0],
      [1.00, 0],
    ]);
    final jpSc = _stops(t, [
      [0.56, 1],
      [0.68, 1],
      [0.72, 0.72],
      [0.76, 1],
      [1.00, 1],
    ]);

    // La langue bascule exactement au centre de l'orbe.
    final frTranslated = t >= 0.24 && t < 0.49;
    final jpTranslated = t >= 0.72 && t < 0.97;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          top: 8,
          child: _person(leftLabel,
              avatarUrl: leftAvatarUrl,
              name: leftName,
              speak: _pulse(t, 0.05, 0.11, 0.20),
              hear: _pulse(t, 0.80, 0.88, 0.98)),
        ),
        Positioned(
          right: 0,
          top: 8,
          child: _person(rightLabel,
              avatarUrl: rightAvatarUrl,
              name: rightName,
              speak: _pulse(t, 0.53, 0.59, 0.68),
              hear: _pulse(t, 0.32, 0.40, 0.50)),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 30,
          child: Center(child: _orb(orbScale, t)),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 52,
          child: Center(
            child: Transform.translate(
              offset: Offset(frX, 0),
              child: Transform.scale(
                scale: frSc,
                child: Opacity(
                  opacity: frOp,
                  child: _bubble(
                    frTranslated ? sourceTranslated : sourceText,
                    mine: true,
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 52,
          child: Center(
            child: Transform.translate(
              offset: Offset(jpX, 0),
              child: Transform.scale(
                scale: jpSc,
                child: Opacity(
                  opacity: jpOp,
                  child: _bubble(
                    jpTranslated ? replyTranslated : replyText,
                    mine: false,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _person(
    String label, {
    required String avatarUrl,
    required String name,
    required double speak,
    required double hear,
  }) {
    return SizedBox(
      width: 64,
      child: Column(
        children: [
          Opacity(
            opacity: speak,
            child: Transform.scale(
              scale: 1 + 0.08 * ((speak - 0.28) / 0.72),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF2A2A2E)),
                ),
                child: ProfileAvatar(
                  displayName: name,
                  avatarUrl: avatarUrl,
                  size: 44,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(label,
              style: const TextStyle(
                color: Color(0xFF7A7F86),
                fontSize: 10,
                letterSpacing: 1.4,
              )),
          const SizedBox(height: 6),
          Opacity(
            opacity: hear,
            child: Container(
              width: 26,
              height: 3,
              decoration: BoxDecoration(
                color: const Color(0xFF00BFFF),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _orb(double scale, double t) {
    return SizedBox(
      width: 68,
      height: 68,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Anneau qui se propage à chaque traduction.
          Transform.scale(
            scale: 1 + 0.9 * ((scale - 1) / 0.35),
            child: Opacity(
              opacity: 0.18 + 0.37 * ((scale - 1) / 0.35),
              child: Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24),
                ),
              ),
            ),
          ),
          Transform.scale(
            scale: scale,
            child: Transform.rotate(
              angle: t * 2 * 3.14159 * 2.2,
              child: Container(
                width: 50,
                height: 50,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: SweepGradient(colors: kCallPromoOrbColors),
                ),
              ),
            ),
          ),
          Container(
            width: 20,
            height: 20,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xEBFFFFFF),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(String text, {required bool mine}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: mine ? const Color(0xFF14343C) : const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: mine ? const Color(0xFF2AA8BD) : const Color(0xFF3A3A3F)),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 20, offset: Offset(0, 6))
        ],
      ),
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          color: mine ? const Color(0xFFEAFCFF) : const Color(0xFFF0F0F2),
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _callButton() {
    return GestureDetector(
      onTap: widget.onCall,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF0F5F6E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF2AA8BD)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.call, size: 17, color: Color(0xFFEAFCFF)),
            const SizedBox(width: 8),
            Text(
              AppStrings.t('call_promo_call_name',
                  args: {'name': widget.calleeName}),
              style: const TextStyle(
                color: Color(0xFFEAFCFF),
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
