import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';
import '../translation/realtime_translation_port.dart';

/// In-call feedback so translation *feels* responsive (progress, chip, pulse when remote talks).
class TranslationFeedbackRibbon extends StatelessWidget {
  const TranslationFeedbackRibbon({
    super.key,
    required this.phase,
    required this.remoteHot,
    required this.remoteParticipantCount,
  });

  final TranslationFeedbackPhase phase;
  final bool remoteHot;
  final int remoteParticipantCount;

  @override
  Widget build(BuildContext context) {
    if (phase == TranslationFeedbackPhase.hidden) {
      return const SizedBox.shrink();
    }

    return Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (phase == TranslationFeedbackPhase.working)
            const LinearProgressIndicator(
              minHeight: 2.5,
              backgroundColor: Colors.transparent,
              color: SC.accent,
            ),
          if (phase == TranslationFeedbackPhase.standby)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
              child: Text(
                remoteParticipantCount == 0
                    ? 'Translation: waiting for someone in this room…'
                    : 'Getting translation ready…',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.82),
                  fontSize: 12,
                  height: 1.25,
                ),
              ),
            ),
          if (phase == TranslationFeedbackPhase.live)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: remoteHot
                        ? SC.accent.withValues(alpha: 0.95)
                        : Colors.white.withValues(alpha: 0.12),
                    width: remoteHot ? 1.5 : 1,
                  ),
                  boxShadow: remoteHot
                      ? [
                          BoxShadow(
                            color: SC.accent.withValues(alpha: 0.35),
                            blurRadius: 12,
                            spreadRadius: 0,
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.translate_rounded, size: 16, color: SC.accent),
                    const SizedBox(width: 8),
                    Text(
                      remoteHot ? 'Translation · listening' : 'Translation on',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.92),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
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
}
