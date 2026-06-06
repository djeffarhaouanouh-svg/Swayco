import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'push_dispatcher.dart';

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    this.recipientId = '',
    required this.senderName,
    required this.body,
    required this.createdAt,
    this.language = '',
    this.audioUrl = '',
    this.audioDurationMs = 0,
    this.imageUrl = '',
    this.discoverPhoto = '',
  });

  final String id;
  final String conversationId;
  final String senderId;

  /// The peer this message was addressed to (`recipient` column). Empty
  /// when the column isn't populated. Together with [senderId] this lets
  /// the chat list resolve the "other party" of a conversation without
  /// parsing the (UUID-laden, dash-ambiguous) conversation id.
  final String recipientId;
  final String senderName;

  /// Text body. For voice messages this carries the STT transcription
  /// produced by the backend so the existing chat translator path
  /// works unchanged.
  final String body;
  final DateTime createdAt;

  /// BCP-47 primary subtag describing what [body] is written in. Sent
  /// at insertion time by [ChatApi.sendMessage] / `/messages/voice`.
  /// Empty when unknown.
  final String language;

  /// Public URL of the original voice recording. Empty for plain text
  /// messages.
  final String audioUrl;

  /// Recording length in milliseconds. 0 when [audioUrl] is empty.
  final int audioDurationMs;

  /// Public URL of an image sent in the thread. Empty for text / voice.
  final String imageUrl;

  /// When this message was sent from a Discover card (intro message or emoji
  /// reaction), the URL of the photo it was about — shown as a Snapchat-style
  /// thumbnail above the message. Empty otherwise.
  final String discoverPhoto;

  /// True when this message was recorded as audio (has a playable URL).
  bool get isVoice => audioUrl.isNotEmpty;

  /// True when this message carries an image.
  bool get isImage => imageUrl.isNotEmpty;

  /// True when this message references a Discover photo (reaction / intro).
  bool get hasDiscoverPhoto => discoverPhoto.isNotEmpty;

  factory ChatMessage.fromMap(Map<String, dynamic> m) {
    final created = m['created_at'];
    final dur = m['audio_duration_ms'];
    return ChatMessage(
      id: m['id']?.toString() ?? '',
      conversationId: m['conversation_id']?.toString() ?? '',
      // Read either `sender` (existing column on user's table) or
      // `sender_id` (the name my earlier migration assumed) — whichever
      // is populated.
      senderId: (m['sender'] ?? m['sender_id'])?.toString() ?? '',
      recipientId: (m['recipient'] ?? m['recipient_id'])?.toString() ?? '',
      senderName: m['sender_name']?.toString() ?? '',
      body: m['body']?.toString() ?? '',
      createdAt: created is String
          ? DateTime.tryParse(created)?.toLocal() ?? DateTime.now()
          : DateTime.now(),
      language: m['language']?.toString().trim() ?? '',
      audioUrl: m['audio_url']?.toString() ?? '',
      imageUrl: m['image_url']?.toString() ?? '',
      discoverPhoto: m['discover_photo']?.toString() ?? '',
      audioDurationMs: dur is int
          ? dur
          : (dur is num
                ? dur.toInt()
                : int.tryParse(dur?.toString() ?? '') ?? 0),
    );
  }
}

/// Thin wrapper over the Supabase `messages` table. All methods assume
/// [Supabase.initialize] has succeeded — callers should gate on
/// [isSupabaseReady] before invoking.
abstract final class ChatApi {
  static SupabaseClient get _client => Supabase.instance.client;

  /// Emojis recognised as "photo reactions": a chat message whose body
  /// matches one of these surfaces on the Demandes feed in addition to the
  /// regular chat thread. Superset of the live Discover rail
  /// (`_ReactionRail._emojis` = 🔥 😍 ❤️) — the older ✨ / 💯 are kept so
  /// reactions sent before the rail changed still resolve.
  static const photoReactionEmojis = <String>['🔥', '✨', '💯', '😍', '❤️'];

  /// Delete every photo-reaction message the local user (`meId`) sent
  /// to [peerId] with body [emoji]. Used by the Discover rail when the
  /// user re-taps a filled reaction button to unsend it. Idempotent —
  /// no row to delete is fine, the call still resolves cleanly.
  static Future<void> deleteMyReaction({
    required String meId,
    required String peerId,
    required String emoji,
    required String photoUrl,
  }) async {
    if (meId.isEmpty || peerId.isEmpty || emoji.isEmpty) return;
    var q = _client
        .from('messages')
        .delete()
        .eq('sender', meId)
        .eq('recipient', peerId)
        .eq('body', emoji);
    // A reaction belongs to a specific photo, stamped in `discover_photo`.
    if (photoUrl.isNotEmpty) q = q.eq('discover_photo', photoUrl);
    await q;
  }

  /// Every photo reaction the local user (`meId`) has ever sent, keyed by the
  /// PHOTO URL it was about (`discover_photo`) and pointing to the set of
  /// emojis sent on that photo. Lets the Discover rail render the buttons
  /// pre-filled only for the exact photo the user reacted to. Legacy
  /// reactions with no photo stamp are ignored (they reset to unreacted).
  static Future<Map<String, Set<String>>> fetchMyOutgoingPhotoReactions(
    String meId,
  ) async {
    if (meId.isEmpty) return const {};
    final rows = await _client
        .from('messages')
        .select('discover_photo, body')
        .eq('sender', meId)
        .inFilter('body', photoReactionEmojis)
        .neq('discover_photo', '');
    final out = <String, Set<String>>{};
    for (final r in rows as List) {
      final map = Map<String, dynamic>.from(r as Map);
      final photo = map['discover_photo']?.toString() ?? '';
      final emoji = map['body']?.toString() ?? '';
      if (photo.isEmpty || emoji.isEmpty) continue;
      out.putIfAbsent(photo, () => <String>{}).add(emoji);
    }
    return out;
  }

  /// Discover photos [meId] has already sent an intro message from. Used by
  /// Discover to enforce "one intro message per photo": once a card's photo is
  /// in this set, that card's message field collapses to its sent state. Each
  /// of a person's photos is a separate card, so they can each be messaged
  /// once. Persisted across restarts via the `discover_photo` column.
  static Future<Set<String>> fetchMyMessagedPhotos(String meId) async {
    if (meId.isEmpty) return <String>{};
    final rows = await _client
        .from('messages')
        .select('discover_photo, body')
        .eq('sender', meId)
        .neq('discover_photo', '');
    final out = <String>{};
    for (final r in rows as List) {
      final map = Map<String, dynamic>.from(r as Map);
      final photo = map['discover_photo']?.toString() ?? '';
      final body = map['body']?.toString() ?? '';
      // Reactions also stamp discover_photo now — they are NOT intro messages.
      if (photo.isEmpty || photoReactionEmojis.contains(body)) continue;
      out.add(photo);
    }
    return out;
  }

  /// Peers [meId] has already sent a Discover intro message to. The Discover
  /// feed is now one card per PERSON (their photos shown in a carousel), so
  /// the "one intro per person" rule keys on the recipient, not the photo.
  /// A non-empty `discover_photo` stamp marks a message as a Discover intro.
  static Future<Set<String>> fetchMyDiscoverMessagedPeers(String meId) async {
    if (meId.isEmpty) return <String>{};
    final rows = await _client
        .from('messages')
        .select('recipient, body')
        .eq('sender', meId)
        .neq('discover_photo', '');
    final out = <String>{};
    for (final r in rows as List) {
      final map = Map<String, dynamic>.from(r as Map);
      final rcpt = map['recipient']?.toString() ?? '';
      final body = map['body']?.toString() ?? '';
      // Reactions now also carry a discover_photo stamp — exclude them so a
      // mere reaction doesn't collapse the card's intro-message field.
      if (rcpt.isEmpty || photoReactionEmojis.contains(body)) continue;
      out.add(rcpt);
    }
    return out;
  }

  /// Most recent photo reactions (Discover-rail emoji taps) addressed
  /// to [meId]. One entry per sender — the latest emoji a given peer
  /// reacted with. Ordered by most recent first.
  static Future<List<ChatMessage>> fetchPhotoReactions(String meId) async {
    if (meId.isEmpty) return const [];
    final rows = await _client
        .from('messages')
        .select()
        .eq('recipient', meId)
        .inFilter('body', photoReactionEmojis)
        .order('created_at', ascending: false)
        .limit(200);
    final seenSenders = <String>{};
    final out = <ChatMessage>[];
    for (final r in rows as List) {
      final msg = ChatMessage.fromMap(Map<String, dynamic>.from(r as Map));
      if (msg.senderId.isEmpty || msg.senderId == meId) continue;
      if (!seenSenders.add(msg.senderId)) continue;
      out.add(msg);
    }
    return out;
  }

  /// Count of photo reactions addressed to [meId] strictly after [since] —
  /// feeds the Demandes "new activity" badge alongside fresh likes.
  static Future<int> countPhotoReactionsSince(
    String meId,
    DateTime since,
  ) async {
    if (meId.isEmpty) return 0;
    try {
      final rows = await _client
          .from('messages')
          .select('sender')
          .eq('recipient', meId)
          .inFilter('body', photoReactionEmojis)
          .gt('created_at', since.toUtc().toIso8601String());
      var n = 0;
      for (final r in rows as List) {
        final s =
            Map<String, dynamic>.from(r as Map)['sender']?.toString() ?? '';
        if (s.isNotEmpty && s != meId) n++;
      }
      return n;
    } catch (e) {
      debugPrint('ChatApi.countPhotoReactionsSince failed: $e');
      return 0;
    }
  }

  /// Most-recent-first window of past messages for a conversation.
  static Future<List<ChatMessage>> fetchMessages(
    String conversationId, {
    int limit = 200,
  }) async {
    final rows = await _client
        .from('messages')
        .select()
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: true)
        .limit(limit);
    return (rows as List)
        .map((r) => ChatMessage.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList(growable: false);
  }

  static Future<void> sendMessage({
    required String conversationId,
    required String senderId,
    required String senderName,
    required String recipientId,
    required String body,
    required String language,
    String discoverPhoto = '',
  }) async {
    await _client.from('messages').insert({
      'conversation_id': conversationId,
      'sender': senderId,
      'recipient': recipientId,
      'sender_name': senderName,
      'body': body,
      'language': language,
      // Stamp the Discover photo this intro was sent from (empty otherwise),
      // so the "one message per photo" rule survives restarts.
      if (discoverPhoto.isNotEmpty) 'discover_photo': discoverPhoto,
    });
    // Fire-and-forget push to the recipient. Best-effort; never block
    // or fail the send because of a notification hiccup.
    unawaited(
      PushDispatcher.notify(
        recipientUid: recipientId,
        title: senderName.isEmpty ? 'Nouveau message' : senderName,
        body: body,
        type: 'message',
        data: {'conversationId': conversationId, 'senderId': senderId},
      ),
    );
  }

  /// Upload [bytes] as a chat image and insert an image message. The file
  /// goes to the existing `avatars` bucket under `chat/<conversation>/` and
  /// its public URL is stored in `image_url`. Best-effort push notification,
  /// like [sendMessage].
  static Future<void> sendImage({
    required String conversationId,
    required String senderId,
    required String senderName,
    required String recipientId,
    required Uint8List bytes,
    String contentType = 'image/jpeg',
  }) async {
    if (bytes.isEmpty) throw ArgumentError('image vide');
    final ext = contentType.endsWith('png') ? 'png' : 'jpg';
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = 'chat/$conversationId/$stamp.$ext';
    await _client.storage.from('avatars').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            upsert: true,
            contentType: contentType,
            cacheControl: '3600',
          ),
        );
    final url = _client.storage.from('avatars').getPublicUrl(path);
    await _client.from('messages').insert({
      'conversation_id': conversationId,
      'sender': senderId,
      'recipient': recipientId,
      'sender_name': senderName,
      'body': '',
      // `language` is NOT NULL with no default — an image carries no language,
      // so stamp it empty (omitting it threw a 23502 not-null violation).
      'language': '',
      'image_url': url,
    });
    unawaited(
      PushDispatcher.notify(
        recipientUid: recipientId,
        title: senderName.isEmpty ? 'Nouveau message' : senderName,
        body: '📷 Photo',
        type: 'message',
        data: {'conversationId': conversationId, 'senderId': senderId},
      ),
    );
  }

  /// Delete a single message by id. Used by "long-press → delete" on a
  /// message the user sent — it removes the row, so the message is gone
  /// for both sides (an "unsend"). RLS decides what the caller may
  /// actually delete: a row the user isn't allowed to touch is simply
  /// left untouched.
  static Future<void> deleteMessage(String messageId) async {
    if (messageId.isEmpty) return;
    await _client.from('messages').delete().eq('id', messageId);
  }

  /// Latest message per conversation that involves [meId]. Used by the
  /// chat list to render WhatsApp-style "last message" previews and to
  /// order rows by recent activity.
  static Future<Map<String, ChatMessage>> fetchLatestPerConversation(
    String meId, {
    // Pulls the N most recent messages across ALL my conversations, then
    // keeps the newest per conversation. So a conversation only drops off
    // the chat list once its last message falls outside this window — i.e.
    // once I've exchanged more than [limit] total messages AND the older
    // thread's friendship has also ended. Bumped 200 → 1000 to push that
    // edge far out of reach for normal usage.
    int limit = 1000,
  }) async {
    if (meId.isEmpty) return const {};
    final rows = await _client
        .from('messages')
        .select()
        .or('sender.eq.$meId,recipient.eq.$meId')
        .order('created_at', ascending: false)
        .limit(limit);
    final out = <String, ChatMessage>{};
    for (final r in rows as List) {
      final msg = ChatMessage.fromMap(Map<String, dynamic>.from(r as Map));
      if (msg.conversationId.isEmpty) continue;
      out.putIfAbsent(msg.conversationId, () => msg);
    }
    return out;
  }

  /// Live stream of all messages in a conversation, ordered chronologically
  /// ascending (oldest first, newest last) so the UI can render them
  /// top-to-bottom in chronological order. Re-emits the entire list on
  /// every insert; fine for typical chat scrollback sizes.
  static Stream<List<ChatMessage>> subscribeMessages(String conversationId) {
    return _client
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: true)
        .map((rows) {
          final list = rows
              .map((m) => ChatMessage.fromMap(Map<String, dynamic>.from(m)))
              .toList();
          // Defensive client-side sort in case the stream ignored the order
          // hint (some Supabase realtime builds default to descending).
          list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          return List<ChatMessage>.unmodifiable(list);
        });
  }
}
