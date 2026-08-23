import 'package:flutter/material.dart';

// Re-export the display-translation helper so every importer of this file
// (onboarding, profile) gets `interestLabel(...)` without an extra import.
export 'interests_i18n.dart';

/// The geometric silhouette used for a category's chips ("pins"). Each
/// interest category renders its chips with a distinct shape so the
/// categories are recognisable at a glance (pill vs cut-corner vs leaf …).
enum InterestShape { stadium, rounded, rectangle, leaf, beveled }

/// A predefined "centre d'intérêt" category — a coloured, emoji-led group of
/// selectable tags shown in the profile's "Centres d'intérêt" section and its
/// picker. The [color] tints every chip belonging to the category and [shape]
/// gives the category its own chip silhouette, so the profile keeps a lively,
/// multi-colour, multi-shape tag look while staying on-brand.
class InterestCategory {
  const InterestCategory({
    required this.label,
    required this.emoji,
    required this.color,
    required this.shape,
    required this.options,
  });

  final String label;
  final String emoji;
  final Color color;
  final InterestShape shape;
  final List<String> options;
}

/// A single universal taxonomy shared by every user regardless of
/// nationality — the whole point is that two people who don't speak the same
/// language can both pick "Football" or "Gaming" and have an instant, legible
/// reason to talk to each other. (This replaces the earlier France⇄Japan
/// "what do you love about the other culture" taxonomy, which by design could
/// never produce a shared tag between two French or two Japanese users.)
/// Tags are stored on the profile as their plain label string, so editing
/// these lists later is safe as long as the labels stay stable.
const List<InterestCategory> kInterestCategories = [
  InterestCategory(
    label: 'Sport',
    emoji: '⚽',
    color: Color(0xFF22C55E), // vert
    shape: InterestShape.stadium,
    options: [
      'Football', 'Basketball', 'Tennis', 'MMA', 'Formule 1',
      'Course à pied', 'Musculation', 'Yoga',
    ],
  ),
  InterestCategory(
    label: 'Musique',
    emoji: '🎵',
    color: Color(0xFFF97316), // orange
    shape: InterestShape.rounded,
    options: [
      'Rap', 'R&B', 'K-pop', 'J-pop', 'Rock', 'Afrobeats', 'Karaoké',
      'Vocaloid',
    ],
  ),
  InterestCategory(
    label: 'Gaming',
    emoji: '🎮',
    color: Color(0xFFD946EF), // magenta
    shape: InterestShape.rectangle,
    options: [
      'Nintendo', 'Pokémon', 'Arcades', 'Compétitif', 'Casual',
      'PlayStation', 'PC', 'Mobile',
    ],
  ),
  InterestCategory(
    label: 'Divertissement',
    emoji: '🎬',
    color: Color(0xFF3B82F6), // bleu
    shape: InterestShape.leaf,
    options: [
      'Manga', 'Anime', 'Studio Ghibli', 'One Piece', 'Naruto',
      'Dragon Ball', 'Demon Slayer', 'Cosplay', 'Cinéma', 'Séries',
    ],
  ),
  InterestCategory(
    label: 'Cuisine',
    emoji: '🍜',
    color: Color(0xFFEAB308), // jaune
    shape: InterestShape.beveled,
    options: [
      'Sushi', 'Ramen', 'Matcha', 'Wagyū', 'Tempura', 'Croissant', 'Fromage',
      'Pâtisserie', 'Vin', 'Café',
    ],
  ),
  InterestCategory(
    label: 'Voyage',
    emoji: '✈️',
    color: Color(0xFFEC4899), // rose
    shape: InterestShape.stadium,
    options: [
      'Tour Eiffel', 'Paris', 'Versailles', 'Notre-Dame', 'Arc de Triomphe',
      'Châteaux', 'Mont Fuji', 'Tokyo', 'Kyoto', 'Osaka',
    ],
  ),
  InterestCategory(
    label: 'Nature & Bien-être',
    emoji: '🌿',
    color: Color(0xFF8B5CF6), // violet
    shape: InterestShape.rounded,
    options: [
      'Onsen', 'Jardins zen', 'Bonsaï', 'Calligraphie', 'Bambou',
      'Randonnée', 'Nature',
    ],
  ),
  InterestCategory(
    label: 'Art & Culture',
    emoji: '🎨',
    color: Color(0xFF0EA5E9), // cyan
    shape: InterestShape.rectangle,
    options: [
      'Samouraïs', 'Sakura', 'Kimono', 'Temples', 'Louvre', 'Monet',
      'Littérature', 'Musées', 'Théâtre', 'Architecture',
    ],
  ),
  InterestCategory(
    label: 'Lifestyle',
    emoji: '👗',
    color: Color(0xFFEF4444), // rouge
    shape: InterestShape.leaf,
    options: [
      'Mode', 'Haute couture', 'Parfum', 'Luxe', 'Bijoux', 'Kawaii',
      'Romance', 'Terrasses', 'Marchés', 'Flâner',
    ],
  ),
  InterestCategory(
    label: 'Ambition',
    emoji: '💼',
    color: Color(0xFF14B8A6), // teal
    shape: InterestShape.beveled,
    options: [
      'Entrepreneuriat', 'Startups', 'Tech', 'Robots', 'Finance',
      'Investissement', 'Études', 'Carrière',
    ],
  ),
];

/// Every category — kept as its own name (rather than inlining
/// [kInterestCategories] at every call site) so helpers below read the same
/// regardless of how many taxonomies existed historically.
const List<InterestCategory> kAllInterestCategories = kInterestCategories;

/// The category set to show a user picking their interests. Every user sees
/// the same universal taxonomy now — [country] is accepted (and ignored) so
/// existing call sites don't need to change.
List<InterestCategory> interestCategoriesFor(String country) {
  return kInterestCategories;
}

/// Cyclic Relief-3D palette for interest tags (display order on the profile).
/// Colour is assigned by index in the list: `PALETTE[i % length]`.
const List<Color> kInterestTagPalette = [
  Color(0xFF22C55E), // vert
  Color(0xFFF97316), // orange
  Color(0xFFD946EF), // magenta
  Color(0xFF3B82F6), // bleu
  Color(0xFFEAB308), // jaune
  Color(0xFFEC4899), // rose
  Color(0xFF8B5CF6), // violet
  Color(0xFF0EA5E9), // cyan
  Color(0xFFEF4444), // rouge
  Color(0xFF14B8A6), // teal
];

/// Palette colour for the tag at [index] in a displayed interests list.
Color interestPaletteColor(int index) =>
    kInterestTagPalette[index % kInterestTagPalette.length];

/// Darken [color] by multiplying each RGB channel by `(1 - amount)`.
/// Used for the hard bottom lip of the Relief-3D tag shadow (amount 0.38).
Color interestDarken(Color color, [double amount = 0.38]) {
  return Color.from(
    alpha: color.a,
    red: color.r * (1 - amount),
    green: color.g * (1 - amount),
    blue: color.b * (1 - amount),
  );
}

/// Colour for a chip [label] = its CATEGORY colour. Falls back to a neutral
/// slate for a tag no longer in the taxonomy (e.g. one picked under the old
/// France/Japan taxonomy) so old selections keep rendering, just undyed.
///
/// Prefer [interestPaletteColor] for profile / discover display chips (Relief
/// 3D handoff). This helper remains for category-tinted picker headers.
Color interestColor(String label) {
  for (final c in kAllInterestCategories) {
    if (c.options.contains(label)) return c.color;
  }
  return const Color(0xFF64748B);
}

/// Shape for a chip [label] = its CATEGORY shape. Mirrors [interestColor];
/// falls back to a pill for a tag no longer in the taxonomy. Picker rows know
/// their own category, so they pass `cat.shape` directly instead (this is for
/// the read-only profile display, where only the stored label is known).
InterestShape interestShape(String label) {
  for (final c in kAllInterestCategories) {
    if (c.options.contains(label)) return c.shape;
  }
  return InterestShape.stadium;
}

/// Builds the [OutlinedBorder] for an [InterestShape], optionally with a
/// [side] (the chip's outline). Used by the chip widgets so the Material
/// fill, the ink ripple and the border all share one silhouette.
OutlinedBorder interestShapeBorder(
  InterestShape shape, {
  BorderSide side = BorderSide.none,
}) {
  switch (shape) {
    case InterestShape.stadium:
      return StadiumBorder(side: side);
    case InterestShape.rounded:
      return RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: side,
      );
    case InterestShape.rectangle:
      return RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: side,
      );
    case InterestShape.leaf:
      return RoundedRectangleBorder(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(18),
          bottomRight: Radius.circular(18),
          topRight: Radius.circular(5),
          bottomLeft: Radius.circular(5),
        ),
        side: side,
      );
    case InterestShape.beveled:
      return BeveledRectangleBorder(
        borderRadius: BorderRadius.circular(11),
        side: side,
      );
  }
}
