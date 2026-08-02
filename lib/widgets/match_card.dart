import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/country_stats.dart';
import '../services/demonyms.dart';
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/profile_api.dart';
import '../theme/swayco_theme.dart';
import 'flag_border.dart';
import 'flag_gradients.dart';
import 'profile_avatar.dart';

/// Which celebration card to show after a mutual match.
enum MatchCardKind { first, rare, standard }

/// Match celebration from the product mocks:
/// * circular peer PDP with **liseré drapeau**
/// * first → "TON PREMIER MATCH" + "Ça y est." + tip
/// * standard → "C'est un match." + yellow underlines
/// * rare → gold square variant
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

  /// Profile picture (PDP) — avatar first, then Discover photo, then gallery.
  String get _peerPhoto {
    if (peer.avatarUrl.trim().isNotEmpty) return peer.avatarUrl.trim();
    if (peer.discoverPhotoUrl.trim().isNotEmpty) {
      return peer.discoverPhotoUrl.trim();
    }
    if (peer.photos.isNotEmpty && peer.photos.first.trim().isNotEmpty) {
      return peer.photos.first.trim();
    }
    return '';
  }

  String get _whoLine {
    final age = peer.age;
    final city = peer.city.trim();
    final bits = <String>[
      _peerName,
      if (age != null) AppStrings.t('match_age_years', args: {'n': '$age'}),
      if (city.isNotEmpty) city,
    ];
    return bits.join(', ');
  }

  String get _metaLine => '$_whoLine.';

  String get _peerLangLabel =>
      findLanguageByCode(peer.language)?.label ?? peer.language.toUpperCase();

  String get _myLangLabel =>
      findLanguageByCode(me.language)?.label ??
      findLanguageByCode(AppStrings.currentBcp47.value)?.label ??
      AppStrings.currentBcp47.value.toUpperCase();

  FlagCountry get _flagCountry =>
      flagCountryForProfile(country: peer.country, language: peer.language) ??
      FlagCountry.france;

  @override
  Widget build(BuildContext context) {
    if (kind == MatchCardKind.rare) return _buildRare(context);
    if (kind == MatchCardKind.first) return _buildFirst(context);
    return _buildStandard(context);
  }

  Widget _buildFirst(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Pill(
          label: AppStrings.t('match_pill_first'),
          bg: SC.accent,
          fg: const Color(0xFF0A1024),
        ),
        const SizedBox(height: 22),
        _FlagPhoto(name: _peerName, photoUrl: _peerPhoto, country: _flagCountry),
        const SizedBox(height: 28),
        Text(
          AppStrings.t('match_first_title'),
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            AppStrings.t('match_first_sub', args: {'who': _whoLine}),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.88),
              fontSize: 15.5,
              fontWeight: FontWeight.w500,
              height: 1.35,
            ),
          ),
        ),
        const SizedBox(height: 22),
        _TipBox(text: AppStrings.t('match_tip_auto_translate')),
        const SizedBox(height: 28),
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

  Widget _buildStandard(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _FlagPhoto(name: _peerName, photoUrl: _peerPhoto, country: _flagCountry),
        const SizedBox(height: 28),
        Text(
          AppStrings.t('match_standard_title'),
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 34,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.6,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Text(
            _metaLine,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.92),
              fontSize: 16,
              fontWeight: FontWeight.w500,
              height: 1.3,
            ),
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

class _TipBox extends StatelessWidget {
  const _TipBox({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.auto_awesome,
              size: 18,
              color: const Color(0xFFA78BFA).withValues(alpha: 0.95),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 13.5,
                  height: 1.35,
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

/// Circular peer PDP wrapped in the flag gradient border (liseré drapeau).
class _FlagPhoto extends StatelessWidget {
  const _FlagPhoto({
    required this.name,
    required this.photoUrl,
    required this.country,
  });

  final String name;
  final String photoUrl;
  final FlagCountry country;

  static const double _size = 156;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _size,
      height: _size,
      child: FlagBorder(
        country: country,
        borderWidth: 3,
        radius: _size / 2,
        glowBlur: 22,
        dropShadow: false,
        child: photoUrl.isEmpty
            ? ColoredBox(
                color: const Color(0xFF0A0A0A),
                child: Center(
                  child: ProfileAvatar(displayName: name, size: _size - 12),
                ),
              )
            : Image.network(
                photoUrl,
                fit: BoxFit.cover,
                width: _size,
                height: _size,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: const Color(0xFF0A0A0A),
                  child: Center(
                    child: ProfileAvatar(displayName: name, size: _size - 12),
                  ),
                ),
              ),
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
