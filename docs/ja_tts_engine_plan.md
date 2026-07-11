# On-device Japanese TTS engine — implementation plan

Status: **post-launch project**. The app currently has NO on-device Japanese
voice; `ja` is absent from `tts_catalogue.dart`, so `call_screen` falls back to
the OS native voice (iOS `AVSpeechSynthesizer`). This document specifies the
dedicated engine that will replace that fallback with a controlled, on-device
Japanese voice.

## Why Japanese needs its own engine (context)

Everything else (15 languages + Korean) runs on sherpa-onnx's `OfflineTts` VITS
path — Piper/mimic3 models phonemise with espeak-ng, bundled inside each model.

Japanese is the exception. It needs a real morphological frontend
(word segmentation + kanji→reading + pitch accent) = **OpenJTalk / mecab**.
sherpa-onnx does NOT ship that: given raw Japanese it splits character by
character and crashes on kanji (`Unknown token`, `IndexError` — verified with a
CLI test of a MeloTTS-ONNX lexicon model). No sherpa-compatible Japanese voice
exists; every good Japanese model (MeloTTS, piper-plus, VOICEVOX,
Style-BERT-VITS2) depends on OpenJTalk, which sherpa lacks.

## THE non-negotiable constraint: ONE ONNX Runtime — share sherpa's ORT in C++

The app must contain **exactly one** ONNX Runtime. sherpa-onnx statically links
its own ORT into `libsherpa-onnx`. Adding a second ORT (e.g. the `onnxruntime`
Dart package we removed, or piper-plus's runtime) makes **iOS fail to link on
duplicate symbols** — this is the exact problem the whole sherpa migration
solved. Do NOT re-introduce a second runtime.

**→ The Japanese VITS `.onnx` must run on the SAME ONNX Runtime sherpa already
bundles. Do the inference in C++, sharing sherpa's ORT — not via a separate Dart
onnxruntime.**

The clean way to do this is to make sherpa itself run the model:

### Recommended architecture: patch sherpa to accept external phonemes

sherpa's VITS path already does model inference on its ORT; it only lacks a way
to accept **pre-computed** phoneme/token IDs instead of running its own
(espeak/lexicon) g2p. This is open feature request k2-fsa/sherpa-onnx#2260.

1. **Fork + patch sherpa-onnx (C++)** to add an "external tokens" entry point to
   the offline VITS TTS: a function that takes `(int64 tokens[], int64 tones[],
   sid, speed)` and runs the loaded VITS model **on sherpa's existing ORT**,
   returning PCM. Expose it through the sherpa C API and the Dart bindings
   (`OfflineTts.generateWithTokens(...)` or similar).
   - This resolves #2260 and means the melo-ja model runs on sherpa's ORT.
   - Build sherpa from source (k2-fsa documents this for iOS/Android). The app
     then depends on this custom sherpa build instead of the pub package —
     **still one ORT, one native lib.**

2. **OpenJTalk frontend as a SEPARATE native lib WITHOUT any ORT.** open_jtalk /
   mecab is pure C, no ONNX. It produces the phoneme + tone sequence that the
   melo-ja model was trained on. This lib links no runtime, so it cannot
   conflict. It only adds ~1–3 MB of native code to the binary.

3. Dart glue: `JaTtsEngine.speak(text)` → FFI call to openjtalk → tokens+tones →
   `OfflineTts.generateWithTokens(...)` (patched sherpa, sherpa's ORT) → PCM →
   same WAV+audioplayers playback as `SherpaTtsEngine`. Run it in a worker
   isolate like `SherpaTtsEngine` (generate is a blocking native call).

Net result: **two native libs (patched sherpa with its single ORT + openjtalk
with no ORT) = one ONNX Runtime total.** iOS links cleanly.

## Model + phoneme contract

- Model: MeloTTS Japanese, exported to ONNX with **BERT zeroed** (the melo export
  already does this — `bert`/`ja_bert` inputs are zeros, no BERT dependency).
  Reference export: `MiaoMint/MeloTTS-ONNX` (`onnx_exports/ja/model.onnx`, 163 MB;
  MIT license). ONNX inputs: `x` (token ids int64), `x_lengths`, `tones` (int64),
  `sid`, `noise_scale`, `length_scale`, `noise_scale_w`. Sample rate 44100.
- The OpenJTalk frontend must produce tokens+tones in the **same symbol set** the
  model expects. MeloTTS's `melo/text/japanese.py` (pyopenjtalk → phonemes/tones
  → symbol ids) is the reference to reimplement in the native frontend. Match its
  `tokens.txt` / symbol order exactly, or the model mispronounces.

## Phases (do them in order; each is a gate)

**Phase 0 — Prove the audio on desktop FIRST (cheap, do before any native work).**
Reproduce MeloTTS's Japanese g2p (pyopenjtalk) → feed `onnx_exports/ja/model.onnx`
via plain `onnxruntime` in Python → write a WAV → listen. If Japanese is
intelligible and natural, the model+g2p combo is validated and worth the native
build. If not, stop here. (This is the equivalent of the Moonshine CLI gate.)

**Phase 1 — Native OpenJTalk frontend.** Build open_jtalk + mecab for iOS (arm64)
and Android (arm64-v8a + others). Package the dictionary (unidic/naist-jdic,
~download-on-demand with the model, NOT in the binary). FFI-bind
`text → tokens[] + tones[]` in Dart. Verify it matches the Phase-0 phoneme output.

**Phase 2 — Patch + build sherpa from source** with the external-tokens VITS
entry point (see architecture above). Wire the Dart binding. Confirm the app still
links with ONE ORT on iOS.

**Phase 3 — `JaTtsEngine` + routing.** New Dart engine (mirror `SherpaTtsEngine`'s
isolate + WAV + playback). Route `ja` to it: give `tts_catalogue.dart` a ja entry
whose bundle is `{model.onnx, tokens.txt, openjtalk-dict}` re-hosted on
`djeffar` HF, and have `SpeechService`/`call_screen` pick `JaTtsEngine` for ja
instead of the OS fallback.

**Phase 4 — Device test** on a real iPhone (and Android): a fr↔ja call. Confirm
Japanese speaks correctly and in real time; if the blocking generate janks, the
isolate already covers it.

## Sizes

- App binary (ALL users): **+~1–3 MB** (openjtalk native code). The dictionary is
  NOT in the binary.
- Japanese users only (download-on-demand): model ~163 MB (or a lighter melo
  export / int8) + OpenJTalk dict ~20–25 MB compressed (~100 MB on disk) ≈
  **~100–180 MB** for the ja voice. Non-Japanese users are unaffected
  (~60 MB Piper). `pruneExcept` keeps only one voice on disk.

## Do NOT

- Do not add a second ONNX Runtime (no `onnxruntime` Dart pkg, no piper-plus
  runtime, no VOICEVOX core) — iOS duplicate-symbol.
- Do not use espeak for Japanese (sherpa's default) — it mangles kanji.
- Do not use a diffusion model (Irodori-TTS ≈ 1 GB VRAM) — crashes phones.
- Do not confuse this with `flutter_tts`: on the native build `flutter_tts` is the
  iOS `AVSpeechSynthesizer` (the current ja fallback), which is fine as a stopgap
  but is not the controlled on-device engine this document builds.
