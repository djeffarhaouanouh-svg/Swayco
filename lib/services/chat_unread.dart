import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_strings.dart';
import 'message_banner.dart';
import 'message_reactions.dart';
import 'supabase_service.dart';

/// Tracks the count of unread messages addressed to the local user, so the
/// Chat tab can show a badge. The "seen" point is one timestamp stored in
/// SharedPreferences — opening the Chat list marks everything older as seen.
abstract final class ChatUnread {
  static final ValueNotifier<int> count = ValueNotifier<int>(0);

  /// Bumped on every write to the seen state (global floor or per-
  /// conversation). [count] only notifies when the numeric badge total
  /// actually changes, which isn't a reliable "the chat list should
  /// repaint its rows" signal — a thread can be marked seen while the
  /// total unread count coincidentally stays the same. Listen to this
  /// instead when a widget needs to know "something was marked read,
  /// re-render," regardless of arrival path (list tap, push notification, …).
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Le plancher d'INSTALLATION : tout ce qui est antérieur est tenu pour lu.
  ///
  /// Posé une fois, au premier lancement, et plus jamais touché. Il se relevait
  /// à chaque passage sur l'onglet Messages, ce qui voulait dire « regarder la
  /// liste = avoir tout lu » : la ligne bleue du message non lu s'éteignait
  /// avant même qu'on ait ouvert la conversation, et on ne savait plus où était
  /// le nouveau message. VOIR n'est pas LIRE — seul l'ouverture d'un fil pose
  /// un point de lecture désormais.
  static const _seenKey = 'chat_last_seen_iso';

  /// Le point de lecture PAR conversation, relevé à l'ouverture d'un fil.
  static const _convSeenPrefix = 'chat_conv_seen_';
  static StreamSubscription<List<Map<String, dynamic>>>? _sub;
  static StreamSubscription<List<MessageReaction>>? _reactionSub;

  /// Les points de lecture par conversation, en mémoire.
  ///
  /// Le compte se calculait sur le seul plancher global, et rien d'autre ne le
  /// bougeait que « toucher l'onglet Messages ». Lire une conversation
  /// n'éteignait donc pas le « 1 » de la barre de nav ni celui du profil : ils
  /// avaient leur propre notion de « vu », séparée de celle des fils, et les
  /// deux ne se parlaient jamais. Une seule source maintenant — ce que le
  /// badge affiche est ce que les conversations disent.
  static Map<String, DateTime> _convSeen = {};

  /// La dernière photo du flux, gardée pour pouvoir RECALCULER le compte quand
  /// un fil est lu, sans attendre que la base réémette quoi que ce soit. C'est
  /// ce qui rend l'extinction immédiate.
  static List<Map<String, dynamic>> _lastRows = const [];

  /// Jusqu'où cette conversation est lue : son propre point s'il existe, le
  /// plancher sinon — et le plus récent des deux, pour que relever le plancher
  /// (toucher l'onglet) suffise à tout éteindre.
  static DateTime? _seenFor(String convId) {
    final floor = DateTime.tryParse(_lastSeenIso);
    final own = _convSeen[convId];
    if (own == null) return floor;
    if (floor == null) return own;
    return own.isAfter(floor) ? own : floor;
  }

  /// Public, live view of [_seenFor] — the single source of truth for the
  /// BADGE count, kept current in memory regardless of which screen last
  /// marked it seen (chat list, thread, push notification, …). Merges the
  /// global floor (bumped just by visiting the Messages tab), which is
  /// correct for "is there something new anywhere" but WRONG for the blue
  /// line / row pastille — see [threadSeenAt].
  static DateTime? seenAt(String convId) => _seenFor(convId);

  /// The thread's OWN read pointer alone, never the global floor. The blue
  /// line / unread pastille answer "was THIS conversation opened," not "was
  /// Messages visited since" — merging the floor here would let landing on
  /// the tab silently clear a row nobody actually read. That distinction is
  /// the entire reason the floor and the per-conversation map are two
  /// separate fields (see the class doc above); [_isUnread] in the chat
  /// list must use this, not [seenAt].
  static DateTime? threadSeenAt(String convId) => _convSeen[convId];
  static String _meId = '';
  static String _lastSeenIso = '';

  /// Start watching the messages table for [meId]. Safe to call repeatedly;
  /// re-subscribes if the id changed.
  static Future<void> start(String meId) async {
    if (meId.isEmpty || !isSupabaseReady) return;
    if (meId == _meId && _sub != null) return;
    _meId = meId;

    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_seenKey);
    if (stored != null) {
      _lastSeenIso = stored;
    } else {
      // Premier lancement : on grave l'instant présent, une bonne fois. Sans
      // cette écriture le plancher se redéfinissait à chaque démarrage, et
      // tout ce qui était arrivé pendant que l'app était fermée passait pour
      // lu — le badge ne signalait jamais rien après un redémarrage.
      _lastSeenIso = DateTime.now().toUtc().toIso8601String();
      await prefs.setString(_seenKey, _lastSeenIso);
    }
    _convSeen = await readPerConversationSeen();

    _primed = false;
    _reactionsPrimed = false;
    await _sub?.cancel();
    await _reactionSub?.cancel();
    _sub = Supabase.instance.client
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('recipient', meId)
        .listen(
          _onRows,
          onError: (e) =>
              debugPrint('ChatUnread stream error: $e'),
        );
    // Reactions on MY messages — same in-app banner path as a new chat
    // line, so a 👍 isn't silent just because it isn't a row in `messages`.
    _reactionSub = MessageReactions.subscribeForAuthor(meId).listen(
      _onReactions,
      onError: (e) => debugPrint('ChatUnread reaction stream error: $e'),
    );
  }

  /// False until the first emission after [start] has been processed —
  /// that first emission is the whole backlog, not new arrivals, and must
  /// not fire a banner per unread message from before the app was open.
  static bool _primed = false;

  static void _onRows(List<Map<String, dynamic>> rows) {
    final previousIds = {for (final r in _lastRows) r['id']?.toString() ?? ''};
    final skipBanners = !_primed;
    _primed = true;
    _lastRows = rows;
    _recount();
    if (!skipBanners) {
      for (final r in rows) {
        final id = r['id']?.toString() ?? '';
        if (id.isEmpty || previousIds.contains(id)) continue;
        _offerBanner(r);
      }
    }
  }

  static void _offerBanner(Map<String, dynamic> row) {
    final convId = row['conversation_id']?.toString() ?? '';
    final senderId = (row['sender'] ?? row['sender_id'])?.toString() ?? '';
    if (convId.isEmpty || senderId.isEmpty) return;
    final imageUrl = row['image_url']?.toString() ?? '';
    final body = row['body']?.toString().trim() ?? '';
    MessageBanner.offer(MessageBannerIntent(
      conversationId: convId,
      peerId: senderId,
      senderName: row['sender_name']?.toString().trim() ?? '',
      preview: imageUrl.isNotEmpty ? AppStrings.t('push_photo') : body,
    ));
  }

  /// False until the first reaction snapshot is in — that emission is the
  /// backlog, not a fresh 👍, and must not toast every historical react.
  static bool _reactionsPrimed = false;
  static Set<String> _knownReactionIds = {};

  static void _onReactions(List<MessageReaction> rows) {
    final previous = _knownReactionIds;
    _knownReactionIds = {
      for (final r in rows)
        if (r.id.isNotEmpty) r.id,
    };
    final skipBanners = !_reactionsPrimed;
    _reactionsPrimed = true;
    if (skipBanners) return;
    for (final r in rows) {
      if (r.id.isEmpty || previous.contains(r.id)) continue;
      if (r.userId.isEmpty || r.userId == _meId) continue;
      MessageBanner.offer(MessageBannerIntent(
        conversationId: r.conversationId,
        peerId: r.userId,
        senderName: r.userName.trim(),
        preview: AppStrings.t('push_reaction_body', args: {'emoji': r.emoji}),
      ));
    }
  }

  /// Recompte à partir de la dernière photo connue.
  ///
  /// Les dates sont comparées comme des DateTime, plus comme des chaînes : le
  /// point de lecture était écrit en `…Z` et Postgres rend `…+00:00`, deux
  /// écritures du même instant qui ne se rangent pas pareil caractère par
  /// caractère.
  static void _recount() {
    var n = 0;
    for (final r in _lastRows) {
      final at = DateTime.tryParse(r['created_at']?.toString() ?? '');
      if (at == null) continue;
      final seen = _seenFor(r['conversation_id']?.toString() ?? '');
      if (seen == null || at.isAfter(seen)) n++;
    }
    if (count.value != n) count.value = n;
  }

  /// Call when the user opens the Chat tab — moves the seen pointer to now
  /// and resets the badge.
  static Future<void> markAllSeen() async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    _lastSeenIso = nowIso;
    // Éteint AVANT l'écriture disque, et sans l'attendre : le badge doit
    // tomber au moment du geste. Le compte se relit du plancher déjà posé en
    // mémoire, donc une réémission du flux entre-temps ne le rallume pas.
    _recount();
    revision.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_seenKey, nowIso);
  }

  static Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _reactionSub?.cancel();
    _reactionSub = null;
    _meId = '';
    _knownReactionIds = {};
    _reactionsPrimed = false;
    count.value = 0;
  }

  /// Mark conversation [convId] as seen *now*. Called when its thread is
  /// opened so the per-row unread indicator on the chat list clears for
  /// that specific row.
  static Future<void> markConversationSeen(String convId) async {
    if (convId.isEmpty) return;
    final now = DateTime.now().toUtc();
    // En mémoire d'abord, et on recompte tout de suite : lire un fil doit
    // faire tomber le badge de la barre de nav et celui du profil à la
    // seconde, pas au prochain passage par la liste.
    _convSeen[convId] = now;
    _recount();
    revision.value++;
    final p = await SharedPreferences.getInstance();
    await p.setString('$_convSeenPrefix$convId', now.toIso8601String());
  }

  /// Le plancher courant, pour que la LISTE juge « non lu » exactement comme
  /// le badge : une conversation jamais ouverte n'est pas non lue depuis
  /// toujours, elle l'est depuis le plancher.
  static DateTime? get seenFloor => DateTime.tryParse(_lastSeenIso);

  /// Snapshot of every per-conversation last-seen timestamp. Returned as
  /// a `{conversationId: DateTime}` map; conversations the user has never
  /// opened are simply absent from the map (callers should treat that as
  /// "everything is unread").
  static Future<Map<String, DateTime>> readPerConversationSeen() async {
    final p = await SharedPreferences.getInstance();
    final out = <String, DateTime>{};
    for (final k in p.getKeys()) {
      if (!k.startsWith(_convSeenPrefix)) continue;
      final iso = p.getString(k);
      if (iso == null) continue;
      final dt = DateTime.tryParse(iso);
      if (dt == null) continue;
      out[k.substring(_convSeenPrefix.length)] = dt;
    }
    return out;
  }

  /// Prefix for per-conversation "cleared at" timestamps — set when the
  /// user deletes a conversation from their chat list. Local-only (delete
  /// for me): the peer's copy is untouched.
  static const _convClearedPrefix = 'chat_conv_cleared_';

  /// Mark conversation [convId] as cleared *now*. The chat list hides it
  /// until a message newer than this timestamp arrives.
  static Future<void> markConversationCleared(String convId) async {
    if (convId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(
      '$_convClearedPrefix$convId',
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  /// Snapshot of every "cleared at" timestamp, `{conversationId: DateTime}`.
  static Future<Map<String, DateTime>> clearedConversations() async {
    final p = await SharedPreferences.getInstance();
    final out = <String, DateTime>{};
    for (final k in p.getKeys()) {
      if (!k.startsWith(_convClearedPrefix)) continue;
      final iso = p.getString(k);
      if (iso == null) continue;
      final dt = DateTime.tryParse(iso);
      if (dt == null) continue;
      out[k.substring(_convClearedPrefix.length)] = dt;
    }
    return out;
  }
}
