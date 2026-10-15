discard """
  # The ask verb's in-process half (coverage decisions, denial-path
  # extraction, the ask rule root, and the grant that rewrites the
  # active policy file). The interactive half, meaning question
  # rendering, key capture and the retry, is pty-level and covered by
  # the tty suite; these tests pin the pure logic it sits on.
  #
  # checkRawPath and friends reload the policy via getCurrentDir(), so
  # each test chdirs into its fixture project and restores cwd on
  # teardown, like test_sandbox_traversal.
"""
import std/[unittest, os, strutils]
import threecode/sandbox

proc newFixture(name: string): tuple[base, proj: string] =
  let base = getTempDir() / ("3code_asktest_" & name & "_" & $getCurrentProcessId())
  if dirExists(base): removeDir(base)
  result = (base, base / "proj")
  createDir(result.proj / "vault")
  createDir(result.proj / "locked")
  writeFile(result.proj / "vault" / "k.txt", "x")
  writeFile(result.proj / ".sandbox",
    "deny /\nallow ./\nask ./vault\ndeny ./locked\n")

proc enterProj(proj: string) =
  setCurrentDir(proj)

template withPolicy(proj: string; body: untyped) =
  # Inlined (template) so unittest's `check` macros keep the enclosing
  # test's status context; a closure would break them.
  let prevCwd = getCurrentDir()
  let wasActive = sandbox.active
  let saved = sandbox.current
  enterProj(proj)
  sandbox.active = true
  sandbox.current = sandbox.loadPolicy(proj)
  try:
    body
  finally:
    sandbox.active = wasActive
    sandbox.current = saved
    setCurrentDir(prevCwd)

suite "ask coverage":
  test "ask-covered path, hard deny, and unmentioned path":
    let (base, proj) = newFixture("coverage")
    defer: removeDir(base)
    withPolicy(proj):
      check sandbox.askCoveredPath(proj / "vault" / "k.txt")
      check sandbox.askCoveredPath("vault/k.txt")
      # a hard deny and the deny-by-default fallthrough never ask
      check not sandbox.askCoveredPath(proj / "locked" / "x")
      check not sandbox.askCoveredPath("/etc/passwd")
      # writable paths are not asks
      check not sandbox.askCoveredPath(proj / "plain.txt")

  test "ask denies reads and writes at the in-process gate":
    let (base, proj) = newFixture("gate")
    defer: removeDir(base)
    withPolicy(proj):
      let wr = sandbox.checkRawPath(proj / "vault" / "k.txt", needsWrite = true)
      check not wr.allowed
      check "denied" in wr.reason
      let rd = sandbox.checkRawPath(proj / "vault" / "k.txt", needsWrite = false)
      check not rd.allowed

suite "denied path extraction":
  test "redirect mutation target wins":
    let (base, proj) = newFixture("mut")
    defer: removeDir(base)
    withPolicy(proj):
      let p = sandbox.deniedAskPath(
        "echo hi > vault/new.txt",
        "sh: line 1: vault/new.txt: Permission denied\n")
      check p == "vault/new.txt"

  test "scraped from coreutils-style error lines":
    let (base, proj) = newFixture("scrape")
    defer: removeDir(base)
    withPolicy(proj):
      check sandbox.deniedAskPath("somecmd",
        "touch: cannot touch '" & proj / "vault" / "t" &
        "': Permission denied\n") == proj / "vault" / "t"
      check sandbox.deniedAskPath("cp a b",
        "cp: cannot create regular file '" & proj / "vault" / "c" &
        "': Permission denied\n") == proj / "vault" / "c"
      # a denial whose path is NOT ask-covered (hard deny or elsewhere)
      # yields nothing: the ask flow must not fire
      check sandbox.deniedAskPath("touch x",
        "touch: cannot touch '" & proj / "locked" / "x" &
        "': Permission denied\n") == ""

  test "no path in the output, no ask":
    let (base, proj) = newFixture("nopath")
    defer: removeDir(base)
    withPolicy(proj):
      check sandbox.deniedAskPath("mystery", "EACCES\n") == ""
      check sandbox.deniedAskPath("mystery", "denied\n") == ""

suite "ask rule root":
  test "last covering ask rule is the root":
    let (base, proj) = newFixture("root")
    defer: removeDir(base)
    withPolicy(proj):
      check sandbox.askRuleRoot(proj / "vault" / "k.txt") ==
        expandFilename(proj / "vault")
      # relative form resolves the same (expandFilename: macOS temp dirs
      # live behind a /var -> /private/var symlink the rule walk resolves)
      check sandbox.askRuleRoot("vault/sub/deep.txt") ==
        expandFilename(proj / "vault")

suite "grant":
  test "grant appends allow to the active file and flips the gate":
    let (base, proj) = newFixture("grant")
    defer: removeDir(base)
    withPolicy(proj):
      let root = sandbox.askRuleRoot(proj / "vault" / "k.txt")
      check sandbox.grantAskAllow(root)
      # file rewritten: ask replaced by allow for that target
      let text = readFile(proj / ".sandbox")
      check "allow ./vault" in text
      # in-memory policy reloaded: the path is writable now
      check sandbox.checkRawPath(proj / "vault" / "new.txt",
        needsWrite = true).allowed

  test "broad grant supersedes the ask mask":
    # allow ./ appended after ask ./vault must un-ask the subtree in the
    # consumed form too, or the kernel mask would outlive the grant
    let (base, proj) = newFixture("broad")
    defer: removeDir(base)
    withPolicy(proj):
      check sandbox.grantAskAllow(proj)
      let r = sandbox.current.resolve()
      check (proj / "vault") notin r.denied
      check sandbox.checkRawPath(proj / "vault" / "x",
        needsWrite = true).allowed
