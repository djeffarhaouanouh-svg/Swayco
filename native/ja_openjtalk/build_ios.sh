#!/usr/bin/env bash
# Build the OpenJTalk reading frontend as an iOS dynamic framework (arm64) and
# package it as ja_openjtalk.xcframework, ready to vendor from
# native/sherpa_onnx_ios_patched/ios/.
#
# It must be a *dynamic* framework (not a static .a): the ja_frontend_* symbols
# are only reached via dart:ffi DynamicLibrary.process(), so nothing references
# them at link time and a static lib's objects would be dead-stripped.
#
# The Info.plist MUST carry CFBundleShortVersionString / CFBundleVersion, or
# App Store validation rejects the upload with "missing plist key" (409).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEPS="$HERE/deps"
OUT="$HERE/build/ios"
PREFIX="$HERE/build/ios-prefix"
mkdir -p "$DEPS" "$OUT" "$PREFIX"

CMAKE="${CMAKE:-cmake}"
IOS_FLAGS="-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DCMAKE_BUILD_TYPE=Release"

[ -d "$DEPS/hts_engine_API" ] || git clone --depth 1 https://github.com/r9y9/hts_engine_API.git "$DEPS/hts_engine_API"
[ -d "$DEPS/open_jtalk" ]     || git clone --depth 1 https://github.com/r9y9/open_jtalk.git     "$DEPS/open_jtalk"

$CMAKE -S "$DEPS/hts_engine_API/src" -B "$DEPS/hts_engine_API/build-ios" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" $IOS_FLAGS
$CMAKE --build "$DEPS/hts_engine_API/build-ios" --target install -j4

$CMAKE -S "$DEPS/open_jtalk/src" -B "$DEPS/open_jtalk/build-ios" \
  -DHTS_ENGINE_INCLUDE_DIR="$PREFIX/include" \
  -DHTS_ENGINE_LIBRARY="$PREFIX/lib/libhts_engine_API.a" $IOS_FLAGS
$CMAKE --build "$DEPS/open_jtalk/build-ios" -j4

OJ="$DEPS/open_jtalk/src"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
INCS=""
for d in mecab/src njd jpcommon text2mecab mecab2njd njd2jpcommon \
         njd_set_pronunciation njd_set_digit njd_set_accent_phrase \
         njd_set_accent_type njd_set_unvoiced_vowel njd_set_long_vowel; do
  INCS="$INCS -I$OJ/$d"
done
INCS="$INCS -I$PREFIX/include -I$HERE/src"

# wrapper -> object, then one combined static lib, then a dynamic framework
xcrun --sdk iphoneos clang++ -arch arm64 -miphoneos-version-min=13.0 -isysroot "$SDK" \
  -O2 -c $INCS "$HERE/src/ja_frontend.c" -o "$OUT/ja_frontend.o"
xcrun libtool -static -o "$OUT/libja_openjtalk.a" "$OUT/ja_frontend.o" \
  "$DEPS/open_jtalk/build-ios/libopenjtalk.a" "$PREFIX/lib/libhts_engine_API.a" 2>/dev/null

FW="$OUT/ja_openjtalk.framework"
rm -rf "$FW"; mkdir -p "$FW/Headers"
xcrun --sdk iphoneos clang++ -arch arm64 -miphoneos-version-min=13.0 -isysroot "$SDK" \
  -dynamiclib -install_name @rpath/ja_openjtalk.framework/ja_openjtalk \
  -Wl,-all_load "$OUT/libja_openjtalk.a" -o "$FW/ja_openjtalk"
cp "$HERE/src/ja_frontend.h" "$FW/Headers/"

cat > "$FW/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>ja_openjtalk</string>
	<key>CFBundleIdentifier</key><string>com.swayco.ja-openjtalk</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>ja_openjtalk</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleSignature</key><string>????</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
	<key>MinimumOSVersion</key><string>13.0</string>
	<key>SupportedPlatform</key><string>ios</string>
	<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
	<key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
</dict>
</plist>
PLIST
plutil -lint "$FW/Info.plist"

rm -rf "$OUT/ja_openjtalk.xcframework"
xcrun xcodebuild -create-xcframework -framework "$FW" -output "$OUT/ja_openjtalk.xcframework"
echo "built $OUT/ja_openjtalk.xcframework"
echo "-> copy into native/sherpa_onnx_ios_patched/ios/"
