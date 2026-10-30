# Build a release APK on the Windows PC.
#
#   powershell -ExecutionPolicy Bypass -File tool\release.ps1 -Version 1.2.0 -Build 4
#
# Bumps `version:` in pubspec.yaml to <Version>+<Build>, runs analyze + tests,
# builds the arm64 release APK and copies it to dist\WalkieTalkie.apk.
# Uploading to GitHub Releases is done from the Linux box (it has `gh`), see
# README "Releasing an update".
param(
    [Parameter(Mandatory = $true)][string]$Version,   # e.g. 1.2.0
    [Parameter(Mandatory = $true)][int]$Build         # must go up every release
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must look like 1.2.0" }

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$env:Path = 'C:\Program Files\Git\cmd;C:\src\flutter\bin;' + $env:Path
if (-not $env:JAVA_HOME) { $env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr' }

$pubspec = Join-Path $root 'pubspec.yaml'
$text = Get-Content $pubspec -Raw
$text = [regex]::Replace($text, '(?m)^version:.*$', "version: $Version+$Build")
[IO.File]::WriteAllText($pubspec, $text)
Write-Host "pubspec version -> $Version+$Build"

flutter pub get;  if ($LASTEXITCODE) { throw 'pub get failed' }
flutter analyze;  if ($LASTEXITCODE) { throw 'analyze failed' }
flutter test;     if ($LASTEXITCODE) { throw 'tests failed' }
flutter build apk --release --split-per-abi --target-platform android-arm64
if ($LASTEXITCODE) { throw 'build failed' }

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$apk = Join-Path $dist 'WalkieTalkie.apk'
Copy-Item 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk' $apk -Force
$hash = (Get-FileHash $apk -Algorithm SHA256).Hash
$size = (Get-Item $apk).Length
Write-Host ""
Write-Host "Built $apk ($size bytes, sha256 $hash)"
Write-Host "Android versionCode = $(2000 + $Build) (arm64 split adds 2000)"
Write-Host "Next: copy it to the box and run there:"
Write-Host "  gh release create v$Version WalkieTalkie.apk --repo Brionwickstrom/walkie-talkie --title 'Stalkie Talkie $Version' --notes '...'"
