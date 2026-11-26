import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'ios_callkit.dart';
import 'notification_client.dart';
import 'profile_api.dart';
import 'revenue_cat.dart';
import 'supabase_service.dart';

/// Un compte gardé sur ce téléphone pour pouvoir y revenir en un tap.
class SavedAccount {
  const SavedAccount({
    required this.id,
    required this.email,
    required this.name,
    required this.avatarUrl,
    required this.refreshToken,
  });

  final String id;
  final String email;
  final String name;
  final String avatarUrl;
  final String refreshToken;

  Map<String, String> toJson() => {
        'id': id,
        'email': email,
        'name': name,
        'avatar': avatarUrl,
        'token': refreshToken,
      };

  static SavedAccount? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String s(String k) => raw[k]?.toString() ?? '';
    if (s('id').isEmpty || s('token').isEmpty) return null;
    return SavedAccount(
      id: s('id'),
      email: s('email'),
      name: s('name'),
      avatarUrl: s('avatar'),
      refreshToken: s('token'),
    );
  }
}

enum SwitchResult { ok, expired, failed }

/// « Changer de compte » (handoff `changer_compte`) : bascule en un tap entre
/// des comptes enregistrés sur l'appareil. Seul le compte actif reçoit les
/// notifications et les appels.
///
/// RÉSERVÉ à Iasmim : la fonction se débloque sur un téléphone où son compte
/// est connecté, et le reste ensuite (sinon, passée sur un autre compte, elle ne
/// pourrait plus revenir). Pour tous les autres utilisateurs, rien n'est
/// enregistré et rien ne change. Pas de limite au nombre de comptes.
abstract final class AccountSwitcher {
  static const String ownerId = '2b5383a3-9afa-4369-add9-87fe3f6298e6';

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  static const _kList = 'saved_accounts_v1';
  static const _kUnlocked = 'account_switcher_unlocked';

  /// Vrai pendant une bascule / un ajout : l'application ignore alors les
  /// changements de session intermédiaires.
  static bool busy = false;

  /// Bumpé à la fin d'une bascule : l'application relit qui est connecté.
  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  static GoTrueClient get _auth => Supabase.instance.client.auth;

  static Future<bool> available() async {
    if (!isSupabaseReady) return false;
    if (AuthService.currentUserId == ownerId) return true;
    try {
      return await _storage.read(key: _kUnlocked) == '1';
    } catch (e) {
      debugPrint('AccountSwitcher.available failed: $e');
      return false;
    }
  }

  static Future<List<SavedAccount>> list() async {
    try {
      final raw = await _storage.read(key: _kList);
      if (raw == null || raw.isEmpty) return [];
      return [
        for (final e in jsonDecode(raw) as List) ?SavedAccount.fromJson(e),
      ];
    } catch (e) {
      debugPrint('AccountSwitcher.list failed: $e');
      return [];
    }
  }

  static Future<void> _save(List<SavedAccount> all) => _storage.write(
        key: _kList,
        value: jsonEncode([for (final a in all) a.toJson()]),
      );

  /// Enregistre (ou met à jour) le compte connecté avec son jeton le plus
  /// récent. Les jetons tournent : à rappeler à chaque rafraîchissement.
  static Future<void> rememberCurrent({bool fetchProfile = true}) async {
    if (!isSupabaseReady) return;
    final session = _auth.currentSession;
    final token = session?.refreshToken ?? '';
    final uid = session?.user.id ?? '';
    if (uid.isEmpty || token.isEmpty) return;
    try {
      if (uid == ownerId) await _storage.write(key: _kUnlocked, value: '1');
      if (!await available()) return;
      var name = '';
      var avatar = '';
      if (fetchProfile) {
        try {
          final p = await ProfileApi.fetchById(uid);
          name = p?.displayName.trim() ?? '';
          avatar = p?.bestAvatarUrl ?? '';
        } catch (_) {}
      }
      final all = await list();
      final i = all.indexWhere((a) => a.id == uid);
      final old = i < 0 ? null : all[i];
      final entry = SavedAccount(
        id: uid,
        email: session?.user.email ?? old?.email ?? '',
        name: name.isNotEmpty ? name : (old?.name ?? ''),
        avatarUrl: avatar.isNotEmpty ? avatar : (old?.avatarUrl ?? ''),
        // Le jeton a pu tourner pendant la lecture du profil : on relit.
        refreshToken: _auth.currentSession?.user.id == uid
            ? (_auth.currentSession?.refreshToken ?? token)
            : token,
      );
      if (i < 0) {
        all.add(entry);
      } else {
        all[i] = entry;
      }
      await _save(all);
    } catch (e) {
      debugPrint('AccountSwitcher.rememberCurrent failed: $e');
    }
  }

  /// Oublie la connexion gardée sur ce téléphone (le compte, lui, reste).
  static Future<void> remove(String id) async {
    try {
      await _save([for (final a in await list()) if (a.id != id) a]);
    } catch (e) {
      debugPrint('AccountSwitcher.remove failed: $e');
    }
  }

  /// Détache l'appareil du compte [uid] (notifications, appels, achats), comme
  /// une déconnexion mais SANS fermer sa session.
  static Future<void> _unlink(String uid) async {
    if (uid.isEmpty) return;
    Future<void> step(Future<void> Function() f) async {
      try {
        await f().timeout(const Duration(seconds: 8));
      } catch (e) {
        debugPrint('AccountSwitcher.unlink step failed: $e');
      }
    }

    await step(() => NotificationClient.unregister(uid));
    await step(() => IosCallKit.unregisterToken(uid));
    await step(RevenueCat.logOut);
  }

  static Future<void> _relink(String uid) async {
    if (uid.isEmpty) return;
    unawaited(NotificationClient.registerIfAuthorized(uid));
    unawaited(IosCallKit.registerToken(uid));
    unawaited(RevenueCat.identify(uid));
  }

  static Future<SwitchResult> switchTo(SavedAccount target) async {
    if (busy || !isSupabaseReady) return SwitchResult.failed;
    final previous = AuthService.currentUserId;
    if (target.id == previous) return SwitchResult.ok;
    busy = true;
    var result = SwitchResult.failed;
    String previousToken = '';
    try {
      await rememberCurrent();
      previousToken = _auth.currentSession?.refreshToken ?? '';
      await _unlink(previous);
      // Le jeton le plus récent connu pour ce compte.
      final fresh = (await list()).where((a) => a.id == target.id);
      await _auth.setSession(
        fresh.isEmpty ? target.refreshToken : fresh.first.refreshToken,
      );
      AuthService.lastSignInMethod = '';
      await rememberCurrent();
      result = SwitchResult.ok;
    } on AuthException catch (e) {
      debugPrint('AccountSwitcher.switchTo auth: $e');
      if (e is! AuthRetryableFetchException) {
        // Jeton expiré ou révoqué : il ne servira plus.
        await remove(target.id);
        result = SwitchResult.expired;
      }
    } catch (e) {
      debugPrint('AccountSwitcher.switchTo failed: $e');
    }
    if (result != SwitchResult.ok) {
      // Un échec a pu fermer la session en cours : on la rouvre.
      try {
        if (AuthService.currentUserId != previous && previousToken.isNotEmpty) {
          await _auth.setSession(previousToken);
          await rememberCurrent(fetchProfile: false);
        }
        await _relink(AuthService.currentUserId);
      } catch (e) {
        debugPrint('AccountSwitcher.restore failed: $e');
      }
    }
    busy = false;
    changed.value++;
    return result;
  }

  /// Avant d'ouvrir l'écran de connexion pour « Ajouter un compte ».
  static Future<String> beginAdd() async {
    busy = true;
    final previous = AuthService.currentUserId;
    await rememberCurrent();
    await _unlink(previous);
    return previous;
  }

  /// Au retour de cet écran (compte ajouté, ou annulé).
  static Future<void> endAdd(String previous) async {
    if (AuthService.currentUserId == previous) {
      await _relink(previous);
    } else {
      await rememberCurrent();
    }
    busy = false;
    changed.value++;
  }

  /// Déconnexion / suppression du compte actif : s'il reste d'autres comptes
  /// enregistrés, on bascule sur le suivant et on rend `true` ; sinon on retire
  /// juste celui-ci de la liste (la déconnexion habituelle suit).
  static Future<bool> leaveCurrentForAnother() async {
    if (!isSupabaseReady) return false;
    final current = AuthService.currentUserId;
    final others = [for (final a in await list()) if (a.id != current) a];
    await remove(current);
    if (others.isEmpty) return false;
    busy = true;
    try {
      await AuthService.signOut();
    } catch (e) {
      debugPrint('AccountSwitcher.signOut failed: $e');
    }
    for (final a in others) {
      try {
        await _auth.setSession(a.refreshToken);
        AuthService.lastSignInMethod = '';
        await rememberCurrent();
        break;
      } catch (e) {
        debugPrint('AccountSwitcher.next failed: $e');
        if (e is AuthException && e is! AuthRetryableFetchException) {
          await remove(a.id);
        }
      }
    }
    busy = false;
    changed.value++;
    return true;
  }
}
