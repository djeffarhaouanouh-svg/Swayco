# sherpa_onnx_ios (patched) — dependency_override for iOS

Copy of `sherpa_onnx_ios` 1.13.4 vendoring two extra/replaced frameworks:
1. `sherpa_onnx.xcframework` rebuilt from sherpa v1.13.4 + **two** patches, both
   `git apply`'d into the sherpa checkout before `build-ios-shared.sh`:
   - `../sherpa_ja_patch/external-tokens-v1.13.4.patch` — exports
     `SherpaOnnxOfflineTtsGenerateFromTokens` (Japanese TTS).
   - `../sherpa_whisper_patch/byte-fallback-utf8-v1.13.4.patch` — STT UTF-8 fix
     (stops ja/zh/ko/hi characters being dropped; see that dir's README).
   Dynamic framework (device + sim).
2. `ja_openjtalk.xcframework` — the OpenJTalk reading lib (`../ja_openjtalk/`)
   as a dynamic framework so `ja_frontend_*` are not dead-stripped and resolve
   via `DynamicLibrary.process()`.

The `.xcframework`s are git-ignored — run `setup.sh` to regenerate. Wired via
`dependency_overrides` in the app pubspec. Currently device arm64 + simulator;
Android is the remaining slice (build-android + NDK cross-compile of ja_openjtalk).
