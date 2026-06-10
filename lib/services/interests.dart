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

/// Two culture-specific taxonomies. The app bridges France ⇄ Japan, so the
/// interests step asks each person what they love about the OTHER culture:
/// someone from Japan picks what they like about France, everyone else picks
/// what they like about Japan (see [interestCategoriesFor]). Tags are stored on
/// the profile as their plain label string, so editing these lists later is
/// safe as long as the labels stay stable.

/// What (non-Japanese) users love about Japan — the default set. Generous but
/// curated: every tag is an iconic, popular pick (no filler).
const List<InterestCategory> kJapanInterestCategories = [
  InterestCategory(
    label: 'Manga & Anime',
    emoji: '🎌',
    color: Color(0xFFFB7185), // rose
    shape: InterestShape.stadium, // pill / "ovale"
    options: [
      'Manga', 'Anime', 'Studio Ghibli', 'One Piece', 'Naruto',
      'Dragon Ball', 'Demon Slayer', 'Cosplay',
    ],
  ),
  InterestCategory(
    label: 'Cuisine',
    emoji: '🍜',
    color: Color(0xFFFBBF24), // amber
    shape: InterestShape.rectangle, // crisp rectangle
    options: [
      'Sushi', 'Ramen', 'Mochi', 'Takoyaki', 'Matcha', 'Wagyū', 'Tempura',
      'Okonomiyaki',
    ],
  ),
  InterestCategory(
    label: 'Traditions',
    emoji: '⛩️',
    color: Color(0xFF22C55E), // green
    shape: InterestShape.rounded, // soft rounded rectangle
    options: [
      'Samouraïs', 'Ninjas', 'Geishas', 'Sakura', 'Onsen', 'Kimono', 'Sumo',
      'Temples',
    ],
  ),
  InterestCategory(
    label: 'Pop & Tech',
    emoji: '🎮',
    color: Color(0xFF38BDF8), // sky blue
    shape: InterestShape.beveled, // cut corners
    options: [
      'Nintendo', 'Pokémon', 'J-pop', 'Karaoké', 'Kawaii', 'Vocaloid',
      'Arcades', 'Robots',
    ],
  ),
  InterestCategory(
    label: 'Voyage & Nature',
    emoji: '🗻',
    color: Color(0xFFA855F7), // violet
    shape: InterestShape.leaf, // diagonally rounded
    options: [
      'Mont Fuji', 'Tokyo', 'Kyoto', 'Osaka', 'Jardins zen', 'Bonsaï',
      'Calligraphie', 'Bambou',
    ],
  ),
];

/// What Japanese users love about France — shown only when the picked country
/// is Japan. Generous but curated: Paris, gastronomy, fashion/luxury, art and
/// the art de vivre, with only iconic, desirable picks.
const List<InterestCategory> kFranceInterestCategories = [
  InterestCategory(
    label: 'Paris & Monuments',
    emoji: '🗼',
    color: Color(0xFF38BDF8), // sky blue
    shape: InterestShape.beveled, // cut corners
    options: [
      'Tour Eiffel', 'Paris', 'Versailles', 'Mont-Saint-Michel', 'Notre-Dame',
      'Arc de Triomphe', 'Châteaux',
    ],
  ),
  InterestCategory(
    label: 'Gastronomie',
    emoji: '🥐',
    color: Color(0xFFFBBF24), // amber
    shape: InterestShape.rectangle, // crisp rectangle
    options: [
      'Croissant', 'Baguette', 'Fromage', 'Macarons', 'Crêpes', 'Pâtisserie',
      'Escargots', 'Foie gras',
    ],
  ),
  InterestCategory(
    label: 'Vins & Café',
    emoji: '🍷',
    color: Color(0xFFFB7185), // rose
    shape: InterestShape.stadium, // pill / "ovale"
    options: [
      'Vin', 'Champagne', 'Bordeaux', 'Café', 'Bistrot', 'Apéro',
    ],
  ),
  InterestCategory(
    label: 'Mode & Luxe',
    emoji: '👜',
    color: Color(0xFFF472B6), // pink
    shape: InterestShape.leaf, // diagonally rounded
    options: [
      'Mode', 'Haute couture', 'Parfum', 'Luxe', 'Élégance', 'Bijoux',
    ],
  ),
  InterestCategory(
    label: 'Art & Culture',
    emoji: '🎨',
    color: Color(0xFFA855F7), // violet
    shape: InterestShape.rounded, // soft rounded rectangle
    options: [
      'Louvre', 'Impressionnisme', 'Monet', 'Cinéma', 'Littérature', 'Musées',
      'Théâtre', 'Architecture',
    ],
  ),
  InterestCategory(
    label: 'Art de vivre',
    emoji: '✨',
    color: Color(0xFF22C55E), // green
    shape: InterestShape.stadium, // pill / "ovale"
    options: [
      'Romance', 'Terrasses', 'Marchés', 'Flâner', 'Provence', "Côte d'Azur",
    ],
  ),
];

/// Every category across both cultures — lets [interestColor] / [interestShape]
/// resolve a stored label's colour/shape regardless of which set it came from.
const List<InterestCategory> kAllInterestCategories = [
  ...kJapanInterestCategories,
  ...kFranceInterestCategories,
];

/// The category set to show for a given [country] (the verbatim name stored by
/// the location picker, e.g. 'Japon'). People from Japan are asked what they
/// like about France; everyone else is asked about Japan.
List<InterestCategory> interestCategoriesFor(String country) {
  return country.trim() == 'Japon'
      ? kFranceInterestCategories
      : kJapanInterestCategories;
}

/// Colour for a chip [label] = its CATEGORY colour, resolved across BOTH the
/// Japan and France taxonomies (so a stored label always finds its colour,
/// whichever set the user picked from). Falls back to a neutral slate for a
/// tag no longer in either taxonomy.
Color interestColor(String label) {
  for (final c in kAllInterestCategories) {
    if (c.options.contains(label)) return c.color;
  }
  return const Color(0xFF64748B);
}

/// Shape for a chip [label] = its CATEGORY shape, resolved across both
/// taxonomies. Mirrors [interestColor]; falls back to a pill for a tag no
/// longer in either taxonomy. Picker rows know their own category, so they
/// pass `cat.shape` directly instead (this is for the read-only profile
/// display, where only the stored label is known).
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
