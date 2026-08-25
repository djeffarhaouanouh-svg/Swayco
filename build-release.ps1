# Build release pour Play Store (AAB) et App Store (IPA).
# Usage : .\build-release.ps1
#
# Avant de lancer :
#  - Bump le numero de build dans pubspec.yaml (ex: 6.1.7+169 -> 6.1.7+170)
#  - Verifie que ios/key.properties et android/key.properties existent
#
# Apres le build :
#  - L'AAB est dans build/app/outputs/bundle/release/app-release.aab
#  - L'IPA est dans build/ios/ipa/
#
# Deux garde-fous, ajoutes apres la suspension Google Play de 6.1.7 :
#
#  1. La config client vient de dart_defines.env, plus de valeurs recopiees
#     ici. Une clef changee a un seul endroit ne peut plus diverger.
#  2. L'artefact produit est RELU avant d'etre declare pret : si la config
#     n'est pas reellement compilee dedans, le script sort en erreur. C'est
#     ce controle qui manquait - l'AAB suspendu etait vide de toute config
#     et rien dans le build ne s'en etait plaint.

$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot
$Defines = Join-Path $Root "dart_defines.env"

if (-not (Test-Path $Defines)) {
  Write-Host "dart_defines.env introuvable : $Defines" -ForegroundColor Red
  exit 1
}

# Flutter 3.47 ne compile plus livekit_client 2.7.0 : le package lit
# publishOptions.videoCodec apres un await et Dart 3.13 ne conserve plus la
# promotion non-null a travers un point de suspension. On builde donc avec le
# worktree 3.41.2 - la version que la CI iOS epingle - quand il est la.
$Pinned = Join-Path (Split-Path $Root -Parent) "flutter-3.41.2\bin\flutter.bat"
if (Test-Path $Pinned) {
  $Flutter = $Pinned
  Write-Host "Flutter epingle : $Flutter" -ForegroundColor Green
} else {
  $Flutter = "flutter"
  Write-Host "Worktree flutter-3.41.2 absent : on tente le Flutter global." -ForegroundColor Yellow
  Write-Host "Si la compilation echoue sur livekit_client/local.dart, recree-le :" -ForegroundColor Yellow
  Write-Host "  git -C <sdk-flutter> worktree add ..\flutter-3.41.2 3.41.2" -ForegroundColor Yellow
}

Write-Host "==> flutter clean" -ForegroundColor Cyan
& $Flutter clean

Write-Host "==> flutter pub get" -ForegroundColor Cyan
& $Flutter pub get

Write-Host "==> Build Android App Bundle (Play Store)" -ForegroundColor Cyan
& $Flutter build appbundle --release --dart-define-from-file=$Defines

if ($LASTEXITCODE -ne 0) {
  Write-Host "Build Android echoue." -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "==> Verification de l'AAB (config reellement compilee ?)" -ForegroundColor Cyan
$Aab = Join-Path $Root "build\app\outputs\bundle\release\app-release.aab"
bash (Join-Path $Root "scripts/verify-release.sh") $Aab

if ($LASTEXITCODE -ne 0) {
  Write-Host "AAB REFUSE - ne l'envoie pas sur le Play Store." -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "AAB Android pret et verifie : $Aab" -ForegroundColor Green
Write-Host ""

# iOS uniquement si on tourne sur macOS (Windows ne peut pas construire pour iOS).
if ($IsMacOS) {
  Write-Host "==> Build iOS IPA (App Store)" -ForegroundColor Cyan
  & $Flutter build ipa --release --dart-define-from-file=$Defines

  if ($LASTEXITCODE -ne 0) {
    Write-Host "Build iOS echoue." -ForegroundColor Red
    exit 1
  }

  Write-Host "==> Verification de l'IPA" -ForegroundColor Cyan
  $Ipa = Get-ChildItem (Join-Path $Root "build/ios/ipa") -Filter *.ipa | Select-Object -First 1
  if ($null -eq $Ipa) {
    Write-Host "Aucun .ipa trouve dans build/ios/ipa - verification impossible." -ForegroundColor Red
    exit 1
  }
  bash (Join-Path $Root "scripts/verify-release.sh") $Ipa.FullName
  if ($LASTEXITCODE -ne 0) {
    Write-Host "IPA REFUSE - ne l'envoie pas sur l'App Store." -ForegroundColor Red
    exit 1
  }
  Write-Host ""
  Write-Host "IPA iOS pret et verifie : $($Ipa.FullName)" -ForegroundColor Green
} else {
  Write-Host "iOS skip (build IPA necessite macOS / Xcode)." -ForegroundColor Yellow
  Write-Host "Sur le Mac :" -ForegroundColor Yellow
  Write-Host "  flutter build ipa --release --dart-define-from-file=dart_defines.env" -ForegroundColor Yellow
  Write-Host "  ./scripts/verify-release.sh build/ios/ipa/*.ipa" -ForegroundColor Yellow
}
