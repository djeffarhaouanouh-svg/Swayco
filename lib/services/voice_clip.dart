// Le lecteur d'un vocal : audioplayers sur mobile, la balise <audio> du
// navigateur sur le web (voir voice_clip_base.dart pour le pourquoi).
export 'voice_clip_base.dart';
export 'voice_clip_stub.dart' if (dart.library.html) 'voice_clip_web.dart';
