import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';
import 'profile_avatar.dart';

/// The "It's a match!" celebration — both sides liked each other, so the
/// relation just became mutual. One [AnimationController] drives every phase
/// (scrim → title → the two avatars sliding together → the heart badge →
/// the buttons) through [Interval]s, so there is nothing to keep in sync.
///
/// Push it with [showMatchOverlay] — it lives on a transparent route so the
/// screen underneath (Discover, Demandes, a profile) stays visible behind it.
class MatchOverlay extends StatefulWidget {
  const MatchOverlay({
    super.key,
    required this.myName,
    required this.myPhotoUrl,
    required this.theirName,
    required this.theirPhotoUrl,
    required this.onSayHi,
    required this.onDismiss,
  });

  final String myName;
  final String myPhotoUrl;
  final String theirName;
  final String theirPhotoUrl;

  /// Open the conversation with the peer.
  final VoidCallback onSayHi;

  /// Close the overlay and go back to whatever was underneath.
  final VoidCallback onDismiss;

  @override
  State<MatchOverlay> createState() => _MatchOverlayState();
}

class _MatchOverlayState extends State<MatchOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  // Each element animates on its own slice of the global 0→1 timeline.
  late final Animation<double> _scrim;
  late final Animation<double> _title;
  late final Animation<double> _avatars;
  late final Animation<double> _badge;
  late final Animation<double> _buttons;

  final AudioPlayer _sfx = AudioPlayer();
  // The heart lands once — haptic + chime fire on that single frame.
  bool _peaked = false;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      duration: const Duration(milliseconds: 1400),
      vsync: this,
    );

    _scrim = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.0, 0.25, curve: Curves.easeOut),
    );
    _title = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.15, 0.45, curve: Curves.easeOutBack),
    );
    _avatars = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.30, 0.70, curve: Curves.easeOutCubic),
    );
    _badge = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.60, 0.85, curve: Curves.elasticOut),
    );
    _buttons = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.75, 1.0, curve: Curves.easeOut),
    );

    _c.addListener(() {
      if (!_peaked && _badge.value > 0.1) {
        _peaked = true;
        HapticFeedback.heavyImpact();
        _sfx.play(AssetSource('sounds/match_pop.wav')).ignore();
      }
    });

    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    _sfx.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: widget.onDismiss,
                child: Opacity(
                  opacity: _scrim.value * 0.94,
                  child: const ColoredBox(color: Color(0xFF0B0E14)),
                ),
              ),
            ),
            SafeArea(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Opacity(
                    opacity: _title.value.clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: 0.7 + 0.3 * _title.value,
                      child: Text(
                        AppStrings.t('match_title'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: SC.accent,
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  // The two avatars slide in from either side and meet under
                  // the heart badge.
                  SizedBox(
                    height: 130,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Transform.translate(
                          offset: Offset(-70 * (1 - _avatars.value) - 45, 0),
                          child: _MatchAvatar(
                            name: widget.myName,
                            photoUrl: widget.myPhotoUrl,
                          ),
                        ),
                        Transform.translate(
                          offset: Offset(70 * (1 - _avatars.value) + 45, 0),
                          child: _MatchAvatar(
                            name: widget.theirName,
                            photoUrl: widget.theirPhotoUrl,
                          ),
                        ),
                        Transform.scale(
                          scale: _badge.value.clamp(0.0, 1.2),
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: const BoxDecoration(
                              color: SC.accent,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.favorite,
                              color: Colors.white,
                              size: 26,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Opacity(
                    opacity: _avatars.value.clamp(0.0, 1.0),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        AppStrings.t(
                          'match_subtitle',
                          args: {'name': widget.theirName},
                        ),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 48),
                  Transform.translate(
                    offset: Offset(0, 30 * (1 - _buttons.value)),
                    child: Opacity(
                      opacity: _buttons.value.clamp(0.0, 1.0),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          children: [
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: widget.onSayHi,
                                style: FilledButton.styleFrom(
                                  backgroundColor: SC.accent,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                ),
                                child: Text(AppStrings.t('match_say_hi')),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: widget.onDismiss,
                              child: Text(
                                AppStrings.t('match_keep_going'),
                                style: const TextStyle(color: Colors.white54),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One of the two circular photos. Falls back to the initials avatar when the
/// person has no photo, so the overlay never shows a broken image.
class _MatchAvatar extends StatelessWidget {
  const _MatchAvatar({required this.name, required this.photoUrl});

  final String name;
  final String photoUrl;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 116,
      height: 116,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: SC.bubbleIn,
        border: Border.fromBorderSide(
          BorderSide(color: Colors.white, width: 3),
        ),
      ),
      padding: const EdgeInsets.all(3),
      child: ClipOval(
        child: ProfileAvatar(
          displayName: name,
          avatarUrl: photoUrl.isEmpty ? null : photoUrl,
          size: 110,
        ),
      ),
    );
  }
}

/// Show the match celebration over the current screen. [onSayHi] runs after the
/// overlay has been popped, so the caller can push the chat on a clean stack.
Future<void> showMatchOverlay(
  BuildContext context, {
  required String myName,
  required String myPhotoUrl,
  required String theirName,
  required String theirPhotoUrl,
  required VoidCallback onSayHi,
}) {
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, _, _) => MatchOverlay(
        myName: myName,
        myPhotoUrl: myPhotoUrl,
        theirName: theirName,
        theirPhotoUrl: theirPhotoUrl,
        onDismiss: () => Navigator.of(ctx).pop(),
        onSayHi: () {
          Navigator.of(ctx).pop();
          onSayHi();
        },
      ),
    ),
  );
}
