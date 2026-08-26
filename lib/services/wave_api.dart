import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_strings.dart';
import 'auth_service.dart';
import 'profile_api.dart';
import 'push_dispatcher.dart';
import 'supabase_service.dart';

/// Pourquoi un signe n'est pas parti. `ok` est le seul cas de succès ; les
/// autres sont des états d'interface, pas des pannes — le bouton se grise et
/// dit pourquoi, il ne montre pas d'erreur rouge.
enum WaveRefusal {
  /// Envoyé.
  ok,

  /// Trois signes d'affilée sans un mot en retour. On attend.
  streak,

  /// Cinq en 24 h vers la même personne.
  daily,

  /// Pas connecté, ou soi-même.
  ineligible,

  /// Le réseau, ou Supabase absent. Le seul cas où réessayer a du sens.
  failed,
}

/// Résultat d'un [WaveApi.send] : le refus éventuel, et ce qu'il reste après
/// coup pour que le bouton sache s'il doit rester actif.
@immutable
class WaveResult {
  const WaveResult(this.refusal, {this.remainingStreak = 0, this.remainingDaily = 0});

  final WaveRefusal refusal;

  /// Signes encore possibles vers cette personne avant qu'elle réponde.
  final int remainingStreak;

  /// Signes encore possibles vers elle dans les 24 h.
  final int remainingDaily;

  bool get ok => refusal == WaveRefusal.ok;

  /// Le bouton reste-t-il actif pour un prochain signe ?
  bool get canWaveAgain => remainingStreak > 0 && remainingDaily > 0;

  /// La clé i18n du message à montrer, ou null quand c'est passé sans rien
  /// à dire de particulier.
  String? get messageKey => switch (refusal) {
        WaveRefusal.ok => null,
        WaveRefusal.streak => 'wave_capped_streak',
        WaveRefusal.daily => 'wave_capped_daily',
        WaveRefusal.ineligible => null,
        WaveRefusal.failed => 'wave_failed',
      };
}

/// Ce qu'il reste de signes vers une personne donnée, tel que le serveur le
/// voit. Absent de la carte = rien n'a encore été envoyé, tout est ouvert.
@immutable
class WaveQuota {
  const WaveQuota({required this.remainingStreak, required this.remainingDaily});

  final int remainingStreak;
  final int remainingDaily;

  bool get canWave => remainingStreak > 0 && remainingDaily > 0;
}

/// « Faire signe » (👋) — le ping de Houseparty, porté par la table `waves`
/// et la fonction `send_wave` (migration 0057).
///
/// Le plafond n'est PAS appliqué ici : trois d'affilée sans réponse, cinq par
/// 24 h, c'est `send_wave()` qui compte, côté serveur, parce qu'un plafond
/// que le client s'impose tout seul ne tient pas une soirée. [send] se
/// contente de transmettre le refus. Ce que cette classe fait en plus, c'est
/// [quotas] : demander l'état AVANT, pour que les boutons déjà à sec partent
/// grisés au lieu de se découvrir sous le doigt.
abstract final class WaveApi {
  static SupabaseClient get _c => Supabase.instance.client;

  /// Faire signe à [peerId]. Envoie aussi la notification push, dans la
  /// langue du DESTINATAIRE — c'est lui qui la lit.
  ///
  /// [peerLang] et [myName] évitent deux allers-retours quand l'écran a déjà
  /// les profils en main ; vides, ils sont retrouvés.
  static Future<WaveResult> send({
    required String peerId,
    String peerLang = '',
    String myName = '',
  }) async {
    if (!isSupabaseReady) return const WaveResult(WaveRefusal.failed);
    final me = AuthService.currentUserId;
    final peer = peerId.trim();
    if (me.isEmpty || peer.isEmpty || me == peer) {
      return const WaveResult(WaveRefusal.ineligible);
    }

    final Map<String, dynamic> res;
    try {
      final raw = await _c.rpc('send_wave', params: {'p_recipient': peer});
      res = Map<String, dynamic>.from(raw as Map);
    } catch (e) {
      debugPrint('WaveApi.send failed: $e');
      return const WaveResult(WaveRefusal.failed);
    }

    final remainingStreak = (res['remaining_streak'] as num?)?.toInt() ?? 0;
    final remainingDaily = (res['remaining_daily'] as num?)?.toInt() ?? 0;
    if (res['ok'] != true) {
      return WaveResult(
        switch (res['reason']?.toString()) {
          'streak' => WaveRefusal.streak,
          'daily' => WaveRefusal.daily,
          _ => WaveRefusal.ineligible,
        },
        remainingStreak: remainingStreak,
        remainingDaily: remainingDaily,
      );
    }

    // Fire-and-forget, comme partout ailleurs : le signe est déjà en base,
    // une notification qui échoue ne doit pas le faire passer pour raté.
    unawaited(_notify(peerId: peer, peerLang: peerLang, myName: myName));

    return WaveResult(
      WaveRefusal.ok,
      remainingStreak: remainingStreak,
      remainingDaily: remainingDaily,
    );
  }

  static Future<void> _notify({
    required String peerId,
    required String peerLang,
    required String myName,
  }) async {
    try {
      final lang = peerLang.isNotEmpty
          ? peerLang
          : (await ProfileApi.fetchById(peerId))?.language ?? '';
      final name = myName.trim();
      await PushDispatcher.notify(
        recipientUid: peerId,
        // Le prénom en titre, comme un message : c'est de QUI que ça vient
        // qui décide si on ouvre. L'emoji le distingue au premier coup d'œil
        // d'un message écrit.
        title: name.isEmpty
            ? AppStrings.tIn(lang, 'push_wave_title_anon')
            : '👋 $name',
        body: AppStrings.tIn(lang, 'push_wave_body'),
        type: 'wave',
        data: {'senderId': AuthService.currentUserId},
      );
    } catch (e) {
      debugPrint('WaveApi notify failed: $e');
    }
  }

  /// Ce qu'il reste de signes vers chaque personne à qui j'ai fait signe ces
  /// 24 h. Les absents n'ont pas de quota entamé : tout leur est ouvert.
  static Future<Map<String, WaveQuota>> quotas() async {
    if (!isSupabaseReady || AuthService.currentUserId.isEmpty) return const {};
    try {
      final rows = await _c.rpc('my_wave_quota');
      final out = <String, WaveQuota>{};
      for (final r in (rows as List? ?? const [])) {
        final m = Map<String, dynamic>.from(r as Map);
        final peer = m['peer']?.toString() ?? '';
        if (peer.isEmpty) continue;
        out[peer] = WaveQuota(
          remainingStreak: (m['remaining_streak'] as num?)?.toInt() ?? 0,
          remainingDaily: (m['remaining_daily'] as num?)?.toInt() ?? 0,
        );
      }
      return out;
    } catch (e) {
      debugPrint('WaveApi.quotas failed: $e');
      return const {};
    }
  }

  /// Les signes qu'on m'a faits et que je n'ai pas encore vus, par personne.
  /// La valeur est l'instant du plus récent — l'écran en fait un « à
  /// l'instant / il y a 5 min » sur la ligne.
  static Future<Map<String, DateTime>> unseenInbound() async {
    final me = AuthService.currentUserId;
    if (!isSupabaseReady || me.isEmpty) return const {};
    try {
      final rows = await _c
          .from('waves')
          .select('sender, created_at')
          .eq('recipient', me)
          .isFilter('seen_at', null)
          .order('created_at', ascending: false);
      final out = <String, DateTime>{};
      for (final r in (rows as List? ?? const [])) {
        final m = Map<String, dynamic>.from(r as Map);
        final from = m['sender']?.toString() ?? '';
        final at = DateTime.tryParse(m['created_at']?.toString() ?? '');
        if (from.isEmpty || at == null) continue;
        // La liste arrive du plus récent au plus ancien : le premier vu pour
        // une personne est le bon.
        out.putIfAbsent(from, () => at.toLocal());
      }
      return out;
    } catch (e) {
      debugPrint('WaveApi.unseenInbound failed: $e');
      return const {};
    }
  }

  /// Marquer vus tous les signes de [peerId]. Rouvre du même coup son
  /// compteur d'affilée : voir un signe VAUT réponse, sinon quelqu'un qui
  /// consulte sans répondre resterait bloqué à trois pour toujours.
  static Future<void> markSeen(String peerId) async {
    final me = AuthService.currentUserId;
    if (!isSupabaseReady || me.isEmpty || peerId.isEmpty) return;
    try {
      await _c
          .from('waves')
          .update({'seen_at': DateTime.now().toUtc().toIso8601String()})
          .eq('recipient', me)
          .eq('sender', peerId)
          .isFilter('seen_at', null);
    } catch (e) {
      debugPrint('WaveApi.markSeen failed: $e');
    }
  }
}
