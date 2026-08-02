import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/country_stats.dart';
import '../services/demonyms.dart';
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/profile_api.dart';
import '../theme/swayco_theme.dart';
import 'profile_avatar.dart';

/// Which celebration card to show after a mutual like.
enum MatchCardKind { first, rare, standard }

/// Visual match celebration — three flavours from the design handoff:
/// * [MatchCardKind.first] — "TON PREMIER MATCH", round rainbow photo, tip box
/// * [MatchCardKind.rare] — gold "RARE · x %" pill, square photo + flag
/// * [MatchCardKind.standard] — same layout as first, without the premier pill
class MatchCard extends StatelessWidget {
  const MatchCard({
    super.key,
    required this.kind,
    required this.me,
    required this.peer,
    required this.onSayHi,
    required this.onDismiss,
    this.countryShare,
  });

  final MatchCardKind kind;
  final RemoteProfile me;
  final RemoteProfile peer;
  final VoidCallback onSayHi;
  final VoidCallback onDismiss;

  /// Pre-fetched share for [peer.country]; null → rare card falls back gently.
  final CountryShare? countryShare;

  String get _peerName {
    final n = peer.displayName.trim();
    return n.isEmpty ? AppStrings.t('profile_anonymous') : n;
  }

  String get _peerPhoto {
    if (peer.discoverPhotoUrl.trim().isNotEmpty) return peer.discoverPhotoUrl;
    if (peer.photos.isNotEmpty && peer.photos.first.trim().isNotEmpty) {
      return peer.photos.first;
    }
    return peer.avatarUrl;
  }

  String get _peerLangLabel =>
      findLanguageByCode(peer.language)?.label ?? peer.language.toUpperCase();

  String get _myLangLabel =>
      findLanguageByCode(me.language)?.label ??
      findLanguageByCode(AppStrings.currentBcp47.value)?.label ??
      AppStrings.currentBcp47.value.toUpperCase();

  @override
  Widget build(BuildContext context) {
    final isRare = kind == MatchCardKind.rare;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (kind == MatchCardKind.first)
          _Pill(
            label: AppStrings.t('match_pill_first'),
            bg: SC.accent,
            fg: const Color(0xFF0A1024),
          )
        else if (isRare)
          _Pill(
            label: AppStrings.t(
              'match_pill_rare',
              args: {
                'pct': _formatPct(countryShare?.percent ?? 0),
              },
            ),
            bg: const Color(0xFFE8C98B),
            fg: const Color(0xFF1A1408),
            leading: const Text('✦ ', style: TextStyle(fontSize: 12)),
          ),
        const SizedBox(height: 28),
        if (isRare)
          _RarePhoto(name: _peerName, photoUrl: _peerPhoto, country: peer.country)
        else
          _FirstPhoto(name: _peerName, photoUrl: _peerPhoto),
        const SizedBox(height: 28),
        if (isRare) _rareHeadline() else _firstHeadline(),
        const SizedBox(height: 28),
        if (kind == MatchCardKind.first) ...[
          _TipBox(text: AppStrings.t('match_tip_auto_translate')),
          const SizedBox(height: 28),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: SizedBox(
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: SC.accent.withValues(alpha: 0.45),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: FilledButton(
                onPressed: onSayHi,
                style: FilledButton.styleFrom(
                  backgroundColor: SC.accent,
                  foregroundColor: const Color(0xFF0A1024),
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: Text(
                  AppStrings.t('match_say_hi'),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (isRare)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              AppStrings.t(
                'match_lang_bridge',
                args: {
                  'their': _peerLangLabel,
                  'mine': _myLangLabel,
                },
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 13.5,
                height: 1.35,
              ),
            ),
          )
        else
          TextButton(
            onPressed: onDismiss,
            child: Text(
              AppStrings.t('match_later'),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }

  Widget _firstHeadline() {
    final age = peer.age;
    final city = peer.city.trim();
    final bits = <String>[
      _peerName,
      if (age != null) AppStrings.t('match_age_years', args: {'n': '$age'}),
      if (city.isNotEmpty) city,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          Text(
            AppStrings.t(
              kind == MatchCardKind.first
                  ? 'match_first_title'
                  : 'match_standard_title',
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.6,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            AppStrings.t(
              kind == MatchCardKind.first
                  ? 'match_first_sub'
                  : 'match_standard_sub',
              args: {'who': bits.join(', ')},
            ),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.78),
              fontSize: 15.5,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _rareHeadline() {
    final headline = demonymHeadline(peer.country, gender: peer.gender);
    final demonym = countryDemonym(peer.country, gender: peer.gender);
    final age = peer.age;
    final city = peer.city.trim();
    final meta = [
      _peerName,
      if (age != null) '$age',
      if (city.isNotEmpty) city,
    ].join(' · ');
    // Split "Une Islandaise" so only the demonym is gold.
    final prefix = headline.endsWith(demonym) && demonym.isNotEmpty
        ? headline.substring(0, headline.length - demonym.length)
        : '';
    final goldWord = demonym.isNotEmpty ? demonym : headline;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          Text.rich(
            TextSpan(
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
                height: 1.15,
              ),
              children: [
                if (prefix.isNotEmpty)
                  TextSpan(text: prefix, style: const TextStyle(color: Colors.white)),
                TextSpan(
                  text: goldWord,
                  style: const TextStyle(color: Color(0xFFE8C98B)),
                ),
              ],
            ),
            textAlign: TextAlign.center,
          ),
          Text(
            AppStrings.t('match_rare_liked'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            meta,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.72),
              fontSize: 14.5,
            ),
          ),
        ],
      ),
    );
  }

  static String _formatPct(double pct) {
    if (pct <= 0) return '—';
    if (pct < 0.1) return pct.toStringAsFixed(2).replaceAll('.', ',');
    return pct.toStringAsFixed(1).replaceAll('.', ',');
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.bg,
    required this.fg,
    this.leading,
  });

  final String label;
  final Color bg;
  final Color fg;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) leading!,
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: fg,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _TipBox extends StatelessWidget {
  const _TipBox({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: const Color(0xFF7C3AED).withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.translate_rounded,
                color: Color(0xFFC4B5FD),
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 13.5,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FirstPhoto extends StatelessWidget {
  const _FirstPhoto({required this.name, required this.photoUrl});
  final String name;
  final String photoUrl;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 168,
      height: 168,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Soft floating confetti accents.
          Positioned(
            top: 8,
            right: 6,
            child: Transform.rotate(
              angle: 0.3,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: const Color(0xFF60A5FA).withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 18,
            left: 4,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.7),
                shape: BoxShape.circle,
              ),
            ),
          ),
          // Rainbow ring.
          Container(
            width: 156,
            height: 156,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(
                colors: [
                  Color(0xFF22D3EE),
                  Color(0xFFA78BFA),
                  Color(0xFFF472B6),
                  Color(0xFFFBBF24),
                  Color(0xFF34D399),
                  Color(0xFF22D3EE),
                ],
              ),
            ),
            padding: const EdgeInsets.all(3.5),
            child: Container(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF0A0A0A),
              ),
              padding: const EdgeInsets.all(3),
              child: ClipOval(
                child: ProfileAvatar(
                  displayName: name,
                  avatarUrl: photoUrl.isEmpty ? null : photoUrl,
                  size: 140,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RarePhoto extends StatelessWidget {
  const _RarePhoto({
    required this.name,
    required this.photoUrl,
    required this.country,
  });

  final String name;
  final String photoUrl;
  final String country;

  @override
  Widget build(BuildContext context) {
    final flag = countryFlagFor(country);
    return SizedBox(
      width: 168,
      height: 168,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 156,
            height: 156,
            margin: const EdgeInsets.only(left: 6, top: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: const Color(0xFFE8C98B), width: 2.5),
            ),
            padding: const EdgeInsets.all(3),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: photoUrl.isEmpty
                  ? ColoredBox(
                      color: SC.bubbleIn,
                      child: Center(
                        child: ProfileAvatar(
                          displayName: name,
                          size: 100,
                        ),
                      ),
                    )
                  : Image.network(
                      photoUrl,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      errorBuilder: (_, _, _) => ColoredBox(
                        color: SC.bubbleIn,
                        child: Center(
                          child: ProfileAvatar(displayName: name, size: 100),
                        ),
                      ),
                    ),
            ),
          ),
          if (flag != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF0A0A0A),
                  border: Border.all(
                    color: const Color(0xFFE8C98B).withValues(alpha: 0.7),
                    width: 2,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(flag, style: const TextStyle(fontSize: 22)),
              ),
            ),
        ],
      ),
    );
  }
}

/// Pick the card kind from match count + country rarity.
MatchCardKind resolveMatchCardKind({
  required int acceptedMatchCount,
  required CountryShare? share,
}) {
  // The match we just made is already counted — first means "only one".
  if (acceptedMatchCount <= 1) return MatchCardKind.first;
  if (share != null && share.isRare) return MatchCardKind.rare;
  return MatchCardKind.standard;
}

/// Tiny helper so a future animation can spin the rainbow without rebuild noise.
double matchCardSpin(double t) => t * 2 * math.pi;
