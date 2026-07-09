#!/usr/bin/env bash
# Cross-compile libvosk.a for arm64 iOS (device) and drop it into ios/Frameworks/.
#
# Alphacephei ships no iOS binary (their ios/ README points at
# contact@alphacephei.com), so we build the Kaldi stack ourselves:
#
#     OpenFST 1.8.2  ->  Kaldi (online2 lm rnnlm)  ->  vosk C API  ->  one .a
#
# Design choices that matter:
#   * --mathlib=ACCELERATE. Accelerate.framework exists on iOS, so Kaldi's BLAS/
#     LAPACK needs come from it directly. This deletes the single most painful
#     cross-compile dependency (OpenBLAS + CLAPACK) that the Android build carries.
#   * Static, not shared. iOS links the archive INTO the app binary; VoskEngine
#     resolves symbols with DynamicLibrary.process(). We fuse every Kaldi/OpenFST
#     .a plus the vosk objects into a single libvosk.a with Apple's libtool.
#   * We build ONLY `online2 lm rnnlm` and their deps — the rest of Kaldi is both
#     unused by vosk and exactly what tends to break under cross-compilation.
#
# THE #1 PITFALL is NOT in this script — it's in Xcode. Nothing in Dart/Swift
# references vosk_* at link time, so the linker dead-strips the whole object and
# you get a green build that crashes with "Failed to lookup symbol" on first use.
# You MUST add to Runner target > Build Settings > Other Linker Flags:
#
#     -force_load $(SRCROOT)/Frameworks/libvosk.a
#     -lc++
#     -framework Accelerate
#
# and add libvosk.a to "Link Binary With Libraries". Then verify the symbol
# survived the app link (step 6 below), NOT just that the build was green.
#
# Usage:  bash scripts/build_libvosk_ios.sh
# Re-runnable: each stage is skipped if its output already exists. Force a clean
# rebuild of everything with:  rm -rf build/libvosk-ios
#
# Prereqs: Xcode Command Line Tools. (No cmake/OpenBLAS thanks to Accelerate;
# no autotools thanks to the OpenFST release tarball, which ships ./configure.)

set -euo pipefail

# ── pinned versions ──────────────────────────────────────────────────────────
# 1.8.0, not something newer: alphacep/kaldi@vosk-android includes <fst/types.h>,
# which upstream OpenFST deleted in 1.8.2. This is also the version the official
# vosk Android build pins. Two upstream papercuts still need patching below.
OPENFST_VERSION="1.8.0"
KALDI_REPO="https://github.com/alphacep/kaldi"
KALDI_BRANCH="vosk-android"          # the Kaldi fork vosk 0.3.45 is built against
VOSK_REPO="https://github.com/alphacep/vosk-api"
VOSK_TAG="v0.3.45"

# ── layout ───────────────────────────────────────────────────────────────────
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
WORK="$REPO_ROOT/build/libvosk-ios"
FST_PREFIX="$WORK/fst-ios"
DEST="$REPO_ROOT/ios/Frameworks"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p "$WORK"

# ── iOS arm64 device toolchain ───────────────────────────────────────────────
# Align with IPHONEOS_DEPLOYMENT_TARGET in the Xcode project (currently 15.0).
IOS_MIN="15.0"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
HOST="arm-apple-darwin"

export CC="$(xcrun --sdk iphoneos -f clang)"
export CXX="$(xcrun --sdk iphoneos -f clang++)"
export AR="$(xcrun --sdk iphoneos -f ar)"
export RANLIB="$(xcrun --sdk iphoneos -f ranlib)"
ARCH_FLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$IOS_MIN"
export CFLAGS="$ARCH_FLAGS -O3"
export CXXFLAGS="$ARCH_FLAGS -O3 -std=c++17 -DFST_NO_DYNAMIC_LINKING"
export LDFLAGS="$ARCH_FLAGS"

echo "==> toolchain"
echo "    SDK           $SDK"
echo "    CXX           $CXX"
echo "    target        arm64-apple-ios$IOS_MIN"
echo "    work dir      $WORK"

# ── 1. OpenFST ───────────────────────────────────────────────────────────────
if [ ! -f "$FST_PREFIX/lib/libfst.a" ]; then
  echo "==> [1/5] building OpenFST $OPENFST_VERSION"
  cd "$WORK"
  if [ ! -d "openfst-$OPENFST_VERSION" ]; then
    curl -fL "https://www.openfst.org/twiki/pub/FST/FstDownload/openfst-$OPENFST_VERSION.tar.gz" \
      -o openfst.tar.gz
    tar xzf openfst.tar.gz
  fi
  cd "openfst-$OPENFST_VERSION"
  # configure's one AC_RUN check (a float-equality sanity test) aborts hard when
  # cross-compiling, and there is no cache var to pre-answer it. arm64 float
  # behaviour is fine and OpenFST re-checks this in `make check` anyway.
  perl -0777 -i -pe \
    's/as_fn_error \$\? "cannot run test program while cross compiling\nSee[^\n]*5; \}/printf "%s\\n" "openfst: float-equality run-test skipped (cross-compile)"; :; }/' \
    configure
  # Upstream typo: VectorHashBiTable's copy ctor initialises from `table.s_`,
  # but the member is `selector_`. Only --enable-lookahead-fsts instantiates it,
  # which is why stock OpenFST builds never trip over it.
  /usr/bin/sed -i '' 's/selector_(table\.s_)/selector_(table.selector_)/' \
    src/include/fst/bi-table.h
  # --host makes autoconf treat this as a cross-build and skip run-tests (iOS
  # binaries can't execute on the build host). PIC so the objects fold into the
  # app's own image cleanly.
  ./configure --prefix="$FST_PREFIX" --host="$HOST" \
    --enable-static --disable-shared --with-pic --disable-bin \
    --enable-far --enable-ngram-fsts --enable-lookahead-fsts
  make -j"$JOBS"
  make install
else
  echo "==> [1/5] OpenFST already built — skipping"
fi

# ── 2. Kaldi (online2 lm rnnlm only) ─────────────────────────────────────────
if [ ! -f "$WORK/kaldi/src/online2/kaldi-online2.a" ]; then
  echo "==> [2/5] building Kaldi ($KALDI_BRANCH)"
  cd "$WORK"
  [ -d kaldi ] || git clone -b "$KALDI_BRANCH" --single-branch --depth 1 "$KALDI_REPO" kaldi
  cd kaldi/src
  # This fork has a real iOS target: `--ios=` selects makefiles/ios.mk, which
  # links -framework Accelerate. It is NOT reachable via --mathlib=ACCELERATE —
  # that value is rejected outright (supported: ATLAS CLAPACK MKL OPENBLAS).
  # --ios also implies static_math, static_fst and dynamic_kaldi=false for us.
  #
  # ios.mk *assigns* CXXFLAGS rather than appending, so an exported CXXFLAGS is
  # discarded. Our arch/sysroot flags have to ride in on EXTRA_CXXFLAGS, or
  # Kaldi silently compiles for the host Mac and the final lipo says arm64
  # anyway (same CPU) while the objects carry the macOS platform.
  export EXTRA_CXXFLAGS="$ARCH_FLAGS"
  export EXTRA_LDFLAGS="$ARCH_FLAGS"
  ./configure --ios=yes --static --use-cuda=no \
    --fst-root="$FST_PREFIX" --fst-version="$OPENFST_VERSION"

  # ios.mk carries -lpthread -ldl; both exist in the iOS SDK as .tbd stubs, so
  # unlike the folklore they need no scrubbing. We only build archives here, so
  # LDLIBS is barely exercised regardless.
  grep -q "framework Accelerate" kaldi.mk \
    || { echo "ERROR: kaldi.mk lost -framework Accelerate" >&2; exit 1; }

  make -j"$JOBS" depend
  make -j"$JOBS" online2 lm rnnlm
else
  echo "==> [2/5] Kaldi already built — skipping"
fi

# ── 3. vosk C API objects ────────────────────────────────────────────────────
if [ ! -f "$WORK/vosk-api/src/vosk_api.o" ]; then
  echo "==> [3/5] compiling vosk C API objects"
  cd "$WORK"
  [ -d vosk-api ] || git clone -b "$VOSK_TAG" --single-branch --depth 1 "$VOSK_REPO" vosk-api
  cd vosk-api/src
  # Compile only the objects; the Makefile's default link is --shared (wrong for
  # iOS). We drive Accelerate on / OpenBLAS off and reuse the Makefile's include
  # paths via EXTRA_CFLAGS carrying our arch/sysroot flags.
  make \
    KALDI_ROOT="$WORK/kaldi" \
    OPENFST_ROOT="$FST_PREFIX" \
    HAVE_OPENBLAS_CLAPACK=0 \
    HAVE_ACCELERATE=1 \
    CXX="$CXX" \
    EXTRA_CFLAGS="$ARCH_FLAGS" \
    recognizer.o language_model.o model.o spk_model.o vosk_api.o
else
  echo "==> [3/5] vosk objects already built — skipping"
fi

# ── 4. fuse everything into one static archive ───────────────────────────────
echo "==> [4/5] fusing archives into libvosk.a"
cd "$WORK/vosk-api/src"
KALDI_LIBS=()
for d in online2 decoder lat gmm tree feat nnet3 ivector hmm transform \
         cudamatrix matrix util base lm rnnlm fstext; do
  for a in "$WORK/kaldi/src/$d"/*.a; do
    [ -f "$a" ] && KALDI_LIBS+=("$a")
  done
done
# Apple's libtool (NOT GNU) merges .a + .o into a single fat static lib.
/usr/bin/libtool -static -o "$WORK/libvosk.a" \
  ./*.o \
  "${KALDI_LIBS[@]}" \
  "$FST_PREFIX/lib/libfst.a" \
  "$FST_PREFIX/lib/libfstngram.a"

# Kaldi's ios.mk compiles -g -O3, so DWARF is ~90% of the archive (320MB -> 33MB).
# `strip -S` drops debug symbols ONLY; the global text symbols dlsym needs stay.
# Never use plain `strip`/`-x` here — that is what silently breaks
# DynamicLibrary.process(). The symbol check below runs after this, on purpose.
strip -S "$WORK/libvosk.a"

# ── 5. validate + deploy ─────────────────────────────────────────────────────
echo "==> [5/5] validating libvosk.a"
echo "    arch: $(lipo -info "$WORK/libvosk.a")"
# Snapshot the symbol table once. Do NOT pipe nm into `grep -q` under
# `set -o pipefail`: grep -q closes the pipe on first hit, nm dies on SIGPIPE,
# and the pipeline reports failure for symbols that are actually present.
SYMS="$(nm -gU "$WORK/libvosk.a" 2>/dev/null || true)"
MISSING=0
# Exactly the symbols lib/services/stt/vosk_engine.dart looks up. Keep in sync:
# a missing one is not a build error, it is a runtime "Failed to lookup symbol".
for sym in vosk_model_new vosk_model_free vosk_recognizer_new \
           vosk_recognizer_accept_waveform_f vosk_recognizer_result \
           vosk_recognizer_partial_result vosk_recognizer_final_result \
           vosk_recognizer_reset vosk_recognizer_free vosk_set_log_level; do
  # 'T' = defined in text, global. A 'U' or an absent symbol means a broken .a.
  if grep -qE "T _?$sym\$" <<<"$SYMS"; then
    echo "    ✓ $sym"
  else
    echo "    ✗ $sym  (not defined/global)" >&2
    MISSING=1
  fi
done
if [ "$MISSING" -ne 0 ]; then
  echo "ERROR: some vosk_* symbols are missing — do NOT ship this .a" >&2
  exit 1
fi

mkdir -p "$DEST"
cp "$WORK/libvosk.a" "$DEST/libvosk.a"
cp "$WORK/vosk-api/src/vosk_api.h" "$DEST/vosk_api.h"
echo "==> done: $DEST/libvosk.a"
cat <<'NEXT'

Next, in Xcode (Runner target) — this is where symbols get kept or dropped:
  1. Drag ios/Frameworks/libvosk.a into "Link Binary With Libraries".
  2. Build Settings > Other Linker Flags, add:
        -force_load $(SRCROOT)/Frameworks/libvosk.a
        -lc++
        -framework Accelerate
  3. flutter build ios, then verify the symbol survived the APP link:
        nm -gU build/ios/iphoneos/Runner.app/Runner | grep vosk_model_new
     No output => -force_load didn't take; it will crash on first call.
NEXT
