#!/usr/bin/env bash
# Drop the prebuilt libvosk.so into the Android build.
#
# Alphacephei ships compiled Android libraries; nothing needs building here.
# VoskEngine loads them with DynamicLibrary.open('libvosk.so'), which resolves
# against the ABI folders below at runtime.
#
#   ./scripts/fetch_libvosk_android.sh
#
# Run once. The .so files are large (~15 MB/ABI) — add them to .gitignore and
# re-run this on a fresh clone, or commit them via git-lfs.

set -euo pipefail

VERSION="0.3.45"
URL="https://github.com/alphacep/vosk-api/releases/download/v${VERSION}/vosk-android-${VERSION}.zip"
DEST="android/app/src/main/jniLibs"

cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> downloading vosk-android-${VERSION}"
curl -fL "$URL" -o "$WORK/vosk.zip"
unzip -q "$WORK/vosk.zip" -d "$WORK/x"

# The zip carries an .aar; the .so files live under its jni/ folder.
AAR="$(find "$WORK/x" -name '*.aar' | head -n1)"
if [ -n "$AAR" ]; then
  unzip -q "$AAR" -d "$WORK/aar"
  SRC="$WORK/aar/jni"
else
  SRC="$(dirname "$(find "$WORK/x" -name 'libvosk.so' | head -n1)")/.."
fi

mkdir -p "$DEST"
# Ship only the ABIs a phone actually uses; x86_64 is emulator-only and would
# add ~15 MB to every download.
for abi in arm64-v8a armeabi-v7a; do
  if [ -f "$SRC/$abi/libvosk.so" ]; then
    mkdir -p "$DEST/$abi"
    cp "$SRC/$abi/libvosk.so" "$DEST/$abi/"
    echo "    $abi ✓"
  else
    echo "    $abi MISSING — inspect $SRC" >&2
  fi
done

echo "done — libvosk.so installed under $DEST"
