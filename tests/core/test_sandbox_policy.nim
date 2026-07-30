discard """
  targets: "c"
"""
## Sandbox policy: single source of truth, seeding, and the implicit
## read-only guard. Exercises `ensureDefaultSandbox` (project file from
## `~/.3code/sandbox`, itself from the built-in default) and `loadPolicy`
## (repo file only, guard rule last, mtime reload) in temp fixtures.

import std/[os, strutils, times, unittest]
import threecode/sandbox

proc newFixture(name: string): tuple[home, proj: string] =
  let base = getTempDir() / ("3code_sbtest_" & name & "_" & $getCurrentProcessId())
  if dirExists(base): removeDir(base)
  result = (base / "home", base / "proj")
  createDir(result.home)
  createDir(result.proj)

proc withHome(home: string; body: proc()) =
  ## Redirect the home dir for the duration of `body`.
  let prev = getEnv("HOME")
  putEnv("HOME", home)
  try: body()
  finally: putEnv("HOME", prev)

suite "sandbox policy: single source of truth":
  test "ensureDefaultSandbox seeds project from user file, user from default":
    let (home, proj) = newFixture("seed")
    withHome(home):
      check ensureDefaultSandbox(proj)
      # Both files materialized, identical default contents.
      check fileExists(proj / PolicyDir / "sandbox")
      check fileExists(home / PolicyDir / "sandbox")
      check readFile(proj / PolicyDir / "sandbox") == defaultPolicyText()
      check readFile(home / PolicyDir / "sandbox") == defaultPolicyText()

  test "user file content wins for new projects":
    let (home, proj) = newFixture("custom")
    withHome(home):
      createDir(home / PolicyDir)
      writeFile(home / PolicyDir / "sandbox", "- /\n+ /\n")
      check ensureDefaultSandbox(proj)
      check readFile(proj / PolicyDir / "sandbox") == "- /\n+ /\n"

  test "existing project file is never overwritten":
    let (home, proj) = newFixture("keep")
    withHome(home):
      createDir(proj / PolicyDir)
      writeFile(proj / PolicyDir / "sandbox", "- /\n")
      check ensureDefaultSandbox(proj)
      check readFile(proj / PolicyDir / "sandbox") == "- /\n"

  test "loadPolicy reads only the repo file and appends the guard":
    let (home, proj) = newFixture("load")
    withHome(home):
      createDir(proj / PolicyDir)
      writeFile(proj / PolicyDir / "sandbox",
                "- /\n+ " & proj & "\n")
      let pol = loadPolicy(proj)
      # The repo file rules apply.
      check pol.checkPath(proj / "x") == akWritable
      check pol.checkPath("/etc/passwd") == akDeny
      # Guard: the policy file itself is read-only (last rule wins over
      # the writable project dir).
      check pol.checkPath(proj / PolicyDir / "sandbox") == akReadOnly

  test "guard wins over an allow rule inside the file":
    let (home, proj) = newFixture("guard")
    withHome(home):
      createDir(proj / PolicyDir)
      # Even an explicit writable rule for the policy file cannot widen
      # it: the implicit guard is appended after every file rule.
      writeFile(proj / PolicyDir / "sandbox",
                "+ " & (proj / PolicyDir / "sandbox") & "\n")
      let pol = loadPolicy(proj)
      check pol.checkPath(proj / PolicyDir / "sandbox") == akReadOnly

  test "reloadIfChanged picks up a mid-session edit":
    let (home, proj) = newFixture("reload")
    withHome(home):
      discard ensureDefaultSandbox(proj)
      active = true
      current = loadPolicy(proj)
      check not reloadIfChanged(proj)
      writeFile(proj / PolicyDir / "sandbox",
                "- /\n+ " & proj & "\n")
      # mtime granularity: force a newer stamp.
      let f = proj / PolicyDir / "sandbox"
      setLastModificationTime(f, getLastModificationTime(f) + times.initDuration(seconds = 2))
      check reloadIfChanged(proj)
      check current.checkPath(proj / "x") == akWritable
      active = false

  test "user file is never consulted as policy":
    let (home, proj) = newFixture("nocascade")
    withHome(home):
      discard ensureDefaultSandbox(proj)
      # Widen the user template after the project file exists: the
      # loaded policy must not change.
      writeFile(home / PolicyDir / "sandbox", "+ /\n")
      let pol = loadPolicy(proj)
      check pol.checkPath("/etc/passwd") == akDeny
