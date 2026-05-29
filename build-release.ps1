# Build release pour Play Store (AAB) et App Store (IPA).
# Usage : .\build-release.ps1
#
# Avant de lancer :
#  - Bump le numero de version dans pubspec.yaml (ex: 1.0.0+2 -> 1.0.0+3)
#  - Verifie que ios/key.properties et android/key.properties existent
#
# Apres le build :
#  - L'AAB est dans build/app/outputs/bundle/release/app-release.aab
#  - L'IPA est dans build/ios/ipa/

$ErrorActionPreference = "Stop"

$SUPABASE_URL = "https://rhxenzcdnfvpgjjefztx.supabase.co"
$SUPABASE_PUBLISHABLE_KEY = "sb_publishable_5NZJowDX1ba6cGwuzFN08Q_j9GxFMXi"
$TOKEN_API_BASE = "https://www.swayco.fr"

Write-Host "==> flutter clean" -ForegroundColor Cyan
flutter clean

Write-Host "==> flutter pub get" -ForegroundColor Cyan
flutter pub get

Write-Host "==> Build Android App Bundle (Play Store)" -ForegroundColor Cyan
flutter build appbundle --release `
  --dart-define=SUPABASE_URL=$SUPABASE_URL `
  --dart-define=SUPABASE_PUBLISHABLE_KEY=$SUPABASE_PUBLISHABLE_KEY `
  --dart-define=TOKEN_API_BASE=$TOKEN_API_BASE

if ($LASTEXITCODE -ne 0) {
  Write-Host "Build Android echoue." -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "AAB Android pret : build/app/outputs/bundle/release/app-release.aab" -ForegroundColor Green
Write-Host ""

# iOS uniquement si on tourne sur macOS (Windows ne peut pas construire pour iOS).
if ($IsMacOS) {
  Write-Host "==> Build iOS IPA (App Store)" -ForegroundColor Cyan
  flutter build ipa --release `
    --dart-define=SUPABASE_URL=$SUPABASE_URL `
    --dart-define=SUPABASE_PUBLISHABLE_KEY=$SUPABASE_PUBLISHABLE_KEY `
    --dart-define=TOKEN_API_BASE=$TOKEN_API_BASE

  if ($LASTEXITCODE -ne 0) {
    Write-Host "Build iOS echoue." -ForegroundColor Red
    exit 1
  }
  Write-Host ""
  Write-Host "IPA iOS pret : build/ios/ipa/" -ForegroundColor Green
} else {
  Write-Host "iOS skip (build IPA necessite macOS / Xcode)." -ForegroundColor Yellow
  Write-Host "Pour iOS : sur un Mac, lance la meme commande --dart-define avec 'flutter build ipa --release'." -ForegroundColor Yellow
}
