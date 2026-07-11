#!/usr/bin/env bash
# Build the OpenJTalk reading frontend as a shared lib for macOS (arm64).
# Produces build/macos/libja_openjtalk.dylib exporting the ja_frontend_* C API.
#
# Deps (open_jtalk + hts_engine_API, r9y9 CMake forks) are fetched into deps/.
# CHARSET is utf8 to match the open_jtalk_dic_utf_8 dictionary shipped at runtime.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEPS="$HERE/deps"
OUT="$HERE/build/macos"
PREFIX="$HERE/build/prefix"
mkdir -p "$DEPS" "$OUT" "$PREFIX"

CMAKE="${CMAKE:-cmake}"
POLICY="-DCMAKE_POLICY_VERSION_MINIMUM=3.5"   # old CMakeLists vs cmake >= 4
COMMON="$POLICY -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_OSX_ARCHITECTURES=arm64"

[ -d "$DEPS/hts_engine_API" ] || git clone --depth 1 https://github.com/r9y9/hts_engine_API.git "$DEPS/hts_engine_API"
[ -d "$DEPS/open_jtalk" ]     || git clone --depth 1 https://github.com/r9y9/open_jtalk.git     "$DEPS/open_jtalk"

# 1) hts_engine_API static lib
$CMAKE -S "$DEPS/hts_engine_API/src" -B "$DEPS/hts_engine_API/build" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" $COMMON
$CMAKE --build "$DEPS/hts_engine_API/build" --target install -j4

# 2) open_jtalk static lib (mecab + njd + jpcommon), utf8
$CMAKE -S "$DEPS/open_jtalk/src" -B "$DEPS/open_jtalk/build" \
  -DHTS_ENGINE_INCLUDE_DIR="$PREFIX/include" \
  -DHTS_ENGINE_LIBRARY="$PREFIX/lib/libhts_engine_API.a" $COMMON
$CMAKE --build "$DEPS/open_jtalk/build" -j4

# 3) our wrapper -> shared lib (link C++ because mecab is C++)
OJ="$DEPS/open_jtalk/src"
INCS=""
for d in mecab/src njd jpcommon text2mecab mecab2njd njd2jpcommon \
         njd_set_pronunciation njd_set_digit njd_set_accent_phrase \
         njd_set_accent_type njd_set_unvoiced_vowel njd_set_long_vowel; do
  INCS="$INCS -I$OJ/$d"
done
INCS="$INCS -I$PREFIX/include -I$HERE/src"
clang++ -O2 -dynamiclib -install_name @rpath/libja_openjtalk.dylib $INCS \
  "$HERE/src/ja_frontend.c" \
  "$DEPS/open_jtalk/build/libopenjtalk.a" "$PREFIX/lib/libhts_engine_API.a" \
  -lm -o "$OUT/libja_openjtalk.dylib"
echo "built $OUT/libja_openjtalk.dylib"
