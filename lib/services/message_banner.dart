import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';
import '../widgets/glass_panel.dart';
import 'app_navigator.dart';
import 'app_strings.dart';
import 'notification_router.dart';
import 'open_thread.dart';

class MessageBannerIntent {
  const MessageBannerIntent({
    required this.conversationId,
    required this.peerId,
    required this.senderName,
    required this.preview,
  });

  final String conversationId;
  final String peerId;
  final String senderName;

  /// "📷 Photo", the translated body preview, whatever fits one line.
  final String preview;
}

/// A brief top banner for a new chat message while the app is open — the
/// in-app equivalent of the OS push banner shown when the app is
/// backgrounded. Without this, a message arriving while the user is
/// anywhere other than that exact thread was silent: no sound, no toast,
/// nothing but a badge count that ticks up somewhere the user isn't
/// looking.
///
/// Tapping it feeds [NotificationRouter] with the same shape a tapped push
/// notification would — reusing the already-wired "open this conversation"
/// path in `RootShell` instead of a second, parallel one.
abstract final class MessageBanner {
  static OverlayEntry? _entry;
  static Timer? _timer;

  static void offer(MessageBannerIntent intent) {
    if (intent.conversationId.isEmpty) return;
    // Already reading this exact thread — the message is already visible
    // live in the list; a banner on top of it would just be noise.
    if (OpenThread.conversationId.value == intent.conversationId) return;
    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay == null) return;
    _dismiss();
    final entry = OverlayEntry(
      builder: (context) => _MessageBannerView(
        intent: intent,
        onTap: () {
          _dismiss();
          NotificationRouter.submit({
            'type': 'message',
            'conversationId': intent.conversationId,
            'senderId': intent.peerId,
          });
        },
        onDismiss: _dismiss,
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    _timer = Timer(const Duration(seconds: 5), _dismiss);
  }

  static void _dismiss() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }
}

class _MessageBannerView extends StatefulWidget {
  const _MessageBannerView({
    required this.intent,
    required this.onTap,
    required this.onDismiss,
  });

  final MessageBannerIntent intent;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  State<_MessageBannerView> createState() => _MessageBannerViewState();
}

class _MessageBannerViewState extends State<_MessageBannerView>
    with SingleTickerProviderStateMixin {
  late final _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..forward();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final intent = widget.intent;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -1.2),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic)),
            child: GestureDetector(
              onTap: widget.onTap,
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) < -200) widget.onDismiss();
              },
              // The OverlayEntry sits directly on the root Overlay, outside
              // any Scaffold — without a Material ancestor, Text falls back
              // to its "no Material found" debug style (a yellow double
              // underline), which is exactly what showed up here.
              child: Material(
                type: MaterialType.transparency,
                child: GlassPanel(
                  borderRadius: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                  children: [
                    const Text('💬', style: TextStyle(fontSize: 20)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            intent.senderName.isEmpty
                                ? AppStrings.t('push_new_message')
                                : intent.senderName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: SC.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          if (intent.preview.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                intent.preview,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: SC.textSecondary,
                                  fontSize: 13,
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
            ),
          ),
        ),
      ),
    );
  }
}
