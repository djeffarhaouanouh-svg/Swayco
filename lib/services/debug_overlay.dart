import 'package:flutter/foundation.dart';

import 'analytics.dart';

// Le puits de journal des chemins appel / STT / présence — environ quatre-vingts
// points d'appel. Il n'y a plus de panneau 🐛 à l'écran.
//
// MUET EN RELEASE, et c'est le point. `debugPrint` n'est pas retiré par le
// compilateur : en release il écrit quand même dans le journal système, donc
// une build de magasin racontait tout l'appel dans logcat — les phrases dites,
// leur traduction, les langues, les prénoms des contacts. Ça ne se voit pas
// dans l'app et ça sort quand même de l'app.
//
// Le garde est `kReleaseMode`, une constante de compilation : la branche est
// repliée à la compilation, l'appel ne coûte rien et la chaîne n'est même pas
// construite si le compilateur peut le voir. Les points d'appel restent en
// place, et ils reparlent dès qu'on lance en debug ou en profile.
//
// Une seule exception en release : le CHOIX DU MOTEUR STT (Apple, repli cloud,
// modèle, détecteur de voix). Ces lignes ne contiennent aucune phrase, et sans
// elles on ne sait pas pourquoi un appel a basculé sur le cloud. Liste blanche
// stricte, plafonnée par lancement, envoyée à `analytics_events` (`stt_debug`).
//
// Usage: DebugOverlay.log('[sway-rt] something happened');
abstract final class DebugOverlay {
  // Uniquement des lignes de sélection de moteur : jamais `stt phrase`,
  // `stt partial`, `stt final`, `stt orig`, `stt translate`… (elles portent du
  // texte dit).
  static final RegExp _engineChoice = RegExp(
    r'^stt (engine|Apple|Android|NO |model|VAD|START|fallback|LOAD|provider|load)',
  );
  static const int _maxReleaseEvents = 40;
  static int _releaseSent = 0;

  /// Journal EN MÉMOIRE pour le panneau de debug de l'écran d'appel, réservé aux
  /// comptes autorisés (le même contrôle que le bouton REC). Il ne part nulle
  /// part : il ne vit que sur le téléphone et s'allume seulement quand
  /// [capture] est vrai. C'est ce qui permet de lire, sur l'écran, ce que la
  /// voix a fait — une release ne journalise rien d'autre.
  static bool capture = false;
  static final ValueNotifier<List<String>> lines =
      ValueNotifier<List<String>>(const <String>[]);

  static void _remember(String msg) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final line = '${two(t.hour)}:${two(t.minute)}:${two(t.second)} '
        '${msg.length > 160 ? msg.substring(0, 160) : msg}';
    final next = [...lines.value, line];
    lines.value =
        next.length > 40 ? next.sublist(next.length - 40) : next;
  }

  static void log(String msg) {
    if (capture) _remember(msg);
    if (kReleaseMode) {
      if (_releaseSent < _maxReleaseEvents && _engineChoice.hasMatch(msg)) {
        _releaseSent++;
        Analytics.track(
          'stt_debug',
          props: {'msg': msg.length > 200 ? msg.substring(0, 200) : msg},
        );
      }
      return;
    }
    debugPrint('[DBG] $msg');
  }
}
