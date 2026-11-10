#!/usr/bin/env pwsh
# Installs the `chaincash` binary and default configuration on Windows.
#
#   irm https://raw.githubusercontent.com/BetterMoneyLabs/chaincash-rs/master/scripts/install/install.ps1 | iex
#
# Install a specific release:
#
#   $v="0.1.0"; irm https://raw.githubusercontent.com/BetterMoneyLabs/chaincash-rs/master/scripts/install/install.ps1 | iex
#
# Environment variables:
#   CHAINCASH_INSTALL      install prefix, the binary goes in "$env:CHAINCASH_INSTALL\bin" (default: ~\.local)
#   CHAINCASH_REPO         GitHub repository to download releases from (default: BetterMoneyLabs/chaincash-rs)
#   CHAINCASH_RELEASE_URL  base URL of release assets, overrides CHAINCASH_REPO (mainly for testing)
#   XDG_CONFIG_HOME        config is written to "$env:XDG_CONFIG_HOME\chaincash" (default: ~\.config\chaincash)
#
# Inspired by https://github.com/nautls/ergomatic/tree/main/scripts/install

$ErrorActionPreference = 'Stop'

if ($v) {
  $Version = $v
}
if ($Args.Length -eq 1) {
  $Version = $Args.Get(0)
}
if ($Version) {
  $Version = "${Version}"
}
if ($Version -and !$Version.StartsWith('v')) {
  $Version = "v${Version}"
}

$Repo = if ($env:CHAINCASH_REPO) { $env:CHAINCASH_REPO } else { 'BetterMoneyLabs/chaincash-rs' }
$ReleaseUrl = if ($env:CHAINCASH_RELEASE_URL) {
  $env:CHAINCASH_RELEASE_URL
} elseif (!$Version) {
  "https://github.com/${Repo}/releases/latest/download"
} else {
  "https://github.com/${Repo}/releases/download/${Version}"
}

$Target = 'x86_64-pc-windows-msvc'
$Asset = "chaincash-${Target}.exe"

$InstallPrefix = if ($env:CHAINCASH_INSTALL) { $env:CHAINCASH_INSTALL } else { "${Home}\.local" }
# resolve relative to the current PowerShell location (GetFullPath would use the process directory)
$InstallPrefix = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallPrefix)
$BinDir = "${InstallPrefix}\bin"
$ChaincashExe = "${BinDir}\chaincash.exe"

# must match `config_dir()` in crates/chaincash_app/src/lib.rs
$ConfigDir = if ($env:XDG_CONFIG_HOME -and [System.IO.Path]::IsPathRooted($env:XDG_CONFIG_HOME)) {
  "$env:XDG_CONFIG_HOME\chaincash"
} else {
  "${Home}\.config\chaincash"
}
$DataDir = if ($env:LOCALAPPDATA) { "$env:LOCALAPPDATA\chaincash" } else { "${Home}\.local\share\chaincash" }
$ConfigFile = "${ConfigDir}\config.toml"
$PredicatesDir = "${ConfigDir}\predicates"
$ExamplePredicate = "${PredicatesDir}\example.toml"

$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("chaincash-" + [System.Guid]::NewGuid())
New-Item $TmpDir -ItemType Directory | Out-Null

function Get-Asset($Name) {
  $Out = "${TmpDir}\${Name}"
  curl.exe --fail --silent --show-error --location --output $Out "${ReleaseUrl}/${Name}"
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to download ${ReleaseUrl}/${Name}"
  }
  $Out
}

function Test-Checksum($Name, $Path) {
  $Line = Get-Content "${TmpDir}\SHA256SUMS" | Where-Object { ($_ -split '\s+')[1] -in @($Name, "*${Name}") }
  if (!$Line) {
    throw "No checksum for ${Name} in SHA256SUMS"
  }
  $Expected = ($Line -split '\s+')[0]
  $Actual = (Get-FileHash $Path -Algorithm SHA256).Hash
  if ($Actual -ne $Expected) {
    throw "Checksum mismatch for ${Name} (expected ${Expected}, got ${Actual})"
  }
}

try {
  # install binary
  Write-Output "Downloading chaincash $(if ($Version) { $Version } else { '(latest)' }) for ${Target}..."
  Get-Asset 'SHA256SUMS' | Out-Null
  $Downloaded = Get-Asset $Asset
  Test-Checksum $Asset $Downloaded

  New-Item $BinDir -ItemType Directory -Force | Out-Null
  Move-Item $Downloaded $ChaincashExe -Force
  Write-Output "Installed binary to ${ChaincashExe}"

  # install configuration, existing files are never overwritten
  New-Item $PredicatesDir -ItemType Directory -Force | Out-Null
  New-Item $DataDir -ItemType Directory -Force | Out-Null

  if (Test-Path $ExamplePredicate) {
    Write-Output "Keeping existing predicate ${ExamplePredicate}"
  } else {
    $Predicate = Get-Asset 'predicate-example.toml'
    Test-Checksum 'predicate-example.toml' $Predicate
    Move-Item $Predicate $ExamplePredicate
    Write-Output "Installed example predicate to ${ExamplePredicate}"
  }

  if (Test-Path $ConfigFile) {
    Write-Output "Keeping existing config ${ConfigFile}"
  } else {
    $Config = @"
# ChainCash server configuration.
#
# Values set here override the built-in defaults, see:
# https://github.com/${Repo}/blob/master/config/default.toml
# Environment variables override this file, e.g. CHAINCASH_NODE.API_KEY=...

[server]
url = "127.0.0.1"
port = 8080

[node]
url = "http://localhost:9053"
# API key of your Ergo node, prefer setting it with the CHAINCASH_NODE.API_KEY env var
api_key = "hello"

[store]
url = '${DataDir}\chaincash.sqlite'

[acceptance]
# paths to predicate configuration files
# if ANY of these evaluate to true a note will be accepted
predicates = ['${ExamplePredicate}']
"@
    # write UTF-8 without a BOM, which Windows PowerShell's Set-Content would add
    [System.IO.File]::WriteAllText($ConfigFile, $Config)
    Write-Output "Installed config to ${ConfigFile}"
  }
} finally {
  Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

# add the bin directory to the user's PATH
$User = [System.EnvironmentVariableTarget]::User
$Path = [System.Environment]::GetEnvironmentVariable('Path', $User)
if (!(";${Path};".ToLower() -like "*;${BinDir};*".ToLower())) {
  [System.Environment]::SetEnvironmentVariable('Path', "${Path};${BinDir}", $User)
  $Env:Path += ";${BinDir}"
  Write-Output "Added ${BinDir} to your PATH, restart your terminal for it to take effect"
}

Write-Output ""
Write-Output "chaincash was installed successfully"
& $ChaincashExe --version
Write-Output "Run 'chaincash run' to start the server"
Write-Output "Edit ${ConfigFile} to configure your Ergo node and acceptance predicates."
