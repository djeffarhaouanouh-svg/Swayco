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

/// Vivid chip palette (Tailwind-500) used by the "bord blanc" interest chips:
/// each chip is a solid colour with a white border + white text. Colours are
/// assigned per tag (stable hash) so the list stays lively and multi-colour
/// like the reference design, not one colour per category.
const List<Color> kInterestChipPalette = [
  Color(0xFF22C55E), // green
  Color(0xFFF97316), // orange
  Color(0xFFD946EF), // fuchsia
  Color(0xFF3B82F6), // blue
  Color(0xFFEAB308), // yellow
  Color(0xFFEC4899), // pink
  Color(0xFF8B5CF6), // violet
  Color(0xFF0EA5E9), // sky
  Color(0xFFEF4444), // red
  Color(0xFF14B8A6), // teal
];

/// Stable vivid colour for a chip [label] — hashes the label into
/// [kInterestChipPalette] so a given tag always gets the same colour.
Color interestColor(String label) {
  var hash = 0;
  for (final c in label.codeUnits) {
    hash = (hash * 31 + c) & 0x7fffffff;
  }
  return kInterestChipPalette[hash % kInterestChipPalette.length];
}
