# sherpa-onnx external-tokens patch (Japanese TTS)

Adds `SherpaOnnxOfflineTtsGenerateFromTokens(...)` to sherpa-onnx **v1.13.4** so
the ja MeloTTS-ONNX model runs on **sherpa's single ONNX Runtime** from
pre-computed token/tone ids — bypassing sherpa's text frontend, which cannot
phonemise Japanese (it char-splits kanji). Resolves the need behind k2-fsa#2260.

This keeps the app's **one-ORT** invariant (see `docs/ja_tts_engine_plan.md`):
no second runtime, no iOS duplicate-symbol link failure.

## The patch (`external-tokens-v1.13.4.patch`, 6 files, ~100 lines)
- `offline-tts-impl.h` — virtual `GenerateFromTokens(tokens, tones, sid, speed)`
  (default: unsupported).
- `offline-tts-vits-impl.h` — override: wraps the ids as a batch of 1 and calls
  the existing private `Process(...)` (which builds the `x`/`tones` tensors and
  runs the VITS model). No g2p, no AddBlank — the caller (Dart phonemizer)
  already produced final, blank-interleaved ids.
- `offline-tts.{h,cc}` — public passthrough.
- `c-api.{h,cc}` — `SherpaOnnxOfflineTtsGenerateFromTokens(tts, tokens, n_tokens,
  tones, n_tones, sid, speed)` (+ TTS-disabled stub).
- `sherpa-onnx-symbols-c.exp` — export the new symbol on macOS/iOS (the Linux/
  Android `.lds` already matches via the `SherpaOnnx*` wildcard).

## Verified (macOS, this repo's fp16 model)
Built `libsherpa-onnx-c-api.dylib` from patched source; `test_from_tokens.c`
loads `model.fp16.onnx` + `tokens.txt`, feeds the Dart-phonemizer token/tone
arrays, and synthesises correct audio on sherpa's ORT.

## Apply + build
```sh
git clone --branch v1.13.4 https://github.com/k2-fsa/sherpa-onnx
cd sherpa-onnx && git apply .../external-tokens-v1.13.4.patch
# macOS dev (used for verification):
cmake -S . -B build -DBUILD_SHARED_LIBS=ON -DSHERPA_ONNX_ENABLE_TTS=ON \
  -DSHERPA_ONNX_ENABLE_C_API=ON -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
  -DSHERPA_ONNX_ENABLE_TESTS=OFF -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
  -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF -DSHERPA_ONNX_ENABLE_BINARY=OFF
cmake --build build --target sherpa-onnx-c-api -j6
```
For the app: build the patched source with sherpa's `build-ios.sh` /
`build-android-arm64-v8a.sh` and swap the resulting framework/.so into the
`sherpa_onnx_ios` / `sherpa_onnx_macos` / `sherpa_onnx_android` plugin (or vendor
it directly). Then FFI the new symbol from Dart (M3).

## Dart side
`GenerateFromTokens` will be called via `dart:ffi` from `JaTtsEngine` (M3),
alongside the OpenJTalk reading (`ja_openjtalk_ffi.dart`) and the phonemizer
(`ja_phonemizer.dart`).
