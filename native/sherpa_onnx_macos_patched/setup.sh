#!/usr/bin/env bash
# Regenerate the patched macOS dylibs for this override.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$HERE/../.."

# 1) stock ORT + cxx-api come straight from the pub-cache plugin
PUB=$(find "$HOME/.pub-cache/hosted/pub.dev" -maxdepth 1 -name "sherpa_onnx_macos-*" | head -1)
cp "$PUB/macos/libonnxruntime."*.dylib "$HERE/macos/"
cp "$PUB/macos/libsherpa-onnx-cxx-api.dylib" "$HERE/macos/"

# 2) patched c-api: clone sherpa v1.13.4, apply patch, build (see sherpa_ja_patch)
WORK="${SHERPA_SRC:-/tmp/sherpa-onnx-patched}"
if [ ! -d "$WORK" ]; then
  git clone --depth 1 --branch v1.13.4 https://github.com/k2-fsa/sherpa-onnx "$WORK"
  git -C "$WORK" apply "$REPO/native/sherpa_ja_patch/external-tokens-v1.13.4.patch"
fi
cmake -S "$WORK" -B "$WORK/build" -DBUILD_SHARED_LIBS=ON -DSHERPA_ONNX_ENABLE_TTS=ON \
  -DSHERPA_ONNX_ENABLE_C_API=ON -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
  -DSHERPA_ONNX_ENABLE_TESTS=OFF -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
  -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF -DSHERPA_ONNX_ENABLE_BINARY=OFF
cmake --build "$WORK/build" --target sherpa-onnx-c-api -j6
cp "$WORK/build/lib/libsherpa-onnx-c-api.dylib" "$HERE/macos/"

# 3) OpenJTalk reading lib
( cd "$REPO/native/ja_openjtalk" && bash build_macos.sh )
cp "$REPO/native/ja_openjtalk/build/macos/libja_openjtalk.dylib" "$HERE/macos/"
echo "done: $(ls "$HERE/macos/"*.dylib | wc -l) dylibs"
