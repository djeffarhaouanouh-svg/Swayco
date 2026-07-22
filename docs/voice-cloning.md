# Voice cloning — the peer hears YOUR voice

Status: **explored and measured, not integrated.** Everything below was run on
real hardware; the dead ends are recorded so nobody re-runs them.

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

1. **One ONNX Runtime in the app.** sherpa statically links its own; a second one
   breaks the iOS link (already hit once). Fix: build sherpa against a shared
   runtime via `SHERPA_ONNXRUNTIME_LIB_DIR` / `SHERPA_ONNXRUNTIME_INCLUDE_DIR`.
   The vendored sherpa is already built from source, so this is a build-script
   change, not a refactor.
2. **A base TTS that returns samples.** `flutter_tts` synthesises *and* plays —
   it never hands over the audio, so nothing can be converted. sherpa's
   `OfflineTts` returns the samples. Playback can stay exactly as it is today,
   which means the half-duplex gate and the mute rule are unaffected — and the
   echo problem that got sherpa TTS removed may well have come from its own
   player rather than from on-device TTS as such.
3. **Dart wiring**: capture the fingerprint from a VAD segment, send it once with
   the first translation (~1.7 KB over the data channel), refine it as the call
   goes on, and convert on the receiving side before playback.

There is no cold start: the fingerprint takes ~50 ms to compute from the same
segment already being sent to the recogniser, so it is ready long before the
~2 s cloud round trip returns. The first sentence already lands in the right
voice.

## Privacy

Capturing during the call and never storing the fingerprint is the low-exposure
design: nothing persisted, nothing biometric in a database, and the audio never
leaves the phone — only an anonymous vector reaches the peer, for the duration
of the call. Keep it behind a toggle.
