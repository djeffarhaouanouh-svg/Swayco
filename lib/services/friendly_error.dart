import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_strings.dart';

/// Le texte d'une erreur, dans la langue de l'appli.
///
/// Supabase répond en anglais (`User already registered`…), une panne réseau
/// donne le texte brut de l'exception (`ClientException: …`), un refus de base
/// de données un code technique : rien de tout ça ne doit s'afficher tel quel à
/// quelqu'un qui lit le français ou le japonais. Le texte d'origine reste dans la
/// console, pour le diagnostic.
///
/// À utiliser partout où une erreur est MONTRÉE (bandeau, snackbar, champ) ; le
/// reste (logs) garde l'exception brute.
String friendlyError(Object e) {
  debugPrint('error shown to user: $e');
  final code = switch (e) {
    AuthException(:final code) => (code ?? '').toLowerCase(),
    PostgrestException(:final code) => (code ?? '').toLowerCase(),
    _ => '',
  };
  final msg = switch (e) {
    AuthException(:final message) => message,
    PostgrestException(:final message) => message,
    _ => '$e',
  }.toLowerCase();

  // Plafond hebdomadaire de nouveaux contacts sans Pro (garde-fou en base). On
  // ne dit JAMAIS pourquoi en détail : le texte brut de la base, lui, parle de
  // comptes IA et ne doit pas être montré.
  if (msg.contains('weekly_friend_limit')) {
    return AppStrings.t('friend_limit_week');
  }
  if (code == 'user_already_exists' ||
      code == 'email_exists' ||
      msg.contains('already registered') ||
      msg.contains('already been registered')) {
    return AppStrings.t('login_err_user_exists');
  }
  if (code == 'weak_password' ||
      msg.contains('weak password') ||
      msg.contains('password should be') ||
      msg.contains('password is too')) {
    return AppStrings.t('login_err_weak_password');
  }
  if (code.contains('rate_limit') ||
      msg.contains('rate limit') ||
      msg.contains('too many') ||
      msg.contains('security purposes')) {
    return AppStrings.t('login_err_rate_limit');
  }
  if (code == 'email_address_invalid' ||
      (code == 'validation_failed' && msg.contains('email')) ||
      msg.contains('invalid email') ||
      msg.contains('unable to validate email')) {
    return AppStrings.t('login_err_email');
  }
  if (msg.contains('socketexception') ||
      msg.contains('failed host lookup') ||
      msg.contains('clientexception') ||
      msg.contains('xmlhttprequest') ||
      msg.contains('network') ||
      msg.contains('connection') ||
      msg.contains('timed out') ||
      msg.contains('timeout')) {
    return AppStrings.t('login_err_network');
  }
  return AppStrings.t('login_err_generic');
}
