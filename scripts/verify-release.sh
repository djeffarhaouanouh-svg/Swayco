#!/usr/bin/env bash
# Refuse a store artifact whose client config was compiled out.
#
# Google Play suspended 6.1.7 under "fonctionnalites defectueuses" because the
# uploaded AAB had been built with a bare `flutter build appbundle` - not one
# --dart-define among them. Supabase was never initialised, "Sign in" threw
# `Supabase non configure`, and the reviewer saw a dead button. Nothing in the
# build failed; the artifact was simply hollow. This script is the check that
# would have caught it, and it reads the compiled binary rather than trusting
# the command line that produced it.
#
#   ./scripts/verify-release.sh                       # last built AAB
#   ./scripts/verify-release.sh path/to/app.aab
#   ./scripts/verify-release.sh path/to/app.ipa       # on the Mac
#
# Exit 0 = safe to upload. Exit 1 = do not upload.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFINES="$ROOT/dart_defines.env"
ART="${1:-$ROOT/build/app/outputs/bundle/release/app-release.aab}"

[ -f "$DEFINES" ] || { echo "FAIL: $DEFINES introuvable."; exit 1; }
[ -f "$ART" ]     || { echo "FAIL: artefact introuvable : $ART"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Artefact : $ART"
echo "Attendu depuis : dart_defines.env"
echo

# Pull the Dart AOT blobs out of the artifact. Android keeps one libapp.so per
# ABI; iOS keeps a single App.framework binary.
case "$ART" in
  *.aab|*.apk) unzip -o -q "$ART" -d "$WORK" 'base/lib/*/libapp.so' 'lib/*/libapp.so' 2>/dev/null || true ;;
  *.ipa)       unzip -o -q "$ART" -d "$WORK" 'Payload/*/Frameworks/App.framework/App' 2>/dev/null || true ;;
  *.app)       cp "$ART/Frameworks/App.framework/App" "$WORK/App" 2>/dev/null || true ;;
  *)           echo "FAIL: format inconnu (.aab, .apk, .ipa ou .app attendu)."; exit 1 ;;
esac

BINS="$(find "$WORK" -type f \( -name 'libapp.so' -o -name 'App' \) | sort)"
[ -n "$BINS" ] || { echo "FAIL: aucun binaire Dart trouve dans l'artefact."; exit 1; }

fail=0

# TOKEN_API_BASE is deliberately not checked by value: https://www.swayco.fr is
# also hardcoded in the Terms/Privacy links, so it is present even in a build
# that never received the define - it would pass while meaning nothing. The
# loopback check below is the honest test for it.
for bin in $BINS; do
  label="$(basename "$(dirname "$bin")")/$(basename "$bin")"
  echo "--- $label"

  while IFS='=' read -r key value; do
    case "$key" in ''|\#*) continue ;; esac
    case "$key" in TOKEN_API_BASE) continue ;; esac
    [ -n "$value" ] || continue
    if grep -aqF "$value" "$bin"; then
      echo "    OK    $key"
    else
      echo "    ABSENT $key   <-- l'app partira cassee"
      fail=1
    fi
  done < "$DEFINES"

  # A release build that still carries the emulator loopback never received
  # TOKEN_API_BASE: every backend call would go to a server on the phone.
  if grep -aqF '10.0.2.2:8787' "$bin"; then
    echo "    ABSENT TOKEN_API_BASE   <-- pointe sur le loopback emulateur"
    fail=1
  else
    echo "    OK    TOKEN_API_BASE (pas de loopback)"
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "OK - la configuration client est bien compilee. Artefact publiable."
else
  echo "REFUSE - config manquante. NE PAS envoyer sur le store."
  echo "Rebuild avec : --dart-define-from-file=dart_defines.env"
fi
exit "$fail"
