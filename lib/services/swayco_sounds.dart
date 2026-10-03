import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SwSound {
  photoAdded,
  deleted,
  reorderPick,
  reorderDrop,
  profileSaved,
  friendRequest,
  friendAccepted,
  reaction,
  boost,
  purchase,
  sentCheck,
  block,
  mute,
  unmute,
  globeLaunch,
  stepNext,
  welcome,
  undo,
  signOut,
  msgSent,
  msgReceived,
  match,
  like,
  pass,
  callConnected,
  callEnded,
  translation,
  error,
}

/// Sons courts de l'app (assets/sounds/). Jamais sur le web, jamais plus
/// fort que la musique de l'utilisateur, et sans toucher à la session audio
/// d'un appel : `callActive` bascule le contexte iOS sur celui de WebRTC
/// (playAndRecord + mixWithOthers) pour que le son ne coupe pas le micro.
abstract final class SwaycoSounds {
  static const _prefKey = 'app_sounds_enabled';
  static const _files = {
    SwSound.photoAdded: 'swayco_photo_added.wav',
    SwSound.deleted: 'swayco_deleted.wav',
    SwSound.reorderPick: 'swayco_reorder_pick.wav',
    SwSound.reorderDrop: 'swayco_reorder_drop.wav',
    SwSound.profileSaved: 'swayco_profile_saved.wav',
    SwSound.friendRequest: 'swayco_friend_request.wav',
    SwSound.friendAccepted: 'swayco_friend_accepted.wav',
    SwSound.reaction: 'swayco_reaction.wav',
    SwSound.boost: 'swayco_boost.wav',
    SwSound.purchase: 'swayco_purchase.wav',
    SwSound.sentCheck: 'swayco_sent_check.wav',
    SwSound.block: 'swayco_block.wav',
    SwSound.mute: 'swayco_mute.wav',
    SwSound.unmute: 'swayco_unmute.wav',
    SwSound.globeLaunch: 'swayco_globe_launch.wav',
    SwSound.stepNext: 'swayco_step_next.wav',
    SwSound.welcome: 'swayco_welcome.wav',
    SwSound.undo: 'swayco_undo.wav',
    SwSound.signOut: 'swayco_signout.wav',
    SwSound.msgSent: 'swayco_msg_sent.wav',
    SwSound.msgReceived: 'swayco_msg_received.wav',
    SwSound.match: 'swayco_match.wav',
    SwSound.like: 'swayco_like.wav',
    SwSound.pass: 'swayco_pass.wav',
    SwSound.callConnected: 'swayco_call_connected.wav',
    SwSound.callEnded: 'swayco_call_ended.wav',
    SwSound.translation: 'swayco_translation.wav',
    SwSound.error: 'swayco_error.wav',
  };
  static final _players = <SwSound, AudioPlayer>{};

  /// Réglage Paramètres > Sons de l'app, vrai par défaut.
  static bool enabled = true;

  /// Vrai pendant un appel : le contexte audio suit celui de WebRTC.
  static bool callActive = false;

  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  static Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      enabled = p.getBool(_prefKey) ?? true;
    } catch (_) {}
  }

  static Future<void> setEnabled(bool v) async {
    enabled = v;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_prefKey, v);
    } catch (_) {}
  }

  static AudioContext get _context => AudioContext(
        iOS: callActive
            ? AudioContextIOS(
                category: AVAudioSessionCategory.playAndRecord,
                options: const {
                  AVAudioSessionOptions.mixWithOthers,
                  AVAudioSessionOptions.defaultToSpeaker,
                  AVAudioSessionOptions.allowBluetooth,
                  AVAudioSessionOptions.allowBluetoothA2DP,
                },
              )
            // « ambient » : respecte le bouton silencieux, se mélange à la musique.
            : AudioContextIOS(
                category: AVAudioSessionCategory.ambient,
                options: const {},
              ),
        // Aucun focus audio : ne baisse ni ne coupe la voix d'un appel.
        android: const AudioContextAndroid(
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.assistanceSonification,
          audioFocus: AndroidAudioFocus.none,
        ),
      );

  static Future<void> play(SwSound s) async {
    if (!enabled || !_supported) return;
    try {
      var p = _players[s];
      if (p == null) {
        p = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
        _players[s] = p;
        await p.setAudioContext(_context);
        await p.setVolume(0.7);
        await p.setSource(AssetSource('sounds/${_files[s]}'));
      } else {
        await p.setAudioContext(_context);
        await p.stop();
      }
      await p.resume();
    } catch (e) {
      debugPrint('SwaycoSounds.play($s) failed: $e');
    }
  }
}
