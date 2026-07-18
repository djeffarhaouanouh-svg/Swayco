#!/usr/bin/env bash
# Build the STQ-fork llama.cpp shared libs for Android arm64-v8a and drop them
# into the vendored plugin's jniLibs. Run ONCE after a fresh clone (the .so are
# git-ignored, ~52 MB unstripped). Mirrors scripts/fetch_llama_ios.sh, but the
# STQ kernel isn't in any prebuilt release, so we build from source.
#
# Why the STQ fork and not the plugin's stock llama.cpp: the on-device model is
# Tencent Hy-MT2 1.8B in the 1.25-bit "STQ1_0" quantisation (440 MB). Only the
# STQ1_0 kernel (llama.cpp PR #22836, not yet merged) can load it; stock
# llama.cpp rejects the file with a tensor-offset mismatch.
#
# Requires: Android NDK + CMake + Ninja (Android Studio bundles all three).
#   ANDROID_NDK_HOME  — NDK dir      (else auto-detected under $ANDROID_SDK/ndk)
#   CMAKE_BIN_DIR     — cmake+ninja  (else Android SDK cmake, else PATH)
set -euo pipefail

STQ_REPO="https://github.com/sjl623/llama.cpp.git"
STQ_BRANCH="STQ_0"
STQ_SHA="781aadf8749c"  # PR #22836 — STQ1_0 ternary kernel

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/native/llm_llamacpp_patched/android/src/main/jniLibs/arm64-v8a"
WORK="${TMPDIR:-/tmp}/swayco-llama-stq"

SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/AppData/Local/Android/Sdk}}"
NDK="${ANDROID_NDK_HOME:-$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1)}"
CMAKE_DIR="${CMAKE_BIN_DIR:-$(ls -d "$SDK"/cmake/*/bin 2>/dev/null | sort -V | tail -1)}"
[ -n "${CMAKE_DIR:-}" ] && export PATH="$CMAKE_DIR:$PATH"

[ -d "$NDK" ] || { echo "ERROR: NDK not found — set ANDROID_NDK_HOME"; exit 1; }
command -v cmake >/dev/null || { echo "ERROR: cmake not found — set CMAKE_BIN_DIR"; exit 1; }
echo "NDK:   $NDK"
echo "CMAKE: $(command -v cmake)"

# Fetch the STQ fork at the pinned commit.
if [ ! -d "$WORK/.git" ]; then
  rm -rf "$WORK"
  git clone --depth 1 --branch "$STQ_BRANCH" --single-branch "$STQ_REPO" "$WORK"
fi
git -C "$WORK" fetch --depth 1 origin "$STQ_SHA" 2>/dev/null || true
git -C "$WORK" checkout -q "$STQ_SHA" 2>/dev/null || echo "(using branch head $STQ_BRANCH)"

# Configure + build arm64-v8a shared libs (CPU/NEON backend, OpenMP off).
cmake -B "$WORK/build-android-so" -S "$WORK" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-28 \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
  -DGGML_OPENMP=OFF -DGGML_LLAMAFILE=OFF \
  -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF
cmake --build "$WORK/build-android-so" --target llama -j

mkdir -p "$DEST"
find "$WORK/build-android-so" -name "libllama.so" -o -name "libggml*.so" \
  | xargs -I{} cp -v {} "$DEST/"
echo "Done → $DEST"
ls -lh "$DEST"
