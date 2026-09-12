# Refuse un artefact Android dont la config client a ete compilee hors du binaire.
#
# Le jumeau Windows de verify-release.sh, et il existe pour une raison simple :
# cette machine n'a pas de bash. `build-release.ps1` appelait donc le script
# shell, celui-ci ne demarrait pas, et la SEULE garde qui aurait attrape la
# suspension Google Play de 6.1.7 ne tournait en realite jamais pour Android.
# Le build reussissait, l'AAB pouvait etre creux, et rien ne s'en plaignait.
#
#   .\scripts\verify-release.ps1                       # dernier AAB construit
#   .\scripts\verify-release.ps1 chemin\vers\app.aab
#   .\scripts\verify-release.ps1 chemin\vers\app.apk
#
# iOS reste au script bash, lance sur le Mac : un .ipa ne se verifie pas ici.
#
# Sortie 0 = publiable. Sortie 1 = ne pas envoyer.

param([string]$Artifact)

$ErrorActionPreference = "Stop"

$Root = Split-Path $PSScriptRoot -Parent
$Defines = Join-Path $Root "dart_defines.env"
if (-not $Artifact) {
  $Artifact = Join-Path $Root "build\app\outputs\bundle\release\app-release.aab"
}

if (-not (Test-Path $Defines)) {
  Write-Host "FAIL: $Defines introuvable." -ForegroundColor Red; exit 1
}
if (-not (Test-Path $Artifact)) {
  Write-Host "FAIL: artefact introuvable : $Artifact" -ForegroundColor Red; exit 1
}
if ($Artifact -notmatch '\.(aab|apk)$') {
  Write-Host "FAIL: format inconnu (.aab ou .apk attendu ; iOS = verify-release.sh sur le Mac)." -ForegroundColor Red
  exit 1
}

Write-Host "Artefact : $Artifact"
Write-Host "Attendu depuis : dart_defines.env"
Write-Host ""

Add-Type -AssemblyName System.IO.Compression.FileSystem

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("swayco-verify-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $Work | Out-Null

try {
  # Les blobs AOT Dart : un libapp.so par ABI. L'AAB les range sous base/lib/,
  # l'APK sous lib/.
  $zip = [System.IO.Compression.ZipFile]::OpenRead($Artifact)
  $bins = @()
  try {
    foreach ($entry in $zip.Entries) {
      if ($entry.Name -ne "libapp.so") { continue }
      # L'ABI est le dossier parent : on le garde dans le nom du fichier extrait
      # pour que le rapport dise DE QUELLE architecture il parle.
      $abi = Split-Path (Split-Path $entry.FullName -Parent) -Leaf
      $out = Join-Path $Work "$abi-libapp.so"
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $out, $true)
      $bins += [pscustomobject]@{ Label = "$abi/libapp.so"; Path = $out }
    }
  } finally {
    $zip.Dispose()
  }

  if ($bins.Count -eq 0) {
    Write-Host "FAIL: aucun binaire Dart trouve dans $Artifact" -ForegroundColor Red
    Write-Host "      (attendu : lib/*/libapp.so)"
    exit 1
  }

  # Les cles attendues, lues depuis la source de verite. TOKEN_API_BASE est
  # deliberement exclu de la recherche par valeur : https://www.swayco.fr est
  # aussi ecrit en dur dans les liens CGU/confidentialite, donc il serait
  # present meme dans un build qui n'a jamais recu le define. Le controle du
  # loopback, plus bas, est le test honnete pour celui-la.
  $expected = @()
  foreach ($line in Get-Content $Defines) {
    $t = $line.Trim()
    if ($t -eq "" -or $t.StartsWith("#")) { continue }
    $i = $t.IndexOf("=")
    if ($i -lt 1) { continue }
    $key = $t.Substring(0, $i).Trim()
    $value = $t.Substring($i + 1).Trim()
    if ($key -eq "TOKEN_API_BASE" -or $value -eq "") { continue }
    $expected += [pscustomobject]@{ Key = $key; Value = $value }
  }

  # ISO-8859-1 et pas UTF-8 : la correspondance octet-caractere y est exacte,
  # donc une recherche de texte sur un binaire ne peut ni perdre ni fusionner
  # d'octets. GetEncoding(28591) plutot que ::Latin1, absent de PowerShell 5.1.
  $latin1 = [System.Text.Encoding]::GetEncoding(28591)
  $fail = 0

  foreach ($bin in $bins) {
    Write-Host "--- $($bin.Label)"
    $text = $latin1.GetString([System.IO.File]::ReadAllBytes($bin.Path))

    foreach ($e in $expected) {
      if ($text.Contains($e.Value)) {
        Write-Host "    OK    $($e.Key)"
      } else {
        Write-Host "    ABSENT $($e.Key)   <-- l'app partira cassee" -ForegroundColor Red
        $fail = 1
      }
    }

    # Un build release qui porte encore le loopback emulateur n'a jamais recu
    # TOKEN_API_BASE : chaque appel backend irait vers un serveur sur le telephone.
    if ($text.Contains("10.0.2.2:8787")) {
      Write-Host "    ABSENT TOKEN_API_BASE   <-- pointe sur le loopback emulateur" -ForegroundColor Red
      $fail = 1
    } else {
      Write-Host "    OK    TOKEN_API_BASE (pas de loopback)"
    }
  }

  Write-Host ""
  if ($fail -eq 0) {
    Write-Host "OK - la configuration client est bien compilee. Artefact publiable." -ForegroundColor Green
  } else {
    Write-Host "REFUSE - config manquante. NE PAS envoyer sur le store." -ForegroundColor Red
    Write-Host "Rebuild avec : --dart-define-from-file=dart_defines.env"
  }
  exit $fail
} finally {
  Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}
