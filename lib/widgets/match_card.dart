import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/country_stats.dart';
import '../services/demonyms.dart';
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/profile_api.dart';
import '../theme/swayco_theme.dart';
import 'profile_avatar.dart';

/// Which celebration card to show after the recipient accepts a like.
enum MatchCardKind { first, rare, standard }

/// Match celebration — design from the product mock:
/// round rainbow photo, yellow-underlined "C'est un match." + meta line,
/// cyan "Dis bonjour", grey "Plus tard". Rare keeps the gold square variant.
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

  String get _metaLine {
    final age = peer.age;
    final city = peer.city.trim();
    final bits = <String>[
      _peerName,
      if (age != null) AppStrings.t('match_age_years', args: {'n': '$age'}),
      if (city.isNotEmpty) city,
    ];
    return '${bits.join(', ')}.';
  }

  String get _peerLangLabel =>
      findLanguageByCode(peer.language)?.label ?? peer.language.toUpperCase();

  String get _myLangLabel =>
      findLanguageByCode(me.language)?.label ??
      findLanguageByCode(AppStrings.currentBcp47.value)?.label ??
      AppStrings.currentBcp47.value.toUpperCase();

  @override
  Widget build(BuildContext context) {
    if (kind == MatchCardKind.rare) return _buildRare(context);
    return _buildStandard(context);
  }

  /// Default + first-match layout (product mock).
  Widget _buildStandard(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RainbowPhoto(name: _peerName, photoUrl: _peerPhoto),
        const SizedBox(height: 28),
        _UnderlinedText(
          text: AppStrings.t('match_standard_title'),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 34,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.6,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 12),
        _UnderlinedText(
          text: _metaLine,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.92),
            fontSize: 16,
            fontWeight: FontWeight.w500,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 36),
        _SayHiButton(onPressed: onSayHi),
        const SizedBox(height: 14),
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

  Widget _buildRare(BuildContext context) {
    final headline = demonymHeadline(peer.country, gender: peer.gender);
    final demonym = countryDemonym(peer.country, gender: peer.gender);
    final prefix = headline.endsWith(demonym) && demonym.isNotEmpty
        ? headline.substring(0, headline.length - demonym.length)
        : '';
    final goldWord = demonym.isNotEmpty ? demonym : headline;
    final age = peer.age;
    final city = peer.city.trim();
    final meta = [
      _peerName,
      if (age != null) '$age',
      if (city.isNotEmpty) city,
    ].join(' · ');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Pill(
          label: AppStrings.t(
            'match_pill_rare',
            args: {'pct': _formatPct(countryShare?.percent ?? 0)},
          ),
          bg: const Color(0xFFE8C98B),
          fg: const Color(0xFF1A1408),
          leading: const Text('✦ ', style: TextStyle(fontSize: 12)),
        ),
        const SizedBox(height: 28),
        _RarePhoto(name: _peerName, photoUrl: _peerPhoto, country: peer.country),
        const SizedBox(height: 28),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
                      TextSpan(
                        text: prefix,
                        style: const TextStyle(color: Colors.white),
                      ),
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
        ),
        const SizedBox(height: 32),
        _SayHiButton(onPressed: onSayHi),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            AppStrings.t(
              'match_lang_bridge',
              args: {'their': _peerLangLabel, 'mine': _myLangLabel},
            ),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 13.5,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }

  static String _formatPct(double pct) {
    if (pct <= 0) return '—';
    if (pct < 0.1) return pct.toStringAsFixed(2).replaceAll('.', ',');
    return pct.toStringAsFixed(1).replaceAll('.', ',');
  }
}

MatchCardKind resolveMatchCardKind({
  required int acceptedMatchCount,
  required CountryShare? share,
}) {
  if (acceptedMatchCount <= 1) return MatchCardKind.first;
  if (share != null && share.isRare) return MatchCardKind.rare;
  return MatchCardKind.standard;
}

// ── pieces ──────────────────────────────────────────────────────────────────

class _UnderlinedText extends StatelessWidget {
  const _UnderlinedText({required this.text, required this.style});
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: IntrinsicWidth(
        child: Column(
          children: [
            Text(text, textAlign: TextAlign.center, style: style),
            const SizedBox(height: 4),
            Container(height: 2, color: const Color(0xFFFBBF24)),
          ],
        ),
      ),
    );
  }
}

class _SayHiButton extends StatelessWidget {
  const _SayHiButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: SizedBox(
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: SC.accent.withValues(alpha: 0.45),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: SC.accent,
              foregroundColor: const Color(0xFF0A1024),
              padding: const EdgeInsets.symmetric(vertical: 18),
              shape: const StadiumBorder(),
            ),
            child: Text(
              AppStrings.t('match_say_hi'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ),
    );
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

class _RainbowPhoto extends StatelessWidget {
  const _RainbowPhoto({required this.name, required this.photoUrl});
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
                child: photoUrl.isEmpty
                    ? ProfileAvatar(displayName: name, size: 140)
                    : Image.network(
                        photoUrl,
                        fit: BoxFit.cover,
                        width: 140,
                        height: 140,
                        errorBuilder: (_, _, _) =>
                            ProfileAvatar(displayName: name, size: 140),
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
                        child: ProfileAvatar(displayName: name, size: 100),
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
