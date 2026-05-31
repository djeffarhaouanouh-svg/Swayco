import 'package:flutter/material.dart';

import '../services/diag.dart';
import '../theme/swayco_theme.dart';
import '../translation/realtime_translation_port.dart';

/// DIAGNOSTIC BUILD 6.1.2+8 — the real CallScreen was ~1500 lines of
/// LiveKit Room / RTC connection / mic-cam control / VAD / translation
/// wiring. With `livekit_client` + `flutter_webrtc` commented out of
/// pubspec.yaml to isolate the post-splash hang on Release builds, the
/// real implementation no longer compiles. This stub keeps the
/// constructor signature so [CallLauncher.startCall] still wires up
/// without changes, and shows a placeholder Scaffold if the user ever
/// reaches a call in the diagnostic build (they won't on a fresh-install
/// reviewer flow). `git revert` restores the real screen after diagnosis.
class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.wsUrl,
    required this.jwt,
    required this.roomName,
    required this.displayName,
    required this.mySourceLang,
    required this.translation,
    this.inviteShareText,
    this.isCaller = false,
  });

  final String wsUrl;
  final String jwt;
  final String roomName;
  final String displayName;
  final String mySourceLang;
  final RealtimeTranslationPort translation;
  final String? inviteShareText;
  final bool isCaller;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  @override
  void initState() {
    super.initState();
    Diag.ping('call-screen-stub-mounted');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SC.bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.science_outlined,
                    color: SC.accent, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Appels désactivés',
                  style: TextStyle(
                    color: SC.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Cette build est une version de diagnostic — les '
                  'appels reviendront sur la prochaine release.',
                  style: TextStyle(
                    color: SC.textMuted,
                    fontSize: 14,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Retour'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
