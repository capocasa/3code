# 3code main-branch installer for Windows (PowerShell). Usage:
#   irm https://3code.capocasa.dev/main/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://3code.capocasa.dev/main/install.ps1))) "your first prompt"

# Versioned here; the site deploy (3code.capocasa.dev, rsynced by its
# publish.nims) serves the copy at https://3code.capocasa.dev/install.ps1.

$ErrorActionPreference = "Stop"

$BinName    = "3code.exe"
$Asset      = "3code-windows-amd64.zip"
$BaseUrl    = "https://3code.capocasa.dev/main/builds"
$InstallDir = if ($env:THREECODE_INSTALL_DIR) { $env:THREECODE_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "3code\bin" }

function Info($m) { Write-Host "==> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "warning: $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "error: $m" -ForegroundColor Red; exit 1 }

if ([Environment]::Is64BitOperatingSystem -ne $true) {
  Die "only 64-bit Windows is supported"
}

$url  = "$BaseUrl/$Asset"
$tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ("3code-install-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
  $zip = Join-Path $tmp $Asset
  Info "downloading $Asset (main)"
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip

  # verify against the .sha256 published next to the archive when the
  # build carried one (main builds publish them; old ones predate them)
  $want = $null
  try {
    # decode a byte[] Content (no text Content-Type on the wire), else
    # the -split joins the bytes with spaces and the hash never matches
    $resp = Invoke-WebRequest -UseBasicParsing -Uri "$url.sha256"
    $sumText = if ($resp.Content -is [byte[]]) {
      [Text.Encoding]::UTF8.GetString($resp.Content)
    } else {
      $resp.Content
    }
    $want = ($sumText -split '\s+')[0]
  } catch { }
  if ($want) {
    $got = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLower()
    if ($got -ne $want.ToLower()) { Die "checksum mismatch for ${Asset}: expected $want, got $got" }
    Info "checksum verified"
  } else {
    Warn "no checksum published for this main build; installing unverified"
  }

  Info "extracting"
  Expand-Archive -Path $zip -DestinationPath $tmp -Force

  $src = Get-ChildItem -Path $tmp -Recurse -Filter $BinName | Select-Object -First 1
  if (-not $src) { Die "binary '$BinName' not found inside archive" }

  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
  # Copy the full archive payload (exe + libssl/libcrypto DLLs + cacert.pem) so
  # the DLLs Nim's std/net LoadLibrarys at runtime sit next to 3code.exe.
  Copy-Item -Path (Join-Path $src.Directory.FullName "*") -Destination $InstallDir -Recurse -Force
  $dest = Join-Path $InstallDir $BinName
  Info "installed $dest"
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$onPath = ($userPath -split ";") -contains $InstallDir -or ($env:Path -split ";") -contains $InstallDir
if (-not $onPath) {
  Warn "$InstallDir is not in PATH"
  try {
    $newUser = if ([string]::IsNullOrEmpty($userPath)) { $InstallDir } else { "$userPath;$InstallDir" }
    [Environment]::SetEnvironmentVariable("Path", $newUser, "User")
    $env:Path = "$env:Path;$InstallDir"
    Info "added $InstallDir to your user PATH (open a new terminal to pick it up)"
    $onPath = $true
  } catch {
    Write-Host "  add manually:  setx Path `"%Path%;$InstallDir`""
  }
}

if ($args.Count -gt 0 -and $args[0]) {
  Info "running: $BinName --interactive $($args -join ' ')"
  & $dest "--interactive" @args
  exit $LASTEXITCODE
}

Write-Host ""
Write-Host "next:"
Write-Host "  mkdir myproject; cd myproject"
if ($onPath) {
  Write-Host "  3code"
} else {
  Write-Host "  $dest"
}
