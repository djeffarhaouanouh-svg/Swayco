import 'app_strings.dart';

/// Gendered demonym for a stored country name ("Islandaise", "Japonais"…).
/// Keys are the French country labels from [kCountries] / profiles.country.
/// Falls back to the country name itself when we have no demonym.
String countryDemonym(String country, {String gender = ''}) {
  final key = country.trim();
  if (key.isEmpty) return '';
  final entry = _kDemonyms[key];
  if (entry == null) return key;
  final g = gender.trim().toLowerCase();
  final feminine = g == 'f';
  final lang = AppStrings.currentBcp47.value;
  if (lang == 'fr') return feminine ? entry.$2 : entry.$1;
  // Non-FR UIs: English demonym pair when present, else country name.
  final en = _kDemonymsEn[key];
  if (en != null) return feminine ? en.$2 : en.$1;
  return key;
}

/// Article + demonym for the rare card headline ("Une Islandaise").
String demonymHeadline(String country, {String gender = ''}) {
  final d = countryDemonym(country, gender: gender);
  if (d.isEmpty) return '';
  final lang = AppStrings.currentBcp47.value;
  if (lang != 'fr') return d;
  final g = gender.trim().toLowerCase();
  if (g == 'f') return 'Une $d';
  if (g == 'm') {
    // "Un" vs "Un'" — French vowel / silent-h elision.
    final startsWithVowel = RegExp(r'^[aeiouyæœàâäéèêëïîôùûü]', caseSensitive: false)
        .hasMatch(d);
    return startsWithVowel ? "Un $d" : 'Un $d';
  }
  return 'Un(e) $d';
}

/// (masculine, feminine) French demonyms.
const Map<String, (String, String)> _kDemonyms = {
  'France': ('Français', 'Française'),
  'Belgique': ('Belge', 'Belge'),
  'Suisse': ('Suisse', 'Suisse'),
  'Canada': ('Canadien', 'Canadienne'),
  'États-Unis': ('Américain', 'Américaine'),
  'Royaume-Uni': ('Britannique', 'Britannique'),
  'Espagne': ('Espagnol', 'Espagnole'),
  'Portugal': ('Portugais', 'Portugaise'),
  'Italie': ('Italien', 'Italienne'),
  'Allemagne': ('Allemand', 'Allemande'),
  'Pays-Bas': ('Néerlandais', 'Néerlandaise'),
  'Mexique': ('Mexicain', 'Mexicaine'),
  'Argentine': ('Argentin', 'Argentine'),
  'Colombie': ('Colombien', 'Colombienne'),
  'Brésil': ('Brésilien', 'Brésilienne'),
  'Maroc': ('Marocain', 'Marocaine'),
  'Algérie': ('Algérien', 'Algérienne'),
  'Tunisie': ('Tunisien', 'Tunisienne'),
  'Sénégal': ('Sénégalais', 'Sénégalaise'),
  "Côte d'Ivoire": ('Ivoirien', 'Ivoirienne'),
  'Égypte': ('Égyptien', 'Égyptienne'),
  'Arabie Saoudite': ('Saoudien', 'Saoudienne'),
  'Émirats arabes unis': ('Émirati', 'Émiratie'),
  'Turquie': ('Turc', 'Turque'),
  'Russie': ('Russe', 'Russe'),
  'Chine': ('Chinois', 'Chinoise'),
  'Japon': ('Japonais', 'Japonaise'),
  'Corée du Sud': ('Coréen', 'Coréenne'),
  'Inde': ('Indien', 'Indienne'),
  'Australie': ('Australien', 'Australienne'),
  'Islande': ('Islandais', 'Islandaise'),
  'Norvège': ('Norvégien', 'Norvégienne'),
  'Suède': ('Suédois', 'Suédoise'),
  'Danemark': ('Danois', 'Danoise'),
  'Finlande': ('Finlandais', 'Finlandaise'),
  'Pologne': ('Polonais', 'Polonaise'),
  'Ukraine': ('Ukrainien', 'Ukrainienne'),
  'Grèce': ('Grec', 'Grecque'),
  'Irlande': ('Irlandais', 'Irlandaise'),
};

const Map<String, (String, String)> _kDemonymsEn = {
  'France': ('Frenchman', 'Frenchwoman'),
  'Belgique': ('Belgian', 'Belgian'),
  'Suisse': ('Swiss', 'Swiss'),
  'Canada': ('Canadian', 'Canadian'),
  'États-Unis': ('American', 'American'),
  'Royaume-Uni': ('Brit', 'Brit'),
  'Espagne': ('Spaniard', 'Spaniard'),
  'Portugal': ('Portuguese', 'Portuguese'),
  'Italie': ('Italian', 'Italian'),
  'Allemagne': ('German', 'German'),
  'Pays-Bas': ('Dutchman', 'Dutchwoman'),
  'Mexique': ('Mexican', 'Mexican'),
  'Argentine': ('Argentine', 'Argentine'),
  'Colombie': ('Colombian', 'Colombian'),
  'Brésil': ('Brazilian', 'Brazilian'),
  'Maroc': ('Moroccan', 'Moroccan'),
  'Algérie': ('Algerian', 'Algerian'),
  'Tunisie': ('Tunisian', 'Tunisian'),
  'Sénégal': ('Senegalese', 'Senegalese'),
  "Côte d'Ivoire": ('Ivorian', 'Ivorian'),
  'Égypte': ('Egyptian', 'Egyptian'),
  'Japon': ('Japanese', 'Japanese'),
  'Chine': ('Chinese', 'Chinese'),
  'Corée du Sud': ('Korean', 'Korean'),
  'Islande': ('Icelander', 'Icelander'),
  'Russie': ('Russian', 'Russian'),
  'Turquie': ('Turk', 'Turk'),
  'Inde': ('Indian', 'Indian'),
  'Australie': ('Australian', 'Australian'),
  'Pologne': ('Pole', 'Pole'),
  'Ukraine': ('Ukrainian', 'Ukrainian'),
};
