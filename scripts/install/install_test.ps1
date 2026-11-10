#!/usr/bin/env pwsh
# Tests for install.ps1.
#
#   .\scripts\install\install_test.ps1              # test against the latest GitHub release
#   .\scripts\install\install_test.ps1 -Dist DIR    # test against local release assets in DIR
#
# Set CHAINCASH_TEST_VERSION (e.g. v0.1.0) to also test installing a specific release,
# and CHAINCASH_REPO to test against releases of a fork.
#
# Everything is installed into a temporary directory. install.ps1 adds the bin directory to the
# user PATH, so the original user PATH is saved and restored when the tests finish.

param(
  [string]$Dist
)

$ErrorActionPreference = 'Stop'

$Installer = Join-Path $PSScriptRoot 'install.ps1'
$Root = Join-Path ([System.IO.Path]::GetTempPath()) ("chaincash-test-" + [System.Guid]::NewGuid())
New-Item $Root -ItemType Directory | Out-Null

$UserTarget = [System.EnvironmentVariableTarget]::User
$SavedUserPath = [System.Environment]::GetEnvironmentVariable('Path', $UserTarget)
$SavedProcessPath = $env:Path
$SavedEnv = @{}
foreach ($Name in 'CHAINCASH_INSTALL', 'CHAINCASH_RELEASE_URL', 'XDG_CONFIG_HOME', 'LOCALAPPDATA', 'TMP', 'CHAINCASH_SERVER.PORT', 'CHAINCASH_BIN_DIR') {
  $SavedEnv[$Name] = [System.Environment]::GetEnvironmentVariable($Name)
}

function ConvertTo-FileUrl($Path) {
  "file:///" + ((Resolve-Path $Path).Path -replace '\\', '/')
}

function Assert-File($Path) {
  if (!(Test-Path $Path -PathType Leaf)) {
    throw "Expected file ${Path} to exist"
  }
}

function Assert-Contains($Path, $Text) {
  if (!("$(Get-Content $Path -Raw)".Contains($Text))) {
    throw "Expected ${Path} to contain '${Text}'"
  }
}

function Assert-Version($Exe) {
  $Out = & $Exe --version
  if (!($Out -like 'chaincash *')) {
    throw "Unexpected --version output from ${Exe}: ${Out}"
  }
}

try {
  # keep config and data out of the real profile
  $env:XDG_CONFIG_HOME = "${Root}\config"
  $env:LOCALAPPDATA = "${Root}\localappdata"
  if ($Dist) {
    $env:CHAINCASH_RELEASE_URL = ConvertTo-FileUrl $Dist
  }
  $ConfigFile = "${Root}\config\chaincash\config.toml"
  $Predicate = "${Root}\config\chaincash\predicates\example.toml"

  Write-Output "=== 1. installs latest release, writes config and updates PATH"
  $env:CHAINCASH_INSTALL = "${Root}\latest"
  $v = $null; & $Installer
  $Exe = "${Root}\latest\bin\chaincash.exe"
  Assert-File $Exe
  Assert-Version $Exe
  Assert-File $ConfigFile
  Assert-File $Predicate
  Assert-Contains $ConfigFile $Predicate
  Assert-Contains $ConfigFile "${Root}\localappdata\chaincash\chaincash.sqlite"
  $UserPath = [System.Environment]::GetEnvironmentVariable('Path', $UserTarget)
  if (!(";${UserPath};".ToLower() -like "*;${Root}\latest\bin;*".ToLower())) {
    throw "Expected ${Root}\latest\bin to be added to the user PATH"
  }

  Write-Output "=== 2. installed binary reads its config from the config directory"
  # bind a random free port, and keep the crash report written when no Ergo node is reachable
  # (which happens after the config is loaded) inside the test directory
  [System.Environment]::SetEnvironmentVariable('CHAINCASH_SERVER.PORT', '0')
  $env:TMP = $Root
  $RunLog = "${Root}\run.log"
  # run from an unrelated directory so .\config\ can't be picked up. Note: the server also writes
  # its log file to %APPDATA%\chaincash.log.d, which is a known folder and can't be redirected
  $Proc = Start-Process -FilePath $Exe -ArgumentList 'run' -WorkingDirectory $Root -NoNewWindow -PassThru `
    -RedirectStandardOutput $RunLog -RedirectStandardError "${Root}\run.err"
  $Deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $Deadline -and !((Test-Path $RunLog) -and (Get-Content $RunLog -Raw) -like '*loaded 1 predicates*')) {
    Start-Sleep -Milliseconds 200
  }
  if (!$Proc.HasExited) {
    Stop-Process -Id $Proc.Id -Force
  }
  $Proc.WaitForExit()
  if (!((Get-Content $RunLog -Raw) -like '*loaded 1 predicates*')) {
    Write-Output "--- chaincash run output ---"
    Get-Content $RunLog, "${Root}\run.err" -ErrorAction SilentlyContinue
    Write-Output "----------------------------"
  }
  Assert-Contains $RunLog "loading config from ${ConfigFile}"
  Assert-Contains $RunLog 'loaded 1 predicates'
  Assert-File "${Root}\localappdata\chaincash\chaincash.sqlite"

  Write-Output "=== 3. re-running keeps existing configuration and replaces the binary"
  Add-Content $ConfigFile '# user edit'
  Add-Content $Predicate '# user edit'
  Set-Content $Exe 'stale'
  $v = $null; & $Installer
  Assert-Contains $ConfigFile '# user edit'
  Assert-Contains $Predicate '# user edit'
  Assert-Version $Exe

  Write-Output "=== 4. a custom bin directory can be chosen with `$ChaincashBinDir, -BinDir or CHAINCASH_BIN_DIR"
  $ChaincashBinDir = "${Root}\dedicated\bin"
  $v = $null; & $Installer
  $ChaincashBinDir = $null
  Assert-File "${Root}\dedicated\bin\chaincash.exe"
  $UserPath = [System.Environment]::GetEnvironmentVariable('Path', $UserTarget)
  if (!(";${UserPath};".ToLower() -like "*;${Root}\dedicated\bin;*".ToLower())) {
    throw "Expected ${Root}\dedicated\bin to be added to the user PATH"
  }
  $v = $null; & $Installer -BinDir "${Root}\arg-bin"
  Assert-File "${Root}\arg-bin\chaincash.exe"
  $env:CHAINCASH_BIN_DIR = "${Root}\env-bin"
  try {
    $v = $null; & $Installer
  } finally {
    $env:CHAINCASH_BIN_DIR = $null
  }
  Assert-File "${Root}\env-bin\chaincash.exe"

  Write-Output "=== 5. installs to a relative custom location"
  Push-Location $Root
  try {
    $env:CHAINCASH_INSTALL = '.'
    $v = $null; & $Installer
    Assert-File "${Root}\bin\chaincash.exe"
  } finally {
    Pop-Location
  }

  if ($env:CHAINCASH_TEST_VERSION -and !$Dist) {
    Write-Output "=== 6. installs a specific release ($env:CHAINCASH_TEST_VERSION)"
    $env:CHAINCASH_INSTALL = "${Root}\versioned"
    $v = $env:CHAINCASH_TEST_VERSION; & $Installer
    $Out = & "${Root}\versioned\bin\chaincash.exe" --version
    if (!($Out -like "*$($env:CHAINCASH_TEST_VERSION.TrimStart('v'))*")) {
      throw "Installed version ${Out} does not match $env:CHAINCASH_TEST_VERSION"
    }
  }

  if ($Dist) {
    Write-Output "=== 7. refuses to install a binary that doesn't match SHA256SUMS"
    $Tampered = "${Root}\tampered"
    Copy-Item $Dist $Tampered -Recurse
    Get-ChildItem "${Tampered}\chaincash-*" | ForEach-Object { Add-Content $_.FullName 'tampered' }
    $env:CHAINCASH_RELEASE_URL = ConvertTo-FileUrl $Tampered
    $env:CHAINCASH_INSTALL = "${Root}\tampered-install"
    $Failed = $false
    try {
      $v = $null; & $Installer
    } catch {
      if (!($_.Exception.Message -like '*Checksum mismatch*')) {
        throw "Expected a checksum error, got: $($_.Exception.Message)"
      }
      $Failed = $true
    }
    if (!$Failed) {
      throw "install succeeded with a tampered binary"
    }
    if (Test-Path "${Root}\tampered-install\bin\chaincash.exe") {
      throw "tampered binary was installed"
    }
  }

  Write-Output ""
  Write-Output "All install tests passed"
} finally {
  [System.Environment]::SetEnvironmentVariable('Path', $SavedUserPath, $UserTarget)
  $env:Path = $SavedProcessPath
  foreach ($Name in $SavedEnv.Keys) {
    [System.Environment]::SetEnvironmentVariable($Name, $SavedEnv[$Name])
  }
  Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue
}
