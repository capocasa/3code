## Near-silent auto-update. Mimics Claude Code's UX:
##
## - On launch, fork a fully detached worker (`<exe> --self-update-check`)
##   that polls the GitHub releases API, downloads the matching tarball,
##   and atomically swaps the running binary's path. The current process
##   keeps using the old inode; the next launch picks up the new one.
## - Throttled so we hit the API at most once per 4h.
## - On the first launch after a swap, print one dim line on stderr.
##
## The build-time default is **off** — source-installed binaries
## (`nimble install`) shouldn't quietly self-replace what the user just
## built. CI passes `-d:autoUpdate` for prebuilt release binaries, which
## flips the default on. Either way, an explicit `auto_update =
## "true"`/`"false"` under `[settings]` in `~/.config/3code/config`
## wins.

import std/[json, os, parsecfg, parseutils, strutils, terminal, times]
import prompts, util

const autoUpdate {.booldefine.} = false

const
  Repo = "capocasa/3code"
  ThrottleSecs = 4 * 60 * 60

proc dbgLog(stage: string) =
  ## Append a timestamped line to `$THREECODE_UPDATE_LOG` if set.
  ## No-op otherwise. Inherits across `execv` so the grandchild's trace
  ## lands in the same file as the parent's. Diagnostic only — there is
  ## no release-mode use of this.
  let path = getEnv("THREECODE_UPDATE_LOG")
  if path.len == 0: return
  try:
    let f = open(path, fmAppend)
    defer: f.close()
    f.writeLine($epochTime().int & " [" & $getCurrentProcessId() & "] " & stage)
  except CatchableError: discard

const Tarball =
  when defined(linux) and (defined(amd64) or defined(x86_64)):
    "3code-linux-amd64.tar.gz"
  elif defined(macosx):
    "3code-macos-universal.tar.gz"
  else:
    ""  # unsupported platform — no auto-update

proc autoUpdateEnabled*(): bool =
  ## Resolution: explicit config value wins; otherwise fall back to the
  ## build-time default. Read `parsecfg` directly so the update path
  ## doesn't drag in the rest of the config machinery.
  let path = userConfigRoot() / "config"
  if fileExists(path):
    try:
      let cfg = loadConfig(path)
      let v = cfg.getSectionValue("settings", "auto_update").strip.toLowerAscii
      if v in ["true", "yes", "on", "1"]: return true
      if v in ["false", "no", "off", "0"]: return false
    except CatchableError: discard
  autoUpdate

proc lastVersionMarker(): string = userDataRoot() / "last-version"
proc updateCheckMarker(): string = userDataRoot() / "last-update-check"

proc parseSemver*(s: string): seq[int] =
  var t = s.strip
  if t.len > 0 and t[0] == 'v': t = t[1 .. ^1]
  for part in t.split('.'):
    var n = 0
    discard parseutils.parseInt(part, n, 0)
    result.add n

proc semverGt*(a, b: string): bool =
  let pa = parseSemver(a)
  let pb = parseSemver(b)
  for i in 0 ..< max(pa.len, pb.len):
    let av = if i < pa.len: pa[i] else: 0
    let bv = if i < pb.len: pb[i] else: 0
    if av != bv: return av > bv
  false

proc throttleExpired(): bool =
  let path = updateCheckMarker()
  if not fileExists(path): return true
  try:
    let ts = readFile(path).strip.parseFloat
    return epochTime() - ts > ThrottleSecs.float
  except CatchableError:
    return true

proc touchThrottle() =
  try:
    createDir(userDataRoot())
    writeFile(updateCheckMarker(), $epochTime())
  except CatchableError: discard

proc fetchLatestTag(): string =
  let r = curlRequest("https://api.github.com/repos/" & Repo &
                      "/releases/latest",
                      userAgent = "3code-update", timeoutSec = 10)
  if r.err.len > 0 or r.status div 100 != 2: return ""
  try:
    let j = parseJson(r.body)
    return j{"tag_name"}.getStr("")
  except CatchableError:
    return ""

proc downloadAsset(tag, asset, dest: string): bool =
  let url = "https://github.com/" & Repo & "/releases/download/" &
            tag & "/" & asset
  let r = curlRequest(url, userAgent = "3code-update", outFile = dest,
                      timeoutSec = 60)
  r.err.len == 0 and r.status div 100 == 2 and
    fileExists(dest) and getFileSize(dest) > 0

proc extractTarball(tar, workDir: string): string =
  ## Extract `tar` into `workDir` (wiped first). Return path to the
  ## extracted `3code` binary, or "" if not found.
  try: removeDir(workDir) except CatchableError: discard
  try: createDir(workDir) except CatchableError: return ""
  let rc = execShellCmd("tar -xzf " & quoteShell(tar) & " -C " &
                        quoteShell(workDir))
  if rc != 0: return ""
  for f in walkDirRec(workDir):
    if f.extractFilename == "3code":
      return f
  ""

proc swapBinary(newBin, dest: string): bool =
  ## Replace `dest` with `newBin`. Stage as `<dest>.new` in the same
  ## directory (same filesystem, so the final rename is a real atomic
  ## `rename(2)`), then rename over `dest`. Works on a busy executable
  ## on Linux/macOS — the running process keeps its old inode.
  let stage = dest & ".new"
  let perm = {fpUserRead, fpUserWrite, fpUserExec,
              fpGroupRead, fpGroupExec,
              fpOthersRead, fpOthersExec}
  try:
    copyFile(newBin, stage)
    setFilePermissions(stage, perm)
    moveFile(stage, dest)
    return true
  except CatchableError:
    try: removeFile(stage) except CatchableError: discard
    return false

proc selfUpdateCheck*(curVersion = Version, targetPath = "",
                      force = false) =
  ## Worker entry point. Runs in the detached background process.
  ## Strictly silent — never writes to stdout/stderr.
  ##
  ## `curVersion` / `targetPath` exist for tests: they spoof the
  ## "running version" and the binary path so the live pipeline can be
  ## exercised without affecting the installed binary. `force` skips
  ## the config gate (tests + manual invocation override).
  dbgLog("selfUpdateCheck enter cur=" & curVersion & " force=" & $force)
  if not force and not autoUpdateEnabled():
    dbgLog("selfUpdateCheck gate=disabled"); return
  if Tarball.len == 0:
    dbgLog("selfUpdateCheck tarball=empty"); return
  let latest = fetchLatestTag()
  dbgLog("selfUpdateCheck latest=" & latest)
  if latest.len == 0: return
  if not semverGt(latest, curVersion):
    dbgLog("selfUpdateCheck not-newer"); return
  let cache = userDataRoot() / "update"
  try: createDir(cache)
  except CatchableError as e:
    dbgLog("selfUpdateCheck mkdir-failed " & e.msg); return
  let tarPath = cache / Tarball
  if not downloadAsset(latest, Tarball, tarPath):
    dbgLog("selfUpdateCheck download-failed " & tarPath); return
  dbgLog("selfUpdateCheck downloaded size=" & $getFileSize(tarPath))
  let extractDir = cache / "extract"
  let bin = extractTarball(tarPath, extractDir)
  if bin.len == 0:
    dbgLog("selfUpdateCheck extract-failed"); return
  let dest = if targetPath.len > 0: targetPath else: getAppFilename()
  let ok = swapBinary(bin, dest)
  dbgLog("selfUpdateCheck swap=" & $ok & " dest=" & dest)
  try: removeFile(tarPath) except CatchableError: discard
  try: removeDir(extractDir) except CatchableError: discard

when defined(posix):
  import std/posix

  proc spawnBackgroundUpdateMaybe*() =
    ## Double-fork + setsid so the worker survives the parent exiting and
    ## SIGHUP from the controlling terminal. Throttle is claimed before
    ## the fork so concurrent launches don't pile up.
    dbgLog("spawn enter")
    if not autoUpdateEnabled() or Tarball.len == 0:
      dbgLog("spawn gate=disabled-or-noplatform"); return
    if not throttleExpired():
      dbgLog("spawn throttled"); return
    touchThrottle()
    let pid = posix.fork()
    if pid < 0:
      dbgLog("spawn fork1-failed"); return
    if pid > 0:
      var status: cint
      discard posix.waitpid(pid, status, 0)
      dbgLog("spawn parent waitpid done")
      return
    dbgLog("spawn child1 setsid")
    discard posix.setsid()
    let pid2 = posix.fork()
    if pid2 < 0:
      dbgLog("spawn fork2-failed"); quit(1)
    if pid2 > 0:
      dbgLog("spawn intermediate exit")
      quit(0)
    dbgLog("spawn grandchild dup2")
    let fd = posix.open("/dev/null", O_RDWR)
    if fd >= 0:
      discard posix.dup2(fd, 0)
      discard posix.dup2(fd, 1)
      discard posix.dup2(fd, 2)
      if fd > 2: discard posix.close(fd)
    let exe = getAppFilename()
    dbgLog("spawn grandchild execv " & exe)
    let argv = allocCStringArray([exe, "--self-update-check"])
    let rc = posix.execv(exe.cstring, argv)
    dbgLog("spawn grandchild execv-returned rc=" & $rc & " errno=" & $errno)
    quit(1)
else:
  proc spawnBackgroundUpdateMaybe*() = discard

proc showUpdateNoticeMaybe*() =
  ## If the recorded last-seen version differs from the running version,
  ## emit one dim line on stderr and update the marker. First launch
  ## (no marker) is silent — only writes the marker.
  let marker = lastVersionMarker()
  var prev = ""
  if fileExists(marker):
    try: prev = readFile(marker).strip
    except CatchableError: discard
  if prev.len > 0 and prev != Version:
    try:
      stderr.styledWriteLine(styleDim,
        "  · updated to v" & Version, resetStyle)
    except CatchableError:
      try: stderr.writeLine "  · updated to v" & Version
      except CatchableError: discard
  if prev != Version:
    try:
      createDir(userDataRoot())
      writeFile(marker, Version)
    except CatchableError: discard
