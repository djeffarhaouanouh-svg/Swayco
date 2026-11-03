import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// `idle` : rien. `holding` : le doigt est sur le micro. `locked` : verrouillé,
/// on peut lâcher. `paused` : verrouillé et en pause.
enum VoiceRecState { idle, holding, locked, paused }

/// Pourquoi [VoiceRecorder.start] n'a rien enregistré.
enum VoiceStart { started, denied, failed }

class VoiceRecording {
  const VoiceRecording(
    this.bytes,
    this.durationMs, {
    this.ext = 'm4a',
    this.contentType = 'audio/mp4',
  });
  final Uint8List bytes;
  final int durationMs;

  /// `m4a` (AAC) sur mobile ; `webm` (Opus) sur le web, où le navigateur n'écrit
  /// pas d'AAC.
  final String ext;
  final String contentType;
}

/// Le conteneur réel d'un fichier audio, lu dans ses premiers octets.
({String ext, String contentType})? sniffAudioContainer(List<int> b) {
  if (b.length >= 4 &&
      b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3) {
    return (ext: 'webm', contentType: 'audio/webm'); // EBML : WebM / Matroska
  }
  if (b.length >= 8 &&
      b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70) {
    return (ext: 'm4a', contentType: 'audio/mp4'); // « ftyp » : MP4 / AAC
  }
  if (b.length >= 4 &&
      b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53) {
    return (ext: 'ogg', contentType: 'audio/ogg'); // « OggS »
  }
  if (b.length >= 4 &&
      b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46) {
    return (ext: 'wav', contentType: 'audio/wav'); // « RIFF »
  }
  return null;
}

/// En dessous : rien n'est envoyé. Au-dessus (60 s) : arrêt et envoi
/// automatiques. La base accepte 120 s ; le front plafonne à 60.
const int kVoiceMinMs = 1000;
const int kVoiceMaxMs = 60000;

/// Combien de niveaux l'onde en direct garde.
const int kVoiceLevelCount = 40;

/// dB -> 0..1 : -45 dB (presque le silence) à 0 dB.
double voiceLevelFromDb(double db) => ((db + 45) / 45).clamp(0.0, 1.0);

/// L'enregistreur des vocaux du chat : AAC-LC dans un .m4a, 44,1 kHz, mono,
/// 64 kbit/s (un .wav 16 kHz sur le web). Rien à voir avec l'enregistreur des
/// appels (WebRTC).
///
/// Le fichier vit dans le dossier temporaire et disparaît dès qu'on envoie ou
/// qu'on annule.
class VoiceRecorder extends ChangeNotifier {
  VoiceRecorder({AudioRecorder? recorder}) : _recorder = recorder;

  AudioRecorder? _recorder;

  /// Créé au premier usage seulement : le composer fabrique un VoiceRecorder à
  /// chaque ouverture d'une conversation, et un plugin qui coince (plateforme
  /// sans micro) ne doit pas pouvoir casser la barre d'écriture tout entière.
  AudioRecorder get _rec => _recorder ??= AudioRecorder();

  VoiceRecState _state = VoiceRecState.idle;
  VoiceRecState get state => _state;
  bool get active => _state != VoiceRecState.idle;

  final List<double> _levels = [];

  /// Les derniers niveaux (0..1), du plus ancien au plus récent.
  List<double> get levels => List.unmodifiable(_levels);
  double get level => _levels.isEmpty ? 0 : _levels.last;

  final Stopwatch _clock = Stopwatch();
  Duration get elapsed => _clock.elapsed;

  /// Appelé une fois, quand les 60 s sont atteintes.
  VoidCallback? onLimit;
  bool _limitFired = false;

  Timer? _tick;
  StreamSubscription<Amplitude>? _amp;
  String? _path;
  Future<VoiceStart>? _starting;

  /// Demande le micro (la 1re fois) et démarre. L'état passe à `holding`
  /// tout de suite, pour que l'écran réagisse sans attendre la permission.
  Future<VoiceStart> start() => _starting ??= _start();

  Future<VoiceStart> _start() async {
    _set(VoiceRecState.holding);
    _levels.clear();
    _limitFired = false;
    _clock.reset();
    try {
      // Web : la demande est celle du navigateur, via le plugin d'enregistrement.
      final granted = kIsWeb
          ? await _rec.hasPermission()
          : (await Permission.microphone.request()).isGranted;
      if (!granted) {
        _set(VoiceRecState.idle);
        return VoiceStart.denied;
      }
      // Web : pas de dossier temporaire, le navigateur garde l'enregistrement
      // en mémoire et rend une adresse à l'arrêt.
      final path = kIsWeb
          ? ''
          : '${(await getTemporaryDirectory()).path}/voice_'
              '${DateTime.now().millisecondsSinceEpoch}.m4a';
      // Annulé pendant la demande de permission : on n'enregistre rien.
      if (_state == VoiceRecState.idle) return VoiceStart.failed;
      await _rec.start(
        RecordConfig(
          // Web : du WAV (PCM 16 bits, 16 kHz, mono). Le MediaRecorder du
          // navigateur écrit du WebM (Chrome) ou du MP4 (Safari / iPhone) selon
          // l'appareil, et l'iPhone échouait à décoder ce que le plugin
          // produisait (« media failed to decode »). Le WAV se lit partout ; à
          // 16 kHz il pèse ~32 Ko/s, soit 1,9 Mo pour 60 s (< 2 Mo du dossier).
          encoder: kIsWeb ? AudioEncoder.wav : AudioEncoder.aacLc,
          sampleRate: kIsWeb ? 16000 : 44100,
          numChannels: 1,
          bitRate: 64000,
          // Moins de blocs à recoller côté plugin : 8192 échantillons par bloc.
          streamBufferSize: kIsWeb ? 8192 : null,
        ),
        path: path,
      );
      _path = path;
      _clock.start();
      _amp = _rec
          .onAmplitudeChanged(const Duration(milliseconds: 80))
          .listen((a) {
        _levels.add(voiceLevelFromDb(a.current));
        if (_levels.length > kVoiceLevelCount) _levels.removeAt(0);
        notifyListeners();
      });
      _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!_limitFired && _clock.elapsedMilliseconds >= kVoiceMaxMs) {
          _limitFired = true;
          onLimit?.call();
        }
        notifyListeners();
      });
      return VoiceStart.started;
    } catch (e) {
      debugPrint('voice record start failed: $e');
      await _teardown(deleteFile: true);
      return VoiceStart.failed;
    } finally {
      _starting = null;
    }
  }

  /// Le doigt a glissé vers le haut : on peut lâcher.
  void lock() {
    if (_state != VoiceRecState.holding) return;
    _set(VoiceRecState.locked);
  }

  Future<void> pause() async {
    if (_state != VoiceRecState.locked) return;
    try {
      await _rec.pause();
    } catch (e) {
      debugPrint('voice record pause failed: $e');
      return;
    }
    _clock.stop();
    _set(VoiceRecState.paused);
  }

  Future<void> resume() async {
    if (_state != VoiceRecState.paused) return;
    try {
      await _rec.resume();
    } catch (e) {
      debugPrint('voice record resume failed: $e');
      return;
    }
    _clock.start();
    _set(VoiceRecState.locked);
  }

  /// Arrête et supprime le fichier.
  Future<void> cancel() async {
    await _starting;
    await _teardown(deleteFile: true);
  }

  /// Arrête et rend l'enregistrement, ou `null` s'il dure moins de 1 s (le
  /// fichier est alors supprimé).
  Future<VoiceRecording?> finish() async {
    await _starting;
    if (!active) return null;
    final ms = _clock.elapsedMilliseconds;
    String? path;
    try {
      path = await _rec.stop();
    } catch (e) {
      debugPrint('voice record stop failed: $e');
    }
    path ??= _path;
    await _teardown(deleteFile: false);
    if (path == null) return null;
    try {
      if (ms < kVoiceMinMs) return null;
      // Web : `path` est l'adresse (blob:) que le navigateur donne à l'arrêt.
      final bytes = kIsWeb
          ? (await http.get(Uri.parse(path))).bodyBytes
          : await File(path).readAsBytes();
      if (bytes.isEmpty) return null;
      // Le navigateur choisit le format : Chrome écrit du WebM, Safari / iPhone du
      // MP4. On lit le vrai conteneur dans le fichier au lieu de supposer : un MP4
      // étiqueté « webm » passe sur Chrome ordinateur, mais pas sur iPhone.
      final kind = kIsWeb ? sniffAudioContainer(bytes) : null;
      return VoiceRecording(
        bytes,
        ms.clamp(kVoiceMinMs, kVoiceMaxMs),
        ext: kind?.ext ?? 'm4a',
        contentType: kind?.contentType ?? 'audio/mp4',
      );
    } catch (e) {
      debugPrint('voice record read failed: $e');
      return null;
    } finally {
      unawaited(_delete(path));
    }
  }

  Future<void> _teardown({required bool deleteFile}) async {
    _tick?.cancel();
    _tick = null;
    await _amp?.cancel();
    _amp = null;
    _clock
      ..stop()
      ..reset();
    final path = _path;
    _path = null;
    if (deleteFile) {
      try {
        await _rec.cancel();
      } catch (_) {}
      if (path != null) await _delete(path);
    }
    if (_state != VoiceRecState.idle) _set(VoiceRecState.idle);
  }

  Future<void> _delete(String path) async {
    if (kIsWeb) return; // pas de fichier : rien à supprimer
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  void _set(VoiceRecState s) {
    _state = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _amp?.cancel();
    final path = _path;
    final rec = _recorder; // jamais créé = rien à fermer
    if (rec != null) {
      unawaited(() async {
        try {
          await rec.cancel();
        } catch (_) {}
        if (path != null) await _delete(path);
        try {
          await rec.dispose();
        } catch (_) {}
      }());
    }
    super.dispose();
  }
}
