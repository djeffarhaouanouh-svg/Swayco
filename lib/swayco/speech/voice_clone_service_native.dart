import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/debug_overlay.dart';
import 'voice_converter.dart';
import 'voice_model_downloader.dart';

/// Makes the peer hear the translation in the SPEAKER's own voice.
///
/// The engine ([VoiceConverter]) is validated separately; this is the part that
/// knows about a call. Two fingerprints, and they are not symmetric:
///
///   * **mine** — built from my own VAD segments and published to the peer, so
///     THEY can re-voice what they play. Refined as I keep talking.
///   * **theirs** — received from the peer and used HERE, because the sentence
///     my phone is about to speak is the peer's.
///
/// Everything degrades to silence-of-the-feature: if the models are absent, the
/// runtime will not open, or a conversion throws, the call behaves exactly as it
/// does today. This must never be the reason a call breaks — it is a garnish on
/// a pipeline that already works.
class VoiceCloneService {
  VoiceCloneService._();

  static final VoiceCloneService instance = VoiceCloneService._();

  /// Where the two graphs live, next to the STT and TTS bundles.
  static const String _dirName = 'voice';
  static const String _encoderFile = 'ref_encoder.onnx';
  static const String _converterFile = 'converter.onnx';

  /// A VAD segment shorter than this says nothing about a timbre — it is a
  /// "oui", a breath, a click. Fingerprinting it drags the average around for
  /// nothing.
  static const int _minObserveMs = 700;

  /// Stop fingerprinting once the average has this many segments in it.
  ///
  /// An average of eight VAD segments is already ~15-20 s of speech, which is
  /// where the fingerprint stops moving audibly. Past that we would be spending
  /// ~50 ms of blocking FFI per phrase, for the rest of the call, to change
  /// nothing. The cost is therefore bounded to the opening of a call.
  static const int _maxObservations = 8;

  VoiceConverter? _conv;
  bool _tried = false;

  VoiceFingerprint? _mine;
  VoiceFingerprint? _peer;

  /// Observation count at the last publish. The fingerprint is an average, so it
  /// improves fastest early: publishing on every segment would spend the data
  /// channel to move it by nothing. Doubling is the natural cadence.
  int _publishedAt = 0;

  bool get isReady => _conv != null;

  /// True once the peer has sent theirs — i.e. we can re-voice what we play.
  bool get canRevoice => _conv != null && _peer != null;

  /// Load the graphs if they are on disk. Safe to call repeatedly; a failure is
  /// remembered so a broken install does not retry on every utterance.
  Future<void> ensureLoaded() async {
    if (_tried || kIsWeb) return;
    _tried = true;
    try {
      // Deferred download, best-effort: if it does not land, the call runs with
      // the stock voice, never blocks on it.
      if (!await VoiceModelDownloader.ensure()) {
        DebugOverlay.log('voice: models not available, feature off');
        return;
      }
      final root = await getApplicationSupportDirectory();
      final dir = Directory('${root.path}/$_dirName');
      final enc = File('${dir.path}/$_encoderFile');
      final cnv = File('${dir.path}/$_converterFile');
      if (!enc.existsSync() || !cnv.existsSync()) {
        DebugOverlay.log('voice: models absent, feature off');
        return;
      }
      _conv = VoiceConverter.open(
        refEncoderPath: enc.path,
        converterPath: cnv.path,
        // Two, not four. The recogniser is already the scarce consumer of the
        // performance cores during a call (commit 4dbd333) — taking four here
        // wins the benchmark and loses the call.
        numThreads: 2,
      );
      DebugOverlay.log('voice: converter ready');
    } catch (e) {
      _conv = null;
      DebugOverlay.log('voice: converter unavailable ($e)');
    }
  }

  final _toPublish =
      StreamController<({Uint8List bytes, int observations})>.broadcast();

  /// Fires when my fingerprint is worth sending to the peer. The call screen
  /// owns the data channel, so it listens here rather than the streamer growing
  /// a transport dependency.
  Stream<({Uint8List bytes, int observations})> get onFingerprintReady =>
      _toPublish.stream;

  /// Feed one VAD segment of MY voice. Fire-and-forget.
  ///
  /// Cheap enough to call on every segment: ~50 ms of encoder, against the ~2 s
  /// cloud round trip the same segment is already waiting on.
  void observeMyVoice(Float32List pcm, int sampleRate) {
    final c = _conv;
    if (c == null) return;
    if ((_mine?.observations ?? 0) >= _maxObservations) return;
    if (pcm.length * 1000 ~/ sampleRate < _minObserveMs) return;
    try {
      final fp = c.fingerprint(pcm, sampleRate: sampleRate);
      final merged = _mine == null ? fp : _mine!.merge(fp);
      _mine = merged;
      // First one goes immediately — the peer is otherwise stuck with a stock
      // voice for the whole opening of the call. After that, only when the
      // average has had a real chance to move.
      if (_publishedAt == 0 || merged.observations >= _publishedAt * 2) {
        _publishedAt = merged.observations;
        _toPublish.add(
            (bytes: merged.toBytes(), observations: merged.observations));
      }
    } catch (e) {
      DebugOverlay.log('voice: fingerprint failed ($e)');
    }
  }

  /// Store the peer's fingerprint, received over the data channel.
  void setPeerFingerprint(Uint8List bytes, {int observations = 1}) {
    try {
      _peer = VoiceFingerprint.fromBytes(bytes, observations: observations);
      DebugOverlay.log('voice: peer fingerprint ($observations obs)');
    } catch (e) {
      DebugOverlay.log('voice: bad peer fingerprint ($e)');
    }
  }

  void forgetPeer() {
    _peer = null;
  }

  /// Re-voice TTS output as the peer, for playback on this phone.
  ///
  /// Returns null when the feature is not available, which the caller must read
  /// as "play what you already had" — never as an error.
  ({Float32List pcm, int sampleRate})? revoiceAsPeer(
    Float32List pcm,
    int sampleRate,
  ) {
    final c = _conv;
    final target = _peer;
    if (c == null || target == null || pcm.isEmpty) return null;
    try {
      final sw = Stopwatch()..start();
      // `source` left null on purpose: it is derived from this very audio, so a
      // change of TTS voice (language switch, gendered pair) needs no bookkeeping
      // here. Costs one extra encoder pass, which is the cheap graph.
      final out = c.convert(pcm: pcm, sampleRate: sampleRate, target: target);
      if (out.isEmpty) return null;
      final ms = out.length * 1000 ~/ c.outputSampleRate;
      DebugOverlay.log(
          'voice: revoiced ${ms}ms in ${sw.elapsedMilliseconds}ms');
      return (pcm: out, sampleRate: c.outputSampleRate);
    } catch (e) {
      DebugOverlay.log('voice: convert failed ($e)');
      return null;
    }
  }

  void dispose() {
    unawaited(_toPublish.close());
    _conv?.dispose();
    _conv = null;
    _mine = null;
    _peer = null;
    _publishedAt = 0;
    _tried = false;
  }
}
