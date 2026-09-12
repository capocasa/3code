## Shared incremental build preparation. config.nims/nimble.paths own dependency
## resolution; no per-test nimble solver or incomplete source-mtime cache.
import std/[os, osproc, strutils, sha1]

proc nimbleDepFlags*(): string =
  ## Out-of-tree probes must explicitly load the project's dependency paths.
  ## `nimble.paths` is a `nimble setup` artifact: present in a dev tree, but
  ## absent in CI, which installs deps into the default nimble path (found by
  ## name without any flags). Only inject flags when the file is there.
  let paths = getCurrentDir() / "nimble.paths"
  if not fileExists(paths):
    return ""
  for line in readFile(paths).splitLines:
    let arg = line.strip
    if arg.startsWith("--path:\"") and arg.endsWith("\""):
      result.add " " & quoteShell("--path:" & arg[8 ..< arg.len - 1])
    elif arg.len > 0:
      result.add " " & quoteShell(arg)

proc buildBinary*(defines, outName: string; forceRebuild = false): string =
  # Different options must never replace a binary another test is using.
  let tag = ($secureHash(defines))[0..15].toLowerAscii
  result = getCurrentDir() / "build" / (outName & "_" & tag)
  when defined(windows): result.add ".exe"
  var cmd = "sh tools/build_binary.sh " & result.quoteShell &
    " src/threecode.nim " & defines
  if forceRebuild: cmd.add " --forceBuild:on"
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, output

proc ensureStubBinary*(extraDefines = "", forceRebuild = false): string =
  ## Cross-compiled runners can inject a prebuilt binary when Nim is absent.
  let prebuilt = getEnv("THREECODE_TEST_STUB_BINARY")
  if prebuilt.len > 0:
    doAssert fileExists(prebuilt), "Missing prebuilt stub: " & prebuilt
    return prebuilt
  buildBinary("-d:ssl -d:providerStub --threads:on " & extraDefines,
    "3code_stub", forceRebuild)
