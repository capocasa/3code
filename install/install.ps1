# 3code installer for Windows (PowerShell). Recommended (download, read, then run):
#   irm https://3code.capocasa.dev/install.ps1 -OutFile install.ps1
#   notepad install.ps1      # see for yourself what it does
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
# Or in one line, if you don't mind piping:
#   irm https://3code.capocasa.dev/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://3code.capocasa.dev/install.ps1))) "your first prompt"

# Versioned here; the site deploy (3code.capocasa.dev, rsynced by its
# publish.nims) serves the copy at https://3code.capocasa.dev/install.ps1.

$ErrorActionPreference = "Stop"

$Repo       = "capocasa/3code"
$BinName    = "3code.exe"
$Asset      = "3code-windows-amd64.zip"
$InstallDir = if ($env:THREECODE_INSTALL_DIR) { $env:THREECODE_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "3code\bin" }

function Info($m) { Write-Host "==> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "warning: $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "error: $m" -ForegroundColor Red; exit 1 }

if ([Environment]::Is64BitOperatingSystem -ne $true) {
  Die "only 64-bit Windows is supported"
}

Info "resolving latest release"
try {
  $req = [Net.HttpWebRequest]::Create("https://github.com/$Repo/releases/latest")
  $req.Method = "HEAD"
  $req.AllowAutoRedirect = $true
  $resp = $req.GetResponse(); $resp.Close()
  $tag = $resp.ResponseUri.Segments[-1].TrimEnd('/')
} catch {
  Die "could not resolve latest release: $_"
}
if (-not $tag) { Die "could not determine latest release tag" }

$url  = "https://github.com/$Repo/releases/download/$tag/$Asset"
$tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ("3code-install-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
  $zip = Join-Path $tmp $Asset
  Info "downloading $Asset ($tag)"
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip

  # verify the archive against the SHASUMS256.txt published with the
  # release, so what lands in PATH is what was built
  $sums = $null
  try {
    $sums = (Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/releases/download/$tag/SHASUMS256.txt").Content
  } catch { }
  if ($sums) {
    $want = $null
    foreach ($line in ($sums -split "`n")) {
      $parts = $line -split '\s+', 2
      if ($parts.Count -eq 2 -and $parts[1].Trim() -eq $Asset) { $want = $parts[0].Trim() }
    }
    if (-not $want) { Die "no checksum line for $Asset in SHASUMS256.txt" }
    $got = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLower()
    if ($got -ne $want.ToLower()) { Die "checksum mismatch for ${Asset}: expected $want, got $got" }
    Info "checksum verified"
  } elseif ($env:THREECODE_ALLOW_UNVERIFIED -eq "1") {
    Warn "no SHASUMS256.txt published for $tag; installing unverified (THREECODE_ALLOW_UNVERIFIED=1)"
  } else {
    Die ("no SHASUMS256.txt published for $tag (the release predates published checksums)." +
         " set THREECODE_ALLOW_UNVERIFIED=1 to install anyway")
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
