import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/job_sectors.dart';
import '../services/locations.dart';
import '../services/persona_categories.dart';
import '../services/profile_api.dart';
import '../services/zodiac.dart';
import '../theme/swayco_theme.dart';
import 'wheel_picker_sheet.dart';

/// Accent d'une catégorie « Ce qui me définit » : bordure, halo et pastille de
/// la carte. Clé = le libellé français stocké sur le profil.
const Map<String, Color> kPersonaColors = {
  'Sportif': Color(0xFFFF8A3D),
  'Mélomane': Color(0xFFB36BFF),
  'Gamer': Color(0xFF7C5CFF),
  'Voyageur': Color(0xFF2AA8FF),
  'Gourmet': Color(0xFFFFB02E),
  'Cinéphile': Color(0xFFE5484D),
  'Fashion': Color(0xFFFF5FA2),
  'Fitness': Color(0xFF34D399),
  'Ambitieux': Color(0xFFF4C20D),
  'Créatif': Color(0xFFFF7A59),
  'Curieux': Color(0xFF22D3EE),
  'Tech': Color(0xFF3B82F6),
  'Nature': Color(0xFF4ADE80),
  'Fêtard': Color(0xFFF43F5E),
  'Culturel': Color(0xFFC08457),
  'Romantique': Color(0xFFFF6B8A),
  'Zen': Color(0xFF2DD4BF),
};

const Color _kDefaultAccent = Color(0xFF2AA8FF);
const Color _kYellow = Color(0xFFF4FF1A);

/// Fichiers PNG des signes (assets/zodiac/), dans l'ordre de [kZodiacSigns].
const List<String> _kZodiacAssets = [
  'belier', 'taureau', 'gemeaux', 'cancer', 'lion', 'vierge',
  'balance', 'scorpion', 'sagittaire', 'capricorne', 'verseau', 'poissons',
];

/// Nom d'un pays dans la langue de l'interface (clé `country_<iso>` quand elle
/// existe, sinon le libellé stocké).
String countryNameForIso(String iso) {
  final code = iso.trim().toLowerCase();
  if (code.isEmpty) return '';
  final t = AppStrings.t('country_$code');
  if (t.isNotEmpty && t != 'country_$code') return t;
  return countryNameForIso2(code) ?? code.toUpperCase();
}

/// Roulette de pays. Renvoie le code ISO2 choisi, `''` pour « Supprimer », ou
/// null si la feuille est fermée sans choix.
Future<String?> pickCountryIso(
  BuildContext context, {
  required String title,
  String current = '',
}) async {
  final items = <(String, String)>[
    for (final c in kCountries)
      if (countryIso2For(c.name).isNotEmpty)
        (countryIso2For(c.name), '${c.flag}  ${countryNameForIso(countryIso2For(c.name))}'),
  ];
  final idx = items.indexWhere((e) => e.$1 == current.trim().toLowerCase());
  final picked = await showWheelPicker(
    context: context,
    title: title,
    labels: [for (final e in items) e.$2],
    initialIndex: idx < 0 ? 0 : idx,
    allowClear: current.trim().isNotEmpty,
  );
  if (picked == null) return null;
  if (picked < 0) return '';
  return items[picked].$1;
}

/// La carte « Mes infos » : identité (nom, nationalité, tampon du pays de
/// résidence), âge / métier / signe, « ce qui me définit », origines mère et
/// père, centres d'intérêt. Conçue en 632 px de large puis mise à l'échelle ;
/// les textes grossissent un peu moins vite que les cadres pour rester lisibles.
///
/// [editable] (mon profil) : toutes les tuiles s'affichent, les vides en
/// « Ajouter ». Sinon une tuile sans valeur est masquée ou estompée.
class ProfileInfoCard extends StatelessWidget {
  const ProfileInfoCard({
    super.key,
    required this.profile,
    this.editable = false,
    this.onNationality,
    this.onAge,
    this.onJob,
    this.onZodiac,
    this.onPersona,
    this.onMother,
    this.onFather,
    this.interestsBody,
    this.showHeader = true,
    this.framed = true,
    this.signReveal,
  });

  final RemoteProfile? profile;
  final bool editable;
  final Future<void> Function(BuildContext)? onNationality;
  final Future<void> Function(BuildContext)? onAge;
  final Future<void> Function(BuildContext)? onJob;
  final Future<void> Function(BuildContext)? onZodiac;
  final Future<void> Function(BuildContext)? onPersona;
  final Future<void> Function(BuildContext)? onMother;
  final Future<void> Function(BuildContext)? onFather;

  /// Contenu complet de la tuile « centres d'intérêt » (libellé compris).
  /// Null = la tuile n'est pas affichée.
  final Widget? interestsBody;

  /// Faux sur le passeport Discover : le nom, le drapeau et le tampon y sont
  /// déjà portés par l'en-tête du passeport.
  final bool showHeader;

  /// Faux sur le passeport : pas de cadre, d'ombre ni de halo propres, les cases
  /// sont posées directement sur la page.
  final bool framed;

  /// Entrée de l'image du signe (rotation -140° -> 0°, échelle .4 -> 1).
  final Animation<double>? signReveal;

  static const double _textBoost = 1.2;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth.isFinite ? c.maxWidth : 360.0;
        return _Scaled(
          k: w / 632,
          card: this,
        );
      },
    );
  }
}

/// Palette de la carte, claire ou sombre.
class _Pal {
  _Pal(this.accent)
      : light = SC.light,
        base = SC.light ? Colors.white : const Color(0xFF10131C),
        tile = SC.light ? const Color(0xFFF1F5FF) : const Color(0x0DFFFFFF),
        tileBorder =
            SC.light ? const Color(0x331F5EFF) : const Color(0x22FFFFFF),
        label = SC.light ? const Color(0xFF6B7490) : const Color(0xFFAAAABB),
        text = SC.light ? const Color(0xFF0B1330) : Colors.white,
        sub = SC.light ? const Color(0xFF4A5372) : const Color(0xFFC4C9D8),
        age = SC.light ? const Color(0xFF1F5EFF) : _kYellow,
        ageUnit = SC.light ? const Color(0xFF4A5372) : const Color(0xFFDDDDDD),
        stamp = SC.light ? const Color(0xFF1F5EFF) : _kYellow;

  final Color accent;
  final bool light;
  final Color base, tile, tileBorder, label, text, sub, age, ageUnit, stamp;
}

class _Scaled extends StatelessWidget {
  const _Scaled({required this.k, required this.card});

  final double k;
  final ProfileInfoCard card;

  double _t(double v) => v * k * ProfileInfoCard._textBoost;
  double _u(double v) => v * k;

  @override
  Widget build(BuildContext context) {
    final p = card.profile;
    final persona = personaCategoryByLabel(p?.personaCategory ?? '');
    final accent = kPersonaColors[persona?.label ?? ''] ?? _kDefaultAccent;
    final pal = _Pal(accent);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (card.showHeader) ...[
          _header(context, pal),
          SizedBox(height: _u(10)),
        ],
        SizedBox(height: _u(191), child: _ageJobSign(context, pal)),
        SizedBox(height: _u(10)),
        _defines(context, pal, persona),
        ..._origins(context, pal),
        ..._interests(pal),
      ],
    );
    if (!card.framed) return content;
    final radius = BorderRadius.circular(_u(34));
    return Container(
      decoration: BoxDecoration(
        color: pal.base,
        borderRadius: radius,
        border: Border.all(color: accent, width: math.max(1.2, _u(1.5))),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: pal.light ? 0.22 : 0.25),
            blurRadius: _u(60),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.bottomCenter,
              radius: 1.1,
              colors: [
                accent.withValues(alpha: pal.light ? 0.16 : 0.4),
                Colors.transparent,
              ],
            ),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(_u(28), _u(18), _u(28), _u(26)),
            child: content,
          ),
        ),
      ),
    );
  }

  // ── En-tête ────────────────────────────────────────────────────────────
  Widget _header(BuildContext context, _Pal pal) {
    final p = card.profile;
    final name = (p?.displayName.trim().isNotEmpty ?? false)
        ? p!.displayName.trim()
        : (p?.handle ?? '');
    final nat = (p?.nationality ?? '').trim().toLowerCase();
    final country = (p?.country ?? '').trim();
    final stampIso = countryIso2For(country);
    final stampText = stampIso.isEmpty
        ? country.toUpperCase()
        : countryNameForIso(stampIso).toUpperCase();

    Widget natLine;
    if (nat.isNotEmpty) {
      natLine = Text(
        countryNameForIso(nat),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: pal.sub,
          fontSize: _t(15),
          fontWeight: FontWeight.w700,
        ),
      );
    } else if (card.editable) {
      natLine = Text(
        '+ ${AppStrings.t('info_nationality')}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: pal.accent,
          fontSize: _t(15),
          fontWeight: FontWeight.w800,
        ),
      );
    } else {
      natLine = const SizedBox.shrink();
    }
    if (card.editable && card.onNationality != null) {
      natLine = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => card.onNationality!(context),
        child: natLine,
      );
    }

    return SizedBox(
      height: _u(66),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: _u(2)),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: pal.text,
                          fontSize: _t(26),
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    if (nat.isNotEmpty) ...[
                      SizedBox(width: _u(10)),
                      _Flag(nat, w: _u(26) * 1.3, h: _u(18) * 1.3, r: _u(3)),
                    ],
                  ],
                ),
                SizedBox(height: _u(5)),
                natLine,
              ],
            ),
          ),
          if (stampText.isNotEmpty)
            Transform.rotate(
              angle: -8 * math.pi / 180,
              child: Container(
                width: _u(66),
                height: _u(66),
                padding: EdgeInsets.symmetric(horizontal: _u(5)),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: pal.stamp,
                    width: math.max(1.4, _u(2.5)),
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('✦',
                        style: TextStyle(color: pal.stamp, fontSize: _t(11))),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          stampText,
                          maxLines: 1,
                          style: GoogleFonts.ibmPlexMono(
                            color: pal.stamp,
                            fontSize: _t(10),
                            letterSpacing: _u(1.2),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Âge / métier / signe ─────────────────────────────────────────────────
  Widget _ageJobSign(BuildContext context, _Pal pal) {
    final p = card.profile;
    final age = p?.age;
    final job = displayJob(p?.job ?? '');
    final signKey = normalizeZodiac(p?.zodiac ?? '');
    final z = kZodiacSigns.indexOf(signKey);
    final signName = z < 0 ? '' : displayZodiac(signKey);

    Widget add() => Text(
          '+ ${AppStrings.t('info_add')}',
          style: TextStyle(
            color: pal.accent,
            fontSize: _t(22),
            fontWeight: FontWeight.w800,
            fontStyle: FontStyle.italic,
          ),
        );
    Widget dash() => Text('—',
        style: TextStyle(color: pal.label, fontSize: _t(22)));

    return Row(
      children: [
        Expanded(
          child: _Tile(
            k: k,
            pal: pal,
            label: AppStrings.t('info_age').toUpperCase(),
            padding: EdgeInsets.fromLTRB(_u(18), _u(14), _u(18), _u(14)),
            onTap: card.editable ? card.onAge : null,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: age == null
                  ? (card.editable ? add() : dash())
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$age',
                          style: TextStyle(
                            color: pal.age,
                            fontSize: _u(92) * 1.1,
                            height: .85,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(width: _u(8)),
                        Text(
                          AppStrings.t('info_years'),
                          style: TextStyle(
                            color: pal.ageUnit,
                            fontSize: _t(20),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
        SizedBox(width: _u(12)),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: _Tile(
                  k: k,
                  pal: pal,
                  label: AppStrings.t('info_job').toUpperCase(),
                  onTap: card.editable ? card.onJob : null,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: job.isEmpty
                        ? (card.editable ? add() : dash())
                        : FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              job,
                              maxLines: 1,
                              style: TextStyle(
                                color: pal.text,
                                fontSize: _t(22),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                  ),
                ),
              ),
              SizedBox(height: _u(12)),
              Expanded(
                child: _Tile(
                  k: k,
                  pal: pal,
                  label: AppStrings.t('info_zodiac').toUpperCase(),
                  onTap: card.editable ? card.onZodiac : null,
                  trailing: signName.isEmpty
                      ? null
                      : _SignArt(
                          asset: 'assets/zodiac/${_kZodiacAssets[z]}.png',
                          size: _u(68),
                          reveal: card.signReveal,
                        ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: signName.isEmpty
                        ? (card.editable ? add() : dash())
                        : Padding(
                            padding: EdgeInsets.only(right: _u(92)),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                signName,
                                maxLines: 1,
                                style: TextStyle(
                                  color: pal.text,
                                  fontSize: _t(24),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Ce qui me définit ──────────────────────────────────────────────────
  Widget _defines(BuildContext context, _Pal pal, PersonaCategory? persona) {
    final lum = pal.accent.computeLuminance();
    final fg = lum > 0.45 ? const Color(0xFF06121F) : Colors.white;
    return _Tile(
      k: k,
      pal: pal,
      shrink: true,
      label: AppStrings.t('info_persona_category').toUpperCase(),
      onTap: card.editable ? card.onPersona : null,
      child: Padding(
        padding: EdgeInsets.only(top: _u(8)),
        child: Align(
          alignment: Alignment.centerLeft,
          child: persona == null
              ? (card.editable
                  ? Text(
                      '+ ${AppStrings.t('info_add')}',
                      style: TextStyle(
                        color: pal.accent,
                        fontSize: _t(20),
                        fontWeight: FontWeight.w800,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  : Text('—',
                      style: TextStyle(color: pal.label, fontSize: _t(20))))
              : Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: _u(26), vertical: _u(6)),
                  // La couleur du persona reste PLEINE : le reflet blanc est
                  // en avant-plan, sinon le dégradé écrase la couleur (gris).
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(99),
                    color: pal.accent,
                    boxShadow: [
                      BoxShadow(
                        color: pal.accent.withValues(alpha: .4),
                        blurRadius: _u(20),
                        offset: Offset(0, _u(6)),
                      ),
                    ],
                  ),
                  foregroundDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(99),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0, .55],
                      colors: [
                        Colors.white.withValues(alpha: .33),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Text(
                    '${persona.emoji} ${personaCategoryLabel(persona.label)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: _t(20),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  // ── Origines mère / père ──────────────────────────────────────────────
  List<Widget> _origins(BuildContext context, _Pal pal) {
    final p = card.profile;
    final mother = (p?.originMother ?? '').trim().toLowerCase();
    final father = (p?.originFather ?? '').trim().toLowerCase();
    final tiles = <Widget>[
      if (card.editable || mother.isNotEmpty)
        _originTile(context, pal,
            label: AppStrings.t('info_origin_mother'),
            iso: mother,
            onTap: card.onMother),
      if (card.editable || father.isNotEmpty)
        _originTile(context, pal,
            label: AppStrings.t('info_origin_father'),
            iso: father,
            onTap: card.onFather),
    ];
    if (tiles.isEmpty) return const [];
    return [
      SizedBox(height: _u(10)),
      SizedBox(
        height: _u(70),
        child: Row(
          children: [
            for (var i = 0; i < tiles.length; i++) ...[
              if (i > 0) SizedBox(width: _u(12)),
              Expanded(child: tiles[i]),
            ],
          ],
        ),
      ),
    ];
  }

  Widget _originTile(
    BuildContext context,
    _Pal pal, {
    required String label,
    required String iso,
    required Future<void> Function(BuildContext)? onTap,
  }) {
    final filled = iso.isNotEmpty;
    final body = Container(
      padding: EdgeInsets.symmetric(horizontal: _u(16)),
      decoration: BoxDecoration(
        color: pal.tile,
        borderRadius: BorderRadius.circular(_u(18)),
        border: Border.all(color: pal.tileBorder),
      ),
      child: Row(
        children: [
          if (filled) ...[
            _Flag(iso, w: _u(44) * 1.1, h: _u(30) * 1.1, r: _u(4)),
            SizedBox(width: _u(12)),
          ],
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.ibmPlexMono(
                    color: pal.label,
                    fontSize: _u(10) * 1.5,
                    letterSpacing: _u(1.2),
                  ),
                ),
                Text(
                  filled
                      ? countryNameForIso(iso)
                      : '+ ${AppStrings.t('info_add')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: filled ? pal.text : pal.accent,
                    fontSize: _t(16),
                    fontWeight: FontWeight.w700,
                    fontStyle: filled ? FontStyle.normal : FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (!card.editable || onTap == null) return body;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap(context),
      child: body,
    );
  }

  // ── Centres d'intérêt ─────────────────────────────────────────────────
  List<Widget> _interests(_Pal pal) {
    final body = card.interestsBody;
    if (body == null) return const [];
    return [
      SizedBox(height: _u(10)),
      Container(
        padding: EdgeInsets.fromLTRB(_u(18), _u(14), _u(18), _u(14)),
        decoration: BoxDecoration(
          color: pal.tile,
          borderRadius: BorderRadius.circular(_u(22)),
          border: Border.all(color: pal.tileBorder),
        ),
        child: body,
      ),
    ];
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.k,
    required this.pal,
    required this.label,
    required this.child,
    this.padding,
    this.onTap,
    this.shrink = false,
    this.trailing,
  });

  final double k;
  final _Pal pal;
  final String label;
  final Widget child;
  final EdgeInsets? padding;
  final Future<void> Function(BuildContext)? onTap;

  /// Hauteur = contenu (pas d'`Expanded`) : la case ne rogne plus son contenu.
  final bool shrink;

  /// Posé par-dessus la case, à droite, centré sur toute sa hauteur.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final u = k;
    final pad = padding ??
        EdgeInsets.fromLTRB(18 * u, 12 * u, 18 * u, 12 * u);
    final labelStyle = GoogleFonts.ibmPlexMono(
      color: pal.label,
      fontSize: 12 * u * 1.5,
      letterSpacing: 1.7 * u,
    );
    Widget tile = Container(
      padding: pad,
      decoration: BoxDecoration(
        color: pal.tile,
        borderRadius: BorderRadius.circular(22 * u),
        border: Border.all(color: pal.tileBorder),
      ),
      child: Column(
        mainAxisSize: shrink ? MainAxisSize.min : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: labelStyle),
          SizedBox(height: 4 * u),
          if (shrink) child else Expanded(child: child),
        ],
      ),
    );
    if (trailing != null) {
      tile = Stack(
        fit: StackFit.passthrough,
        children: [
          tile,
          Positioned(
            right: 12 * u,
            top: 0,
            bottom: 0,
            child: Center(child: trailing),
          ),
        ],
      );
    }
    if (onTap == null) return tile;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap!(context),
      child: tile,
    );
  }
}

/// L'image du signe : ronde d'origine (fond transparent), jamais rognée.
class _SignArt extends StatelessWidget {
  const _SignArt({required this.asset, required this.size, this.reveal});

  final String asset;
  final double size;
  final Animation<double>? reveal;

  @override
  Widget build(BuildContext context) {
    final img = Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
    final r = reveal;
    if (r == null) return img;
    return AnimatedBuilder(
      animation: r,
      builder: (_, c) {
        final t = r.value.clamp(0.0, 1.0);
        final e = Curves.easeOutBack.transform(t);
        return Opacity(
          opacity: t,
          child: Transform.rotate(
            angle: -140 * math.pi / 180 * (1 - e),
            child: Transform.scale(scale: 0.4 + 0.6 * e, child: c),
          ),
        );
      },
      child: img,
    );
  }
}

class _Flag extends StatelessWidget {
  const _Flag(this.iso, {required this.w, required this.h, required this.r});

  final String iso;
  final double w, h, r;

  @override
  Widget build(BuildContext context) {
    final emoji = countryFlagFor(countryNameForIso2(iso) ?? '') ?? '';
    return ClipRRect(
      borderRadius: BorderRadius.circular(r),
      child: Image.network(
        'https://flagcdn.com/w80/${iso.toLowerCase()}.png',
        width: w,
        height: h,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => SizedBox(
          width: w,
          height: h,
          child: Center(
            child: Text(emoji, style: TextStyle(fontSize: h * 0.8)),
          ),
        ),
      ),
    );
  }
}
