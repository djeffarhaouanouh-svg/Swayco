import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/paywall_screen.dart';
import '../theme/swayco_theme.dart';
import 'app_strings.dart';
import 'profile_api.dart';
import 'push_dispatcher.dart';

/// The "péage" on outgoing calls: a user with no remaining credit can't
/// place a call, but — since the *caller* pays for the minutes — they can
/// invite a credited peer to call THEM instead (free on their side). This
/// turns the paywall moment into an engagement loop instead of a dead end.
///
/// The gate is purely a UX shortcut: the backend re-validates credits on
/// `/livekit/token`, so a tampered client still can't place a free call.
abstract final class CallCreditGate {
  /// Whether [p] is allowed to PLACE (pay for) a call. Ultra Plus is
  /// unlimited; everyone else — Plus with exhausted hours, Free with no
  /// weekly seconds left — needs a positive balance.
  ///
  /// Fail-open: a null profile means the read failed, and we never block a
  /// real call on a transient network blip (the server is the final
  /// authority). Mirrors the "never clobber on a failed read" rule.
  static bool canPlaceCall(RemoteProfile? p) {
    // Launch/testing: calls are UNLIMITED — never gate placing one on the
    // credit balance. To restore the paywall, return
    // `p == null || p.isUltraPlus || p.creditsSeconds > 0` here AND flip
    // UsageTracker._kDisabled back to `false`.
    return true;
  }

  /// Modal shown when a credit-less user taps a call button. Offers two
  /// exits: (1) invite the peer to call them back (sends a push, the péage's
  /// viral side), or (2) open the paywall to buy hours.
  static Future<void> showAskToBeCalled(
    BuildContext context, {
    required String peerId,
    required String peerName,
    required String myId,
    required String myName,
  }) {
    final name = peerName.trim().isEmpty
        ? AppStrings.t('call_locked_peer_fallback')
        : peerName.trim();
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF0A0A0A),
        insetPadding: const EdgeInsets.symmetric(horizontal: 36),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: SC.accent.withValues(alpha: 0.15),
                ),
                child: const Icon(
                  Icons.lock_rounded,
                  color: SC.accent,
                  size: 42,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                AppStrings.t('call_locked_title'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                AppStrings.t('call_locked_body', args: {'name': name}),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14.5,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: SC.accent,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    unawaited(_sendInvite(
                      context,
                      peerId: peerId,
                      myId: myId,
                      myName: myName,
                    ));
                  },
                  icon: const Icon(Icons.phone_callback_rounded, size: 20),
                  label: Text(
                    AppStrings.t('call_locked_invite', args: {'name': name}),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  unawaited(showPaywallSheet(context));
                },
                child: Text(
                  AppStrings.t('call_locked_subscribe'),
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Fire a push at [peerId] asking them to call [myName] back, then confirm
  /// to the sender with a snackbar. Fire-and-forget like every other push.
  static Future<void> _sendInvite(
    BuildContext context, {
    required String peerId,
    required String myId,
    required String myName,
  }) async {
    // Localise the push into the PEER's language (they receive it).
    final peer = await ProfileApi.fetchById(peerId);
    final lang = peer?.language ?? '';
    final caller = myName.trim().isEmpty
        ? AppStrings.tIn(lang, 'call_locked_peer_fallback')
        : myName.trim();
    unawaited(PushDispatcher.notify(
      recipientUid: peerId,
      title: AppStrings.tIn(lang, 'call_invite_push_title', args: {'name': caller}),
      body: AppStrings.tIn(lang, 'call_invite_push_body'),
      type: 'call_invite',
      data: {'fromId': myId, 'fromName': myName},
    ));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('call_locked_invite_sent'))),
      );
    }
  }
}
