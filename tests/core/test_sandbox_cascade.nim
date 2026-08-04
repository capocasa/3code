discard """
  # The cascade concatenates a system level and a repo level (each falling
  # back to the built-in default when absent) and parses once. The parser
  # itself is exhaustively tested in sandwall's test_rules; these tests
  # cover the 3code-facing surface: the cascade semantics via
  # `parseCascaded` (re-exported from sandwall) and the mtime-driven
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

suite "sandbox cascade (parseCascaded)":
  test "both levels at default -> deny /, writable cwd":
    # Two default texts concatenate (- /, + /tmp, + each); the effective
    # access is decided by last-wins, so assert via checkPath, not raw rule
    # count.
    let s = parseCascaded(defaultPolicyText(), defaultPolicyText(), proj)
    check s.checkPath("/") == akDeny
    check s.checkPath(proj) == akWritable
    check s.checkPath(proj / "sub") == akWritable
    when not defined(windows):
      # POSIX default opens /tmp so the agent's throwaway scripts (directed
      # there by the system prompt) are writable out of the box.
      check s.checkPath("/tmp") == akWritable

  test "repo file only -> repo rules win for the paths it names":
    let s = parseCascaded(defaultPolicyText(), "allow " & opt & "\n", proj)
    check s.rules[^1].access == akWritable
    check s.rules[^1].path == opt
    # cwd stays writable (from the default).
    check s.checkPath(proj) == akWritable

  test "system file only -> system rules apply":
    let s = parseCascaded("readonly " & varDir & "\n", defaultPolicyText(), proj)
    check s.rules[0].access == akReadOnly
    check s.rules[0].path == varDir

  test "both -> system then repo concatenated; repo deny resets a system allow":
    let s = parseCascaded("allow " & opt & "\n", "deny " & opt & "\n", proj)
    check s.checkPath(opt) == akDeny

  test "repo can broaden beyond the system default":
    let s = parseCascaded(defaultPolicyText(), "allow " & opt & "\nreadonly " & varDir & "\n", proj)
    check s.checkPath(opt) == akWritable
    check s.checkPath(varDir) == akReadOnly

  test "sandboxEnabled default is on (types.nim contract)":
    # The gate lives in types.nim; assert the default so a future change
    # to the declaration is caught here, not in production.
    check sandboxEnabled == true

suite "policy reload (reloadIfChanged)":
  test "mtime change reloads the cascade":
    # Drive a real repo policy file: load, tighten it on disk, expect the
    # next reloadIfChanged to pick up the new rule. The system file is
    # global, so the repo rule is the one asserted (last-wins).
    let dir = getTempDir() / ("3code-reload-" & $getCurrentProcessId())
    createDir(dir)
    let repoFile = dir / ".sandboxrc"
    let target = (dir / "locked").normalizedPath
    writeFile(repoFile, "allow ./\n")
    let wasActive = sandbox.active
    let saved = sandbox.current
    sandbox.active = true
    try:
      sandbox.current = sandbox.loadCascaded(dir)
      check sandbox.current.checkPath(target) == akWritable
      check sandbox.reloadIfChanged(dir) == false
      # Tighten the policy and force a detectably newer mtime (filesystem
      # mtime granularity can exceed the test's runtime).
      writeFile(repoFile, "allow ./\ndeny ./locked\n")
      setLastModificationTime(repoFile, getTime() + 3.seconds)
      check sandbox.reloadIfChanged(dir) == true
      check sandbox.current.checkPath(target) == akDeny
      check sandbox.reloadIfChanged(dir) == false
    finally:
      sandbox.active = wasActive
      sandbox.current = saved
      removeDir(dir)

  test "gather mode appends allow rules for would-be denials":
    # checkRawPath with gather mode on: a denied path is permitted and
    # appended live to the repo policy as an `allow` rule. Toggling
    # gather off restores enforcement.
    let dir = getTempDir() / ("3code-gather-" & $getCurrentProcessId())
    createDir(dir)
    let repoFile = dir / ".sandboxrc"
    writeFile(repoFile, "deny /\nallow ./\n")
    let outside = (dir / ".." / "outside-gather").normalizedPath
    let wasActive = sandbox.active
    let saved = sandbox.current
    let savedEnabled = sandboxEnabled
    let savedGathering = sandbox.gathering
    sandbox.active = true
    sandboxEnabled = true
    try:
      sandbox.current = sandbox.loadCascaded(dir)
      let oldCwd = getCurrentDir()
      setCurrentDir(dir)
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
        sandbox.current = sandbox.loadCascaded(dir)
        let (okAfter, _) = sandbox.checkRawPath(outside, needsWrite = true)
        check okAfter
      finally:
        setCurrentDir(oldCwd)
    finally:
      sandbox.active = wasActive
      sandbox.current = saved
      sandboxEnabled = savedEnabled
      sandbox.gathering = savedGathering
      removeDir(dir)

  test "resolve surfaces narrowing denies (deny under an allow)":
    let s = parseCascaded("allow " & opt & "\n", "deny " & opt / "locked" & "\n", proj)
    let r = s.resolve()
    check r.writable == @[opt]
    check r.denied == @[opt / "locked"]
    # A deny for a path under no surviving allow is not carried.
    let s2 = parseCascaded("deny /\n", "deny " & opt & "\n", proj)
    check s2.resolve().denied.len == 0
