import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Web-only in-app alert for an incoming call.
///
/// Triggers:
///   * `navigator.vibrate(...)` repeated every two seconds — no-op on
///     desktop browsers (API missing) and on iOS Safari (Apple still
///     refuses to ship the Vibration API). Works on Chrome / Firefox /
///     Edge on Android, which covers most mobile-web cases.
///   * A short "brrring-brrring" ringtone generated on the fly with the
///     Web Audio API (no asset needed). Loops every 2s until [stop].
///   * A flashing tab title that alternates between the original page
///     title and a "📞 Appel entrant…" marker every 800ms, so the user
///     notices a call even when the tab isn't focused.
///
/// The dialog itself (rendered by [RootShell._IncomingCallDialog]) is
/// the visual / interactive piece — this class only adds the sensory
/// cues around it.
abstract final class CallAlert {
  /// When false, the ring / dial-tone beeps are muted (Settings →
  /// In-app sounds). Vibration and the flashing tab title still fire —
  /// they are not "sounds".
  static bool soundsEnabled = true;

  static Timer? _vibTimer;
  static Timer? _titleTimer;
  static Timer? _ringTimer;
  static String? _origTitle;
  static web.AudioContext? _audioCtx;

  static void start({String? callerName}) {
    // Defensive: if start() is called twice without a stop() in between,
    // collapse to a single set of timers so we don't leak.
    stop();
    _vibrateOnce();
    _vibTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _vibrateOnce(),
    );

    _ringOnce();
    _ringTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _ringOnce(),
    );

    _origTitle = web.document.title;
    final flashLabel = (callerName != null && callerName.isNotEmpty)
        ? '📞 $callerName…'
        : '📞 Appel entrant…';
    var on = true;
    _titleTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      web.document.title = on ? flashLabel : (_origTitle ?? '');
      on = !on;
    });
  }

  /// Caller-side dial tone: a single longer beep every 3s, softer than
  /// the brrring-brrring used for incoming calls. No vibration (the
  /// caller doesn't need to feel their own outgoing ring), no title
  /// flashing (the title is set once and held).
  static void startDialing({String? calleeName}) {
    stop();

    _dialOnce();
    _ringTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _dialOnce(),
    );

    _origTitle = web.document.title;
    final label = (calleeName != null && calleeName.isNotEmpty)
        ? '📞 Appel vers $calleeName…'
        : '📞 Appel sortant…';
    web.document.title = label;
  }

  static void _dialOnce() {
    if (!soundsEnabled) return;
    try {
      final ctx = _audioCtx ??= web.AudioContext();
      if (ctx.state == 'suspended') {
        ctx.resume().toDart.catchError((Object _) => null);
      }
      final now = ctx.currentTime;
      // One longer, quieter beep at a lower pitch — feels like a phone
      // ring-back tone rather than a doorbell.
      _scheduleBeep(ctx, now, durationSec: 1.2, freq: 440, peak: 0.10);
    } catch (e) {
      debugPrint('CallAlert dial failed: $e');
    }
  }

  /// Pattern: 300ms on / 200ms off / 300ms on / 200ms off / 600ms on.
  /// Approximates a classic ring "brrring-brrring".
  static void _vibrateOnce() {
    try {
      final pattern =
          <int>[300, 200, 300, 200, 600].map((v) => v.toJS).toList().toJS;
      web.window.navigator.vibrate(pattern);
    } catch (_) {
      // Desktop browsers + iOS Safari throw or no-op here — fine.
    }
  }

  /// Plays a "brrring brrring" pair of beeps on the WebAudio graph.
  /// Browsers gate AudioContext on a prior user gesture — that's fine
  /// here: receiving a call means the user is already signed in and has
  /// interacted with the app, so the context resumes cleanly.
  static void _ringOnce() {
    if (!soundsEnabled) return;
    try {
      final ctx = _audioCtx ??= web.AudioContext();
      // If the browser parked the context (tab was backgrounded), wake
      // it up — fire-and-forget, errors are non-fatal.
      if (ctx.state == 'suspended') {
        ctx.resume().toDart.catchError((Object _) => null);
      }
      final now = ctx.currentTime;
      _scheduleBeep(ctx, now,        durationSec: 0.30);
      _scheduleBeep(ctx, now + 0.50, durationSec: 0.30);
    } catch (e) {
      debugPrint('CallAlert ring failed: $e');
    }
  }

  /// One short tone at `freq`Hz, faded in / out to avoid clicky edges.
  static void _scheduleBeep(
    web.AudioContext ctx,
    double startSec, {
    double durationSec = 0.3,
    double freq = 480,
    double peak = 0.18,
  }) {
    final osc = ctx.createOscillator();
    osc.type = 'sine';
    osc.frequency.value = freq;
    final gain = ctx.createGain();
    final endSec = startSec + durationSec;
    const ramp = 0.02;
    // Silence → peak → hold → silence, with linear ramps so the ear
    // doesn't pick up a "tick" at the start/end of each beep.
    gain.gain.setValueAtTime(0.0001, startSec);
    gain.gain.exponentialRampToValueAtTime(peak, startSec + ramp);
    gain.gain.setValueAtTime(peak, endSec - ramp);
    gain.gain.exponentialRampToValueAtTime(0.0001, endSec);
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start(startSec);
    osc.stop(endSec + 0.01);
  }

  static void stop() {
    _vibTimer?.cancel();
    _vibTimer = null;
    _titleTimer?.cancel();
    _titleTimer = null;
    _ringTimer?.cancel();
    _ringTimer = null;
    if (_origTitle != null) {
      web.document.title = _origTitle!;
      _origTitle = null;
    }
    // Cancel any in-flight vibration.
    try {
      web.window.navigator.vibrate(0.toJS);
    } catch (_) {}
    // Tear down the audio graph so the context can be garbage-collected
    // and the browser's "🔊" tab indicator goes away.
    final ctx = _audioCtx;
    if (ctx != null) {
      _audioCtx = null;
      try {
        ctx.close().toDart.catchError((Object _) => null);
      } catch (_) {}
    }
  }
}
