import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'voice_clip_base.dart';

/// Web : la balise `<audio>` du navigateur, directement. Pas de Web Audio, pas de
/// `crossOrigin` : le fichier est lu tel quel, depuis le bucket public.
VoiceClip createVoiceClip() => _WebClip();

class _WebClip implements VoiceClip {
  _WebClip() {
    _a.preload = 'auto';
    _on('playing', () => _playing.add(true));
    _on('play', () => _playing.add(true));
    _on('pause', () => _playing.add(false));
    _on('ended', () {
      _playing.add(false);
      _completed.add(null);
    });
    _on('timeupdate', () {
      final t = _a.currentTime;
      if (t.isFinite) _position.add(Duration(milliseconds: (t * 1000).round()));
    });
    void emitDuration() {
      final d = _a.duration;
      // Un enregistrement du navigateur (MediaRecorder) n'a pas de durée dans
      // son en-tête : Infinity. On ne la donne que si elle est réelle ; la bulle
      // retombe sur `audio_duration_ms`.
      if (d.isFinite && d > 0) {
        _duration.add(Duration(milliseconds: (d * 1000).round()));
      }
    }

    _on('durationchange', emitDuration);
    _on('loadedmetadata', emitDuration);
    _on('error', () {
      final e = _a.error;
      _errors.add(
        e == null
            ? 'lecture impossible'
            : 'lecture impossible (code ${e.code}${e.message.isEmpty ? '' : ': ${e.message}'})',
      );
      _playing.add(false);
    });
  }

  final web.HTMLAudioElement _a = web.HTMLAudioElement();
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _errors = StreamController<String>.broadcast();

  void _on(String type, void Function() f) {
    _a.addEventListener(type, ((web.Event _) => f()).toJS);
  }

  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<String> get errors => _errors.stream;

  Future<void> _start() async {
    try {
      await _a.play().toDart;
    } catch (e) {
      // Le navigateur a refusé (blocage de lecture automatique, source illisible).
      _errors.add('lecture refusée : $e');
      rethrow;
    }
  }

  @override
  Future<void> play(String url) async {
    _a.src = url;
    _a.currentTime = 0;
    await _start();
  }

  @override
  Future<void> pause() async => _a.pause();

  @override
  Future<void> resume() => _start();

  @override
  Future<void> seek(Duration to) async {
    _a.currentTime = to.inMilliseconds / 1000;
  }

  @override
  Future<void> stop() async {
    _a.pause();
    _a.currentTime = 0;
  }

  @override
  Future<void> dispose() async {
    _a.pause();
    _a.removeAttribute('src');
    _a.load();
    await Future.wait([
      _playing.close(),
      _position.close(),
      _duration.close(),
      _completed.close(),
      _errors.close(),
    ]);
  }
}
