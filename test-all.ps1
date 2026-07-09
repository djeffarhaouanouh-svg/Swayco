# Runs the integration_test suite on a connected device/emulator.
#
# The app reads its config ONLY from --dart-define (NOT from .env at runtime —
# see lib/config/app_config.dart), so this script reads .env and forwards every
# key as a --dart-define. Pass -Email/-Password (or set $env:TEST_EMAIL /
# $env:TEST_PASSWORD) to also run the authenticated-navigation suite; without
# them that suite SKIPS and the run stays green.
#
# Usage:
#   .\test-all.ps1                                  # boot + login suites
#   .\test-all.ps1 -Email you@x.com -Password pw    # + authenticated flows
#   .\test-all.ps1 -Device emulator-5554
#   .\test-all.ps1 -Target integration_test/login_test.dart   # one file

param(
  [string]$Device = "",
  [string]$Email = $env:TEST_EMAIL,
  [string]$Password = $env:TEST_PASSWORD,
  [string]$Target = "integration_test"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path ".env")) {
  Write-Host "X .env introuvable a la racine du projet." -ForegroundColor Red
  exit 1
}

# Build the --dart-define list from .env (KEY=VALUE lines, '#' comments ignored).
$defines = @()
foreach ($line in Get-Content ".env") {
  $t = $line.Trim()
  if ($t -eq "" -or $t.StartsWith("#")) { continue }
  $i = $t.IndexOf("=")
  if ($i -lt 1) { continue }
  $k = $t.Substring(0, $i).Trim()
  $v = $t.Substring($i + 1).Trim()
  $defines += "--dart-define=$k=$v"
}

if ($Email)    { $defines += "--dart-define=TEST_EMAIL=$Email" }
if ($Password) { $defines += "--dart-define=TEST_PASSWORD=$Password" }

$cmd = @("test", $Target)
if ($Device) { $cmd += @("-d", $Device) }
$cmd += $defines

$authNote = if ($Email -and $Password) { "WITH test account" } else { "no test account (authenticated suite will skip)" }
Write-Host "> flutter test $Target  [$($defines.Count) dart-defines from .env, $authNote]" -ForegroundColor Cyan

& flutter @cmd
