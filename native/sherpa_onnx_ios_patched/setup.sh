#!/usr/bin/env bash
# Regenerate the patched iOS xcframeworks for this override.
#
# The .xcframeworks are git-ignored (they are ~100 MB), so this is what you run
# on a fresh checkout — see SETUP.md for what each one is.
#
# Counterpart of ../sherpa_onnx_macos_patched/setup.sh. iOS differs in two ways:
# sherpa is built through its own build-ios-shared.sh (three slices + lipo +
# xcframework), and ORT stays a static library, which is why the export patch
# below exists.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$HERE/../.."

JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
ORT_VERSION="${SHERPA_ONNX_ONNXRUNTIME_VERSION:-1.27.0}"

# cmake is not in the base macOS toolchain. Homebrew is the usual source; a
# standalone CMake.app works just as well. 3.x is required — CMake 4 dropped
# compatibility with cmake_minimum_required < 3.5 and sherpa's vendored
# espeak-ng / kaldi still declare those.
CMAKE="${CMAKE:-$(command -v cmake || true)}"
if [ -z "$CMAKE" ]; then
  echo "error: cmake not found. Install it (brew install cmake) or set CMAKE=/path/to/cmake" >&2
  exit 1
fi
case "$("$CMAKE" --version | head -1)" in
  *" 4."*) echo "error: CMake 4 cannot configure sherpa's vendored deps; use 3.x" >&2; exit 1;;
esac

# 1) sherpa source: v1.13.4 + three patches. Delete $WORK to force a clean
#    re-clone + re-apply.
WORK="${SHERPA_SRC:-/tmp/sherpa-onnx-patched}"
if [ ! -d "$WORK" ]; then
  git clone --depth 1 --branch v1.13.4 https://github.com/k2-fsa/sherpa-onnx "$WORK"
  # Japanese TTS: exports SherpaOnnxOfflineTtsGenerateFromTokens.
  git -C "$WORK" apply "$REPO/native/sherpa_ja_patch/external-tokens-v1.13.4.patch"
  # STT byte-fallback UTF-8 fix (ja/zh/ko/hi character dropping).
  git -C "$WORK" apply "$REPO/native/sherpa_whisper_patch/byte-fallback-utf8-v1.13.4.patch"
  # Exports OrtGetApiBase so the voice converter can reach the runtime sherpa
  # already links, instead of the app vendoring a second ONNX Runtime.
  git -C "$WORK" apply "$REPO/native/sherpa_ort_export_patch/ort-getapibase-v1.13.4.patch"
fi

# 2) ORT for iOS. build-ios-shared.sh fetches this with wget, which macOS does
#    not ship; stage it with curl so that branch is skipped. Same layout the
#    script expects, symlink included.
ORT_DIR="$WORK/build-ios-shared/ios-onnxruntime"
if [ ! -f "$ORT_DIR/$ORT_VERSION/onnxruntime.xcframework/ios-arm64/onnxruntime.framework/onnxruntime" ]; then
  mkdir -p "$ORT_DIR/$ORT_VERSION"
  ZIP="onnxruntime-ios-static-xcframework-$ORT_VERSION.zip"
  curl -fL --retry 3 -o "$ORT_DIR/$ZIP" \
    "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v$ORT_VERSION/$ZIP"
  ( cd "$ORT_DIR" && unzip -q "$ZIP" && rm "$ZIP" \
    && mv "onnxruntime-ios-static-xcframework-$ORT_VERSION/onnxruntime.xcframework" "$ORT_VERSION/" \
    && rmdir "onnxruntime-ios-static-xcframework-$ORT_VERSION" )
fi
ln -sfn "$ORT_VERSION/onnxruntime.xcframework" "$ORT_DIR/onnxruntime.xcframework"

# 3) Build the three slices (sim x86_64, sim arm64, device arm64) and assemble
#    the xcframework. The upstream script is resumable: it skips a slice whose
#    dylib is already there, so a re-run after a failure is cheap.
export PATH="$(dirname "$CMAKE"):$PATH"
( cd "$WORK" && sed "s/-j 4 /-j $JOBS /g" build-ios-shared.sh > /tmp/build-ios-shared-jobs.sh \
  && bash /tmp/build-ios-shared-jobs.sh )

# 4) Vendor it.
rm -rf "$HERE/ios/sherpa_onnx.xcframework"
cp -R "$WORK/build-ios-shared/sherpa_onnx.xcframework" "$HERE/ios/"

# 5) The OpenJTalk reading lib. Independent of sherpa, so only build it if it is
#    actually missing — it is a slow build and nothing above invalidates it.
if [ ! -d "$HERE/ios/ja_openjtalk.xcframework" ]; then
  ( cd "$REPO/native/ja_openjtalk" && bash build_ios.sh )
  cp -R "$REPO/native/ja_openjtalk/build/ios/ja_openjtalk.xcframework" "$HERE/ios/"
fi

# 6) The point of the export patch — fail loudly if it silently stopped working
#    (e.g. sherpa's generate.sh regenerated the .exp from its ^_Sherpa grep).
BIN="$HERE/ios/sherpa_onnx.xcframework/ios-arm64/sherpa_onnx.framework/sherpa_onnx"
if ! nm -gU "$BIN" | grep -q "_OrtGetApiBase"; then
  echo "error: _OrtGetApiBase is not exported — the voice converter will not open" >&2
  echo "       (see ../sherpa_ort_export_patch/README.md)" >&2
  exit 1
fi
echo "done: sherpa_onnx.xcframework rebuilt, _OrtGetApiBase exported"
