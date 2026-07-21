## Shared helpers for tests that build a stubbed `3code` binary to drive
## through a PTY or as a subprocess.
##
## The stub binary is deterministic (fixed flags, same source), so we build it
## once into a stable path under `build/` and reuse it across every test that
## needs it. Previously each test recompiled its own copy keyed by PID with a
## throwaway cache, which was the single biggest runtime cost in the suite.

import std/[os, osproc, strutils, times]

proc nimbleDepPaths(): seq[string] =
  ## The dep include paths nimble injects, resolved the same way nimble does.
  ## The bare `nim c` the stub build uses needs these to find streamhttp,
  ## unicodedb, ttty, tinotify and nimbox, none of which sit on Nim's
  ## default path.
  for pkg in ["unicodedb", "streamhttp", "ttty", "tinotify", "nimbox"]:
    let (outp, code) = execCmdEx("nimble path " & pkg)
    if code == 0:
      let first = outp.splitLines()[0]
      if first.len > 0:
        result.add("--path:" & first)

proc nimbleDepFlags*(): string =
  ## Space-joined `--path:` flags for the nimble deps, suitable for splicing
  ## into a `nim c` command string built by a test (e.g. a probe that imports
  ## threecode and must resolve its transitive deps).
  result = nimbleDepPaths().join(" ")

proc buildBinary*(defines, outName: string; forceRebuild = false): string =
  ## Build a `3code` binary with an arbitrary `-d:` define set into
  ## `build/<outName>`, caching by name + mtime like `ensureStubBinary`.
  ## Used by tests that need a non-stub binary (e.g. the real-transport
  ## connect/stream tests that point at a local mock HTTP server).
  result = getCurrentDir() / "build" / outName
  if forceRebuild and fileExists(result):
    removeFile(result)
  if fileExists(result):
    let binMtime = getLastModificationTime(result)
    var stale = false
    for f in walkDirRec(getCurrentDir() / "src"):
      if f.endsWith(".nim") and getLastModificationTime(f) > binMtime:
        stale = true
        break
    if stale:
      removeFile(result)
  if fileExists(result):
    return
  createDir(result.parentDir)
  let cacheDir = getCurrentDir() / "build" / (outName & "_cache")
  createDir(cacheDir)
  var cmd = "nim c " & defines
  for p in nimbleDepPaths():
    cmd.add(" " & p)
  cmd.add(" --path:src")
  cmd.add(" --nimcache:" & cacheDir.quoteShell)
  cmd.add(" -o:" & result.quoteShell)
  cmd.add(" src/threecode.nim")
  let (outp, code) = execCmdEx(cmd)
  doAssert code == 0, outp

proc ensureStubBinary*(extraDefines = "", forceRebuild = false): string =
  ## Returns the path to a stub `3code` binary, building it once if missing.
  ##
  ## `extraDefines` is appended to the `-d:` set for tests that need an
  ## additional define beyond the standard provider stub flags. The output
  ## path encodes the define set, so different flag combinations do not share
  ## a binary. Call `forceRebuild` to discard a cached binary first.
  const baseDefines = "-d:ssl -d:providerStub --threads:on"
  let defines =
    if extraDefines.len > 0: baseDefines & " " & extraDefines
    else: baseDefines
  let tag =
    if extraDefines.len > 0: "_" & extraDefines.replace(" ", "_")
    else: ""
  result = getCurrentDir() / "build" / ("3code_stub" & tag)
  if forceRebuild and fileExists(result):
    removeFile(result)
  # Invalidate the cache when source is newer than the cached binary.
  # Without this, a source edit is silently ignored because the old binary
  # is reused, so tests run against stale code and fail for the wrong reason.
  if fileExists(result):
    let binMtime = getLastModificationTime(result)
    var stale = false
    for f in walkDirRec(getCurrentDir() / "src"):
      if f.endsWith(".nim") and getLastModificationTime(f) > binMtime:
        stale = true
        break
    if stale:
      removeFile(result)
  if fileExists(result):
    return
  createDir(result.parentDir)
  let cacheDir = getCurrentDir() / "build" / "stub_cache" & tag
  createDir(cacheDir)
  var cmd = "nim c " & defines
  for p in nimbleDepPaths():
    cmd.add(" " & p)
  cmd.add(" --path:src")
  cmd.add(" --nimcache:" & cacheDir.quoteShell)
  cmd.add(" -o:" & result.quoteShell)
  cmd.add(" src/threecode.nim")
  let (outp, code) = execCmdEx(cmd)
  doAssert code == 0, outp
