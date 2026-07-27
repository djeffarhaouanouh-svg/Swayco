/// Unités locales. Une taille est TOUJOURS stockée en centimètres
/// (`profiles.height_cm`) : seul l'affichage — et la roulette de saisie —
/// change de pays. Sans ça, un Américain lit « 178 » comme un nombre qui ne
/// lui dit rien, et tape « 5'10" » dans un champ qui attend des cm.
library;

/// Les pays de la liste [kCountries] qui mesurent une personne en pieds et
/// pouces. Le reste du monde — France, Japon, Corée… — est en centimètres.
/// Le Royaume-Uni est métrique sur le papier mais donne toujours sa taille en
/// pieds ; c'est l'usage qui compte ici, pas la loi.
const Set<String> _kImperialCountries = {'États-Unis', 'Royaume-Uni'};

bool countryUsesImperial(String country) =>
    _kImperialCountries.contains(country.trim());

/// « 178 cm » ou « 5'10" », selon le pays du profil affiché.
String formatHeight(int cm, {String country = ''}) {
  if (cm <= 0) return '';
  if (!countryUsesImperial(country)) return '$cm cm';
  final totalInches = (cm / 2.54).round();
  final feet = totalInches ~/ 12;
  final inches = totalInches % 12;
  return "$feet'$inches\"";
}

/// Bornes de la roulette de saisie, en centimètres — larges mais crédibles.
const int kMinHeightCm = 120;
const int kMaxHeightCm = 220;

/// Les valeurs proposées par la roulette pour [country] : des centimètres
/// partout, des pouces entiers (donc des paliers de ~2,5 cm) en impérial, pour
/// que la valeur affichée soit exactement celle qu'on a choisie.
List<int> heightWheelValues(String country) {
  if (!countryUsesImperial(country)) {
    return [for (var cm = kMinHeightCm; cm <= kMaxHeightCm; cm++) cm];
  }
  final minIn = (kMinHeightCm / 2.54).ceil();
  final maxIn = (kMaxHeightCm / 2.54).floor();
  return [for (var i = minIn; i <= maxIn; i++) (i * 2.54).round()];
}
