import 'dart:async';
import 'dart:convert';
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

  /// Context window, in tokens. The plugin defaults to 4096; one utterance plus
  /// two turns of history is a few hundred tokens, so 1024 is already generous.
  ///
  /// This is hygiene, NOT the crash fix — measured from the GGUF metadata,
  /// hunyuan-dense is GQA (head_count 16 / head_count_kv 4), so the KV cache is
  /// only 268 MB at 4096 and 67 MB here. With 440 MB of mmap'd weights that is
  /// far under an iPhone's per-app ceiling, which is what ruled memory out as
  /// the cause of the first-inference kill.
  static const int _contextSize = 1024;

  /// Prompt-ingest batch. Must not exceed [_contextSize]; the plugin's 512
  /// default already fits, but pin it so the two stay consistent if the context
  /// is ever lowered further.
  static const int _batchSize = 256;

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
      final chat = LlamaCppChatRepository.withModel(
        model,
        repo.bindings,
        contextSize: _contextSize,
        batchSize: _batchSize,
      );
      _repo = repo;
      _model = model;
      _chat = chat;
      _ready = true;
      DebugOverlay.log('translate on-device READY (hy-mt2, gpu=$_gpuLayers, '
          'ctx=$_contextSize, batch=$_batchSize)');
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
      // Breadcrumbs around the native call. The app dies INSIDE it with no crash
      // report, so these are the only instrument we have — and DebugOverlay
      // keeps its lines in memory only, so they vanish with the process. Mirror
      // them to a file that survives the kill; [lastCrashTrace] reads it back on
      // the next launch.
      await _trace('infer start (${prompt.length} chars)');
      final buf = StringBuffer();
      var chunks = 0;
      final stream = chat.streamChatWithGenerationOptions(
        'hy-mt2',
        messages: [LLMMessage(role: LLMRole.user, content: prompt)],
        // GREEDY on purpose, against Tencent's recommended 0.7/0.6/20 for the
        // dense models. That default is meant for generative use; translating a
        // spoken line is not creative work — we want the single most likely
        // rendering, and we want the SAME one every time. At 0.7 the same
        // sentence came back three different ways, drifting from the natural
        // "On se retrouve samedi ou dimanche ?" into stilted forms like
        // "Voulez-vous que nous nous rencontrions…" or the calque "Devrions-nous
        // nous rencontrer…". temp 0 + topK 1 pins it to the good one.
        //
        // Checked across both directions (fr↔ja, greetings, apologies, casual
        // register): no repetition loops, no quality loss, ~1.2 s per utterance.
        // Slang is still weak ("je suis crevé" → 私は死んでしまった) but that
        // was equally wrong at 0.7 — a model limit, not a sampling one.
        generationOptions: const GenerationOptions(
          temperature: 0.0,
          topP: 1.0,
          topK: 1,
          maxTokens: 256,
          repeatPenalty: 1.05,
        ),
      );
      await for (final chunk in stream) {
        if (chunks == 0) await _trace('first token');
        chunks++;
        buf.write(chunk.message?.content ?? '');
      }
      await _trace('done ($chunks chunks)');
      return _sanitise(buf.toString(), source: text);
    } catch (e) {
      DebugOverlay.log('translate on-device error: $e');
      return '';
    }
  }

  /// Last line of defence between the model and the peer's loudspeaker.
  ///
  /// The prompt tells the model to output the translation and nothing else, and
  /// it usually obeys — but "usually" is not good enough when the failure mode
  /// is the TTS reading our own instructions out loud. Observed twice on
  /// device: a Japanese line came back prefixed "日本語訳：", and once the model
  /// returned the ENTIRE prompt translated into French ("Contexte : préservez
  /// le sens exact… Premiers passages de la conversation…"), which the peer's
  /// phone dutifully spoke for fifteen seconds.
  ///
  /// A prompt can be ignored; this cannot. Returns '' to DROP the utterance —
  /// the caller already treats an empty translation as "say nothing", and
  /// silence is far better than confidently speaking our own scaffolding.
  String _sanitise(String raw, {required String source}) {
    var out = raw.trim();
    if (out.isEmpty) return '';

    // 1. The prompt came back at us. These anchors are our own wording, and
    //    none of them can legitimately appear in the translation of a spoken
    //    line. Checked case-insensitively; the leak we saw was translated, so
    //    also catch the shape rather than only the English.
    const anchors = [
      'translate the following text into',
      'without any additional explanation',
      'context: sound natural',
      'sound natural, not word-for-word',
    ];
    final low = out.toLowerCase();
    for (final a in anchors) {
      if (low.contains(a)) {
        DebugOverlay.log('translate DROPPED: prompt echoed back');
        return '';
      }
    }

    // 2. A spoken utterance translates to ONE line. Our prompt is the only
    //    multi-line thing in the request, so several lines coming back means we
    //    are looking at a translated copy of it (that is exactly how the
    //    fifteen-second incident looked) — not at someone's sentence.
    if (!source.contains('\n') && '\n'.allMatches(out).length >= 2) {
      DebugOverlay.log('translate DROPPED: multi-line output for a one-line utterance');
      return '';
    }

    // 3. A label glued in front: "日本語訳：…", "Translation: …", "Traduction : …".
    //    Only strip a SHORT leading fragment that ends in a colon, so a real
    //    sentence that happens to contain one ("Il a dit : viens") survives.
    final label = RegExp(r'^[^\n:：]{0,24}[:：]\s*');
    final m = label.firstMatch(out);
    if (m != null) {
      final rest = out.substring(m.end).trim();
      // Keep the strip only if it leaves a real sentence behind.
      if (rest.isNotEmpty) out = rest;
    }

    // 4. Wrapping quotes the model sometimes adds around the whole line.
    out = out.replaceAll(RegExp(r'^[“”"«»\x27]+|[“”"«»\x27]+$'), '').trim();
    return out;
  }

  /// Build Hy-MT2's instruction. The model has NO system prompt: gender,
  /// history and the target language all go into the one user turn.
  ///
  /// Written TELEGRAPHIC on purpose. Prompt ingestion is the bulk of the
  /// latency on the phone — measured on device, 334 chars took 2.53 s to the
  /// first token and 505 chars took 5.13 s, i.e. ~15 ms per character — so
  /// every clause is paid on every single utterance. Compressing the context
  /// and the history (108 -> 75 tokens) cut ~2 s per phrase with byte-identical
  /// output on the fr/ja battery.
  ///
  /// What is NOT compressed: the closing "Note that you should only output the
  /// translated result without any additional explanation". It is Hy-MT2's
  /// canonical wording and it earns its 5 tokens — shortened to "Output only
  /// the translation:" the model prefixed a label ("日本語訳：…") that the peer's
  /// TTS then read out loud.
  ///
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
    // Always first: keep the meaning intact and phrase it the way a native
    // speaker of the TARGET language actually talks. Without this the model
    // renders word-for-word and the peer hears a stilted, translated-sounding
    // line instead of natural speech.
    ctx.add('sound natural, not word-for-word');
    final ag = _genderPhrase(authorGender, 'speaker');
    if (ag != null) ctx.add(ag);
    final pg = _genderPhrase(peerGender, 'listener');
    if (pg != null) ctx.add(pg);
    // [speech] deliberately adds nothing to the prompt. It used to append
    // "this is a rough voice transcription — correct an obvious mis-hearing and
    // translate the intended meaning", which measured as pure cost: fed a
    // degraded transcript (こんにちは、パリのよそうはいかがすか) Hy-MT2 returned
    // the same "Bonjour, comment allez-vous à Paris ?" with or without it, and
    // it is ~110 characters the CPU has to ingest on every utterance. Prompt
    // eval is the bulk of the latency here — 85 tokens took 1076 ms where 30
    // took 420 ms — so anything that does not change the output is worth
    // dropping. The flag stays in the signature: the cloud path still uses it,
    // and it marks the call site as speech for whatever we do next.
    if (ctx.isNotEmpty) lines.add('Context: ${ctx.join('. ')}.');

    if (history != null && history.isNotEmpty) {
      lines.add('Earlier:');
      for (final h in history) {
        lines.add('${h.author == 'peer' ? 'them' : 'me'}: ${h.text}');
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
        return '$subject: man';
      case 'f':
        return '$subject: woman';
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

  /// Write a breadcrumb to BOTH the in-app overlay and a file, then flush.
  ///
  /// The overlay alone is not enough: it holds its lines in memory, so when the
  /// process is killed mid-inference every line dies with it and the user sees
  /// "nothing". The file is flushed on each write, so whatever was reached
  /// before the kill is still on disk at the next launch — read it with
  /// [lastCrashTrace]. Never throws: a failing breadcrumb must not break a call.
  Future<void> _trace(String msg) async {
    DebugOverlay.log('translate: $msg');
    try {
      final f = File('${(await getApplicationSupportDirectory()).path}'
          '/translate/trace.log');
      await f.parent.create(recursive: true);
      await f.writeAsString(
        '${DateTime.now().toIso8601String()} $msg\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Diagnostics must never take the call down with them.
    }
  }

  /// The breadcrumbs left by the run that died, oldest first — empty when the
  /// last run exited cleanly or never wrote any. Surface this after a crash to
  /// see how far inference got.
  static Future<List<String>> lastCrashTrace() async {
    try {
      final f = File('${(await getApplicationSupportDirectory()).path}'
          '/translate/trace.log');
      if (!f.existsSync()) return const [];
      return const LineSplitter().convert(await f.readAsString());
    } catch (_) {
      return const [];
    }
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
