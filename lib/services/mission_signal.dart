import 'package:flutter/foundation.dart';

/// Pulsed by any action that might complete an onboarding mission — a like, a
/// message, a reaction, a friend request. [MissionsService] listens and
/// re-checks immediately. Lives in its own tiny file so the data-layer APIs
/// can poke it WITHOUT importing the missions feature (avoids an import cycle).
final ValueNotifier<int> missionSignal = ValueNotifier<int>(0);

void pokeMissions() => missionSignal.value++;
