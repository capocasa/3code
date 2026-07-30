discard """
  # The policy has a single source of truth: the repo file
  # `.3code/sandbox`, always materialized at launch (seeded from
  # `~/.3code/sandbox`, itself seeded from the built-in default), with an
  # implicit read-only guard for the file itself appended last. The
  # parser itself is exhaustively tested in sandwall's test_rules; these
  # tests cover the 3code-facing surface: `loadPolicy` semantics and the
  # mtime-driven `reloadIfChanged` that picks up mid-session policy
  # edits.
"""
import std/[unittest, os, times]
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

suite "sandbox policy file (parsePolicy)":
  test "default text -> deny /, writable cwd":
    let s = parsePolicy(defaultPolicyText(), proj)
    check s.checkPath("/") == akDeny
    check s.checkPath(proj) == akWritable
    check s.checkPath(proj / "sub") == akWritable
    when not defined(windows):
      # POSIX default opens /tmp so the agent's throwaway scripts (directed
      # there by the system prompt) are writable out of the box.
      check s.checkPath("/tmp") == akWritable

  test "repo rules win by order":
    let s = parsePolicy("+ " & opt & "\n", proj)
    check s.rules[^1].access == akWritable
    check s.rules[^1].path == opt

  test "later deny resets an earlier allow":
    let s = parsePolicy("+ " & opt & "\n- " & opt & "\n", proj)
    check s.checkPath(opt) == akDeny

  test "broad allow with read-only narrowing":
    let s = parsePolicy("+ " & opt & "\n* " & varDir & "\n", proj)
    check s.checkPath(opt) == akWritable
    check s.checkPath(varDir) == akReadOnly

  test "sandboxEnabled default is on (types.nim contract)":
    # The gate lives in types.nim; assert the default so a future change
    # to the declaration is caught here, not in production.
    check sandboxEnabled == true

suite "policy reload (reloadIfChanged)":
  test "mtime change reloads the policy file":
    # Drive a real repo policy file: load, tighten it on disk, expect the
    # next reloadIfChanged to pick up the new rule.
    let dir = getTempDir() / ("3code-reload-" & $getCurrentProcessId())
    createDir(dir / ".3code")
    let repoFile = dir / ".3code" / "sandbox"
    let target = (dir / "locked").normalizedPath
    writeFile(repoFile, "+ ./\n")
    let wasActive = sandbox.active
    let saved = sandbox.current
    sandbox.active = true
    try:
      sandbox.current = sandbox.loadPolicy(dir)
      check sandbox.current.checkPath(target) == akWritable
      check sandbox.reloadIfChanged(dir) == false
      # Tighten the policy and force a detectably newer mtime (filesystem
      # mtime granularity can exceed the test's runtime).
      writeFile(repoFile, "+ ./\n- ./locked\n")
      setLastModificationTime(repoFile, getTime() + 3.seconds)
      check sandbox.reloadIfChanged(dir) == true
      check sandbox.current.checkPath(target) == akDeny
      check sandbox.reloadIfChanged(dir) == false
    finally:
      sandbox.active = wasActive
      sandbox.current = saved
      removeDir(dir)

  test "resolve surfaces narrowing denies (deny under an allow)":
    let s = parsePolicy("+ " & opt & "\n- " & opt / "locked" & "\n", proj)
    let r = s.resolve()
    check r.writable == @[opt]
    check r.denied == @[opt / "locked"]
    # A deny for a path under no surviving allow is not carried.
    let s2 = parsePolicy("- /\n- " & opt & "\n", proj)
    check s2.resolve().denied.len == 0

  test "guard pins the policy file read-only inside the loaded policy":
    # The implicit last rule keeps `.3code/sandbox` read-only even when
    # the file itself opens the whole project writable.
    let dir = getTempDir() / ("3code-guard-" & $getCurrentProcessId())
    createDir(dir / ".3code")
    writeFile(dir / ".3code" / "sandbox", "+ ./\n")
    let pol = sandbox.loadPolicy(dir)
    check pol.checkPath(dir / "x") == akWritable
    check pol.checkPath(dir / ".3code" / "sandbox") == akReadOnly
    removeDir(dir)
