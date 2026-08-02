import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/country_stats.dart';
import '../services/friendship_api.dart';
import '../services/profile_api.dart';
import 'match_card.dart';

/// The "It's a match!" celebration. Resolves first / rare / standard, then
/// renders [MatchCard]. Push it with [showMatchOverlay].
class MatchOverlay extends StatefulWidget {
  const MatchOverlay({
    super.key,
    required this.me,
    required this.peer,
    required this.onSayHi,
    required this.onDismiss,
  });

  final RemoteProfile me;
  final RemoteProfile peer;

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
  late final Animation<double> _scrim;
  late final Animation<double> _body;

  final AudioPlayer _sfx = AudioPlayer();
  bool _peaked = false;

  MatchCardKind _kind = MatchCardKind.standard;
  CountryShare? _share;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      duration: const Duration(milliseconds: 900),
      vsync: this,
    );
    _scrim = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.0, 0.35, curve: Curves.easeOut),
    );
    _body = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.15, 1.0, curve: Curves.easeOutCubic),
    );
    _c.addListener(() {
      if (!_peaked && _body.value > 0.35) {
        _peaked = true;
        HapticFeedback.heavyImpact();
        _sfx.play(AssetSource('sounds/match_pop.wav')).ignore();
      }
    });
    _resolve();
  }

  Future<void> _resolve() async {
    final meId = widget.me.id;
    final matches = meId.isEmpty
        ? const <RemoteProfile>[]
        : await FriendshipApi.fetchMatches(meId);
    final ids = {for (final p in matches) p.id};
    // Ensure the peer we just matched is counted even if the fetch raced.
    ids.add(widget.peer.id);

    final share = widget.peer.country.trim().isEmpty
        ? null
        : await CountryStats.shareFor(widget.peer.country);

    if (!mounted) return;
    setState(() {
      _share = share;
      _kind = resolveMatchCardKind(
        acceptedMatchCount: ids.length,
        share: share,
      );
      _ready = true;
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
                  opacity: _scrim.value * 0.96,
                  child: const ColoredBox(color: Color(0xFF000000)),
                ),
              ),
            ),
            if (_ready)
              SafeArea(
                child: Opacity(
                  opacity: _body.value.clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: Offset(0, 24 * (1 - _body.value)),
                    child: Transform.scale(
                      scale: 0.92 + 0.08 * _body.value,
                      child: MatchCard(
                        kind: _kind,
                        me: widget.me,
                        peer: widget.peer,
                        countryShare: _share,
                        onSayHi: widget.onSayHi,
                        onDismiss: widget.onDismiss,
                      ),
                    ),
                  ),
                ),
              )
            else
              const Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white54,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Show the match celebration over the current screen. [onSayHi] runs after the
/// overlay has been popped, so the caller can push the chat on a clean stack.
Future<void> showMatchOverlay(
  BuildContext context, {
  required RemoteProfile me,
  required RemoteProfile peer,
  required VoidCallback onSayHi,
}) {
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, _, _) => MatchOverlay(
        me: me,
        peer: peer,
        onDismiss: () => Navigator.of(ctx).pop(),
        onSayHi: () {
          Navigator.of(ctx).pop();
          onSayHi();
        },
      ),
    ),
  );
}
