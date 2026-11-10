#!/usr/bin/env pwsh
# Builds chaincash from source and runs the install.ps1 tests against that build, so the
# installer can be tested on Windows without a GitHub release. Run from any directory:
#
#   powershell -ExecutionPolicy Bypass -File scripts\install\test_local.ps1            # build, then test
#   powershell -ExecutionPolicy Bypass -File scripts\install\test_local.ps1 -NoBuild   # reuse existing build
#
# Requirements: git, Rust with the MSVC toolchain (https://rustup.rs) and the
# "Desktop development with C++" Visual Studio Build Tools (needed to compile SQLite).
# Files are installed into a temporary directory and your user PATH is restored afterwards.

param(
  [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Target = 'x86_64-pc-windows-msvc'

Push-Location $RepoRoot
$Dist = Join-Path ([System.IO.Path]::GetTempPath()) ("chaincash-dist-" + [System.Guid]::NewGuid())
try {
  if (!$NoBuild) {
    Write-Output "Building chaincash (features: bundled-sqlite)..."
    git submodule update --init
    if ($LASTEXITCODE -ne 0) { throw "git submodule update failed" }
    cargo build --release --locked -p chaincash_cli --features bundled-sqlite
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
  }

  $Binary = Join-Path $RepoRoot 'target\release\chaincash.exe'
  if (!(Test-Path $Binary)) {
    throw "${Binary} not found, run without -NoBuild"
  }

  # lay out the same assets a GitHub release has (see .github/workflows/release.yaml)
  New-Item $Dist -ItemType Directory | Out-Null
  Copy-Item $Binary (Join-Path $Dist "chaincash-${Target}.exe")
  Copy-Item (Join-Path $RepoRoot 'config\predicates\example.toml') (Join-Path $Dist 'predicate-example.toml')
  $Sums = Get-ChildItem $Dist | ForEach-Object {
    "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name
  }
  [System.IO.File]::WriteAllLines((Join-Path $Dist 'SHA256SUMS'), [string[]]$Sums)

  Write-Output "Testing install.ps1 against local assets in ${Dist}"
  & (Join-Path $PSScriptRoot 'install_test.ps1') -Dist $Dist
} finally {
  Pop-Location
  Remove-Item $Dist -Recurse -Force -ErrorAction SilentlyContinue
}
