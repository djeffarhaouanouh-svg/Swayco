import 'package:flutter/foundation.dart';

/// The tab currently selected in [RootShell]'s bottom nav, exposed as a
/// shared notifier so screens pushed *on top* of the shell (a peer's
/// profile, the friends list, …) can render the same nav bar and switch
/// tabs without holding a reference to the shell's private state.
///
/// Tab indices match [RootShell]'s page list: Chat 0, Discover 1,
/// Demandes 2, Profile 3. Defaults to Discover, the launch tab.
abstract final class NavTab {
  static const int chat = 0;
  static const int discover = 1;
  static const int demandes = 2;
  static const int profile = 3;

  static final ValueNotifier<int> index = ValueNotifier<int>(discover);

  /// Switch to tab [i]. No-op when it's already selected.
  static void select(int i) {
    if (i != index.value) index.value = i;
  }

  /// One-shot: the post-onboarding "Suivant" (tip #4) wants the own-profile
  /// add-photo picker opened — the same sheet as tapping + on "Tes photos".
  static bool _addPhotoPending = false;
  static final ValueNotifier<int> addPhotoTick = ValueNotifier<int>(0);

  static bool get hasAddPhotoRequest => _addPhotoPending;

  static void requestAddPhoto() {
    _addPhotoPending = true;
    addPhotoTick.value++;
  }

  static bool takeAddPhotoRequest() {
    if (!_addPhotoPending) return false;
    _addPhotoPending = false;
    return true;
  }
}
