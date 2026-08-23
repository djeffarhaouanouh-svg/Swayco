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
    examplesFr: 'Football, basket, tennis, MMA, F1, course à pied, salle',
  ),
  PersonaCategory(
    label: 'Mélomane',
    emoji: '🎵',
    examplesFr: 'Rap, R&B, K-pop, rock, afrobeat, EDM',
  ),
  PersonaCategory(
    label: 'Gamer',
    emoji: '🎮',
    examplesFr: 'FPS, RPG, Nintendo, PlayStation, PC, mobile',
  ),
  PersonaCategory(
    label: 'Voyageur',
    emoji: '✈️',
    examplesFr: 'Japon, Europe, sac à dos, road trips, voyage solo',
  ),
  PersonaCategory(
    label: 'Gourmet',
    emoji: '🍜',
    examplesFr: 'Cuisine japonaise, street food, restaurants, pâtisserie',
  ),
  PersonaCategory(
    label: 'Cinéphile',
    emoji: '🎬',
    examplesFr: 'Films, séries, anime, K-dramas, Marvel, Disney',
  ),
  PersonaCategory(
    label: 'Fashion',
    emoji: '👗',
    examplesFr: 'Streetwear, luxe, sneakers, vintage, beauté',
  ),
  PersonaCategory(
    label: 'Fitness',
    emoji: '💪',
    examplesFr: 'Musculation, course à pied, nutrition, CrossFit, bien-être',
  ),
  PersonaCategory(
    label: 'Ambitieux',
    emoji: '💼',
    examplesFr: 'Entrepreneuriat, business, finance, carrière, leadership',
  ),
  PersonaCategory(
    label: 'Créatif',
    emoji: '🎨',
    examplesFr: 'Dessin, photo, vidéo, design, musique',
  ),
  PersonaCategory(
    label: 'Curieux',
    emoji: '📚',
    examplesFr: 'Histoire, sciences, philosophie, psychologie, culture',
  ),
  PersonaCategory(
    label: 'Tech',
    emoji: '💻',
    examplesFr: 'IA, programmation, startups, gadgets, crypto',
  ),
  PersonaCategory(
    label: 'Nature',
    emoji: '🌿',
    examplesFr: 'Randonnée, camping, animaux, plage, montagne',
  ),
  PersonaCategory(
    label: 'Fêtard',
    emoji: '🎉',
    examplesFr: 'Clubs, festivals, concerts, nuits, événements',
  ),
  PersonaCategory(
    label: 'Culturel',
    emoji: '🎭',
    examplesFr: 'Traditions, langues, art, histoire, cultures étrangères',
  ),
  PersonaCategory(
    label: 'Romantique',
    emoji: '❤️',
    examplesFr: 'Rencontres, couples, romance, relations',
  ),
  PersonaCategory(
    label: 'Zen',
    emoji: '🧘',
    examplesFr: 'Méditation, yoga, bien-être, spiritualité',
  ),
  PersonaCategory(
    label: "Passionné d'automobile",
    emoji: '🏎️',
    examplesFr: 'Voitures, JDM, supercars, sport auto, tuning',
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
