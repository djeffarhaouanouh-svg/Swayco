import 'package:flutter/foundation.dart';

/// The conversation id currently on screen in a `ChatThreadScreen`, or
/// empty when none is open. Lets the in-app "new message" banner
/// ([MessageBanner]) suppress itself for the conversation the user is
/// already looking at — a message that's already appearing live in that
/// thread doesn't need a banner shouting about it too.
abstract final class OpenThread {
  static final ValueNotifier<String> conversationId =
      ValueNotifier<String>('');
}
