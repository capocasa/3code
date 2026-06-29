## Shared helpers for tests that shell out to `nim c` to compile a stub
## binary or a probe. Such subprocess compiles run from a temp working dir
## and don't inherit the project's config.nims / nimble path switches, so
## the transitive deps (streamhttp, unicodedb, ttty, tinotify) don't
## resolve. We inject them explicitly.
##
## `nimble path <pkg>` lists every installed version; passing all of them
## lets Nim resolve against the wrong (older) one. Pin to the exact version
## recorded in nimble.lock: pkgs2 dirs are named <pkg>-<ver>-<sha1>, so we
## keep only the install dir whose path ends with the locked sha1.

import std/[json, os, osproc, strutils]

const DepPackages = ["streamhttp", "unicodedb", "ttty", "tinotify"]

proc depPathFlags*(): string =
  let lockPath = getCurrentDir() / "nimble.lock"
  let pkgs = parseFile(lockPath)["packages"]
  result = ""
  for pkg in DepPackages:
    let sha = pkgs[pkg]["checksums"]["sha1"].getStr()
    let (outp, code) = execCmdEx("nimble path " & pkg.quoteShell)
    if code != 0:
      raise newException(OSError, "nimble path " & pkg & " failed: " & outp)
    var picked = ""
    for line in outp.strip().splitLines():
      if line.endsWith(sha):
        picked = line
        break
    if picked.len == 0:
      raise newException(OSError,
        "no installed " & pkg & " matches locked sha1 " & sha)
    result.add " --path:" & picked.quoteShell

proc nimBaseFlags*(): string =
  "-d:ssl -d:providerStub --path:src " & depPathFlags()

## Build a full 3code stub binary (threads on, quiet thresholds for tty
## tests) into a temp path and return it. Reuses the output if present.
proc compileStubBinary*(pid: string): string =
  result = getTempDir() / ("3code_tty_stub_" & pid)
  if fileExists(result):
    removeFile(result)
  let cacheDir = getTempDir() / ("3code_tty_stub_cache_" & pid)
  createDir(cacheDir)
  let cmd = "nim c -d:QuietThresholdMs=1000 --threads:on " & nimBaseFlags() &
    " --nimcache:" & cacheDir.quoteShell & " -o:" & result.quoteShell &
    " src/threecode.nim"
  let (outp, code) = execCmdEx(cmd)
  doAssert code == 0, outp
