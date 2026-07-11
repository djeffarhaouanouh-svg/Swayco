# sherpa_onnx_macos (patched) — dependency_override for macOS

Copy of the `sherpa_onnx_macos` 1.13.4 plugin with two swaps so the Japanese
voice works on macOS:

1. `libsherpa-onnx-c-api.dylib` rebuilt from sherpa v1.13.4 + the external-tokens
   patch (`../sherpa_ja_patch/`) → exports `SherpaOnnxOfflineTtsGenerateFromTokens`.
2. `libja_openjtalk.dylib` (`../ja_openjtalk/`) added; the podspec's
   `vendored_libraries = '*.dylib'` bundles it, so `DynamicLibrary.process()`
   resolves the `ja_frontend_*` symbols.

The `.dylib`s are git-ignored — run `setup.sh` to regenerate them from the patch
and the ja_openjtalk build. Wired via `dependency_overrides` in the app pubspec.
