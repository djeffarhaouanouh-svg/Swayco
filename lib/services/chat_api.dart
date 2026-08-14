import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_strings.dart';
import 'profile_api.dart';
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

  /// Text body of the message.
  final String body;
  final DateTime createdAt;

  /// BCP-47 primary subtag describing what [body] is written in. Sent
  /// at insertion time by [ChatApi.sendMessage]. Empty when unknown.
  final String language;

  /// Public URL of an image sent in the thread. Empty for text.
  final String imageUrl;

  /// When this message was sent from a Discover card (intro message or emoji
  /// reaction), the URL of the photo it was about — shown as a Snapchat-style
  /// thumbnail above the message. Empty otherwise.
  final String discoverPhoto;

  /// True when this message carries an image.
  bool get isImage => imageUrl.isNotEmpty;

  /// True when this message references a Discover photo (reaction / intro).
  bool get hasDiscoverPhoto => discoverPhoto.isNotEmpty;

  factory ChatMessage.fromMap(Map<String, dynamic> m) {
    final created = m['created_at'];
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
      imageUrl: m['image_url']?.toString() ?? '',
      discoverPhoto: m['discover_photo']?.toString() ?? '',
    );
  }
}

/// Thin wrapper over the Supabase `messages` table. All methods assume
/// [Supabase.initialize] has succeeded — callers should gate on
/// [isSupabaseReady] before invoking.
abstract final class ChatApi {
  static SupabaseClient get _client => Supabase.instance.client;

  /// Emojis recognised as legacy "photo reaction" messages — no current UI
  /// sends these, but historical rows with these bodies are excluded from
  /// intro-message detection ([fetchMyMessagedPhotos],
  /// [fetchMyDiscoverMessagedPeers]) and the ❤️ ones still surface on the
  /// "Liked photos" page ([fetchMyHeartedItems]).
  static const photoReactionEmojis = <String>['🔥', '✨', '💯', '😍', '❤️'];

  /// Photos [meId] sent a heart (❤️) reaction on, as (photoUrl, ownerId)
  /// pairs — `recipient` is the photo owner. Feeds the "Liked photos" page so
  /// each row knows whose photo to link to.
  static Future<List<({String photoUrl, String ownerId})>> fetchMyHeartedItems(
    String meId,
  ) async {
    if (meId.isEmpty) return const [];
    final rows = await _client
        .from('messages')
        .select('discover_photo, recipient, body')
        .eq('sender', meId)
        .inFilter('body', photoReactionEmojis)
        .neq('discover_photo', '');
    final out = <({String photoUrl, String ownerId})>[];
    for (final r in rows as List) {
      final map = Map<String, dynamic>.from(r as Map);
      final body = map['body']?.toString() ?? '';
      if (!body.contains('❤')) continue;
      final photo = map['discover_photo']?.toString() ?? '';
      final owner = map['recipient']?.toString() ?? '';
      if (photo.isEmpty || owner.isEmpty) continue;
      out.add((photoUrl: photo, ownerId: owner));
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
    String recipientLang = '',
  }) async {
    // The insert FK-references my profiles row (messages_sender_fkey); make
    // sure it exists first, else a launch that skipped the profile sync
    // crashes with 23503 "key not present in table profiles".
    await ProfileApi.ensureMyProfileRow();
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
    // Fire-and-forget push to the recipient, localised into THEIR language.
    // Best-effort; never block or fail the send on a notification hiccup.
    // [recipientLang] is passed by the chat thread (peer profile already in
    // hand) to avoid a fetch; falls back to a lookup when it's empty.
    unawaited(_notifyMessage(
      recipientId: recipientId,
      recipientLang: recipientLang,
      senderName: senderName,
      conversationId: conversationId,
      senderId: senderId,
      body: body,
    ));
  }

  /// Resolve the recipient's language (param or fetch) and fire the localised
  /// "new message" push. [imageBody] true → the body is a localised "📷 Photo"
  /// label instead of the message text.
  static Future<void> _notifyMessage({
    required String recipientId,
    required String recipientLang,
    required String senderName,
    required String conversationId,
    required String senderId,
    String body = '',
    bool imageBody = false,
  }) async {
    final lang = recipientLang.isNotEmpty
        ? recipientLang
        : (await ProfileApi.fetchById(recipientId))?.language ?? '';
    await PushDispatcher.notify(
      recipientUid: recipientId,
      title: senderName.isEmpty
          ? AppStrings.tIn(lang, 'push_new_message')
          : senderName,
      body: imageBody ? AppStrings.tIn(lang, 'push_photo') : body,
      type: 'message',
      data: {'conversationId': conversationId, 'senderId': senderId},
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
    String recipientLang = '',
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
    // Self-heal my profiles row before the FK-bound insert (see sendMessage).
    await ProfileApi.ensureMyProfileRow();
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
    unawaited(_notifyMessage(
      recipientId: recipientId,
      recipientLang: recipientLang,
      senderName: senderName,
      conversationId: conversationId,
      senderId: senderId,
      imageBody: true,
    ));
  }

  /// Envoie un GIF : le fichier reste chez Giphy, on ne stocke que son URL
  /// dans `image_url`. Le rendu et la notification sont ceux d'une image —
  /// pour le reste de l'app, un GIF EST une image.
  static Future<void> sendGif({
    required String conversationId,
    required String senderId,
    required String senderName,
    required String recipientId,
    required String gifUrl,
    String recipientLang = '',
  }) async {
    if (gifUrl.isEmpty) throw ArgumentError('GIF sans URL');
    // Self-heal my profiles row before the FK-bound insert (see sendMessage).
    await ProfileApi.ensureMyProfileRow();
    await _client.from('messages').insert({
      'conversation_id': conversationId,
      'sender': senderId,
      'recipient': recipientId,
      'sender_name': senderName,
      'body': '',
      // `language` est NOT NULL sans défaut : un GIF n'a pas de langue.
      'language': '',
      'image_url': gifUrl,
    });
    unawaited(_notifyMessage(
      recipientId: recipientId,
      recipientLang: recipientLang,
      senderName: senderName,
      conversationId: conversationId,
      senderId: senderId,
      imageBody: true,
    ));
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

  /// Recent inbound messages addressed to [meId] (newest first), as
  /// (conversationId, createdAt) pairs. Feeds the per-row UNREAD COUNT on
  /// the chat list: the caller keeps those newer than its last-seen time
  /// per conversation. Bounded window — a conversation with more unread
  /// than fits is capped (the badge shows e.g. "99+").
  static Future<List<({String conversationId, DateTime createdAt})>>
      fetchInboundForUnread(String meId, {int limit = 500}) async {
    if (meId.isEmpty) return const [];
    final rows = await _client
        .from('messages')
        .select('conversation_id, created_at')
        .eq('recipient', meId)
        .order('created_at', ascending: false)
        .limit(limit);
    final out = <({String conversationId, DateTime createdAt})>[];
    for (final r in rows as List) {
      final m = Map<String, dynamic>.from(r as Map);
      final cid = m['conversation_id']?.toString() ?? '';
      final ts = DateTime.tryParse(m['created_at']?.toString() ?? '');
      if (cid.isEmpty || ts == null) continue;
      out.add((conversationId: cid, createdAt: ts));
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
