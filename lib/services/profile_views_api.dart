import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'block_api.dart';
import 'profile_api.dart';
import 'supabase_service.dart';

/// Une visite : qui, et quand (une ligne par visiteur et par jour).
typedef ProfileVisit = ({String viewerId, DateTime at});

/// Une personne qui a ouvert mon profil, et quand pour la dernière fois.
typedef ProfileView = ({RemoteProfile profile, DateTime at});

/// Les réglages des vues : [history] coupé, je n'apparais plus chez les autres
/// et je ne vois plus les miennes ; [notify], une notification par jour au plus.
typedef ProfileViewSettings = ({bool history, bool notify});

const ProfileViewSettings kDefaultViewSettings = (history: true, notify: false);

/// Les visites de mon profil sur les 60 derniers jours (30 affichés, 30 pour la
/// comparaison). Les calculs se font en jours calendaires locaux.
class ProfileViewsData {
  const ProfileViewsData({
    this.visits = const [],
    this.people = const {},
    this.settings = kDefaultViewSettings,
  });

  /// La plus récente d'abord.
  final List<ProfileVisit> visits;
  final Map<String, RemoteProfile> people;
  final ProfileViewSettings settings;

  /// Minuit du premier jour d'une période de [days] jours finissant à [now].
  static DateTime startOf(DateTime now, int days) =>
      DateTime(now.year, now.month, now.day - (days - 1));

  Iterable<ProfileVisit> _within(int days, DateTime now) {
    final from = startOf(now, days);
    return visits.where((v) => !v.at.isBefore(from));
  }

  /// Nombre de visites sur les [days] derniers jours.
  int count(int days, DateTime now) => _within(days, now).length;

  /// Évolution en % par rapport à la période d'avant ; `null` si elle est vide
  /// (aucun pourcentage honnête à annoncer).
  int? deltaPercent(int days, DateTime now) {
    final current = count(days, now);
    final before = count(days * 2, now) - current;
    if (before == 0) return null;
    return ((current - before) * 100 / before).round();
  }

  /// Les visites des 7 derniers jours, jour par jour (le dernier = aujourd'hui).
  List<int> lastWeek(DateTime now) {
    final days = [for (var i = 6; i >= 0; i--) startOf(now, i + 1)];
    final out = List<int>.filled(7, 0);
    for (final v in visits) {
      final day = DateTime(v.at.year, v.at.month, v.at.day);
      final i = days.indexOf(day);
      if (i >= 0) out[i]++;
    }
    return out;
  }

  /// Les visiteurs de la période, une fois chacun (dernier passage), le plus
  /// récent d'abord.
  List<ProfileView> visitors(int days, DateTime now) {
    final seen = <String>{};
    return [
      for (final v in _within(days, now))
        if (people[v.viewerId] != null && seen.add(v.viewerId))
          (profile: people[v.viewerId]!, at: v.at),
    ];
  }

  /// Combien de personnes sont passées depuis [seen].
  int newSince(DateTime seen) => {
        for (final v in visits)
          if (v.at.isAfter(seen) && people[v.viewerId] != null) v.viewerId,
      }.length;
}

/// Les vues de profil (tables `profile_views` et `profile_view_settings`,
/// migrations 0099 et 0100).
abstract final class ProfileViewsApi {
  static SupabaseClient get _c => Supabase.instance.client;

  static const int _page = 1000;
  static const int _maxRows = 5000;

  /// J'ai ouvert le profil de [peerId]. Une ligne par jour (l'heure suit le
  /// dernier passage), sans jamais gêner la page : un échec est ignoré, comme le
  /// refus de la base quand mon historique est coupé.
  static Future<void> record(String peerId) async {
    final me = AuthService.currentUserId;
    if (!isSupabaseReady || me.isEmpty || peerId.isEmpty || me == peerId) {
      return;
    }
    try {
      await ProfileApi.ensureMyProfileRow();
      await _c.from('profile_views').upsert(
        {'viewed_id': peerId, 'viewer_id': me},
        onConflict: 'viewed_id,viewer_id,day',
      );
    } catch (e) {
      debugPrint('ProfileViewsApi.record failed: $e');
    }
  }

  /// Mes réglages. Lève en cas d'échec.
  static Future<ProfileViewSettings> settings() async {
    final me = AuthService.currentUserId;
    if (!isSupabaseReady || me.isEmpty) return kDefaultViewSettings;
    final row = await _c
        .from('profile_view_settings')
        .select('history, notify')
        .eq('user_id', me)
        .maybeSingle();
    if (row == null) return kDefaultViewSettings;
    return (history: row['history'] != false, notify: row['notify'] == true);
  }

  static Future<void> saveSettings(ProfileViewSettings s) async {
    final me = AuthService.currentUserId;
    if (!isSupabaseReady || me.isEmpty) return;
    await ProfileApi.ensureMyProfileRow();
    await _c.from('profile_view_settings').upsert(
      {
        'user_id': me,
        'history': s.history,
        'notify': s.notify,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      onConflict: 'user_id',
    );
  }

  /// Efface toutes les visites de MON profil.
  static Future<void> clear() => _c.rpc('clear_profile_views');

  /// Les visites de mon profil, sans les personnes bloquées. Lève en cas
  /// d'échec.
  static Future<ProfileViewsData> load() async {
    final me = AuthService.currentUserId;
    if (!isSupabaseReady || me.isEmpty) return const ProfileViewsData();
    var mine = kDefaultViewSettings;
    try {
      mine = await settings();
    } catch (e) {
      // Table des réglages absente : la liste reste lisible.
      debugPrint('profile view settings: $e');
    }
    if (!mine.history) return ProfileViewsData(settings: mine);

    final now = DateTime.now();
    final since = ProfileViewsData.startOf(now, 60).toUtc().toIso8601String();
    final visits = <ProfileVisit>[];
    for (var from = 0; from < _maxRows; from += _page) {
      final rows = await _c
          .from('profile_views')
          .select('viewer_id, viewed_at')
          .eq('viewed_id', me)
          .gte('viewed_at', since)
          .order('viewed_at', ascending: false)
          .range(from, from + _page - 1);
      for (final r in rows) {
        final id = r['viewer_id']?.toString() ?? '';
        final at = DateTime.tryParse(r['viewed_at']?.toString() ?? '');
        if (id.isEmpty || at == null) continue;
        visits.add((viewerId: id, at: at.toLocal()));
      }
      if (rows.length < _page) break;
    }
    if (visits.isEmpty) return ProfileViewsData(settings: mine);

    final blocks = await Future.wait<Object>([
      BlockApi.fetchMyBlockedProfiles(me),
      BlockApi.fetchMyBlockerIds(),
    ]);
    final hidden = {
      for (final p in blocks[0] as List<RemoteProfile>) p.id,
      ...blocks[1] as Set<String>,
    };
    final shown = [
      for (final v in visits)
        if (!hidden.contains(v.viewerId)) v,
    ];

    // Les profils ne servent que pour la période affichée.
    final listed = ProfileViewsData.startOf(now, 30);
    final ids = {
      for (final v in shown)
        if (!v.at.isBefore(listed)) v.viewerId,
    }.toList();
    final people = <String, RemoteProfile>{};
    for (var i = 0; i < ids.length; i += 100) {
      final chunk = ids.sublist(i, i + 100 > ids.length ? ids.length : i + 100);
      for (final p in await ProfileApi.fetchByIds(chunk)) {
        people[p.id] = p;
      }
    }
    return ProfileViewsData(visits: shown, people: people, settings: mine);
  }

  static String _seenKey() =>
      'profile_views_seen_${AuthService.currentUserId}';

  /// La dernière fois que j'ai ouvert la liste (pour la pastille « nouveaux »).
  static Future<DateTime> lastSeen() async {
    final p = await SharedPreferences.getInstance();
    return DateTime.fromMillisecondsSinceEpoch(p.getInt(_seenKey()) ?? 0);
  }

  static Future<void> markSeen() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_seenKey(), DateTime.now().millisecondsSinceEpoch);
  }
}
