import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Inclinaison gauche / droite du téléphone, lissée, dans
/// [-[amplitude], [amplitude]] : négatif quand le bord droit descend. Natif
/// seulement — sur le web, Safari exige une autorisation « mouvement » : la
/// valeur y reste à 0.
///
/// Un seul abonnement à l'accéléromètre, partagé : chaque carte appelle
/// [acquire] / [release], le capteur s'arrête quand plus personne n'écoute.
abstract final class DeviceTilt {
  static final ValueNotifier<double> roll = ValueNotifier(0);

  /// Toute la plage : c'est le zoom de la carte qui borne le déplacement.
  static const double amplitude = 1.0;

  /// sin(20°) : pencher de 20° amène la photo au bout de sa course.
  static const double _fullTilt = 0.34;
  static const double _gravity = 9.81;

  /// Part de l'écart rattrapée à chaque mesure (~50 Hz, soit ~0,2 s pour
  /// rejoindre le geste) : la photo suit sans à-coups.
  static const double _smoothing = 0.1;

  static StreamSubscription<AccelerometerEvent>? _sub;
  static int _users = 0;

  static void acquire() {
    if (kIsWeb) return;
    if (_users++ > 0) return;
    _sub = accelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(
      (e) {
        final target =
            (e.x / (_gravity * _fullTilt)).clamp(-1.0, 1.0) * amplitude;
        final next = roll.value + (target - roll.value) * _smoothing;
        if ((next - roll.value).abs() > 0.002) roll.value = next;
      },
      // Pas d'accéléromètre (émulateur, appareil exotique) : photo fixe.
      onError: (_) {},
      cancelOnError: true,
    );
  }

  static void release() {
    if (kIsWeb || _users == 0) return;
    if (--_users > 0) return;
    _sub?.cancel();
    _sub = null;
    roll.value = 0;
  }
}
