import 'dart:async';
import 'dart:typed_data';

/// Web build of [VoiceCloneService]: the feature simply does not exist here.
///
/// The real one binds the ONNX Runtime through `dart:ffi`, which the web does
/// not have. A `kIsWeb` guard at the call site is not enough — imports resolve
/// at compile time — so the web gets this no-op instead, same arrangement as
/// `tts_engines.dart`.
class VoiceCloneService {
  VoiceCloneService._();

  static final VoiceCloneService instance = VoiceCloneService._();

  bool get isReady => false;

  bool get canRevoice => false;

  Future<void> ensureLoaded() async {}

  Stream<({Uint8List bytes, int observations})> get onFingerprintReady =>
      const Stream.empty();

  void observeMyVoice(Float32List pcm, int sampleRate) {}

  void setPeerFingerprint(Uint8List bytes, {int observations = 1}) {}

  void forgetPeer() {}

  ({Float32List pcm, int sampleRate})? revoiceAsPeer(
    Float32List pcm,
    int sampleRate,
  ) =>
      null;

  void dispose() {}
}
