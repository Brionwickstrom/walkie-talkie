# Build the Windows desktop app on the PC and zip it (v1.9.6).
#
#   powershell -ExecutionPolicy Bypass -File tool\release_windows.ps1
#
# Run after tool\release.ps1 (which sets the version in pubspec.yaml and
# runs analyze + tests). Builds build\windows\x64\runner\Release, adds the
# Visual C++ runtime DLLs next to the exe (so it starts on PCs without the
# VC++ redistributable) and writes dist\WalkieTalkie-Windows.zip with one
# "WalkieTalkie" folder inside. Upload it to the same GitHub release as the
# APK (from the Linux box):
#   gh release upload v1.9.6 WalkieTalkie-Windows.zip --repo Brionwickstrom/walkie-talkie
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
# flutter_tts' Windows plugin needs nuget.exe (C:\src\nuget\nuget.exe).
$env:Path = 'C:\src\nuget;C:\Program Files\Git\cmd;C:\src\flutter\bin;' + $env:Path

flutter build windows --release
if ($LASTEXITCODE) { throw 'windows build failed' }

$rel = Join-Path $root 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $rel 'WalkieTalkie.exe'))) { throw 'WalkieTalkie.exe missing' }

# App-local Visual C++ runtime (allowed by the VC++ redistributable terms).
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath
$crt = Get-ChildItem -Path (Join-Path $vs 'VC\Redist\MSVC') -Recurse -Directory -Filter 'Microsoft.VC143.CRT' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\' -and $_.FullName -notmatch 'onecore|debug' } |
    Select-Object -First 1
if ($crt) {
    foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
        $src = Join-Path $crt.FullName $dll
        if (Test-Path $src) { Copy-Item $src $rel -Force }
    }
    Write-Host "Added VC++ runtime from $($crt.FullName)"
} else {
    Write-Warning 'VC++ runtime DLLs not found; PCs without the VC++ redistributable will not start the app'
}

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$stage = Join-Path $dist 'WalkieTalkie'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
Copy-Item $rel $stage -Recurse
@"
Stalkie Talkie for Windows
=========================

1. Unzip this folder anywhere (for example Documents\WalkieTalkie).
   Keep every file together: WalkieTalkie.exe needs the DLLs and the
   data folder next to it.
2. Double-click WalkieTalkie.exe.
   Windows SmartScreen may say "Windows protected your PC" because the app
   is not signed: click "More info", then "Run anyway".
3. When Windows Firewall asks, allow Private networks (and Public if you
   want to talk over hotspots), so phones on the same Wi-Fi can reach you.
4. Hold the Space bar (or the big button) to talk.

Updating: the app tells you when a new version is out. Close it, unzip the
new download over this folder, and start WalkieTalkie.exe again.
"@ | Set-Content -Encoding UTF8 (Join-Path $stage 'README.txt')

$zip = Join-Path $dist 'WalkieTalkie-Windows.zip'
if (Test-Path $zip) { Remove-Item -Force $zip }
# .NET zip (forward slashes in entry names; PowerShell 5's Compress-Archive
# writes backslashes, which some unzip tools mishandle).
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
$size = (Get-Item $zip).Length
Write-Host ""
Write-Host "Built $zip ($size bytes, sha256 $hash)"
