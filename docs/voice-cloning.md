# Voice cloning — the peer hears YOUR voice

Status: **built, shipped to a device, then REMOVED from the tree.** Everything
below was run on real hardware; the dead ends are recorded so nobody re-runs
them.

It worked end to end on iOS — fingerprint captured in-call, sent over the data
channel, peer's sentences re-voiced. It came out because of **what it sounded
like on Japanese**, which is half the launch market.

An earlier version of this note blamed latency. That was wrong, and the
correction matters because it changes what would have to be true to bring the
feature back. Speed was never the blocker.

### The real reason: nothing to match the speaker's gender in Japanese

The converter extrapolates: `target' = source + 1.5*(target - source)`. The
further the base voice sits from the fingerprint, the further `alpha` pushes,
and past some distance it goes metallic. So the size of that gap decides how the
feature sounds.

Everywhere with a gendered voice pair, the gap is already small before the
converter runs: `ttsSpecForLang(lang, gender:)` picks the base voice by the
SPEAKER's account gender, so a male speaker's fingerprint lands on a male base
voice. Japanese has no pair — `tts_catalogue.dart` carries exactly one voice for
it ("~110 MB, one voice"). There is nothing for the selector to choose, so a
male French fingerprint is extrapolated onto whatever that single voice is.
Worst case for this model, and it is structural, not a tuning mistake.

### What would have to change first

**A gendered Japanese voice pair**, the same treatment the other launch
languages already got. Until then the conversion has nothing to aim at and the
rest is beside the point.

Only after that is the cost worth re-measuring. For the record, since it was
measured: on a phone the fixed-520 graph cost ~2.1 s per sentence; the
dynamic-shape export (`eb2f6d8`, validated on macOS in `18f6c30`) makes a
sentence cost its own length, which on the ~2.1 s phrases in a real call works
out near ~0.9 s. Never run on a device.

To restore: `3fb6508` (engine), `b0bd145` (wiring), `eb2f6d8` (dynamic
converter), `18f6c30` (its validation). Re-read the accelerator note in
`lib/swayco/asr/universal_asr_engine.dart` at the same time — the NPU is only
worth its slower decode when something CPU-hungry like this needs the room.

## What the feature is

The peer hears the translation **in the speaker's own voice**, not a stock TTS
voice. It is not a nicety: the product exists to create a bond between people
who share no language, and an imperfect version of the real voice does that
where a flawless stranger's voice does not.

## The architecture that works

Voice **conversion**, not voice-cloning TTS — the two problems stay separate:

```
translated text
  -> Piper / sherpa TTS  ->  correct Japanese, neutral voice   (~14 GFLOPs)
  -> OpenVoice converter ->  same speech, speaker's timbre     (33M params, 1 pass)
```

This sidesteps the hard cross-lingual problem: the base TTS is a *Japanese*
model, so the Japanese is already right; the converter only moves the timbre.
The alternative (F5-TTS cloning) must generate Japanese phonemes from a French
voice sample — 336M params x 16 diffusion passes, ~450x the compute, and it
needs a language-specific fine-tune.

## The model

**OpenVoice V2 tone-color converter** — MIT, commercial use explicit.
33M parameters. Native ja / fr / ko / es / zh / en.

Two graphs, because they run at different rates:

| | size | when it runs |
|---|---|---|
| `ref_encoder.onnx` | 3 MB | when capturing the speaker's voice |
| `converter_fp32.onnx` | 121 MB | on every sentence spoken |

Exported from `myshell-ai/OpenVoiceV2`, verified against PyTorch (embeddings
match to 1.5e-06). Fixed shape, 520 frames ≈ 6 s; shorter sentences are padded
and the tail trimmed after.

Two edits were needed to export cleanly:
- `ToneColorConverter.__init__` passes `enable_watermark` to a parent that does
  not accept it — pop it first.
- `tau=0` still emitted `RandomNormalLike` (randn multiplied by zero). Skipping
  the draw entirely removes the op; **listened to, it changes nothing** — and a
  deterministic voice is arguably better for a call.

## Settings that were chosen by ear

- **Conversion strength `alpha = 1.5`**, where `target' = base + alpha*(target - base)`.
  `tau` is NOT the strength knob — it is the noise amplitude in the posterior
  sample. Extrapolating the embedding gap is what actually exaggerates the
  timbre. 1.0 was too timid, 2.0+ starts to sound metallic.
- **Reference audio quality dominates everything.** A first sample recorded in a
  tiled bathroom gave an unconvincing result: 0 % silence, 13 % energy below
  100 Hz, noise floor only -26 dB — reverb, not noise, and the encoder baked the
  room into the fingerprint. A clean sample (4 % low end, -38 dB floor) was
  immediately better.
- **More audio helps.** Averaging two references beat one. The encoder accepts a
  list and averages, so the fingerprint can be refined mid-call as the speaker
  keeps talking — the model does not improve, the fingerprint sharpens.

## Speed — measured on Apple silicon

| | RTF |
|---|---|
| **fp32 / CPU** | **0.202** |
| fp16 / CPU | 0.226 |
| fp16 / CoreML | 0.229 |
| fp32 / CoreML | 0.296 |

**Ship fp32 on the CPU.** For reference, the same fp32 graph runs at RTF 0.49 on
an x86 desktop — Apple silicon is ~2.5x faster here, so do not size this feature
from a PC measurement.

Two things that table hides, both measured while porting the front-end to Dart:

- **The RTF above is the 4-thread figure.** The same pass is 1302 ms at 4 intra-op
  threads and 2278 ms at 2 — a 1.75x swing. Those are the Mac's four performance
  cores, and during a call the recogniser is already competing for them (see
  commit 4dbd333, "the CPU is the scarce resource"). So the number to trust for
  the product is whatever the phone gives us with STT running, not this one.
- **A short sentence pays the full pass.** The graph's input is a fixed 520
  frames ≈ 6.04 s, so a 3.7 s sentence still costs 1.3 s: effective RTF 0.37, not
  0.22. The lever, if it is ever needed, is exporting a second fixed shape (~260
  frames) and picking per sentence — not more threads.

### Dead ends, with the reason

- **int8 (dynamic quantisation): 11x SLOWER** (RTF 0.50 -> 5.46). The graph is
  196 1-D convolutions; dynamic quantisation drops them onto unoptimised
  kernels. Not a size/quality trade-off — it is simply worse.
- **CoreML / Neural Engine: slower than the CPU.** It understands 837 of 908
  nodes, but splits them into **32 partitions**; the CPU<->ANE hand-offs cost
  more than the compute saved. The culprits are 214 scattered `Slice` ops (the
  flow's channel splits) and convolutions that are *all* 1-D, where CoreML is
  built for 2-D. Fixing it means restructuring the flow — bad effort/return.
- **fp16: no gain** (0.226 vs 0.202). ONNX Runtime has no optimised fp16 CPU
  kernel here and converts internally.
- **Core ML conversion (`coremltools`)**: unnecessary. ONNX Runtime's `coreml`
  provider takes the ONNX file directly. (It also fails to convert on Windows.)

## What still blocks integration

1. **One ONNX Runtime in the app — iOS only.** On macOS sherpa already links ORT
   as a separate dylib exporting `OrtGetApiBase`, so the Dart side can be built
   and validated on a Mac today. iOS is where the static link collides, and iOS
   is what ships. Fix: build sherpa against a shared runtime via
   `SHERPA_ONNXRUNTIME_LIB_DIR` / `SHERPA_ONNXRUNTIME_INCLUDE_DIR`. The vendored
   sherpa is already built from source, so this is a build-script change, not a
   refactor.
2. ~~**A base TTS that returns samples.**~~ **Already there** — corrected after
   this was first written. `flutter_tts` indeed never hands over the audio, but
   the sherpa engine does: `neural_tts_engine.dart:121` takes a `Float32List`
   back from its worker isolate, then writes a temp WAV and plays it. The
   conversion slots in between those two steps. Small change, not a project.

   Worth noting while in there: playback goes through `audioplayers`
   (`_player.play(DeviceFileSource(...))`) — a *separate* player from the
   flutter_tts path. That is the likeliest source of the echo that got sherpa
   TTS pulled: a player that ignores the call's audio session, not the TTS model
   itself.
3. ~~**Dart wiring.**~~ **The engine is written and validated** —
   `voice_converter.dart` (+ `ort_runtime.dart`, `voice_spectrogram.dart`). It
   drives the runtime the app already ships through `dart:ffi`, so it adds no
   binary. What is left is *app* wiring, not engine work: capture the fingerprint
   from a VAD segment, send it once with the first translation (1 KB over the
   data channel), refine it as the call goes on, and convert on the receiving
   side between `neural_tts_engine.dart`'s `Float32List` and its WAV.

### How the engine is checked

`tool/voice_convert_check.dart` runs the whole chain outside the app, on the
macOS plugin's own `libonnxruntime`:

```sh
dart run tool/voice_convert_check.dart --models ~/Downloads \
  --in docs/ja_tts_phase0_samples/fp16/fp16_03_kinou_ryouri.wav [--ref voice.wav]
```

Three properties, re-checked against the **dynamic-shape** converter
(`converter.onnx`, 3 inputs, no `spec_lengths`) — the numbers below are the
dynamic graph's, and they reproduce the fixed-520 graph's to 3 decimals:

- **The front-end matches numpy** to float noise — spectrogram sum within 2e-8,
  fingerprint cosine 1.000000. Checked with `--golden`, whose JSON comes from the
  OpenVoice numpy env and is *not* in this repo; the dynamic re-export did not
  touch the front-end, and its spec sum (55749.1) and `se` norm (9.9005) are
  unchanged. This matters because the spectrogram convention
  (reflect-pad 384, centre off, periodic Hann, `sqrt(|X|² + 1e-6)`) is not
  something the graph validates: get it wrong and it returns noise, not an error.
- **Identity holds.** Converting a voice onto its *own* fingerprint gives back
  the input: log-spectral distance 0.82, RMS 0.117 → 0.106. Phase is not
  preserved (waveform correlation ~0) — that is the vocoder, and it is fine.
- **The fingerprint is a speaker, not an utterance.** Two different sentences in
  the same voice score 0.925 and convert to almost nothing (LSD 0.91, barely
  above identity); a different timbre scores 0.398 and moves the audio properly
  (LSD 1.22).

The pass now costs the sentence's own length, not a flat 6 s. On the Mac, 3.67 s
of speech (316 frames) converts in 823 ms, RTF 0.22; a 0.7 s clip (60 frames) in
202 ms. Under the old fixed-520 graph that short clip paid a full ~1.35 s pass —
the same ~6× that turns the phone's `revoiced` line from RTF ~3 into RTF < 1.

There is no cold start: the fingerprint takes ~50 ms to compute from the same
segment already being sent to the recogniser, so it is ready long before the
~2 s cloud round trip returns. The first sentence already lands in the right
voice.

## Privacy

Capturing during the call and never storing the fingerprint is the low-exposure
design: nothing persisted, nothing biometric in a database, and the audio never
leaves the phone — only an anonymous vector reaches the peer, for the duration
of the call. Keep it behind a toggle.
