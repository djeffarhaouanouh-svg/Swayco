import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/fact_emojis.dart';
import '../services/units.dart';
import 'wheel_picker_sheet.dart';

/// Roulette de taille. Rend les centimètres choisis, `0` pour effacer la
/// valeur, et `null` si on referme sans rien décider.
///
/// C'est le sélecteur qui impose le format : la liste est graduée en pieds et
/// pouces pour un profil américain, en centimètres partout ailleurs, mais elle
/// rend toujours des centimètres — la base n'a qu'une unité.
Future<int?> showHeightPicker(
  BuildContext context, {
  required String country,
  int? current,
}) async {
  final values = heightWheelValues(country);
  final target = current ?? 170;
  // La valeur actuelle si elle existe, sinon 170 cm — le milieu crédible, pour
  // que la roulette n'ouvre pas sur 120 cm.
  var start = 0;
  var bestGap = 1 << 30;
  for (final (i, v) in values.indexed) {
    final gap = (v - target).abs();
    if (gap < bestGap) {
      bestGap = gap;
      start = i;
    }
  }
  final picked = await showWheelPicker(
    context: context,
    title: AppStrings.t('info_height'),
    emoji: kFactEmojiHeight,
    labels: [for (final v in values) formatHeight(v, country: country)],
    initialIndex: start,
    allowClear: current != null,
  );
  if (picked == null) return null;
  if (picked < 0) return 0; // « Supprimer »
  return values[picked];
}
