import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_strings.dart';
import 'chat_api.dart';
import 'profile_api.dart';
import 'push_dispatcher.dart';

/// Un membre d'un groupe (table `chat_group_members`).
class GroupMember {
  const GroupMember({
    required this.userId,
    required this.admin,
    required this.muted,
    required this.joinedAt,
  });

  final String userId;
  final bool admin;
  final bool muted;
  final DateTime joinedAt;
}

/// Un groupe de discussion (tables `chat_groups` + `chat_group_members`).
class ChatGroup {
  const ChatGroup({
    required this.id,
    required this.name,
    required this.createdBy,
    required this.createdAt,
    required this.members,
    this.photoUrl = '',
  });

  /// La photo choisie pour le groupe ('' = mosaïque des membres).
  final String photoUrl;

  final String id;
  final String name;
  final String createdBy;
  final DateTime createdAt;
  final List<GroupMember> members;

  /// L'identifiant de conversation des messages du groupe.
  String get conversationId => '$kGroupConvPrefix$id';

  GroupMember? memberOf(String userId) {
    for (final m in members) {
      if (m.userId == userId) return m;
    }
    return null;
  }

  bool isAdmin(String userId) => memberOf(userId)?.admin ?? false;
}

/// Préfixe des conversations de groupe (`grp-<uuid>`), à côté de `dm-…`.
const String kGroupConvPrefix = 'grp-';

bool isGroupConversation(String conversationId) =>
    conversationId.startsWith(kGroupConvPrefix);

/// Les groupes : création, membres, envoi. Les écritures passent par des
/// fonctions SQL (`create_group`, `group_add_members`…) : un client ne peut pas
/// se nommer admin lui-même. Les messages, eux, vivent dans `messages` avec
/// `conversation_id = grp-<uuid>` et SANS destinataire.
abstract final class GroupApi {
  static SupabaseClient get _client => Supabase.instance.client;

  /// Le nom du groupe que je viens de QUITTER, le temps que la liste Messages
  /// affiche la bannière « Tu as quitté … » (puis elle le vide).
  static String justLeftName = '';

  /// Mes groupes, avec leurs membres. Vide si la table n'est pas migrée.
  static Future<List<ChatGroup>> fetchMine(String meId) async {
    if (meId.isEmpty) return const [];
    try {
      final mine = await _client
          .from('chat_group_members')
          .select('group_id')
          .eq('user_id', meId);
      final ids = <String>{
        for (final r in mine as List)
          if ((r as Map)['group_id'] != null) r['group_id'].toString(),
      }.toList();
      if (ids.isEmpty) return const [];
      final results = await Future.wait([
        _client.from('chat_groups').select().inFilter('id', ids),
        _client.from('chat_group_members').select().inFilter('group_id', ids),
      ]);
      final byGroup = <String, List<GroupMember>>{};
      for (final r in results[1] as List) {
        final m = Map<String, dynamic>.from(r as Map);
        final gid = m['group_id']?.toString() ?? '';
        if (gid.isEmpty) continue;
        byGroup.putIfAbsent(gid, () => []).add(GroupMember(
              userId: m['user_id']?.toString() ?? '',
              admin: m['role'] == 'admin',
              muted: m['muted'] == true,
              joinedAt: DateTime.tryParse(m['joined_at']?.toString() ?? '')
                      ?.toLocal() ??
                  DateTime.now(),
            ));
      }
      final out = <ChatGroup>[];
      for (final r in results[0] as List) {
        final g = Map<String, dynamic>.from(r as Map);
        final id = g['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final members = byGroup[id] ?? const <GroupMember>[];
        // Un ordre STABLE : le créateur d'abord, puis par arrivée, puis par id.
        // Les membres ajoutés à la création ont tous la même heure
        // (`now()` d'une transaction) : sans le dernier critère, l'ordre
        // changeait à chaque relecture et la mosaïque de la photo du groupe
        // bougeait toute seule.
        final creator = g['created_by']?.toString() ?? '';
        members.sort((a, b) {
          if (a.userId == creator && b.userId != creator) return -1;
          if (b.userId == creator && a.userId != creator) return 1;
          final c = a.joinedAt.compareTo(b.joinedAt);
          return c != 0 ? c : a.userId.compareTo(b.userId);
        });
        out.add(ChatGroup(
          id: id,
          name: g['name']?.toString() ?? '',
          photoUrl: g['photo_url']?.toString() ?? '',
          createdBy: g['created_by']?.toString() ?? '',
          createdAt: DateTime.tryParse(g['created_at']?.toString() ?? '')
                  ?.toLocal() ??
              DateTime.now(),
          members: members,
        ));
      }
      return out;
    } catch (e) {
      debugPrint('GroupApi.fetchMine failed: $e');
      return const [];
    }
  }

  /// Un groupe précis (null s'il n'existe plus ou si je n'en suis plus membre).
  static Future<ChatGroup?> fetchOne(String meId, String groupId) async {
    final all = await fetchMine(meId);
    for (final g in all) {
      if (g.id == groupId) return g;
    }
    return null;
  }

  static Future<String> create({
    required String name,
    required List<String> memberIds,
  }) async {
    final res = await _client.rpc('create_group', params: {
      'p_name': name,
      'p_members': memberIds,
    });
    return res?.toString() ?? '';
  }

  static Future<void> addMembers(String groupId, List<String> ids) =>
      _client.rpc('group_add_members', params: {
        'p_group': groupId,
        'p_members': ids,
      });

  static Future<void> removeMember(String groupId, String userId) =>
      _client.rpc('group_remove_member', params: {
        'p_group': groupId,
        'p_user': userId,
      });

  static Future<void> makeAdmin(String groupId, String userId) =>
      _client.rpc('group_set_admin', params: {
        'p_group': groupId,
        'p_user': userId,
      });

  static Future<void> leave(String groupId) =>
      _client.rpc('group_leave', params: {'p_group': groupId});

  /// Change la photo du groupe : l'image part dans le stockage (`avatars`,
  /// dossier `groups/`), son URL publique est rangée sur le groupe.
  static Future<String> setPhoto(
    String groupId,
    Uint8List bytes, {
    String contentType = 'image/jpeg',
  }) async {
    final ext = contentType.endsWith('png') ? 'png' : 'jpg';
    final path =
        'groups/$groupId/${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _client.storage.from('avatars').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: true),
        );
    final url = _client.storage.from('avatars').getPublicUrl(path);
    await _client.rpc('group_set_photo', params: {
      'p_group': groupId,
      'p_url': url,
    });
    return url;
  }

  static Future<void> setMuted(String groupId, bool muted) =>
      _client.rpc('group_set_muted', params: {
        'p_group': groupId,
        'p_muted': muted,
      });

  /// Le dernier message de chaque groupe (pour l'aperçu et le tri de la liste).
  static Future<Map<String, ChatMessage>> fetchLatest(
    List<ChatGroup> groups,
  ) async {
    if (groups.isEmpty) return const {};
    try {
      final rows = await _client
          .from('messages')
          .select()
          .inFilter('conversation_id', [for (final g in groups) g.conversationId])
          .order('created_at', ascending: false)
          .limit(400);
      final out = <String, ChatMessage>{};
      for (final r in rows as List) {
        final msg = ChatMessage.fromMap(Map<String, dynamic>.from(r as Map));
        out.putIfAbsent(msg.conversationId, () => msg);
      }
      return out;
    } catch (e) {
      debugPrint('GroupApi.fetchLatest failed: $e');
      return const {};
    }
  }

  /// Les messages reçus (pas les miens) de mes groupes, pour la pastille de non
  /// lus : (conversation, date).
  static Future<List<({String conversationId, DateTime createdAt})>>
      fetchInbound(String meId, List<ChatGroup> groups) async {
    if (groups.isEmpty) return const [];
    try {
      final rows = await _client
          .from('messages')
          .select('conversation_id, created_at, sender')
          .inFilter('conversation_id', [for (final g in groups) g.conversationId])
          .neq('sender', meId)
          .order('created_at', ascending: false)
          .limit(500);
      final out = <({String conversationId, DateTime createdAt})>[];
      for (final r in rows as List) {
        final m = Map<String, dynamic>.from(r as Map);
        final ts = DateTime.tryParse(m['created_at']?.toString() ?? '');
        final cid = m['conversation_id']?.toString() ?? '';
        if (ts == null || cid.isEmpty) continue;
        out.add((conversationId: cid, createdAt: ts));
      }
      return out;
    } catch (e) {
      debugPrint('GroupApi.fetchInbound failed: $e');
      return const [];
    }
  }

  /// Prévient chaque personne AJOUTÉE à un groupe (à sa création ou plus tard) :
  /// « Lely t'a ajouté au groupe », dans SA langue, avec le nom du groupe en
  /// titre. Un tap ouvre la conversation du groupe. Au mieux : un échec
  /// n'annule jamais l'ajout.
  static Future<void> notifyAdded({
    required String groupId,
    required String groupName,
    required List<String> addedIds,
  }) async {
    try {
      final meId = _client.auth.currentUser?.id ?? '';
      final targets = [
        for (final id in addedIds)
          if (id.isNotEmpty && id != meId) id,
      ];
      if (targets.isEmpty || groupId.isEmpty) return;
      final me = meId.isEmpty ? null : await ProfileApi.fetchById(meId);
      final first =
          (me?.displayName ?? '').trim().split(RegExp(r'\s+')).first;
      final profiles = await ProfileApi.fetchByIds(targets);
      final langOf = {for (final p in profiles) p.id: p.language};
      for (final uid in targets) {
        unawaited(PushDispatcher.notify(
          recipientUid: uid,
          title: groupName.trim().isEmpty ? 'Swayco' : groupName.trim(),
          body: AppStrings.tIn(
            langOf[uid] ?? '',
            'push_group_added',
            args: {'name': first.isEmpty ? 'Swayco' : first},
          ),
          type: 'message',
          data: {
            'conversationId': 'grp-$groupId',
            'groupId': groupId,
            'groupName': groupName,
            'senderId': meId,
          },
        ));
      }
    } catch (e) {
      debugPrint('GroupApi.notifyAdded failed: $e');
    }
  }

  /// Notifie les autres membres (sauf ceux qui ont mis le groupe en silence),
  /// chacun dans SA langue. Au mieux : un échec n'arrête jamais l'envoi.
  static Future<void> notifyMembers({
    required ChatGroup group,
    required String meId,
    required String senderName,
    required String preview,
  }) async {
    try {
      final targets = [
        for (final m in group.members)
          if (m.userId != meId && !m.muted) m.userId,
      ];
      if (targets.isEmpty) return;
      final profiles = await ProfileApi.fetchByIds(targets);
      final langOf = {for (final p in profiles) p.id: p.language};
      final first = senderName.trim().split(RegExp(r'\s+')).first;
      for (final uid in targets) {
        final lang = langOf[uid] ?? '';
        unawaited(PushDispatcher.notify(
          recipientUid: uid,
          title: group.name,
          body: first.isEmpty
              ? preview
              : '$first : ${preview.isEmpty ? AppStrings.tIn(lang, 'push_photo') : preview}',
          type: 'message',
          data: {
            'conversationId': group.conversationId,
            'groupId': group.id,
            'groupName': group.name,
            'senderId': meId,
          },
        ));
      }
    } catch (e) {
      debugPrint('GroupApi.notifyMembers failed: $e');
    }
  }
}
