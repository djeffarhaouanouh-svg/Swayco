import 'dart:async';

import 'package:flutter/foundation.dart';

import 'profile_api.dart';

/// Tracks elapsed call time and debits the user's translation credits
/// periodically. Designed to be `start()`-ed when the call screen mounts
/// and `stop()`-ed when it tears down — flushing any partial period so
/// quitting mid-tick doesn't lose the seconds already spent.
///
/// Why client-side: the v1 model is honor-system. The decrement runs
/// against Supabase under the user's RLS, so they could in theory cheat
/// it by editing the request. If/when that matters, move the decrement
/// into a Postgres `SECURITY DEFINER` function and call it via RPC.
abstract final class UsageTracker {
  /// Master switch for the credit / call-time gating system. Flipping
  /// to `true` makes every public method a no-op and pins the reactive
  /// notifiers at "infinite credits / never exhausted" — useful when
  /// running long end-to-end tests without burning through quota.
  ///
  /// Production: `false`. Each call deducts seconds against the user's
  /// credit balance via the SECURITY DEFINER RPC the implementation
  /// flushes to every [_tickSeconds] tick.
  // Launch/testing: calls + translation are UNLIMITED for everyone. Forces
  // "infinite credits" so the call screen never cuts translation and nothing
  // is debited. To restore the 15-min-free-then-paid model, flip this back to
  // `false` AND revert CallCreditGate.canPlaceCall's unconditional `true`.
  static const bool _kDisabled = true;

  /// Public mirror so callers (CallScreen) can also skip their own
  /// credit gates when tracking is off.
  static bool get isDisabled => _kDisabled;

  /// Flush window. Every [_tickSeconds] we push the accumulated time to
  /// Supabase. Short enough that closing the tab mid-call only loses a few
  /// seconds; long enough that we're not hammering the DB.
  static const _tickSeconds = 30;

  static Timer? _timer;
  static String _userId = '';
  static int _pendingSeconds = 0;

  /// Reactive snapshot of remaining credits. The Profile screen and Call
  /// screen both watch this so they see decrements live.
  static final ValueNotifier<int> creditsRemaining = ValueNotifier<int>(0);

  /// Fires once when [creditsRemaining] crosses from >0 to 0 during this
  /// tracking session. The Call screen uses this to disable translation
  /// without ending the call.
  static final ValueNotifier<bool> creditsExhausted =
      ValueNotifier<bool>(false);

  static bool get isRunning => _timer != null;

  /// True between an explicit `pause()` and the next `resume()`. While
  /// paused the periodic timer is cancelled — no ticks, no flush — so
  /// no credits are spent. State (userId, pendingSeconds, remaining)
  /// is preserved so a `resume()` picks up exactly where we left off.
  static bool _paused = false;

  /// Pause the timer without losing accumulated state. Used by the
  /// CallScreen when the live pipeline detaches (peer left, VAD
  /// silenced, credits hit 0) — we shouldn't keep billing call time
  /// when nothing's being translated.
  static void pause() {
    if (_kDisabled) return;
    if (_paused) return;
    if (_timer == null) return; // nothing to pause
    _timer?.cancel();
    _timer = null;
    _paused = true;
    debugPrint('[usage] paused (pending=$_pendingSeconds, userId=$_userId)');
  }

  /// Resume ticking after a `pause()`. No-op if not currently paused.
  static void resume() {
    if (_kDisabled) return;
    if (!_paused) return;
    if (_userId.isEmpty) return;
    _paused = false;
    debugPrint('[usage] resumed for $_userId');
    _timer = Timer.periodic(
      const Duration(seconds: _tickSeconds),
      (_) => _onTick(),
    );
  }

  /// Start tracking for [userId] with the known starting credit balance.
  /// Safe to call repeatedly — restarts the timer if the user changed,
  /// no-ops if already running for the same user.
  static void start({
    required String userId,
    required int initialCredits,
  }) {
    if (_kDisabled) {
      // Force "infinite credits" so the call screen never disables
      // translation and the profile doesn't render an empty bar.
      creditsRemaining.value = 1 << 30;
      creditsExhausted.value = false;
      return;
    }
    if (userId.isEmpty) {
      debugPrint('[usage] start aborted: empty userId');
      return;
    }
    if (_timer != null && _userId == userId) {
      debugPrint('[usage] start no-op: timer already running for $userId');
      return;
    }
    stop(); // cancel previous if any
    _userId = userId;
    _pendingSeconds = 0;
    creditsRemaining.value = initialCredits;
    creditsExhausted.value = initialCredits <= 0;
    debugPrint(
      '[usage] started → userId=$userId initialCredits=$initialCredits '
      'tickEvery=${_tickSeconds}s',
    );
    _timer = Timer.periodic(
      const Duration(seconds: _tickSeconds),
      (_) => _onTick(),
    );
  }

  static void _onTick() {
    _pendingSeconds += _tickSeconds;
    final localNext = (creditsRemaining.value - _tickSeconds).clamp(0, 1 << 31);
    creditsRemaining.value = localNext;
    debugPrint(
      '[usage] tick → pending=${_pendingSeconds}s localRemaining=$localNext',
    );
    if (localNext == 0 && !creditsExhausted.value) {
      creditsExhausted.value = true;
    }
    unawaited(_flush());
  }

  static Future<void> _flush() async {
    // Capture state synchronously BEFORE any await so a concurrent
    // start()/stop() can't change _userId out from under us.
    final userId = _userId;
    if (userId.isEmpty || _pendingSeconds <= 0) {
      debugPrint(
        '[usage] flush skipped: userId="$userId" pending=$_pendingSeconds',
      );
      return;
    }
    final amount = _pendingSeconds;
    _pendingSeconds = 0;
    debugPrint('[usage] flushing $amount seconds for $userId…');
    final remaining =
        await ProfileApi.consumeCredits(userId: userId, seconds: amount);
    debugPrint('[usage] flush returned remaining=$remaining');
    // Only push the authoritative remaining into the notifiers when the
    // tracker hasn't been re-bound to a different user mid-flight.
    if (remaining != null && _userId == userId) {
      creditsRemaining.value = remaining;
      if (remaining == 0 && !creditsExhausted.value) {
        creditsExhausted.value = true;
      }
    }
  }

  /// Stop the periodic timer and flush any partial seconds so we don't
  /// lose what was already used since the last tick.
  ///
  /// Clears `_userId` BEFORE the await so a concurrent `start()` —
  /// which fires-and-forgets `stop()` to discard previous state — can't
  /// have its newly-assigned `_userId` clobbered by this method's
  /// post-flush cleanup. The race was real: every tick was firing with
  /// `_userId=""` because start() ran `_userId = uid` and then stop()
  /// resumed past its `await _flush()` and reset it back to `''`.
  static Future<void> stop({int extraSeconds = 0}) async {
    if (_kDisabled) return;
    _timer?.cancel();
    _timer = null;
    _pendingSeconds += extraSeconds;
    // Snapshot + clear synchronously.
    final flushUserId = _userId;
    final flushAmount = _pendingSeconds;
    _userId = '';
    _pendingSeconds = 0;
    if (flushUserId.isEmpty || flushAmount <= 0) return;
    debugPrint(
      '[usage] stop flushing $flushAmount seconds for $flushUserId…',
    );
    final remaining = await ProfileApi.consumeCredits(
      userId: flushUserId,
      seconds: flushAmount,
    );
    debugPrint('[usage] stop flush returned remaining=$remaining');
    // Only touch notifiers if no new user has started since.
    if (_userId.isEmpty && remaining != null) {
      creditsRemaining.value = remaining;
      if (remaining == 0 && !creditsExhausted.value) {
        creditsExhausted.value = true;
      }
    }
  }

  /// Wipe local state (e.g. on sign-out). Does NOT flush — caller should
  /// stop first if there's anything to persist.
  static void reset() {
    _timer?.cancel();
    _timer = null;
    _userId = '';
    _pendingSeconds = 0;
    creditsRemaining.value = 0;
    creditsExhausted.value = false;
  }
}
