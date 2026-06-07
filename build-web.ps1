# Build release WEB (pour swayco.fr).
# Usage : .\build-web.ps1
#
# Sortie : build/web/  ->  a deployer sur swayco.fr comme d'habitude.
# Les memes --dart-define que run.ps1 / build-release.ps1, pour que les
# events analytics (dont le nouveau tracking par surface) partent bien
# vers https://www.swayco.fr/api/events.

$ErrorActionPreference = "Stop"

$SUPABASE_URL = "https://rhxenzcdnfvpgjjefztx.supabase.co"
$SUPABASE_PUBLISHABLE_KEY = "sb_publishable_5NZJowDX1ba6cGwuzFN08Q_j9GxFMXi"
$TOKEN_API_BASE = "https://www.swayco.fr"
$GOOGLE_WEB_CLIENT_ID = "361554699132-vjspl0l68h93fg9vateiinb1ndboj4ge.apps.googleusercontent.com"
$GOOGLE_IOS_CLIENT_ID = "361554699132-7864a6b9g008r6do0gekdh4ddftcul48.apps.googleusercontent.com"

Write-Host "==> flutter build web (release)" -ForegroundColor Cyan
flutter build web --release `
  --dart-define=SUPABASE_URL=$SUPABASE_URL `
  --dart-define=SUPABASE_PUBLISHABLE_KEY=$SUPABASE_PUBLISHABLE_KEY `
  --dart-define=TOKEN_API_BASE=$TOKEN_API_BASE `
  --dart-define=GOOGLE_WEB_CLIENT_ID=$GOOGLE_WEB_CLIENT_ID `
  --dart-define=GOOGLE_IOS_CLIENT_ID=$GOOGLE_IOS_CLIENT_ID

if ($LASTEXITCODE -ne 0) {
  Write-Host "Build web echoue." -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "Build web pret : build/web/  (deploie-le sur swayco.fr)" -ForegroundColor Green
