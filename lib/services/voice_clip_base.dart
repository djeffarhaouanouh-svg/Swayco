/// Le lecteur audio d'UN vocal du chat, sans dépendre de la plateforme.
///
/// Sur mobile c'est `audioplayers` ; sur le web, la balise `<audio>` du
/// navigateur (voir voice_clip_web.dart) : `audioplayers` y branche le son sur
/// un contexte Web Audio que le navigateur laisse parfois suspendu, et la lecture
/// attend alors sans fin, sans la moindre erreur.
abstract class VoiceClip {
  /// Vrai tant que le son joue.
  Stream<bool> get playing;
  Stream<Duration> get position;

  /// La durée du fichier, quand le lecteur la connaît.
  Stream<Duration> get duration;

  /// La fin du fichier.
  Stream<void> get completed;

  /// Un message lisible quand la lecture échoue (format, réseau, blocage).
  Stream<String> get errors;

  /// Lit [url] depuis le début.
  Future<void> play(String url);
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(Duration to);
  Future<void> stop();
  Future<void> dispose();
}
