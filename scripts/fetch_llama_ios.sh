#!/usr/bin/env bash
# Drop the prebuilt llama.cpp / ggml STATIC libraries into the iOS build.
#
# The on-device translation plugin (llm_llamacpp, brynjen/dart-llm) ships its
# iOS release as static archives — libllama.a + libggml*.a incl. libggml-metal.a
# — NOT a dynamic framework. Its own Dart iOS path resolves symbols through
# DynamicLibrary.process(), i.e. it expects these linked statically into the app
# binary. native/llm_llamacpp_patched/ios/llm_llamacpp.podspec -force_loads them
# and keeps the API symbols with -Wl,-u roots (see native/.../ios/
# llama_symbols.txt). Same shape as scripts/build_libvosk_ios.sh's libvosk.a.
#
#   ./scripts/fetch_llama_ios.sh
#
# Run once after a fresh clone. The .a are ~15 MB total and git-ignored; this
# re-fetches them. The GitHub release tag is pinned to the version the plugin's
# hook/build.dart hardcodes (_packageVersion), NOT the pubspec ^ constraint.

set -euo pipefail

VERSION="0.1.0"                       # matches _packageVersion in hook/build.dart
OWNER="brynjen"
REPO="dart-llm"
ASSET="llm_llamacpp-v${VERSION}-ios-arm64.zip"
URL="https://github.com/${OWNER}/${REPO}/releases/download/v${VERSION}/${ASSET}"
DEST="native/llm_llamacpp_patched/ios/libs"

cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> downloading ${ASSET}"
curl -fL "$URL" -o "$WORK/llama.zip"
unzip -q "$WORK/llama.zip" -d "$WORK/x"

mkdir -p "$DEST"
found=0
while IFS= read -r a; do
  cp "$a" "$DEST/"
  found=$((found + 1))
done < <(find "$WORK/x" -name '*.a')

if [ "$found" -eq 0 ]; then
  echo "ERROR: no .a archives found in ${ASSET} — release layout changed?" >&2
  exit 1
fi

echo "==> installed ${found} static libs into ${DEST}:"
ls -1 "$DEST"/*.a | sed 's|.*/|    |'

# Sanity: the app force_loads these by name; a missing one is a link error.
for lib in libllama.a libggml.a libggml-base.a libggml-cpu.a \
           libggml-metal.a libggml-blas.a libcommon.a libcpp-httplib.a; do
  [ -f "$DEST/$lib" ] || { echo "ERROR: expected $lib missing" >&2; exit 1; }
done
echo "==> done. arch: $(lipo -archs "$DEST/libllama.a" 2>/dev/null || echo '?')"
