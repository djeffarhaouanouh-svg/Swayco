import 'dart:async';

import 'package:flutter/foundation.dart';

/// Bookkeeping behind Discover's "retour" on a like.
///
/// A right swipe starts a like that takes a few round trips, and "retour" can be
/// tapped before it has landed. So the swipe opens a slot for that person
/// ([begin]) and the like fills it with the id of the pending row it wrote, if
/// any: an older like or a match leaves it empty, because those are not for
/// "retour" to take back. [undo] withdraws that row as soon as its id is known,
/// and [turn] makes a new like on the same person wait for the withdrawal, so a
/// late delete can't erase the like just sent.
class LikeUndo {
  LikeUndo(this._withdraw);

  /// Deletes the pending row; true when it was really withdrawn.
  final Future<bool> Function(String friendshipId) _withdraw;

  final Map<String, Future<String?>> _slots = {};
  final Map<String, Future<void>> _withdrawing = {};

  /// Opens the slot for a like about to be sent to [peerId]. Complete it with the
  /// id of the pending row that like wrote, or null when it wrote none.
  Completer<String?> begin(String peerId) {
    final slot = Completer<String?>();
    _slots[peerId] = slot.future;
    return slot;
  }

  /// A pass is the last word on [peerId]: no like is left to take back.
  void forget(String peerId) => _slots.remove(peerId);

  /// Resolves once any withdrawal in flight for [peerId] is over. Bounded, so a
  /// stalled request can't lock the person out of being liked again.
  Future<void> turn(String peerId) =>
      (_withdrawing[peerId] ?? Future<void>.value()).timeout(
        const Duration(seconds: 10),
        onTimeout: () {},
      );

  /// Takes back the like the last swipe on [peerId] sent, if there is one.
  /// Resolves to the id of the row withdrawn, or null when nothing was.
  Future<String?> undo(String peerId) {
    final slot = _slots.remove(peerId);
    if (slot == null) return Future<String?>.value();
    final done = () async {
      try {
        final id = await slot;
        if (id == null) return null;
        return await _withdraw(id) ? id : null;
      } catch (e) {
        debugPrint('like undo failed: $e');
        return null;
      }
    }();
    final marker = done.then<void>((_) {});
    _withdrawing[peerId] = marker;
    marker.whenComplete(() {
      if (_withdrawing[peerId] == marker) _withdrawing.remove(peerId);
    });
    return done;
  }
}
