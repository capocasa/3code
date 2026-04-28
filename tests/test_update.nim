## Offline tests for auto-update logic + an opt-in live e2e test.
##
## Default run: `nimble test` — pure-logic tests only.
## Live e2e (hits real GitHub, downloads the latest release tarball,
## extracts and exec's it in /tmp):
##   nim c -d:live -d:ssl -r tests/test_update.nim

import std/[os, strutils, unittest]
import threecode/update
when defined(live):
  import std/osproc

suite "update: semver":
  test "greater patch":
    check semverGt("0.2.5", "0.2.4")

  test "equal returns false":
    check not semverGt("0.2.4", "0.2.4")

  test "numeric compare, not lexical":
    check semverGt("0.10.0", "0.2.4")

  test "leading v stripped":
    check semverGt("v0.3.0", "0.2.9")

  test "shorter prefix doesn't beat longer-with-greater-tail":
    check not semverGt("0.2", "0.2.4")

  test "parseSemver pads / ignores trailing junk":
    check parseSemver("0.2.4") == @[0, 2, 4]
    check parseSemver("v1.0") == @[1, 0]
    check parseSemver("0.2.4-rc1") == @[0, 2, 4]

suite "update: config gate":
  ## Exercise `autoUpdateEnabled` against a temp HOME so we don't
  ## clobber the developer's real config.
  var savedHome = ""
  var savedXdg = ""
  var tmpHome = ""

  setup:
    tmpHome = getTempDir() / "3code-test-home"
    removeDir(tmpHome)
    createDir(tmpHome / ".config" / "3code")
    savedHome = getEnv("HOME")
    savedXdg = getEnv("XDG_CONFIG_HOME")
    putEnv("HOME", tmpHome)
    putEnv("XDG_CONFIG_HOME", tmpHome / ".config")

  teardown:
    putEnv("HOME", savedHome)
    if savedXdg.len > 0: putEnv("XDG_CONFIG_HOME", savedXdg)
    else: delEnv("XDG_CONFIG_HOME")
    removeDir(tmpHome)

  test "no config: falls back to build-time default":
    # built without -d:autoUpdate (the default for `nimble test`),
    # so this is false.
    check not autoUpdateEnabled()

  test "config true wins":
    writeFile(tmpHome / ".config" / "3code" / "config",
              "[settings]\nauto_update = \"true\"\n")
    check autoUpdateEnabled()

  test "config false wins":
    writeFile(tmpHome / ".config" / "3code" / "config",
              "[settings]\nauto_update = \"false\"\n")
    check not autoUpdateEnabled()

  test "alt truthy spellings":
    for v in ["yes", "on", "1"]:
      writeFile(tmpHome / ".config" / "3code" / "config",
                "[settings]\nauto_update = \"" & v & "\"\n")
      check autoUpdateEnabled()

  test "alt falsy spellings":
    for v in ["no", "off", "0"]:
      writeFile(tmpHome / ".config" / "3code" / "config",
                "[settings]\nauto_update = \"" & v & "\"\n")
      check not autoUpdateEnabled()

when defined(live):
  suite "update: live e2e (hits real GitHub)":
    test "fetches latest release, swaps target binary, target runs":
      ## Spoofs `curVersion = "0.0.0"` so the latest published tag is
      ## always "newer", points the swap at a temp file, executes the
      ## resulting binary and verifies `--version` returns *something*
      ## semver-shaped. Uses `force = true` to bypass the config gate.
      let tmp = getTempDir() / "3code-update-live"
      removeDir(tmp)
      createDir(tmp)
      let target = tmp / "3code"
      writeFile(target, "stub-old-binary")
      let beforeSize = getFileSize(target)

      selfUpdateCheck(curVersion = "0.0.0",
                      targetPath = target,
                      force = true)

      check fileExists(target)
      let afterSize = getFileSize(target)
      check afterSize > beforeSize * 100  # real binary is megabytes
      check getFilePermissions(target).contains(fpUserExec)

      let (output, code) = execCmdEx(target.quoteShell & " --version")
      check code == 0
      let v = output.strip
      check parseSemver(v).len >= 2  # printed something semver-shaped

      removeDir(tmp)
      # Cache scratch in the real userDataRoot — clean it.
      removeDir(getHomeDir() / ".local" / "share" / "3code" / "update")
