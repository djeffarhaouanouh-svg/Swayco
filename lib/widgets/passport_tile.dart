import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/job_sectors.dart';
import '../services/persona_categories.dart';
import '../services/profile_api.dart';
import '../services/zodiac.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';
import 'profile_info_card.dart';

/// La tuile « passeport » de la grille de photos d'un profil : l'essentiel du
/// passeport (âge, métier, signe, ce qui définit la personne) dans le format
/// d'une photo. Un appui l'ouvre dans la visionneuse, comme une image.
class PassportTile extends StatelessWidget {
  const PassportTile({super.key, required this.profile, required this.onTap});

  final RemoteProfile profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final light = SC.light;
    final persona = personaCategoryByLabel(p.personaCategory);
    final accent = kPersonaColors[persona?.label ?? ''] ?? SC.brandCyan;
    final job = displayJob(p.job);
    final signKey = normalizeZodiac(p.zodiac);
    final signName = kZodiacSigns.contains(signKey) ? displayZodiac(signKey) : '';
    final asset = zodiacAssetFor(p.zodiac);
    final ink = light ? const Color(0xFF04123A) : Colors.white;
    final pillFg = accent.computeLuminance() > 0.45
        ? const Color(0xFF04123A)
        : Colors.white;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: light ? Colors.white : const Color(0xFF161B2E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: accent.withValues(alpha: 0.5)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(19),
          child: Stack(
            children: [
              // Dégradé du bas, aux couleurs du persona.
              Positioned.fill(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: 0.62,
                    widthFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            accent.withValues(alpha: 0.55),
                            accent.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: 26,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: const BoxDecoration(gradient: SC.brandGradient),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            AppStrings.t('passport_title'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.ibmPlexMono(
                              fontSize: 9.5,
                              letterSpacing: 1.6,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.public_rounded,
                          size: 14,
                          color: SC.accent,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (p.age != null) ...[
                            Text(
                              AppStrings.t('info_age').toUpperCase(),
                              maxLines: 1,
                              style: GoogleFonts.ibmPlexMono(
                                fontSize: 9.5,
                                letterSpacing: 1.4,
                                color: ink.withValues(alpha: 0.65),
                              ),
                            ),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Text(
                                  '${p.age}',
                                  style: popupDisplay(
                                    fontSize: 40,
                                    letterSpacing: -2.4,
                                    color: light
                                        ? const Color(0xFF1F5EFF)
                                        : SC.accent,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  AppStrings.t('info_years'),
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: ink.withValues(alpha: 0.8),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (job.isNotEmpty)
                            Text(
                              job,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: ink,
                              ),
                            ),
                          if (signName.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Row(
                                children: [
                                  Container(
                                    width: 30,
                                    height: 30,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.black,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Color(0x9904123A),
                                          blurRadius: 8,
                                          spreadRadius: -3,
                                          offset: Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: asset == null
                                        ? null
                                        : ClipOval(
                                            child: Image.asset(
                                              asset,
                                              fit: BoxFit.contain,
                                              errorBuilder: (_, _, _) =>
                                                  const SizedBox.shrink(),
                                            ),
                                          ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      signName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w800,
                                        color: ink,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const Spacer(),
                          if (persona != null)
                            Container(
                              height: 24,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: accent,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(persona.emoji,
                                      style: const TextStyle(fontSize: 11)),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      personaCategoryLabel(persona.label),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w800,
                                        color: pillFg,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              // « Agrandir » : décoratif, tout le tap ouvre la visionneuse.
              Positioned(
                top: 34,
                right: 8,
                child: ClipOval(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.13),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.30),
                        ),
                      ),
                      child: Icon(
                        Icons.open_in_full_rounded,
                        size: 14,
                        color: ink,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
