// Re-export the display-translation helper so every importer of this file
// (onboarding, profile) gets `personaCategoryLabel(...)` / `personaCategoryExamples(...)`
// without an extra import.
export 'persona_categories_i18n.dart';

/// A single "what defines you most" identity option — asked once at
/// onboarding (single choice, unlike the multi-select `interests` tags) so
/// Discover has one high-signal chip to show on the card and one more bonus
/// to weigh in the matching score. [examplesFr] is a short, purely
/// illustrative hint shown under the label (e.g. "Football, Basketball,
/// Tennis…") — it is display text, not a list of selectable tags.
class PersonaCategory {
  const PersonaCategory({
    required this.label,
    required this.emoji,
    required this.examplesFr,
  });

  final String label;
  final String emoji;
  final String examplesFr;
}

/// The 18-option "what defines you most" taxonomy. Stored on the profile as
/// the plain [label] string (`profiles.persona_category`), so editing this
/// list later is safe as long as labels stay stable.
const List<PersonaCategory> kPersonaCategories = [
  PersonaCategory(
    label: 'Sportif',
    emoji: '🏆',
    examplesFr: 'Football, Basketball, Tennis, MMA, F1, Running, Gym',
  ),
  PersonaCategory(
    label: 'Mélomane',
    emoji: '🎵',
    examplesFr: 'Rap, R&B, K-pop, Rock, Afrobeat, EDM',
  ),
  PersonaCategory(
    label: 'Gamer',
    emoji: '🎮',
    examplesFr: 'FPS, RPG, Nintendo, PlayStation, PC, Mobile',
  ),
  PersonaCategory(
    label: 'Voyageur',
    emoji: '✈️',
    examplesFr: 'Japon, Europe, Backpacking, Road trips, Solo travel',
  ),
  PersonaCategory(
    label: 'Gourmet',
    emoji: '🍜',
    examplesFr: 'Cuisine japonaise, Street food, Restaurants, Pâtisserie',
  ),
  PersonaCategory(
    label: 'Cinéphile',
    emoji: '🎬',
    examplesFr: 'Films, Séries, Anime, K-dramas, Marvel, Disney',
  ),
  PersonaCategory(
    label: 'Fashion',
    emoji: '👗',
    examplesFr: 'Streetwear, Luxury, Sneakers, Vintage, Beauty',
  ),
  PersonaCategory(
    label: 'Fitness',
    emoji: '💪',
    examplesFr: 'Musculation, Running, Nutrition, CrossFit, Wellness',
  ),
  PersonaCategory(
    label: 'Ambitieux',
    emoji: '💼',
    examplesFr: 'Entrepreneuriat, Business, Finance, Carrière, Leadership',
  ),
  PersonaCategory(
    label: 'Créatif',
    emoji: '🎨',
    examplesFr: 'Dessin, Photo, Vidéo, Design, Musique',
  ),
  PersonaCategory(
    label: 'Curieux',
    emoji: '📚',
    examplesFr: 'Histoire, Science, Philosophie, Psychologie, Culture',
  ),
  PersonaCategory(
    label: 'Tech',
    emoji: '💻',
    examplesFr: 'IA, Programmation, Startups, Gadgets, Crypto',
  ),
  PersonaCategory(
    label: 'Nature',
    emoji: '🌿',
    examplesFr: 'Randonnée, Camping, Animaux, Plage, Montagne',
  ),
  PersonaCategory(
    label: 'Fêtard',
    emoji: '🎉',
    examplesFr: 'Clubs, Festivals, Concerts, Nightlife, Events',
  ),
  PersonaCategory(
    label: 'Culturel',
    emoji: '🎭',
    examplesFr: 'Traditions, Langues, Art, Histoire, Culture étrangère',
  ),
  PersonaCategory(
    label: 'Romantique',
    emoji: '❤️',
    examplesFr: 'Dating, Couples, Romance, Relations',
  ),
  PersonaCategory(
    label: 'Zen',
    emoji: '🧘',
    examplesFr: 'Méditation, Yoga, Wellness, Spiritualité',
  ),
  PersonaCategory(
    label: "Passionné d'automobile",
    emoji: '🏎️',
    examplesFr: 'Cars, JDM, Supercars, Motorsport, Tuning',
  ),
];

/// The stored labels only, in taxonomy order — used by the onboarding step
/// and the profile wheel picker.
List<String> get kPersonaCategoryLabels =>
    kPersonaCategories.map((c) => c.label).toList(growable: false);

/// Find a [PersonaCategory] by its stored [label], or null if it isn't one
/// of the 18 (e.g. the field is empty, or came from an older client build).
PersonaCategory? personaCategoryByLabel(String label) {
  for (final c in kPersonaCategories) {
    if (c.label == label) return c;
  }
  return null;
}
