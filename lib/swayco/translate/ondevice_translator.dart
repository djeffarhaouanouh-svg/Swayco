import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:llm_llamacpp/llm_llamacpp.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/debug_overlay.dart';
import '../../services/translation_api.dart' show TranslationHistoryItem;

/// On-device call translation with Tencent **Hy-MT2** (GGUF) on llama.cpp,
/// via the MIT-licensed `llm_llamacpp` plugin. Drop-in replacement for the
/// cloud `fetchTextTranslation` → `/translation/text` call in the native call
/// pipeline: same inputs (text, gender, 2-turn history, speech flag), same
/// output (the translated string).
///
/// The model is a SINGLE multilingual GGUF that covers all of Hy-MT2's 33
/// languages, so a device downloads it once regardless of the call's language
/// pair — unlike the per-language STT models.
///
/// It is loaded ONCE and kept resident (the singleton outlives a call, like
/// [AsrService] caches its recogniser): loading takes seconds, inference does
/// not, so the model must not be reloaded per utterance.
///
/// This is a SECOND native runtime (ggml) alongside sherpa_onnx — a different
/// engine, so no ONNX duplicate-symbol clash, but the iOS link/size still has
/// to be validated on the Mac build.
class OnDeviceTranslator {
  OnDeviceTranslator._();
  static final OnDeviceTranslator instance = OnDeviceTranslator._();

  /// Our own model mirror — same repo the STT models come from (the GGUF must
  /// be uploaded under `translate/`). It is AngelSlim's 1.25-bit STQ quant
  /// (440 MB), which only loads with Tencent's STQ1_0 ternary kernel —
  /// llama.cpp PR #22836 (`sjl623/llama.cpp`, branch `STQ_0`, not merged). The
  /// native libs the app links are built from that fork: iOS static libs via
  /// scripts/build_llama_ios.sh, Android arm64 .so via
  /// scripts/build_llama_android.sh (jniLibs). The plugin's stock prebuilt does
  /// NOT carry the kernel and rejects this file ("tensor offset mismatch").
  static const String _modelUrl =
      'https://huggingface.co/djeffar/swayco-stt-models/resolve/main/translate/hy-mt2-1.8b-1.25bit.gguf';

  /// On-disk name under `<appSupport>/translate/`. Bumping it is what makes a
  /// phone fetch new weights (the "is it installed?" check keys on this).
  static const String _modelFile = 'hy-mt2-1.8b-1.25bit.gguf';

  /// STQ1_0 ships ONLY a CPU ARM-NEON vec_dot kernel (PR #22836) — there is no
  /// Metal path for the ternary weights, so offloading them to the GPU is not
  /// possible. Keep inference on the CPU (NEON), which is what the quant is
  /// designed for; iPhone's ARM cores run it. Revisit if a Metal STQ kernel
  /// lands. (Was 99 = all-GPU for the Q4_K_M quant.)
  static const int _gpuLayers = 0;

  LlamaCppRepository? _repo;
  LlamaCppModel? _model;
  LlamaCppChatRepository? _chat;

  /// Set once the model is loaded and ready to translate. While false, every
  /// [translate] returns '' so the caller drops the utterance (a call must
  /// never crash or hang on a model still downloading).
  bool _ready = false;
  bool get isReady => _ready;

  /// Guards against two concurrent loads (call restart on a language change).
  Future<void>? _loading;

  /// Download the model if missing, then load it resident. Idempotent and
  /// safe to call unawaited from the streamer's `start()` — the first call in a
  /// call kicks it off; later ones join the same future.
  Future<void> ensureLoaded() {
    if (_ready) return Future.value();
    return _loading ??= _load()
      ..whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    try {
      final path = await _ensureModelFile();
      final repo = LlamaCppRepository();
      final model = await repo.loadModel(
        path,
        options: const ModelLoadOptions(nGpuLayers: _gpuLayers),
      );
      final chat = LlamaCppChatRepository.withModel(model, repo.bindings);
      _repo = repo;
      _model = model;
      _chat = chat;
      _ready = true;
      DebugOverlay.log('translate on-device READY (hy-mt2, gpu=$_gpuLayers)');
    } catch (e) {
      _ready = false;
      DebugOverlay.log('translate on-device LOAD FAILED: $e');
    }
  }

  /// Translate one utterance. Mirrors `fetchTextTranslation`: [from]/[to] are
  /// the app's language codes, [history] the last 2 turns (both sides, original
  /// text), [authorGender]/[peerGender] are `m`/`f`/`x`, and [speech] marks a
  /// raw STT transcript so the model repairs an obvious mis-hearing from context
  /// rather than rendering it literally.
  ///
  /// Returns '' when the model is not ready or on any error — the caller drops
  /// an empty translation, exactly as it already does for the cloud path.
  Future<String> translate({
    required String text,
    required String to,
    String? from,
    List<TranslationHistoryItem>? history,
    String? authorGender,
    String? peerGender,
    bool speech = false,
  }) async {
    final chat = _chat;
    if (!_ready || chat == null || text.trim().isEmpty) return '';
    try {
      final prompt = _buildPrompt(
        text: text,
        to: to,
        history: history,
        authorGender: authorGender,
        peerGender: peerGender,
        speech: speech,
      );
      final buf = StringBuffer();
      final stream = chat.streamChatWithGenerationOptions(
        'hy-mt2',
        messages: [LLMMessage(role: LLMRole.user, content: prompt)],
        // Hy-MT2's recommended sampling for the 1.8B/7B dense models.
        generationOptions: const GenerationOptions(
          temperature: 0.7,
          topP: 0.6,
          topK: 20,
          maxTokens: 256,
          repeatPenalty: 1.05,
        ),
      );
      await for (final chunk in stream) {
        buf.write(chunk.message?.content ?? '');
      }
      return buf.toString().trim();
    } catch (e) {
      DebugOverlay.log('translate on-device error: $e');
      return '';
    }
  }

  /// Build Hy-MT2's instruction. The model has NO system prompt: gender,
  /// history and the speech-repair note all go into the one user turn, ahead of
  /// the fixed "Translate ... only output the result" instruction.
  String _buildPrompt({
    required String text,
    required String to,
    List<TranslationHistoryItem>? history,
    String? authorGender,
    String? peerGender,
    bool speech = false,
  }) {
    final lines = <String>[];

    final ctx = <String>[];
    final ag = _genderPhrase(authorGender, 'the speaker');
    if (ag != null) ctx.add(ag);
    final pg = _genderPhrase(peerGender, 'the person being spoken to');
    if (pg != null) ctx.add(pg);
    if (speech) {
      ctx.add('this is a rough voice transcription — correct an obvious '
          'mis-hearing and translate the intended meaning');
    }
    if (ctx.isNotEmpty) lines.add('Context: ${ctx.join('. ')}.');

    if (history != null && history.isNotEmpty) {
      lines.add('Earlier turns of the conversation (original text), for context:');
      for (final h in history) {
        final who = h.author == 'peer' ? 'other person' : 'speaker';
        lines.add('- ($who) ${h.text}');
      }
    }

    lines.add('Translate the following text into ${_langName(to)}. Note that '
        'you should only output the translated result without any additional '
        'explanation:');
    lines.add('');
    lines.add(text);
    return lines.join('\n');
  }

  /// "the speaker is a man/woman", or null for unknown / non-binary (`x`),
  /// where forcing a grammatical gender would be wrong.
  String? _genderPhrase(String? g, String subject) {
    switch (g?.trim().toLowerCase()) {
      case 'm':
        return '$subject is a man';
      case 'f':
        return '$subject is a woman';
      default:
        return null;
    }
  }

  /// Hy-MT2 wants full English language NAMES, not codes. Covers the app's
  /// supported languages; falls back to the raw code so an unmapped language
  /// still translates (the model auto-detects the source anyway).
  String _langName(String code) {
    final c = code.toLowerCase().split(RegExp(r'[-_]')).first;
    return const {
      'en': 'English', 'fr': 'French', 'es': 'Spanish', 'pt': 'Portuguese',
      'de': 'German', 'it': 'Italian', 'nl': 'Dutch', 'ru': 'Russian',
      'uk': 'Ukrainian', 'pl': 'Polish', 'cs': 'Czech', 'ja': 'Japanese',
      'ko': 'Korean', 'zh': 'Chinese', 'ar': 'Arabic', 'he': 'Hebrew',
      'fa': 'Persian', 'hi': 'Hindi', 'ur': 'Urdu', 'bn': 'Bengali',
      'ta': 'Tamil', 'te': 'Telugu', 'mr': 'Marathi', 'gu': 'Gujarati',
      'th': 'Thai', 'vi': 'Vietnamese', 'id': 'Indonesian', 'ms': 'Malay',
      'fil': 'Filipino', 'tl': 'Filipino', 'km': 'Khmer', 'my': 'Burmese',
      'tr': 'Turkish',
    }[c] ??
        code;
  }

  /// Ensure the GGUF is on disk, downloading it once if missing. Returns the
  /// absolute path. Same on-demand pattern as the STT model downloader.
  Future<String> _ensureModelFile() async {
    final dir = Directory(
        '${(await getApplicationSupportDirectory()).path}/translate');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/$_modelFile');
    if (file.existsSync() && file.lengthSync() > 0) return file.path;

    DebugOverlay.log('translate model: downloading $_modelFile …');
    // STREAM to disk — a plain http.get() buffers the whole 440 MB in RAM
    // (res.bodyBytes) before writing, which OOM-crashes the phone. Pipe the
    // response straight into a `.part` file, then rename: an interrupted
    // download leaves no final file, so it re-downloads instead of loading a
    // truncated model.
    final tmp = File('${file.path}.part');
    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(_modelUrl)));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('model download HTTP ${resp.statusCode}');
      }
      final sink = tmp.openWrite();
      try {
        await resp.stream.pipe(sink);
      } finally {
        await sink.close();
      }
      await tmp.rename(file.path);
    } catch (e) {
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {}
      }
      rethrow;
    } finally {
      client.close();
    }
    DebugOverlay.log('translate model: downloaded '
        '${(file.lengthSync() / 1e6).round()} MB');
    return file.path;
  }

  /// Free the native model. Not called on a normal call end (the model is kept
  /// resident for the next call, like the STT recogniser); reserved for a hard
  /// teardown.
  void release() {
    try {
      _chat?.dispose();
      final p = _model?.path;
      if (p != null) _repo?.unloadModel(p, force: true);
      _repo?.dispose();
    } catch (_) {}
    _chat = null;
    _model = null;
    _repo = null;
    _ready = false;
  }
}
