## Shared fixture builder for the plugin tests: compiles the fixture and
## bad-ABI .so files into a redirected XDG data root, plus the log-file
## conventions the fixture plugin reads (TC_FIXTURE_LOG / TC_FIXTURE_MODE).
import std/[os, strutils, times]

proc pluginFixtureName*(stem: string): string =
  when defined(windows): stem & ".dll"
  elif defined(macosx): stem & ".dylib"
  else: stem & ".so"

proc buildPluginFixtures*(dataRoot: string) =
  ## Build both fixture libs into `<dataRoot>/3code/lib` (dataRoot is the
  ## XDG_DATA_HOME value the test redirects to).
  let libdir = dataRoot / "3code" / "lib"
  createDir(libdir)
  let cwd = getCurrentDir()
  proc build(src, outp: string) =
    let cmd = "nim c --noNimblePath --mm:orc --threads:on " &
      "-d:release -p:" & cwd / "src -p:" & cwd / "tests " &
      "--app:lib -o:" & outp & " " & src
    let rc = execShellCmd(cmd)
    doAssert rc == 0, "fixture build failed: " & cmd
  let stamp = libdir / ".built"
  if fileExists(stamp):
    var stale = false
    for f in [cwd / "tests" / "testdata" / "plugin_fixture.nim",
              cwd / "tests" / "testdata" / "plugin_badabi.nim",
              cwd / "src" / "threecode" / "pluginabi.nim",
              cwd / "src" / "threecode" / "plugin_sdk.nim",
              cwd / "src" / "threecode" / "plugins.nim"]:
      if getLastModificationTime(f) > getLastModificationTime(stamp):
        stale = true
    if not stale: return
  build(cwd / "tests" / "testdata" / "plugin_fixture.nim",
        libdir / pluginFixtureName("plugin_fixture"))
  build(cwd / "tests" / "testdata" / "plugin_badabi.nim",
        libdir / pluginFixtureName("plugin_badabi"))
  writeFile(stamp, "ok")

proc pluginLogLines*(logPath: string): seq[string] =
  if not fileExists(logPath): return @[]
  readFile(logPath).strip.splitLines

proc pluginWaitForLog*(logPath: string;
                       pred: proc (l: string): bool; timeoutMs = 3000): bool =
  ## Async hooks land on the plugin thread; poll the fixture log.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    for l in pluginLogLines(logPath):
      if pred(l): return true
    sleep(20)
  false

proc pluginResetLog*(logPath: string) =
  if fileExists(logPath): removeFile(logPath)
