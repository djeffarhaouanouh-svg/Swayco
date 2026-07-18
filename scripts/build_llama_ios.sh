#!/usr/bin/env bash
# Cross-compile llama.cpp (+ Metal) for arm64 iOS WITH Tencent's STQ1_0 ternary
# kernel, and drop the static libs into native/llm_llamacpp_patched/ios/libs/.
#
# Why from source and not the plugin's prebuilt GitHub release: the on-device
# translator runs AngelSlim's 1.25-bit Hy-MT2 GGUF (440 MB), whose weights are
# STQ1_0. That quant needs Tencent's STQ kernel — llama.cpp PR #22836, still
# OPEN — which the stock prebuilt does not carry (it would fail to load the
# file). The fork below is the PR branch.
#
# The plugin's iOS Dart path resolves symbols via DynamicLibrary.process(), so
# these are STATIC libs force-loaded into the app binary by
# native/llm_llamacpp_patched/ios/llm_llamacpp.podspec (which also keeps the API
# symbols with -Wl,-u roots from ios/llama_symbols.txt). Same shape as libvosk.
#
#   ./scripts/build_llama_ios.sh
#
# Needs CMake + Xcode. The libs (~8 MB) are git-ignored; run once after a clone.
# NOTE: STQ1_0 ships only a CPU ARM-NEON kernel — there is no Metal path for the
# ternary weights, so ondevice_translator.dart runs with nGpuLayers = 0.

set -euo pipefail

FORK="https://github.com/sjl623/llama.cpp"
BRANCH="STQ_0"                        # PR #22836 — ggml-cpu STQ1_0 kernel
IOS_MIN="15.0"

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
DEST="$REPO_ROOT/native/llm_llamacpp_patched/ios/libs"
WORK="$REPO_ROOT/build/llama-ios"
SRC="$WORK/llama.cpp"
BUILD="$WORK/build"

CMAKE="$(command -v cmake || true)"
[ -n "$CMAKE" ] || { echo "ERROR: cmake not found (brew install cmake, or use a portable build)" >&2; exit 1; }

mkdir -p "$WORK"
if [ ! -d "$SRC/.git" ]; then
  echo "==> cloning $FORK ($BRANCH)"
  git clone --depth 1 -b "$BRANCH" "$FORK" "$SRC"
fi

echo "==> configure (iOS arm64, Metal embedded, static)"
"$CMAKE" -S "$SRC" -B "$BUILD" -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_ACCELERATE=ON -DGGML_BLAS=OFF \
  -DLLAMA_CURL=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF

# Build only `llama`; it pulls the ggml libs (incl. Metal) as deps. The fork's
# extra `app/` target is broken (missing build-info.h) and unneeded — do NOT
# build all targets.
echo "==> build target llama"
"$CMAKE" --build "$BUILD" --config Release --target llama -j"$(sysctl -n hw.ncpu)"

mkdir -p "$DEST"
rm -f "$DEST"/*.a
found=0
for lib in libllama libggml libggml-base libggml-cpu libggml-metal; do
  a="$(find "$BUILD" -name "$lib.a" | head -1)"
  [ -n "$a" ] || { echo "ERROR: $lib.a not produced" >&2; exit 1; }
  cp "$a" "$DEST/"; found=$((found + 1))
done
echo "==> installed $found libs into $DEST"

# Sanity: the STQ1_0 kernel and the llama C API must be present, or the 440 MB
# model won't load / the app won't link.
CPU="$DEST/libggml-cpu.a"
nm "$CPU" 2>/dev/null | grep -q "stq1_0" \
  || { echo "ERROR: STQ1_0 kernel missing from libggml-cpu.a" >&2; exit 1; }
echo "==> STQ1_0 kernel present. arch: $(lipo -archs "$DEST/libllama.a")"
echo "==> done."
