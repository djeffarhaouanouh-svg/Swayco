import 'package:flutter/material.dart';

import '../services/profile_api.dart';
import '../theme/swayco_theme.dart';
import 'translated_profile_text.dart';
import 'voice_intro_player.dart';

/// Sous une présentation vocale, PENDANT l'écoute seulement : ce qui est dit,
/// traduit dans la langue de l'interface.
class VoiceIntroTranslation extends StatelessWidget {
  const VoiceIntroTranslation({
    super.key,
    required this.profile,
    this.divider = false,
  });

  final RemoteProfile profile;

  /// Un filet au-dessus (en bas d'une carte du fil).
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    final ink = light ? const Color(0xFF04123A) : Colors.white;
    return ValueListenableBuilder<String?>(
      valueListenable: VoiceIntroPlayer.playingUrl,
      builder: (context, playing, _) {
        if (playing != profile.voiceIntroUrl) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 12),
          padding: EdgeInsets.only(top: divider ? 10 : 0),
          decoration: divider
              ? BoxDecoration(
                  border: Border(
                    top: BorderSide(color: ink.withValues(alpha: 0.12)),
                  ),
                )
              : null,
          child: TranslatedProfileText(
            text: profile.voiceIntroTranscript.trim(),
            profileId: profile.id,
            // L'adresse change à chaque enregistrement : pas de traduction
            // périmée en cache.
            field: 'voice-${profile.voiceIntroUrl.hashCode}',
            fromLang: profile.voiceIntroLang.isNotEmpty
                ? profile.voiceIntroLang
                : profile.language,
            showNote: true,
            textAlign: TextAlign.start,
            style: TextStyle(
              color: ink.withValues(alpha: 0.85),
              fontSize: 14,
              height: 1.4,
            ),
          ),
        );
      },
    );
  }
}
