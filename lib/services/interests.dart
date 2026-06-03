import 'package:flutter/material.dart';

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

/// The master taxonomy. Tags are stored on the profile as their plain label
/// string (e.g. "K-pop"), so editing this list later is safe as long as the
/// labels stay stable. Tweak freely — categories, colours, shapes and options
/// are all here.
const List<InterestCategory> kInterestCategories = [
  InterestCategory(
    label: 'Culture Pop',
    emoji: '🎌',
    color: Color(0xFFFB7185), // rose
    shape: InterestShape.stadium, // pill / "ovale"
    options: [
      'Anime', 'Manga', 'K-pop', 'J-pop', 'Films', 'Séries', 'Cosplay',
    ],
  ),
  InterestCategory(
    label: 'Gaming',
    emoji: '🎮',
    color: Color(0xFF38BDF8), // sky blue
    shape: InterestShape.beveled, // cut corners
    options: [
      'RPG', 'FPS', 'Mobile', 'Nintendo', 'Pokémon', 'Esport', 'Rétro',
    ],
  ),
  InterestCategory(
    label: 'Rencontres',
    emoji: '🤝',
    color: Color(0xFF22C55E), // green
    shape: InterestShape.rounded, // soft rounded rectangle
    options: [
      'Nouveaux amis', 'Discussions', 'Voyage', 'Langues', 'Découverte',
      'Cultures',
    ],
  ),
  InterestCategory(
    label: 'Musique',
    emoji: '🎵',
    color: Color(0xFFA855F7), // violet
    shape: InterestShape.leaf, // diagonally rounded
    options: [
      'Pop', 'Rap', 'Rock', 'Électro', 'K-pop', 'J-pop', 'Jazz',
    ],
  ),
  InterestCategory(
    label: 'Lifestyle',
    emoji: '✨',
    color: Color(0xFFFBBF24), // amber
    shape: InterestShape.rectangle, // crisp rectangle
    options: [
      'Cuisine', 'Photo', 'Mode', 'Art', 'Animaux', 'Café', 'Nature',
      'Lecture',
    ],
  ),
];

/// Colour for a chip [label] = its CATEGORY colour (Culture Pop → rose,
/// Gaming → blue, Rencontres → green, Musique → violet, Lifestyle → amber).
/// Labels present in two categories (K-pop, J-pop) take the first match.
/// Falls back to a neutral slate for a tag no longer in the taxonomy.
Color interestColor(String label) {
  for (final c in kInterestCategories) {
    if (c.options.contains(label)) return c.color;
  }
  return const Color(0xFF64748B);
}

/// Shape for a chip [label] = its CATEGORY shape. Mirrors [interestColor];
/// falls back to a pill for a tag no longer in the taxonomy. Picker rows know
/// their own category, so they pass `cat.shape` directly instead (this is for
/// the read-only profile display, where only the stored label is known).
InterestShape interestShape(String label) {
  for (final c in kInterestCategories) {
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
