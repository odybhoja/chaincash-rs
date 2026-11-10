#!/usr/bin/env pwsh
# Builds chaincash from source and runs the install.ps1 tests against that build, so the
# installer can be tested on Windows without a GitHub release. Run from any directory:
#
#   powershell -ExecutionPolicy Bypass -File scripts\install\test_local.ps1            # build, then test
#   powershell -ExecutionPolicy Bypass -File scripts\install\test_local.ps1 -NoBuild   # reuse existing build
#
# All output is also written to install-test-windows-<arch>-<timestamp>.log in the repository root,
# ready to be shared. Use -LogFile to choose a different file.
#
# Requirements: git, Rust with the MSVC toolchain (https://rustup.rs) and the
# "Desktop development with C++" Visual Studio Build Tools (needed to compile SQLite).
# Files are installed into a temporary directory and your user PATH is restored afterwards.

param(
  [switch]$NoBuild,
  [string]$LogFile
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Target = 'x86_64-pc-windows-msvc'
if (!$LogFile) {
  $Arch = "$env:PROCESSOR_ARCHITECTURE".ToLower()
  $LogFile = Join-Path $RepoRoot ("install-test-windows-${Arch}-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
}
$LogFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogFile)

# Runs a native command with stderr merged into stdout by cmd.exe. Windows PowerShell turns
# native stderr lines (cargo's progress output) into errors, which would abort the script.
function Invoke-Native($CommandLine) {
  cmd.exe /c "$CommandLine 2>&1"
  if ($LASTEXITCODE -ne 0) {
    throw "'${CommandLine}' failed with exit code ${LASTEXITCODE}"
  }
}

function Get-Version($CommandLine) {
  try { (cmd.exe /c "$CommandLine 2>&1" | Select-Object -First 1) } catch { 'not found' }
}

function Write-Environment {
  $Os = try { (Get-CimInstance Win32_OperatingSystem).Caption } catch { 'unknown' }
  Write-Output "chaincash install test report"
  Write-Output "date:       $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC"
  Write-Output "system:     ${Os} ($([System.Environment]::OSVersion.VersionString))"
  Write-Output "arch:       $env:PROCESSOR_ARCHITECTURE"
  Write-Output "powershell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
  Write-Output "commit:     $(Get-Version 'git rev-parse --short HEAD') ($(Get-Version 'git rev-parse --abbrev-ref HEAD'))"
  Write-Output "rustc:      $(Get-Version 'rustc --version')"
  Write-Output "cargo:      $(Get-Version 'cargo --version')"
  Write-Output "curl:       $(Get-Version 'curl.exe --version')"
  Write-Output ""
}

function Invoke-Tests {
  $Dist = Join-Path ([System.IO.Path]::GetTempPath()) ("chaincash-dist-" + [System.Guid]::NewGuid())
  try {
    if (!$NoBuild) {
      Write-Output "Building chaincash (features: bundled-sqlite)..."
      Invoke-Native 'git submodule update --init'
      Invoke-Native 'cargo build --release --locked -p chaincash_cli --features bundled-sqlite'
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

    Write-Output ""
    Write-Output "Testing install.ps1 against local assets in ${Dist}"
    & (Join-Path $PSScriptRoot 'install_test.ps1') -Dist $Dist
  } finally {
    Remove-Item $Dist -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# UTF-8 without BOM; Tee-Object would write UTF-16 on Windows PowerShell
$Writer = New-Object System.IO.StreamWriter($LogFile, $false, (New-Object System.Text.UTF8Encoding($false)))
$Writer.AutoFlush = $true
$Failed = $false

Push-Location $RepoRoot
try {
  & {
    Write-Environment
    try {
      Invoke-Tests
      Write-Output ""
      Write-Output "RESULT: PASSED"
    } catch {
      $script:Failed = $true
      Write-Output ""
      Write-Output "FAIL: $($_.Exception.Message)"
      Write-Output "at: $($_.InvocationInfo.PositionMessage)"
      Write-Output ""
      Write-Output "RESULT: FAILED"
    }
  } *>&1 | ForEach-Object {
    $Line = "$_"
    Write-Host $Line
    $Writer.WriteLine($Line)
  }
} finally {
  Pop-Location
  $Writer.Close()
}

Write-Host ""
Write-Host "Test report written to ${LogFile}"
if ($Failed) {
  exit 1
}
