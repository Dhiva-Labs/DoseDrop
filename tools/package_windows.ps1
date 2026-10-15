<#
.SYNOPSIS
Packages the Windows release build as a zip and a Microsoft Store .msix.

.DESCRIPTION
Run after `flutter build windows --release`:

    pwsh tools/package_windows.ps1 [-OutDir dist] [-Arch x64|arm64]

-Arch defaults to the machine's architecture ($env:PROCESSOR_ARCHITECTURE),
which is also the only one `flutter build windows` targets, so the build is
read from build\windows\x64\... on x64 and build\windows\arm64\... on ARM64.

Writes to -OutDir (default dist\):

    DoseDrop-<version>-windows-<arch>.zip   the release folder, unpackaged
    DoseDrop.msix                           x64 Store package (msix_config's
                                            output_name, as before)
    DoseDrop-arm64.msix                     arm64 Store package

The .msix files are unsigned Store uploads (`msix:create --store`); Partner
Center signs them. The zip is made first because msix:create drops its
temporary files into the release folder while it runs.
#>
param(
    [string]$OutDir = 'dist',
    [ValidateSet('x64', 'arm64')]
    [string]$Arch
)

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

if (-not $Arch) {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { $Arch = 'x64' }
        'ARM64' { $Arch = 'arm64' }
        default { throw "unsupported PROCESSOR_ARCHITECTURE '$env:PROCESSOR_ARCHITECTURE' (AMD64 or ARM64)" }
    }
}

$versionLine = Select-String -Path pubspec.yaml -Pattern '^version:\s*(\S+)' | Select-Object -First 1
if (-not $versionLine) { throw 'no version: line in pubspec.yaml' }
$version = ($versionLine.Matches[0].Groups[1].Value -split '\+')[0]

$release = "build\windows\$Arch\runner\Release"
if (-not (Test-Path "$release\dose_drop.exe")) {
    throw "$release\dose_drop.exe not found - run 'flutter build windows --release' first"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$out = (Resolve-Path $OutDir).Path

# Zip: one DoseDrop-<version>-windows-<arch>\ folder holding the release build.
$name = "DoseDrop-$version-windows-$Arch"
$stage = Join-Path ([IO.Path]::GetTempPath()) "dosedrop-zip-$([guid]::NewGuid())"
try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item -Recurse -Path $release -Destination (Join-Path $stage $name)
    $zip = Join-Path $out "$name.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        (Join-Path $stage $name), $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
    Write-Host "built $zip"
} finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}

# MSIX: the x64 name stays what msix_config gives it.
$msixName = if ($Arch -eq 'x64') { 'DoseDrop' } else { "DoseDrop-$Arch" }
dart run msix:create --store --architecture $Arch --build-windows false `
    --output-path $out --output-name $msixName
if ($LASTEXITCODE -ne 0) { throw "msix:create failed with exit code $LASTEXITCODE" }
$msix = Join-Path $out "$msixName.msix"
if (-not (Test-Path $msix)) { throw "msix:create did not write $msix" }
Write-Host "built $msix"
