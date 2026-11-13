import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_strings.dart';
import '../services/languages.dart';
import '../swayco/realtime_translation_port.dart';
import '../theme/swayco_theme.dart';

/// « Animation d'explication de la traduction en appel » : deux écrans d'appel
/// côte à côte (le tien, celui de l'autre) et quatre étapes — tu parles, tu
/// patientes, l'autre reçoit la traduction, tu peux reparler.
///
/// BRANCHÉ SUR L'APPEL quand [myVoice] et [myLines] sont fournis (c'est le cas
/// dans l'appel) : les étapes suivent ce que tu fais vraiment.
///   1. Tu parles     — ton micro capte de la vraie parole ([myVoice] > 0).
///   2. Patiente      — tu t'es tu, ta phrase n'est pas encore partie.
///   3. Reçu          — ta phrase reconnue vient de partir vers l'autre
///                      ([myLines] change, `delivered`) : ta phrase s'affiche
///                      chez toi, sa traduction chez lui.
///   4. Reparle       — un instant après l'envoi.
/// LiveKit ne renvoie aucun accusé de réception : « a reçu » veut dire
/// « envoyée », comme le dit le dossier. Une phrase qui n'a pas pu partir
/// ramène simplement à l'étape 1.
///
/// Sans ces signaux (aperçu, tests), la même animation tourne en boucle sur un
/// minuteur, avec une phrase d'exemple.
///
/// Le délai annoncé (« 2 à 3 secondes ») est une estimation, pas une mesure.
/// Le galet est celui de la vraie page d'appel, fourni par [orbBuilder].
class TranslationTutorial extends StatefulWidget {
  const TranslationTutorial({
    super.key,
    required this.peerName,
    required this.peerLang,
    required this.peerPhotoUrl,
    required this.orbBuilder,
    required this.onClose,
    this.myVoice,
    this.myLines,
  });

  /// Le prénom de la personne en appel ; vide = un exemple (« Aiko »).
  final String peerName;

  /// Sa langue (`ja`, `fr`…).
  final String peerLang;

  /// Sa photo, ou vide : un fond de marque à la place.
  final String peerPhotoUrl;

  /// Construit le VRAI galet de l'appel, branché sur ces deux signaux : la
  /// traduction est dite ([tts]) et le niveau de la voix ([level], 0 à 1).
  final Widget Function(
    ValueListenable<bool> tts,
    ValueListenable<double> level,
  ) orbBuilder;

  final VoidCallback onClose;

  /// Ma voix au micro, 0..1 (0 quand je ne parle pas vraiment).
  final ValueListenable<double>? myVoice;

  /// Mes phrases reconnues, au moment où elles partent vers l'autre.
  final ValueListenable<SpokenLine>? myLines;

  static const String _seenKey = 'seen_translation_tuto';

  /// Le tuto n'a jamais été montré sur cet appareil.
  static Future<bool> shouldShow() async {
    try {
      final p = await SharedPreferences.getInstance();
      return !(p.getBool(_seenKey) ?? false);
    } catch (_) {
      return false;
    }
  }

  /// Ne revient plus : posé dès qu'il a été fermé.
  static Future<void> markSeen() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_seenKey, true);
    } catch (_) {}
  }

  @override
  State<TranslationTutorial> createState() => _TranslationTutorialState();
}

class _TranslationTutorialState extends State<TranslationTutorial> {
  static const _yellow = Color(0xFFF4FF1F);

  /// Démo : durée de chaque étape.
  static const _demoDurations = [2400, 2200, 2200, 2200];

  /// Branché : silence qui marque la fin de ma phrase (le pipeline ferme une
  /// phrase après 300 ms de silence ; un peu plus pour ne pas clignoter).
  static const _endOfSpeech = Duration(milliseconds: 400);

  /// Branché : sans phrase partie après ce délai, on revient à « Parle ».
  static const _waitGiveUp = Duration(seconds: 12);

  /// Branché : « à toi » s'affiche ce temps-là, puis on attend la phrase suivante.
  static const _yourTurnFor = Duration(milliseconds: 2500);

  int _step = 0;

  /// Je suis en train de parler (cadre jaune, badge). En démo : à l'étape 1.
  bool _speakingNow = false;

  /// Branché : ma dernière phrase partie, et sa traduction.
  String _myText = '';
  String _peerText = '';
  int _lastSeq = 0;

  Timer? _timer;
  Timer? _quiet;

  /// Ma dernière phrase n'est pas partie : « Traduction non envoyée », en rouge.
  bool _failed = false;
  Timer? _failTimer;

  // Deux galets, un par écran : chacun a ses propres signaux.
  final _myTts = ValueNotifier<bool>(false);
  final _myLevel = ValueNotifier<double>(0.05);
  final _peerTts = ValueNotifier<bool>(false);
  final _peerLevel = ValueNotifier<double>(0.05);

  bool get _live => widget.myVoice != null && widget.myLines != null;

  @override
  void initState() {
    super.initState();
    if (_live) {
      _lastSeq = widget.myLines!.value.seq;
      widget.myVoice!.addListener(_onVoice);
      widget.myLines!.addListener(_onLine);
      _goLive(0);
    } else {
      _demo(0);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _quiet?.cancel();
    _failTimer?.cancel();
    widget.myVoice?.removeListener(_onVoice);
    widget.myLines?.removeListener(_onLine);
    _myTts.dispose();
    _myLevel.dispose();
    _peerTts.dispose();
    _peerLevel.dispose();
    super.dispose();
  }

  // ── Branché sur l'appel ─────────────────────────────────────────────────

  void _onVoice() {
    final v = widget.myVoice!.value;
    if (v > 0) {
      _quiet?.cancel();
      _quiet = null;
      _myLevel.value = (0.4 + v * 2).clamp(0.0, 1.0);
      if (_step != 0 || !_speakingNow) _goLive(0, speaking: true);
    } else {
      _myLevel.value = 0.05;
      // Je me tais : passé un court silence, ma phrase est en route.
      if (_speakingNow && _quiet == null) {
        _quiet = Timer(_endOfSpeech, () {
          _quiet = null;
          if (mounted) _goLive(1);
        });
      }
    }
  }

  void _onLine() {
    final line = widget.myLines!.value;
    if (line.seq == _lastSeq) return;
    _lastSeq = line.seq;
    if (!line.delivered || line.text.trim().isEmpty) {
      // Pas partie : on ne prétend pas qu'elle est arrivée, on le dit en rouge.
      _goLive(0);
      _failTimer?.cancel();
      if (mounted) setState(() => _failed = true);
      _failTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _failed = false);
      });
      return;
    }
    _myText = line.text.trim();
    _peerText = line.translated.trim();
    _goLive(2);
  }

  void _goLive(int s, {bool speaking = false}) {
    _timer?.cancel();
    _step = s;
    _speakingNow = s == 0 && speaking;
    if (s != 0 || speaking) {
      _failTimer?.cancel();
      _failed = false;
    }
    switch (s) {
      case 0:
        if (speaking) {
          // Une nouvelle phrase commence : l'ancienne s'efface.
          _myText = '';
          _peerText = '';
        }
        _peerTts.value = false;
        _peerLevel.value = 0.05;
      case 1:
        _myLevel.value = 0.05;
        _peerLevel.value = 0.12;
        _timer = Timer(_waitGiveUp, () {
          if (mounted) _goLive(0);
        });
      case 2:
        _peerTts.value = true;
        _peerLevel.value = 0.9;
        // Le temps de lire (et pour lui, d'entendre) la phrase.
        final int ms = (60 * math.max(_myText.length, _peerText.length))
            .clamp(1500, 6000)
            .toInt();
        _timer = Timer(Duration(milliseconds: ms), () {
          if (mounted) _goLive(3);
        });
      default:
        _peerTts.value = false;
        _peerLevel.value = 0.05;
        _myLevel.value = 0.35;
        _timer = Timer(_yourTurnFor, () {
          if (mounted) _goLive(0);
        });
    }
    if (mounted) setState(() {});
  }

  // ── Démo (sans appel) ───────────────────────────────────────────────────

  void _demo(int s) {
    _step = s;
    _speakingNow = s == 0;
    switch (s) {
      case 0:
        _myLevel.value = 1;
        _peerLevel.value = 0.05;
        _peerTts.value = false;
      case 1:
        _myLevel.value = 0.05;
        _peerLevel.value = 0.12;
      case 2:
        _peerTts.value = true;
        _peerLevel.value = 0.9;
      default:
        _peerTts.value = false;
        _peerLevel.value = 0.05;
        _myLevel.value = 0.35;
    }
    if (mounted) setState(() {});
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: _demoDurations[s]), () {
      if (mounted) _demo((s + 1) % 4);
    });
  }

  // ── Rendu ────────────────────────────────────────────────────────────────

  String get _name =>
      widget.peerName.trim().isEmpty ? 'Aiko' : widget.peerName.trim();

  String _t(String key, {Map<String, String> args = const {}}) =>
      AppStrings.t(key, args: {'name': _name, ...args});

  /// Le nom de la langue de l'autre, dans MA langue (« japonais »).
  String get _peerLangName {
    final code =
        widget.peerLang.trim().split(RegExp(r'[-_]')).first.toLowerCase();
    if (code.isEmpty) return '';
    final n = AppStrings.t('lang_name_$code');
    if (n != 'lang_name_$code') return n;
    return findLanguageByCode(code)?.label ?? code.toUpperCase();
  }

  /// Ma bulle : en démo, la phrase d'exemple pendant que je parle ; branché,
  /// ma vraie phrase, une fois partie.
  String? get _myBubble {
    if (_live) return _step == 2 && _myText.isNotEmpty ? _myText : null;
    return _step <= 1
        ? AppStrings.tIn(AppStrings.currentBcp47.value, 'tuto_tr_sample')
        : null;
  }

  /// La bulle de l'autre : ce qu'il reçoit, dans sa langue.
  String? get _peerBubble {
    if (_step != 2) return null;
    if (_live) return _peerText.isNotEmpty ? _peerText : null;
    return AppStrings.tIn(widget.peerLang, 'tuto_tr_sample');
  }

  @override
  Widget build(BuildContext context) {
    final steps = [
      _t('tuto_tr_s1'),
      _t('tuto_tr_s2'),
      _t('tuto_tr_s3'),
      _t('tuto_tr_s4'),
    ];
    return Material(
      color: const Color(0xF2060A14),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              ),
              Text(
                _t('tuto_tr_title'),
                textAlign: TextAlign.center,
                style: GoogleFonts.unbounded(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  height: 1.3,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: _screen(title: _t('tuto_tr_you'), mine: true),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _screen(title: _t('tuto_tr_peer'), mine: false),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (var i = 0; i < 4; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    Expanded(child: _pill(steps[i], i == _step)),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: widget.onClose,
                  style: FilledButton.styleFrom(
                    backgroundColor: _yellow,
                    foregroundColor: SC.onAccent,
                    shape: const StadiumBorder(),
                  ),
                  child: Text(
                    _t('tuto_tr_ok'),
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(String label, bool active) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      decoration: BoxDecoration(
        color: active ? _yellow : Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 2,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.plusJakartaSans(
          fontSize: 10.5,
          height: 1.15,
          fontWeight: FontWeight.w800,
          color: active ? SC.onAccent : Colors.white.withValues(alpha: 0.55),
        ),
      ),
    );
  }

  /// Un écran d'appel en miniature : une toile de 390 × 780 mise à l'échelle.
  Widget _screen({required String title, required bool mine}) {
    return Column(
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.ibmPlexMono(
            fontSize: 11,
            letterSpacing: 0.5,
            color: Colors.white.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(width: 390, height: 780, child: _canvas(mine)),
          ),
        ),
      ],
    );
  }

  Widget _canvas(bool mine) {
    final speaking = mine && _speakingNow;
    // Les libellés sous le galet, par écran et par étape.
    String? label;
    var labelYellow = false;
    if (mine) {
      label = switch (_step) {
        0 => _t('tuto_tr_l1'),
        1 => _t('tuto_tr_l2'),
        2 => _t('tuto_tr_l3'),
        _ => _t('tuto_tr_l4'),
      };
      labelYellow = _step == 3;
      if (_failed) label = _t('tuto_tr_fail');
    } else {
      label = switch (_step) {
        1 => _t('tuto_tr_p2'),
        2 => _t('tuto_tr_p3', args: {'lang': _peerLangName}),
        _ => null,
      };
      labelYellow = _step == 2;
    }
    final bubble = mine ? _myBubble : _peerBubble;
    const orbY = 540.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(52),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Photo plein cadre (ou le fond de marque), voilée en bas.
          if (!mine && widget.peerPhotoUrl.isNotEmpty)
            Image.network(
              widget.peerPhotoUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _brandBg(),
            )
          else
            _brandBg(),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 300,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.6),
                  ],
                ),
              ),
            ),
          ),
          // Ma vignette : cadre jaune quand c'est moi qui parle.
          Positioned(
            top: 56,
            right: 12,
            width: 118,
            height: 176,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF161D30),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: speaking
                      ? _yellow
                      : Colors.white.withValues(alpha: 0.3),
                  width: speaking ? 2.5 : 1.5,
                ),
              ),
              child: Icon(
                Icons.person_rounded,
                size: 56,
                color: Colors.white.withValues(alpha: 0.35),
              ),
            ),
          ),
          if (speaking)
            Positioned(top: 240, right: 12, child: _badge(_t('tuto_tr_s1'))),
          if (bubble != null)
            Positioned(
              top: 300,
              left: mine ? 80 : 18,
              right: mine ? 18 : 80,
              child: Align(
                alignment:
                    mine ? Alignment.centerRight : Alignment.centerLeft,
                child: _bubble(bubble, mine: mine),
              ),
            ),
          // L'anneau d'attente, autour du galet, à l'étape « Patiente ».
          if (mine && _step == 1)
            const Positioned(
              top: orbY - 48,
              left: 195 - 48,
              width: 96,
              height: 96,
              child: CircularProgressIndicator(
                strokeWidth: 4,
                color: _yellow,
                backgroundColor: Color(0x24FFFFFF),
              ),
            ),
          // Le VRAI galet de l'appel.
          Positioned(
            top: orbY - 80,
            left: 0,
            right: 0,
            height: 160,
            child: Center(
              child: widget.orbBuilder(
                mine ? _myTts : _peerTts,
                mine ? _myLevel : _peerLevel,
              ),
            ),
          ),
          if (label != null)
            Positioned(
              top: orbY + 82,
              left: 16,
              right: 16,
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: (mine && _failed)
                      ? const Color(0xFFFF4D4D)
                      : (labelYellow ? _yellow : Colors.white),
                  shadows: const [Shadow(color: Colors.black87, blurRadius: 6)],
                ),
              ),
            ),
          // Les boutons d'appel, en miniature (décor).
          Positioned(
            left: 0,
            right: 0,
            bottom: 36,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _callBtn(Icons.volume_up_rounded, Colors.white24),
                _callBtn(Icons.videocam_rounded, Colors.white24),
                _callBtn(Icons.mic_rounded, Colors.white24),
                _callBtn(Icons.call_end_rounded, const Color(0xFFFF3B30)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _brandBg() => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0A0F1C), Color(0xFF1F3B8F)],
          ),
        ),
      );

  Widget _badge(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: _yellow,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: SC.onAccent,
          ),
        ),
      );

  Widget _bubble(String text, {required bool mine}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          gradient: mine
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF1F5EFF),
                    Color(0xFF2B7FFF),
                    Color(0xFF18DDEA),
                  ],
                )
              : null,
          color: mine ? null : Colors.white.withValues(alpha: 0.16),
          border: mine
              ? null
              : Border.all(color: Colors.white.withValues(alpha: 0.22)),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 6),
            bottomRight: Radius.circular(mine ? 6 : 18),
          ),
        ),
        child: Text(
          text,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style:
              const TextStyle(color: Colors.white, fontSize: 17, height: 1.35),
        ),
      );

  Widget _callBtn(IconData icon, Color bg) => Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 26),
      );
}
