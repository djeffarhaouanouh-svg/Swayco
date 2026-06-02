import 'package:flutter/material.dart';

/// A predefined "centre d'intérêt" category — a coloured, emoji-led group of
/// selectable tags shown in the profile's "Centres d'intérêt" section and its
/// picker. The [color] tints every chip belonging to the category so the
/// profile keeps the lively, multi-colour tag look while staying on-brand.
class InterestCategory {
  const InterestCategory({
    required this.label,
    required this.emoji,
    required this.color,
    required this.options,
  });

  final String label;
  final String emoji;
  final Color color;
  final List<String> options;
}

/// The master taxonomy. Tags are stored on the profile as their plain label
/// string (e.g. "K-pop"), so editing this list later is safe as long as the
/// labels stay stable. Tweak freely — categories and options are all here.
const List<InterestCategory> kInterestCategories = [
  InterestCategory(
    label: 'Musique',
    emoji: '🎵',
    color: Color(0xFFA855F7), // violet
    options: [
      'Pop', 'Électro', 'Rap/Hip-hop', 'Rock', 'R&B',
      'K-pop', 'Jazz', 'Classique', 'Reggaeton', 'Métal',
    ],
  ),
  InterestCategory(
    label: 'Sport',
    emoji: '⚽',
    color: Color(0xFF22C55E), // green
    options: [
      'Football', 'Basket', 'Tennis', 'Muscu', 'Course',
      'Combat', 'Ski', 'Vélo', 'Yoga',
    ],
  ),
  InterestCategory(
    label: 'Films & Séries',
    emoji: '🎬',
    color: Color(0xFFFB7185), // rose
    options: [
      'Action', 'Comédie', 'Horreur', 'Anime', 'Romance',
      'SF', 'Documentaire', 'Thriller',
    ],
  ),
  InterestCategory(
    label: 'Gaming',
    emoji: '🎮',
    color: Color(0xFF38BDF8), // sky blue
    options: ['FPS', 'RPG', 'Aventure', 'Battle Royale', 'Rétro', 'Mobile'],
  ),
  InterestCategory(
    label: 'Lifestyle',
    emoji: '✨',
    color: Color(0xFFFBBF24), // amber
    options: [
      'Voyage', 'Cuisine', 'Mode', 'Photo', 'Lecture',
      'Art', 'Nature', 'Fête', 'Tatouage', 'Animaux',
    ],
  ),
];

/// Colour for a chip [label] = its CATEGORY colour (Musique → violet,
/// Sport → green, Films → pink, Gaming → blue, Lifestyle → orange). So every
/// chip of a category shares one vivid colour. Falls back to a neutral slate
/// for a tag no longer in the taxonomy.
Color interestColor(String label) {
  for (final c in kInterestCategories) {
    if (c.options.contains(label)) return c.color;
  }
  return const Color(0xFF64748B);
}
