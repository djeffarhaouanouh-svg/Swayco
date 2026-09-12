import 'package:flutter/foundation.dart';

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
// Usage: DebugOverlay.log('[sway-rt] something happened');
abstract final class DebugOverlay {
  static void log(String msg) {
    if (kReleaseMode) return;
    debugPrint('[DBG] $msg');
  }
}
