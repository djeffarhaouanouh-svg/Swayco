import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'account_switcher.dart';
import 'auth_service.dart';
import 'supabase_service.dart';

/// Un téléphone peut rester connecté à un compte supprimé ailleurs (autre
/// appareil, base) : son jeton reste valable un moment, l'app a l'air normale,
/// et la moindre action échoue sur la clé étrangère `profiles`. Ici on demande
/// au serveur si le compte existe encore ; sinon on le déconnecte et l'écran de
/// connexion le dit.
abstract final class AccountGuard {
  static const _resumeGap = Duration(minutes: 1);

  static Future<bool>? _running;
  static DateTime? _lastResumeCheck;
  static String _goneUid = '';
  static bool _notice = false;

  /// [uid] vient d'être reconnu comme supprimé : l'action en cours s'arrête là,
  /// sans message d'erreur.
  static bool isGone(String uid) => uid.isNotEmpty && uid == _goneUid;

  /// Un message « ce compte n'existe plus » attend l'écran de connexion.
  static bool get hasNotice => _notice;

  /// L'écran de connexion prend ce message : une seule fois.
  static bool takeNotice() {
    final pending = _notice;
    _notice = false;
    return pending;
  }

  /// Au retour de l'app au premier plan (au plus une fois par minute).
  static Future<void> checkOnResume() async {
    final now = DateTime.now();
    final last = _lastResumeCheck;
    if (last != null && now.difference(last) < _resumeGap) return;
    _lastResumeCheck = now;
    await signOutIfDeleted();
  }

  /// Rend `true` si le compte connecté n'existe plus (il est alors déconnecté).
  /// Au moindre doute (réseau, jeton expiré…), on ne touche à rien.
  static Future<bool> signOutIfDeleted() =>
      _running ??= _check().whenComplete(() => _running = null);

  static Future<bool> _check() async {
    if (!isSupabaseReady || AccountSwitcher.busy) return false;
    final auth = Supabase.instance.client.auth;
    final uid = AuthService.currentUserId;
    if (uid.isEmpty) return false;
    try {
      await auth.getUser().timeout(const Duration(seconds: 6));
      return false;
    } on AuthException catch (e) {
      // La seule réponse qui prouve la suppression.
      if (e.code != 'user_not_found' &&
          !e.message.contains('sub claim in JWT does not exist')) {
        return false;
      }
    } catch (e) {
      debugPrint('AccountGuard check failed: $e');
      return false;
    }
    if (AuthService.currentUserId != uid) return false;
    _goneUid = uid;
    try {
      // D'autres comptes gardés sur ce téléphone : on passe au suivant.
      if (await AccountSwitcher.leaveCurrentForAnother()) return true;
      _notice = true;
      await AuthService.signOut();
    } catch (e) {
      debugPrint('AccountGuard sign out failed: $e');
    }
    return true;
  }
}
