import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_strings.dart';
import '../swayco/realtime_translation_port.dart';

/// Le texte d'explication posé SOUS le galet de l'appel, qui suit ce que je
/// fais vraiment :
///   1. « Parle normalement »               — au repos, ou pendant que je parle ;
///   2. « Patiente 2 à 3 secondes… »        — je me suis tu, ma phrase est en route ;
///   3. « {name} a reçu ta traduction »     — ma phrase vient de partir ;
///   4. « À toi, tu peux reparler »         — un instant après (en jaune).
/// Une phrase qui n'a pas pu partir : « Traduction non envoyée », en rouge.
///
/// « A reçu » veut dire « envoyée » : LiveKit ne renvoie aucun accusé.
/// Le délai annoncé est une estimation, pas une mesure.
///
/// Affiché tant qu'aucune de mes phrases n'est jamais partie sur cet appareil ;
/// la première qui part le marque comme vu (il reste pour le reste de l'appel).
class TranslationStepCaption extends StatefulWidget {
  const TranslationStepCaption({
    super.key,
    required this.peerName,
    required this.myVoice,
    required this.myLines,
    this.compact = false,
  });

  /// Version étroite (≈112 px, 2 lignes) : quand la vignette caméra est en bas
  /// à droite, le texte ne doit pas la toucher.
  final bool compact;

  /// Le prénom de la personne en appel (vide : « l'autre » n'est pas nommé).
  final String peerName;

  /// Ma voix au micro, 0..1 (0 quand je ne parle pas vraiment).
  final ValueListenable<double> myVoice;

  /// Mes phrases reconnues, au moment où elles partent vers l'autre. Null
  /// (web, port sans transcript) : seul « Parle normalement » s'affiche.
  final ValueListenable<SpokenLine>? myLines;

  static const String _seenKey = 'seen_translation_tuto';

  /// Jamais vu une de mes phrases partir sur cet appareil.
  static Future<bool> shouldShow() async {
    try {
      final p = await SharedPreferences.getInstance();
      return !(p.getBool(_seenKey) ?? false);
    } catch (_) {
      return false;
    }
  }

  static Future<void> markSeen() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_seenKey, true);
    } catch (_) {}
  }

  @override
  State<TranslationStepCaption> createState() => _TranslationStepCaptionState();
}

class _TranslationStepCaptionState extends State<TranslationStepCaption> {
  static const _yellow = Color(0xFFF4FF1F);
  static const _red = Color(0xFFFF4D4D);

  /// Le silence qui marque la fin de ma phrase (le pipeline ferme une phrase
  /// après 300 ms ; un peu plus pour ne pas clignoter).
  static const _endOfSpeech = Duration(milliseconds: 400);

  /// Sans phrase partie après ce délai, on revient à « Parle normalement ».
  static const _waitGiveUp = Duration(seconds: 12);

  int _step = 0;
  bool _speaking = false;
  bool _failed = false;
  int _lastSeq = 0;
  bool _markedSeen = false;

  Timer? _timer;
  Timer? _quiet;

  @override
  void initState() {
    super.initState();
    _lastSeq = widget.myLines?.value.seq ?? 0;
    widget.myVoice.addListener(_onVoice);
    widget.myLines?.addListener(_onLine);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _quiet?.cancel();
    widget.myVoice.removeListener(_onVoice);
    widget.myLines?.removeListener(_onLine);
    super.dispose();
  }

  void _onVoice() {
    // « X a reçu ta traduction » (étape 2) dure son temps plein : un bruit de
    // micro (la voix traduite qui revient dans le micro d'un test, un souffle)
    // ne doit pas la renvoyer à « Parle normalement » avant qu'on l'ait lue —
    // c'est ce qui donnait l'impression de n'avoir que deux états.
    if (_step == 2) return;
    if (widget.myVoice.value > 0) {
      _quiet?.cancel();
      _quiet = null;
      if (!_speaking || _step != 0) _go(0, speaking: true);
    } else if (_speaking && _quiet == null) {
      _quiet = Timer(_endOfSpeech, () {
        _quiet = null;
        if (mounted) _go(1);
      });
    }
  }

  void _onLine() {
    final line = widget.myLines!.value;
    if (line.seq == _lastSeq) return;
    _lastSeq = line.seq;
    if (!line.delivered || line.text.trim().isEmpty) {
      _go(0, failed: true);
      return;
    }
    if (!_markedSeen) {
      _markedSeen = true;
      unawaited(TranslationStepCaption.markSeen());
    }
    _go(2);
  }

  void _go(int s, {bool speaking = false, bool failed = false}) {
    _timer?.cancel();
    _step = s;
    _speaking = s == 0 && speaking;
    _failed = failed;
    switch (s) {
      case 1:
        _timer = Timer(_waitGiveUp, () {
          if (mounted) _go(0);
        });
      case 2:
        _timer = Timer(const Duration(milliseconds: 2500), () {
          if (mounted) _go(3);
        });
      case 3:
        _timer = Timer(const Duration(milliseconds: 3000), () {
          if (mounted) _go(0);
        });
      default:
        if (failed) {
          _timer = Timer(const Duration(seconds: 3), () {
            if (mounted) setState(() => _failed = false);
          });
        }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.peerName.trim();
    final args = {'name': name.isEmpty ? '—' : name};
    final String text;
    Color color = Colors.white;
    if (_failed) {
      text = AppStrings.t('tuto_tr_fail');
      color = _red;
    } else {
      switch (_step) {
        case 1:
          text = AppStrings.t('tuto_tr_l2');
        case 2:
          text = AppStrings.t('tuto_tr_l3', args: args);
        case 3:
          text = AppStrings.t('tuto_tr_l4');
          color = _yellow;
        default:
          text = AppStrings.t('tuto_tr_l1');
      }
    }
    // Sur un fond sombre arrondi : le texte blanc reste lisible quelle que
    // soit la vidéo derrière.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: Container(
        key: ValueKey('$_step-$_failed-${widget.compact}'),
        constraints: widget.compact
            ? const BoxConstraints(maxWidth: 112)
            : const BoxConstraints(),
        padding: EdgeInsets.symmetric(
          horizontal: widget.compact ? 10 : 12,
          vertical: widget.compact ? 4 : 5,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(widget.compact ? 14 : 999),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: GoogleFonts.plusJakartaSans(
            fontSize: widget.compact ? 11 : 13,
            height: widget.compact ? 1.25 : null,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      ),
    );
  }
}
