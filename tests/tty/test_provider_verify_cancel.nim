## The provider wizard's `verifying...` probe used to swallow Ctrl-C and
## ESC: the input thread is parked between wizard prompts, so the keys
## sat in the tty buffer until the (up to 30s) probe finished. The fix
## watches stdin on the wizard thread during verification and cancels the
## pool. This test drives `:provider add` into the probe, sends ESC, and
## checks the wizard aborts back to a fresh prompt without saving the
## provider.
discard """
  disabled: "win"
  ## Same ConPTY ESC-in-wizard gap as test_provider_wizard_cancel: ESC
  ## sent during the verifying probe does not surface as a cancel under
  ## ConPTY, so the wizard keeps probing and "cancelled" never prints.
  ## POSIX covers the regression; a ConPTY ESC semantics fix is a
  ## separate pass.
"""

import std/[os, strutils, unittest]
import tty_expect
import stub_helpers

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
  createDir(root / "tmp")
  @[
    (key: "XDG_DATA_HOME", val: root / "xdg"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_CACHE_HOME", val: root / "xdg" / "cache"),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "HOME", val: root),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
    (key: "THREECODE_STUB_STREAM", val: "1"),
    # Stretch the verification probe so the ESC below lands while the
    # wizard is still inside `verifying...`.
    (key: "THREECODE_STUB_VERIFY_DELAY_MS", val: "3000"),
  ]

suite "provider verification cancel":
  test "ESC during verifying... aborts the add wizard":
    let root = newFixture("provider_verify_cancel")
    writeConfiguredProvider(root)
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, ""),
                            keepHistory = false)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send ":provider add"
    tty.send "\r"
    tty.drain(200)
    tty.expect "api key"
    tty.send "another-stub-key\r"
    tty.expect "provider name"
    tty.send "second\r"
    tty.expect "url"
    tty.send "stub://second\r"
    tty.expect "models"
    tty.send "stub-model\r"
    tty.expect "verifying"
    # ESC must cancel the probe, not sit in the tty buffer.
    tty.send "\x1b"
    tty.expect "cancelled"
    # The wizard unwound and a fresh prompt is up: typing must land on
    # it (the ESC was consumed by the watcher, not queued into the
    # editor). The add wizard exiting without `added`/`updated` output
    # proves the provider was not saved.
    tty.drain(300)
    tty.expect "\u276f"
    tty.send ":q"
    tty.send "\r"
    tty.expectExit(0, timeoutMs = 5000)
    let cfg = readFile(root / "xdg" / "3code" / "config")
    check cfg.count("[provider]") == 1
    check "second" notin cfg
