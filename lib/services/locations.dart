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
