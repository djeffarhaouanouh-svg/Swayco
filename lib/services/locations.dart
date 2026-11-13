/// Curated country → cities dataset for the profile location picker (a single
/// field where the user selects a country, then a city). Not exhaustive — it
/// covers the most common countries with their major cities; the picker always
/// offers an "Autre ville…" free-text fallback for anything not listed, and a
/// country with an empty [cities] list simply goes straight to that fallback.
///
/// Labels are stored verbatim on the profile (`country` / `city`), so editing
/// this list later is safe as long as existing labels stay stable.
class Country {
  const Country({required this.name, required this.flag, this.cities = const []});
  final String name;
  final String flag;
  final List<String> cities;
}

const List<Country> kCountries = [
  Country(name: 'France', flag: '🇫🇷', cities: [
    'Paris', 'Marseille', 'Lyon', 'Toulouse', 'Nice', 'Nantes',
    'Montpellier', 'Strasbourg', 'Bordeaux', 'Lille', 'Rennes', 'Toulon',
  ]),
  Country(name: 'Belgique', flag: '🇧🇪', cities: [
    'Bruxelles', 'Anvers', 'Gand', 'Charleroi', 'Liège', 'Bruges', 'Namur',
  ]),
  Country(name: 'Suisse', flag: '🇨🇭', cities: [
    'Genève', 'Zurich', 'Lausanne', 'Bâle', 'Berne', 'Lugano',
  ]),
  Country(name: 'Canada', flag: '🇨🇦', cities: [
    'Montréal', 'Toronto', 'Vancouver', 'Québec', 'Ottawa', 'Calgary',
    'Edmonton', 'Winnipeg',
  ]),
  Country(name: 'États-Unis', flag: '🇺🇸', cities: [
    'New York', 'Los Angeles', 'Chicago', 'Houston', 'Miami', 'San Francisco',
    'Boston', 'Seattle', 'Las Vegas', 'Atlanta', 'Washington', 'Dallas',
  ]),
  Country(name: 'Royaume-Uni', flag: '🇬🇧', cities: [
    'Londres', 'Manchester', 'Birmingham', 'Liverpool', 'Glasgow', 'Édimbourg',
    'Leeds', 'Bristol',
  ]),
  Country(name: 'Espagne', flag: '🇪🇸', cities: [
    'Madrid', 'Barcelone', 'Valence', 'Séville', 'Bilbao', 'Malaga',
    'Saragosse', 'Grenade',
  ]),
  Country(name: 'Portugal', flag: '🇵🇹', cities: [
    'Lisbonne', 'Porto', 'Braga', 'Coimbra', 'Faro', 'Funchal',
  ]),
  Country(name: 'Italie', flag: '🇮🇹', cities: [
    'Rome', 'Milan', 'Naples', 'Turin', 'Florence', 'Venise', 'Bologne',
    'Palerme',
  ]),
  Country(name: 'Allemagne', flag: '🇩🇪', cities: [
    'Berlin', 'Munich', 'Hambourg', 'Cologne', 'Francfort', 'Stuttgart',
    'Düsseldorf', 'Leipzig',
  ]),
  Country(name: 'Pays-Bas', flag: '🇳🇱', cities: [
    'Amsterdam', 'Rotterdam', 'La Haye', 'Utrecht', 'Eindhoven', 'Groningue',
  ]),
  Country(name: 'Mexique', flag: '🇲🇽', cities: [
    'Mexico', 'Guadalajara', 'Monterrey', 'Puebla', 'Tijuana', 'Cancún',
  ]),
  Country(name: 'Argentine', flag: '🇦🇷', cities: [
    'Buenos Aires', 'Córdoba', 'Rosario', 'Mendoza', 'La Plata',
  ]),
  Country(name: 'Colombie', flag: '🇨🇴', cities: [
    'Bogota', 'Medellín', 'Cali', 'Barranquilla', 'Cartagena',
  ]),
  Country(name: 'Brésil', flag: '🇧🇷', cities: [
    'São Paulo', 'Rio de Janeiro', 'Brasília', 'Salvador', 'Fortaleza',
    'Belo Horizonte', 'Curitiba',
  ]),
  Country(name: 'Maroc', flag: '🇲🇦', cities: [
    'Casablanca', 'Rabat', 'Marrakech', 'Fès', 'Tanger', 'Agadir', 'Meknès',
  ]),
  Country(name: 'Algérie', flag: '🇩🇿', cities: [
    'Alger', 'Oran', 'Constantine', 'Annaba', 'Blida', 'Sétif',
  ]),
  Country(name: 'Tunisie', flag: '🇹🇳', cities: [
    'Tunis', 'Sfax', 'Sousse', 'Kairouan', 'Bizerte',
  ]),
  Country(name: 'Sénégal', flag: '🇸🇳', cities: [
    'Dakar', 'Thiès', 'Saint-Louis', 'Touba',
  ]),
  Country(name: "Côte d'Ivoire", flag: '🇨🇮', cities: [
    'Abidjan', 'Bouaké', 'Yamoussoukro', 'Daloa',
  ]),
  Country(name: 'Égypte', flag: '🇪🇬', cities: [
    'Le Caire', 'Alexandrie', 'Gizeh', 'Charm el-Cheikh', 'Louxor',
  ]),
  Country(name: 'Arabie Saoudite', flag: '🇸🇦', cities: [
    'Riyad', 'Djeddah', 'La Mecque', 'Médine', 'Dammam',
  ]),
  Country(name: 'Émirats arabes unis', flag: '🇦🇪', cities: [
    'Dubaï', 'Abou Dabi', 'Charjah', 'Al-Aïn',
  ]),
  Country(name: 'Turquie', flag: '🇹🇷', cities: [
    'Istanbul', 'Ankara', 'Izmir', 'Antalya', 'Bursa', 'Adana',
  ]),
  Country(name: 'Russie', flag: '🇷🇺', cities: [
    'Moscou', 'Saint-Pétersbourg', 'Novossibirsk', 'Iekaterinbourg', 'Kazan',
  ]),
  Country(name: 'Chine', flag: '🇨🇳', cities: [
    'Pékin', 'Shanghai', 'Canton', 'Shenzhen', 'Chengdu', 'Hong Kong',
  ]),
  Country(name: 'Japon', flag: '🇯🇵', cities: [
    'Tokyo', 'Osaka', 'Kyoto', 'Yokohama', 'Nagoya', 'Sapporo', 'Fukuoka',
  ]),
  Country(name: 'Corée du Sud', flag: '🇰🇷', cities: [
    'Séoul', 'Busan', 'Incheon', 'Daegu', 'Daejeon',
  ]),
  Country(name: 'Inde', flag: '🇮🇳', cities: [
    'Bombay', 'Delhi', 'Bangalore', 'Hyderabad', 'Chennai', 'Calcutta',
  ]),
  Country(name: 'Australie', flag: '🇦🇺', cities: [
    'Sydney', 'Melbourne', 'Brisbane', 'Perth', 'Adélaïde',
  ]),
  Country(name: 'Luxembourg', flag: '🇱🇺', cities: ['Luxembourg', 'Esch-sur-Alzette']),
  Country(name: 'Islande', flag: '🇮🇸', cities: ['Reykjavík', 'Akureyri', 'Kópavogur']),
  Country(name: 'Norvège', flag: '🇳🇴', cities: ['Oslo', 'Bergen', 'Trondheim', 'Stavanger']),
  Country(name: 'Suède', flag: '🇸🇪', cities: ['Stockholm', 'Göteborg', 'Malmö', 'Uppsala']),
  Country(name: 'Danemark', flag: '🇩🇰', cities: ['Copenhague', 'Aarhus', 'Odense']),
  Country(name: 'Finlande', flag: '🇫🇮', cities: ['Helsinki', 'Espoo', 'Tampere', 'Turku']),
  Country(name: 'Irlande', flag: '🇮🇪', cities: ['Dublin', 'Cork', 'Galway', 'Limerick']),
  Country(name: 'Pologne', flag: '🇵🇱', cities: ['Varsovie', 'Cracovie', 'Gdańsk', 'Wrocław']),
  Country(name: 'Ukraine', flag: '🇺🇦', cities: ['Kyiv', 'Lviv', 'Odessa', 'Kharkiv']),
  Country(name: 'Grèce', flag: '🇬🇷', cities: ['Athènes', 'Thessalonique', 'Héraklion']),
  Country(name: 'Philippines', flag: '🇵🇭', cities: [
    'Manille', 'Quezon City', 'Cebu', 'Davao', 'Makati', 'Pasig', 'Taguig', 'Baguio',
  ]),
  // ── Tous les autres pays du monde (ordre alphabétique) ──
  Country(name: 'Afrique du Sud', flag: '🇿🇦', cities: ['Johannesburg', 'Le Cap', 'Durban', 'Pretoria']),
  Country(name: 'Albanie', flag: '🇦🇱', cities: ['Tirana', 'Durrës']),
  Country(name: 'Arménie', flag: '🇦🇲', cities: ['Erevan']),
  Country(name: 'Autriche', flag: '🇦🇹', cities: ['Vienne', 'Graz', 'Salzbourg', 'Innsbruck']),
  Country(name: 'Azerbaïdjan', flag: '🇦🇿', cities: ['Bakou']),
  Country(name: 'Bahreïn', flag: '🇧🇭', cities: ['Manama']),
  Country(name: 'Bangladesh', flag: '🇧🇩', cities: ['Dacca', 'Chittagong', 'Khulna']),
  Country(name: 'Biélorussie', flag: '🇧🇾', cities: ['Minsk']),
  Country(name: 'Bolivie', flag: '🇧🇴', cities: ['La Paz', 'Santa Cruz de la Sierra', 'Cochabamba', 'Sucre', 'El Alto']),
  Country(name: 'Bosnie-Herzégovine', flag: '🇧🇦', cities: ['Sarajevo']),
  Country(name: 'Bulgarie', flag: '🇧🇬', cities: ['Sofia', 'Plovdiv', 'Varna']),
  Country(name: 'Cambodge', flag: '🇰🇭', cities: ['Phnom Penh', 'Siem Reap']),
  Country(name: 'Cameroun', flag: '🇨🇲', cities: ['Douala', 'Yaoundé']),
  Country(name: 'Chili', flag: '🇨🇱', cities: ['Santiago', 'Valparaíso', 'Concepción', 'Viña del Mar', 'Antofagasta']),
  Country(name: 'Chypre', flag: '🇨🇾', cities: ['Nicosie']),
  Country(name: 'Costa Rica', flag: '🇨🇷', cities: ['San José']),
  Country(name: 'Croatie', flag: '🇭🇷', cities: ['Zagreb', 'Split']),
  Country(name: 'Cuba', flag: '🇨🇺', cities: ['La Havane']),
  Country(name: 'Équateur', flag: '🇪🇨', cities: ['Quito', 'Guayaquil', 'Cuenca']),
  Country(name: 'Estonie', flag: '🇪🇪', cities: ['Tallinn']),
  Country(name: 'Géorgie', flag: '🇬🇪', cities: ['Tbilissi', 'Batoumi']),
  Country(name: 'Guadeloupe', flag: '🇬🇵', cities: ['Pointe-à-Pitre']),
  Country(name: 'Guatemala', flag: '🇬🇹', cities: ['Guatemala', 'Quetzaltenango']),
  Country(name: 'Guyane française', flag: '🇬🇫', cities: ['Cayenne']),
  Country(name: 'Haïti', flag: '🇭🇹', cities: ['Port-au-Prince', 'Cap-Haïtien']),
  Country(name: 'Honduras', flag: '🇭🇳', cities: ['Tegucigalpa', 'San Pedro Sula']),
  Country(name: 'Hong Kong', flag: '🇭🇰', cities: ['Hong Kong']),
  Country(name: 'Hongrie', flag: '🇭🇺', cities: ['Budapest', 'Debrecen']),
  Country(name: 'Indonésie', flag: '🇮🇩', cities: ['Jakarta', 'Surabaya', 'Bandung', 'Denpasar']),
  Country(name: 'Irak', flag: '🇮🇶', cities: ['Bagdad', 'Erbil']),
  Country(name: 'Iran', flag: '🇮🇷', cities: ['Téhéran', 'Ispahan', 'Chiraz']),
  Country(name: 'Israël', flag: '🇮🇱', cities: ['Tel Aviv', 'Jérusalem', 'Haïfa']),
  Country(name: 'Jordanie', flag: '🇯🇴', cities: ['Amman']),
  Country(name: 'Kenya', flag: '🇰🇪', cities: ['Nairobi', 'Mombasa']),
  Country(name: 'Koweït', flag: '🇰🇼'),
  Country(name: 'La Réunion', flag: '🇷🇪', cities: ['Saint-Denis']),
  Country(name: 'Lettonie', flag: '🇱🇻', cities: ['Riga']),
  Country(name: 'Liban', flag: '🇱🇧', cities: ['Beyrouth', 'Tripoli']),
  Country(name: 'Lituanie', flag: '🇱🇹', cities: ['Vilnius', 'Kaunas']),
  Country(name: 'Macédoine du Nord', flag: '🇲🇰', cities: ['Skopje']),
  Country(name: 'Malaisie', flag: '🇲🇾', cities: ['Kuala Lumpur', 'George Town', 'Johor Bahru']),
  Country(name: 'Malte', flag: '🇲🇹', cities: ['La Valette']),
  Country(name: 'Martinique', flag: '🇲🇶', cities: ['Fort-de-France']),
  Country(name: 'Mayotte', flag: '🇾🇹', cities: ['Mamoudzou']),
  Country(name: 'Moldavie', flag: '🇲🇩', cities: ['Chișinău']),
  Country(name: 'Monténégro', flag: '🇲🇪', cities: ['Podgorica']),
  Country(name: 'Népal', flag: '🇳🇵', cities: ['Katmandou', 'Pokhara']),
  Country(name: 'Nicaragua', flag: '🇳🇮', cities: ['Managua']),
  Country(name: 'Nigeria', flag: '🇳🇬', cities: ['Lagos', 'Abuja', 'Kano', 'Ibadan']),
  Country(name: 'Nouvelle-Calédonie', flag: '🇳🇨', cities: ['Nouméa']),
  Country(name: 'Nouvelle-Zélande', flag: '🇳🇿', cities: ['Auckland', 'Wellington', 'Christchurch']),
  Country(name: 'Oman', flag: '🇴🇲', cities: ['Mascate']),
  Country(name: 'Pakistan', flag: '🇵🇰', cities: ['Karachi', 'Lahore', 'Islamabad']),
  Country(name: 'Palestine', flag: '🇵🇸', cities: ['Gaza', 'Ramallah']),
  Country(name: 'Panama', flag: '🇵🇦', cities: ['Panama', 'Colón']),
  Country(name: 'Paraguay', flag: '🇵🇾', cities: ['Asunción', 'Ciudad del Este', 'Encarnación']),
  Country(name: 'Pérou', flag: '🇵🇪', cities: ['Lima', 'Arequipa', 'Trujillo', 'Cusco', 'Chiclayo']),
  Country(name: 'Polynésie française', flag: '🇵🇫', cities: ['Papeete']),
  Country(name: 'Porto Rico', flag: '🇵🇷', cities: ['San Juan']),
  Country(name: 'Qatar', flag: '🇶🇦', cities: ['Doha']),
  Country(name: 'République dominicaine', flag: '🇩🇴', cities: ['Saint-Domingue', 'Santiago de los Caballeros']),
  Country(name: 'Roumanie', flag: '🇷🇴', cities: ['Bucarest', 'Cluj-Napoca', 'Timișoara']),
  Country(name: 'Salvador', flag: '🇸🇻', cities: ['San Salvador']),
  Country(name: 'Serbie', flag: '🇷🇸', cities: ['Belgrade', 'Novi Sad']),
  Country(name: 'Singapour', flag: '🇸🇬', cities: ['Singapour']),
  Country(name: 'Slovaquie', flag: '🇸🇰', cities: ['Bratislava', 'Košice']),
  Country(name: 'Slovénie', flag: '🇸🇮', cities: ['Ljubljana']),
  Country(name: 'Sri Lanka', flag: '🇱🇰', cities: ['Colombo', 'Kandy']),
  Country(name: 'Syrie', flag: '🇸🇾', cities: ['Damas', 'Alep']),
  Country(name: 'Taïwan', flag: '🇹🇼', cities: ['Taipei', 'Kaohsiung', 'Taichung']),
  Country(name: 'Tchéquie', flag: '🇨🇿', cities: ['Prague', 'Brno']),
  Country(name: 'Thaïlande', flag: '🇹🇭', cities: ['Bangkok', 'Chiang Mai', 'Phuket', 'Pattaya']),
  Country(name: 'Uruguay', flag: '🇺🇾', cities: ['Montevideo', 'Salto', 'Punta del Este']),
  Country(name: 'Venezuela', flag: '🇻🇪', cities: ['Caracas', 'Maracaibo', 'Valencia', 'Barquisimeto']),
  Country(name: 'Viêt Nam', flag: '🇻🇳', cities: ['Hô Chi Minh-Ville', 'Hanoï', 'Da Nang']),
];

/// The flag emoji for a stored [country] name (verbatim match against
/// [kCountries]), or null when the name is empty / unknown. Used to show a
/// person's COUNTRY flag (which the spoken language doesn't always match).
String? countryFlagFor(String country) {
  final name = country.trim();
  if (name.isEmpty) return null;
  for (final c in kCountries) {
    if (c.name == name) return c.flag;
  }
  return null;
}

/// ISO-3166-1 alpha-2 code for a stored country label, or `''` when unknown.
/// Real flag artwork is fetched with this code — nordic crosses, the Union
/// Jack and disc flags can't be faked with colour bands.
String countryIso2For(String country) => _kIso2[country.trim()] ?? '';

/// The inverse of [countryIso2For]: the canonical label stored on
/// `profiles.country` for an ISO2 code, or null when it isn't one of our
/// curated countries. Used to turn a GPS reverse-geocode result (which only
/// gives an ISO2 code) back into the exact string every other consumer of
/// `profiles.country` (flags, Discover's cross-country bonus, …) expects.
String? countryNameForIso2(String iso2) {
  final code = iso2.trim().toLowerCase();
  if (code.isEmpty) return null;
  for (final entry in _kIso2.entries) {
    if (entry.value == code) return entry.key;
  }
  return null;
}

const Map<String, String> _kIso2 = {
  'France': 'fr',
  'Belgique': 'be',
  'Suisse': 'ch',
  'Canada': 'ca',
  'États-Unis': 'us',
  'Royaume-Uni': 'gb',
  'Espagne': 'es',
  'Portugal': 'pt',
  'Italie': 'it',
  'Allemagne': 'de',
  'Pays-Bas': 'nl',
  'Mexique': 'mx',
  'Argentine': 'ar',
  'Colombie': 'co',
  'Brésil': 'br',
  'Maroc': 'ma',
  'Algérie': 'dz',
  'Tunisie': 'tn',
  'Sénégal': 'sn',
  "Côte d'Ivoire": 'ci',
  'Égypte': 'eg',
  'Arabie Saoudite': 'sa',
  'Émirats arabes unis': 'ae',
  'Turquie': 'tr',
  'Russie': 'ru',
  'Chine': 'cn',
  'Japon': 'jp',
  'Corée du Sud': 'kr',
  'Inde': 'in',
  'Australie': 'au',
  'Luxembourg': 'lu',
  'Islande': 'is',
  'Norvège': 'no',
  'Suède': 'se',
  'Danemark': 'dk',
  'Finlande': 'fi',
  'Irlande': 'ie',
  'Pologne': 'pl',
  'Ukraine': 'ua',
  'Grèce': 'gr',
  'Philippines': 'ph',
  'Afrique du Sud': 'za',
  'Albanie': 'al',
  'Arménie': 'am',
  'Autriche': 'at',
  'Azerbaïdjan': 'az',
  'Bahreïn': 'bh',
  'Bangladesh': 'bd',
  'Biélorussie': 'by',
  'Bolivie': 'bo',
  'Bosnie-Herzégovine': 'ba',
  'Bulgarie': 'bg',
  'Cambodge': 'kh',
  'Cameroun': 'cm',
  'Chili': 'cl',
  'Chypre': 'cy',
  'Costa Rica': 'cr',
  'Croatie': 'hr',
  'Cuba': 'cu',
  'Équateur': 'ec',
  'Estonie': 'ee',
  'Géorgie': 'ge',
  'Guadeloupe': 'gp',
  'Guatemala': 'gt',
  'Guyane française': 'gf',
  'Haïti': 'ht',
  'Honduras': 'hn',
  'Hong Kong': 'hk',
  'Hongrie': 'hu',
  'Indonésie': 'id',
  'Irak': 'iq',
  'Iran': 'ir',
  'Israël': 'il',
  'Jordanie': 'jo',
  'Kenya': 'ke',
  'Koweït': 'kw',
  'La Réunion': 're',
  'Lettonie': 'lv',
  'Liban': 'lb',
  'Lituanie': 'lt',
  'Macédoine du Nord': 'mk',
  'Malaisie': 'my',
  'Malte': 'mt',
  'Martinique': 'mq',
  'Mayotte': 'yt',
  'Moldavie': 'md',
  'Monténégro': 'me',
  'Népal': 'np',
  'Nicaragua': 'ni',
  'Nigeria': 'ng',
  'Nouvelle-Calédonie': 'nc',
  'Nouvelle-Zélande': 'nz',
  'Oman': 'om',
  'Pakistan': 'pk',
  'Palestine': 'ps',
  'Panama': 'pa',
  'Paraguay': 'py',
  'Pérou': 'pe',
  'Polynésie française': 'pf',
  'Porto Rico': 'pr',
  'Qatar': 'qa',
  'République dominicaine': 'do',
  'Roumanie': 'ro',
  'Salvador': 'sv',
  'Serbie': 'rs',
  'Singapour': 'sg',
  'Slovaquie': 'sk',
  'Slovénie': 'si',
  'Sri Lanka': 'lk',
  'Syrie': 'sy',
  'Taïwan': 'tw',
  'Tchéquie': 'cz',
  'Thaïlande': 'th',
  'Uruguay': 'uy',
  'Venezuela': 've',
  'Viêt Nam': 'vn',
};
