discard """
  # Exactly one policy file is active: the repo `.wallrc` when it
  # exists, else the user file `~/.config/3code/wallrc` (initialized
  # from the built-in default on first run). Never a cascade. The parser
  # itself is exhaustively tested in sandwall's test_rules; these tests
  # cover the 3code-facing surface: file selection via `activePolicyPath`,
  # the copy-on-edit materialization in `appendRule`, and the mtime-driven
  # `reloadIfChanged` that picks up mid-session policy edits.
"""
import std/[unittest, os, times, strutils]
import threecode/sandbox
import threecode/types

# Use platform-appropriate absolute paths so the test is meaningful on
# both Unix and Windows. On Windows a bare "/opt" is not absolute (no
# drive letter), so policy path normalization would resolve it relative
# to cwd and the path assertions would fail.
when defined(windows):
  const opt = "C:\\opt"
  const varDir = "C:\\var"
  const proj = "C:\\proj"
else:
  const opt = "/opt"
  const varDir = "/var"
  const proj = "/proj"

proc newFixture(name: string): tuple[home, proj: string] =
  ## Isolated XDG config home + project dir; restores env on teardown
  ## via the caller's defer.
  let base = getTempDir() / ("3code_sbtest_" & name & "_" & $getCurrentProcessId())
  if dirExists(base): removeDir(base)
  result = (base / "xdg", base / "proj")
  createDir(result.home)
  createDir(result.proj)
  putEnv("XDG_CONFIG_HOME", result.home)

suite "single active policy file":
  test "default text denies root, keeps tmp and cwd writable":
    let s = parsePolicy(defaultPolicyText(), proj)
    check s.checkPath("/") == akDeny
    when defined(windows):
      check s.checkPath(getHomeDir() / "AppData" / "Local" / "Temp") == akWritable
      # No host rules: the AppContainer child gets its internet
      # capability only when the policy carries none.
      check s.resolve().hosts.len == 0
    else:
      # bash needs /tmp for heredocs (and the model drops scratch files
      # there by the system prompt) are writable out of the box.
      check s.checkPath("/tmp") == akWritable
      check s.checkPath("/var/tmp") == akWritable
      # Open network: the wildcard host rule passes all traffic
      # through the wall proxy.
      check s.resolve().hosts.len == 1

  test "repo file wins over the user file; never both":
    let (home, projDir) = newFixture("sel")
    defer:
      putEnv("XDG_CONFIG_HOME", "")
      removeDir(home.parentDir)
    check ensureUserPolicy()
    let userFile = home / "3code" / "wallrc"
    check fileExists(userFile)
    check readFile(userFile) == defaultPolicyText()
    # No repo file -> user file is active.
    check activePolicyPath(projDir) == userFile
    # Repo file appears -> it alone is active.
    writeFile(repoPolicyPath(projDir), "allow /\n")
    check activePolicyPath(projDir) == repoPolicyPath(projDir)

  test "appendRule materializes the repo file from the user file":
    let (home, projDir) = newFixture("edit")
    defer:
      putEnv("XDG_CONFIG_HOME", "")
      removeDir(home.parentDir)
    check ensureUserPolicy()
    let userFile = home / "3code" / "wallrc"
    writeFile(userFile, "deny /\nallow " & opt & "\n")
    let repoFile = repoPolicyPath(projDir)
    check not fileExists(repoFile)
    let oldCwd = getCurrentDir()
    setCurrentDir(projDir)
    try:
      check appendRule(repoFile, varDir, akReadOnly)
    finally:
      setCurrentDir(oldCwd)
    # The repo file starts from the user's baseline, then the new rule.
    let text = readFile(repoFile)
    check text.contains("allow " & opt)
    check text.contains("readonly " & varDir)
    # The user file is untouched by the repo edit.
    check readFile(userFile) == "deny /\nallow " & opt & "\n"

  test "wallEnabled default is on (types.nim contract)":
    # The gate lives in types.nim; assert the default so a future change
    # to the declaration is caught here, not in production.
    check wallEnabled == true

suite "policy reload (reloadIfChanged)":
  test "mtime change reloads the policy":
    # Drive a real repo policy file: load, tighten it on disk, expect the
    # next reloadIfChanged to pick up the new rule.
    let (home, projDir) = newFixture("reload")
    defer:
      putEnv("XDG_CONFIG_HOME", "")
      removeDir(home.parentDir)
    let repoFile = repoPolicyPath(projDir)
    let target = (projDir / "locked").normalizedPath
    writeFile(repoFile, "allow ./\n")
    let wasActive = sandbox.active
    let saved = sandbox.current
    sandbox.active = true
    try:
      sandbox.current = sandbox.loadPolicy(projDir)
      check sandbox.current.checkPath(target) == akWritable
      check not sandbox.reloadIfChanged(projDir)
      # mtime granularity: ensure the rewrite lands on a later tick.
      sleep(1100)
      writeFile(repoFile, "allow ./\ndeny " & target & "\n")
      check sandbox.reloadIfChanged(projDir)
      check sandbox.current.checkPath(target) == akDeny
    finally:
      sandbox.active = wasActive
      sandbox.current = saved

  test "gather mode appends allow rules for would-be denials":
    # checkRawPath in gather mode turns a denial into an allow and appends
    # to the repo policy as an `allow` rule (materializing it from the
    # user file first). Toggling gather off restores enforcement.
    let (home, projDir) = newFixture("gather")
    defer:
      putEnv("XDG_CONFIG_HOME", "")
      removeDir(home.parentDir)
    let repoFile = repoPolicyPath(projDir)
    writeFile(repoFile, "deny /\nallow ./\n")
    let outside = (projDir / ".." / "outside-gather").normalizedPath
    let wasActive = sandbox.active
    let saved = sandbox.current
    let savedEnabled = wallEnabled
    let savedGathering = sandbox.gathering
    sandbox.active = true
    wallEnabled = true
    try:
      sandbox.current = sandbox.loadPolicy(projDir)
      let oldCwd = getCurrentDir()
      setCurrentDir(projDir)
      try:
        # Enforcement on: denied.
        let (okNo, _) = sandbox.checkRawPath(outside, needsWrite = true)
        check not okNo
        check outside notin readFile(repoFile)
        # Gather on: allowed, rule appended live.
        sandbox.gathering = true
        let (okG, _) = sandbox.checkRawPath(outside, needsWrite = true)
        check okG
        check ("allow " & outside) in readFile(repoFile)
        # Gather off: enforcement resumes; the gathered rule now covers
        # the path so it stays allowed.
        sandbox.gathering = false
        sandbox.current = sandbox.loadPolicy(projDir)
        let (okAfter, _) = sandbox.checkRawPath(outside, needsWrite = true)
        check okAfter
      finally:
        setCurrentDir(oldCwd)
    finally:
      sandbox.active = wasActive
      sandbox.current = saved
      wallEnabled = savedEnabled
      sandbox.gathering = savedGathering

  test "resolve surfaces narrowing denies (deny under an allow)":
    let s = parsePolicy("allow " & opt & "\ndeny " & opt / "locked" & "\n", proj)
    let r = s.resolve()
    check r.writable == @[opt]
    check r.denied == @[opt / "locked"]
    # A deny for a path under no surviving allow is not carried...
    # unless it narrows a backend baseline root (macOS baselineRead
    # includes /opt, so there it must be carried through).
    let s2 = parsePolicy("deny /\ndeny " & opt & "\n", proj)
    when defined(macosx):
      check s2.resolve().denied == @[opt]
    else:
      check s2.resolve().denied.len == 0
