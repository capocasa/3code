discard """
  # The cascade concatenates a system level and a repo level (each falling
  # back to the built-in default when absent) and parses once. These tests
  # exercise `parseCascaded`, the pure file-free core, so they don't depend
  # on `~/.config/3code/sandbox` or write repo files.
"""
import std/[unittest, os]
import threecode/sandbox
import threecode/types

# Use platform-appropriate absolute paths so the test is meaningful on
# both Unix and Windows. On Windows a bare "/opt" is not absolute (no
# drive letter), so normalizeSandboxPath would resolve it relative to
# cwd and the path assertions would fail.
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
    # Two default texts concatenate to four raw rules (two deny /, two
    # cwd-O); the effective access is decided by last-wins, so assert via
    # checkPath, not raw rule count.
    let s = parseCascaded(defaultSandboxText(), defaultSandboxText(), proj)
    check s.checkPath("/") == akDeny
    check s.checkPath(proj) == akWritable
    check s.checkPath(proj / "sub") == akWritable

  test "repo file only -> repo rules win for the paths it names":
    let s = parseCascaded(defaultSandboxText(), "O " & opt & "\n", proj)
    check s.rules[^1].access == akWritable
    check s.rules[^1].path == opt
    # cwd stays writable (from the default).
    check s.checkPath(proj) == akWritable

  test "system file only -> system rules apply":
    let s = parseCascaded("o " & varDir & "\n", defaultSandboxText(), proj)
    check s.rules[0].access == akReadOnly
    check s.rules[0].path == varDir

  test "both -> system then repo concatenated; repo deny resets a system allow":
    let s = parseCascaded("O " & opt & "\n", ". " & opt & "\n", proj)
    check s.checkPath(opt) == akDeny

  test "repo can broaden beyond the system default":
    let s = parseCascaded(defaultSandboxText(), "O " & opt & "\no " & varDir & "\n", proj)
    check s.checkPath(opt) == akWritable
    check s.checkPath(varDir) == akReadOnly

  test "sandboxEnabled default is on (types.nim contract)":
    # The gate lives in types.nim; assert the default so a future change
    # to the declaration is caught here, not in production.
    check sandboxEnabled == true