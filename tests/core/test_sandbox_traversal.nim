discard """
  The in-process path gate (checkRawPath) must resolve the raw tool
  path the same way the OS backends do: absolute + normalizedPath +
  symlink resolution. Without it, `<proj>/sub/../../etc/passwd` still
  starts with the project prefix as a raw string, so isPathUnder
  accepts it and the read/write/patch tools escape the policy while
  the box subprocess (which canonicalizes via sandwall normalize)
  would have blocked the same path.

  checkRawPath reloads the policy via getCurrentDir(), so each test
  chdirs into the fixture project dir (restoring cwd on teardown) to
  load that project's own policy, not whatever repo the suite runs in.
"""
import std/[unittest, os, strutils]
import threecode/sandbox

proc newFixture(name: string): tuple[home, proj: string] =
  ## Isolated XDG config home + project dir whose repo policy allows
  ## only itself, so nothing outside the project is reachable no matter
  ## where the temp dir sits.
  let base = getTempDir() / ("3code_travtest_" & name & "_" & $getCurrentProcessId())
  if dirExists(base): removeDir(base)
  result = (base / "xdg", base / "proj")
  createDir(result.home)
  createDir(result.proj / "sub")
  putEnv("XDG_CONFIG_HOME", result.home)
  writeFile(result.proj / ".sandbox", "deny /\nallow ./\n")

proc enterProj(proj: string) =
  putEnv("XDG_CONFIG_HOME", "")
  setCurrentDir(proj)

proc leaveProj(prev: string) =
  setCurrentDir(prev)

suite "checkRawPath traversal":
  test "project allow, ../.. escape denied":
    let (home, proj) = newFixture("escape")
    let prevCwd = getCurrentDir()
    defer: leaveProj(prevCwd)
    enterProj(proj)
    let wasActive = sandbox.active
    let saved = sandbox.current
    sandbox.active = true
    try:
      sandbox.current = sandbox.loadPolicy(proj)
      # `/` would lexically collapse the `..` components at join time;
      # the raw string must reach the gate unnormalized, as a model
      # tool call would send it.
      let esc = proj & "/sub/../../../etc/passwd"
      let r = sandbox.checkRawPath(esc, needsWrite = false)
      check not r.allowed
      check "denied" in r.reason
      # plain in-project path still allowed (write: under the project root)
      check sandbox.checkRawPath(proj / "sub" / "x.txt",
                                 needsWrite = true).allowed
    finally:
      sandbox.active = wasActive
      sandbox.current = saved
      removeDir(home.parentDir)

  test "path through a symlinked dir pointing outside is denied":
    when defined(posix):
      # symlink resolution: the deepest existing ancestor of the write
      # target resolves through `out` to outside the project.
      let (home, proj) = newFixture("symlink")
      let prevCwd = getCurrentDir()
      defer: leaveProj(prevCwd)
      let outside = proj.parentDir / "outside"
      createDir(outside)
      createSymlink(outside, proj / "sub" / "out")
      enterProj(proj)
      let wasActive = sandbox.active
      let saved = sandbox.current
      sandbox.active = true
      try:
        sandbox.current = sandbox.loadPolicy(proj)
        let r = sandbox.checkRawPath(proj / "sub" / "out" / "secret.txt",
                                     needsWrite = true)
        check not r.allowed
        check "denied" in r.reason
      finally:
        sandbox.active = wasActive
        sandbox.current = saved
        removeDir(home.parentDir)
