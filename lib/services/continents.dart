/// Continents « de Discover » : on équilibre le paquet entre ces trois zones.
/// Les pays sont ceux de `profiles.country` (noms français, comme en base).
enum DiscoverContinent { latam, asia, europe, other }

const Set<String> _kLatam = {
  'Mexique', 'Argentine', 'Colombie', 'Brésil', 'Pérou', 'Chili', 'Venezuela',
  'Vénézuela', 'Équateur', 'Uruguay', 'Paraguay', 'Bolivie', 'Costa Rica',
  'Panama', 'Cuba', 'République dominicaine', 'Guatemala', 'Honduras',
  'Salvador', 'Nicaragua',
};

const Set<String> _kAsia = {
  'Japon', 'Corée du Sud', 'Philippines', 'Inde', 'Chine', 'Thaïlande',
  'Vietnam', 'Viêt Nam', 'Indonésie', 'Malaisie', 'Singapour', 'Taïwan',
  'Hong Kong', 'Pakistan', 'Bangladesh', 'Sri Lanka', 'Népal', 'Cambodge',
};

const Set<String> _kEurope = {
  'France', 'Belgique', 'Suisse', 'Allemagne', 'Suède', 'Espagne', 'Portugal',
  'Italie', 'Pays-Bas', 'Royaume-Uni', 'Irlande', 'Luxembourg', 'Islande',
  'Norvège', 'Danemark', 'Finlande', 'Pologne', 'Ukraine', 'Grèce', 'Russie',
  'Turquie', 'Autriche', 'Roumanie', 'République tchèque', 'Hongrie',
};

/// Le continent d'un pays (nom stocké dans `profiles.country`), ou `other`
/// quand il est vide ou hors de ces trois zones : aucun quota ne s'y applique.
DiscoverContinent continentOfCountry(String country) {
  final c = country.trim();
  if (_kLatam.contains(c)) return DiscoverContinent.latam;
  if (_kAsia.contains(c)) return DiscoverContinent.asia;
  if (_kEurope.contains(c)) return DiscoverContinent.europe;
  return DiscoverContinent.other;
}
