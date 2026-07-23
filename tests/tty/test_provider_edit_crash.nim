discard """
  # See docs/windows-testing.md. The tty_expect harness uses openpty/fork/
  # execv (POSIX only). A ConPTY port is the path to re-enable on Windows.
  disabled: "win"
"""
## Regression: editing a provider (`:provider edit <name>`) used to
## SIGSEGV the input thread on the next redraw after the wizard returned.
## The modal's save/nil/save dance on the editor's hook closures raced
## with the input thread reading those fields; a torn read (one word
## zero, the other the prior value) made the input thread's
## `if hook != nil: hook(ed)` codegen jump to a nil function pointer.
## The fix routes every hook call through a `callHook` template that
## loads the fn word directly, and the modal no longer nils the
## closures (it only flips an atomic flag the hook bodies check).
## This test drives the wizard through the stub provider and then
## types `:q` to exercise the post-wizard redraw path that crashed.
import std/[json, os, strutils, unittest]
import tty_expect
import stub_helpers

const Root = "testdata/output/tty/provider_edit_crash"

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata/output/tty" / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "data"); createDir(result / "run")

proc writeConfiguredProvider(root: string) =
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")

proc stubEnv(root, responsesPath: string): seq[EnvVar] =
  let data = root / "data"
  createDir(root / "tmp")
  @[
    (key: "XDG_DATA_HOME", val: root / "xdg"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_CACHE_HOME", val: root / "xdg" / "cache"),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "HOME", val: root),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
    (key: "THREECODE_STUB_STREAM", val: "1"),
  ]

suite "provider edit crash regression":
  test ":provider edit then :q keeps the input thread alive":
    let root = newFixture("provider_edit_crash")
    writeConfiguredProvider(root)
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, ""),
                            keepHistory = false)
    defer:
      tty.close()

    # Idle prompt is up.
    tty.expect "\u276f"

    # Run the edit wizard, accepting every default (Enter on each prompt).
    tty.send ":provider edit stub"
    tty.send "\r"
    tty.drain(200)
    tty.expect "name [stub]"
    tty.send "\r"
    tty.expect "url ["
    tty.send "\r"
    tty.expect "api key [keep existing]"
    tty.send "\r"
    tty.expect "models ["
    tty.send "\r"
    tty.expect "verifying"
    tty.expect "ok"

    # Wait for the modal to fully return and the prompt to repaint.
    tty.drain(500)
    tty.expect "\u276f"

    # Drive the post-wizard redraw path that used to crash. The old
    # `for ch in ":q": tty.send($ch); tty.drain(20)` per-keystroke
    # loop was a hang-over from when the input thread's redraws raced
    # the wizard's on the way out; with the wizard running on the
    # input thread itself (5db5aa8) the steady-state redraws are
    # uninteresting and `:q` is the clean signal that the wizard
    # returned control to the main loop without a SIGSEGV.
    tty.send ":q"
    tty.send "\r"
    tty.drain(300)

    # `:q` exits the REPL. A SIGSEGV on the way out would have killed
    # the process with a non-zero exit status; a clean exit code 0
    # proves the input thread survived the wizard.
    tty.expectExit(0, timeoutMs = 5000)

    echo "  PASS: :provider edit then :q did not segfault"