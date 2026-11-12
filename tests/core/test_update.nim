## Offline tests for auto-update logic + an opt-in live e2e test.
##
## Default run: `nimble test` — pure-logic tests only.
## Live e2e (hits real GitHub, downloads the latest release tarball,
## extracts and exec's it in /tmp):
##   nim c -d:live -d:ssl -r tests/test_update.nim

import std/[os, osproc, strutils, unittest]
import threecode/update

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

suite "update: swapInstall skip list":
  ## `swapInstall` must copy the binary (and any sibling runtime libs)
  ## but leave zip-bundle documentation (README, LICENSE, and the
  ## VERSION capture added in 0.5.0 CI) behind. A stray VERSION next
  ## to the binary is the regression this guards.
  test "README/LICENSE/VERSION are not installed beside the binary":
    let src = getTempDir() / "3code-update-src"
    let dst = getTempDir() / "3code-update-dst"
    removeDir(src); removeDir(dst)
    createDir(src); createDir(dst)
    # fake bundle: binary + the three doc/metadata files
    writeFile(src / "3code", "fake-bin")
    writeFile(src / "README.md", "readme")
    writeFile(src / "LICENSE", "license")
    writeFile(src / "VERSION", "0.5.0")
    let target = dst / "3code"
    check swapInstall(src, target)
    check fileExists(target)
    check readFile(target) == "fake-bin"
    check not fileExists(dst / "README.md")
    check not fileExists(dst / "LICENSE")
    check not fileExists(dst / "VERSION")
    removeDir(src); removeDir(dst)

suite "update: swapInstall renamed destination":
  ## A user can install under any name (curl > ~/bin/agent, a wrapper
  ## copy, a second checkout). The canonical binary member must land on
  ## the *destination* path — not beside it under the archive's own
  ## name — while sibling runtime libraries still install in the
  ## destination directory under their member names.
  test "renamed target is replaced in place, no canonical sibling":
    let src = getTempDir() / "3code-update-ren-src"
    let dst = getTempDir() / "3code-update-ren-dst"
    removeDir(src); removeDir(dst)
    createDir(src); createDir(dst)
    writeFile(src / "3code", "new-bin-bytes")
    writeFile(src / "libagent.so", "fake-rt-lib")
    writeFile(src / "README.md", "readme")
    writeFile(src / "LICENSE", "license")
    writeFile(src / "VERSION", "9.9.9")
    let target = dst / "custom-code"
    writeFile(target, "old-bin-bytes")
    check swapInstall(src, target)
    check readFile(target) == "new-bin-bytes"
    when not defined(windows):
      check fpUserExec in getFilePermissions(target)
    check not fileExists(dst / "3code")
    check readFile(dst / "libagent.so") == "fake-rt-lib"
    check not fileExists(dst / "README.md")
    check not fileExists(dst / "LICENSE")
    check not fileExists(dst / "VERSION")
    removeDir(src); removeDir(dst)

  test "bundle without canonical binary fails before touching anything":
    let src = getTempDir() / "3code-update-nobin-src"
    let dst = getTempDir() / "3code-update-nobin-dst"
    removeDir(src); removeDir(dst)
    createDir(src); createDir(dst)
    writeFile(src / "stray-file", "stray")
    writeFile(src / "README.md", "readme")
    let target = dst / "3code"
    writeFile(target, "old-bin-bytes")
    check not swapInstall(src, target)
    check readFile(target) == "old-bin-bytes"
    check not fileExists(dst / "stray-file")
    removeDir(src); removeDir(dst)

  test "target name colliding with another member is refused":
    ## With the target named `custom-code`, a bundle also carrying a
    ## `custom-code` member would race the exe against it in directory
    ## iteration order. That bundle/target pair must be rejected
    ## before any file changes.
    let src = getTempDir() / "3code-update-col-src"
    let dst = getTempDir() / "3code-update-col-dst"
    removeDir(src); removeDir(dst)
    createDir(src); createDir(dst)
    writeFile(src / "3code", "new-bin-bytes")
    writeFile(src / "helper-tool", "helper")
    let target = dst / "helper-tool"
    writeFile(target, "old-helper-bytes")
    check not swapInstall(src, target)
    check readFile(target) == "old-helper-bytes"
    check not fileExists(dst / "3code")
    removeDir(src); removeDir(dst)

when defined(windows):
  suite "update: swapInstall renamed .exe on windows":
    test "renamed .exe target swaps in place, stale .old from destination":
      let src = getTempDir() / "3code-update-wex-src"
      let dst = getTempDir() / "3code-update-wex-dst"
      removeDir(src); removeDir(dst)
      createDir(src); createDir(dst)
      writeFile(src / "3code.exe", "new-bin-bytes")
      let target = dst / "custom-tool.exe"
      writeFile(target, "old-bin-bytes")
      check swapInstall(src, target)
      check readFile(target) == "new-bin-bytes"
      check not fileExists(dst / "3code.exe")
      check not fileExists(dst / "3code")
      check not fileExists(dst / "3code.exe.old")
      # the in-use file was parked beside the *actual* destination
      check fileExists(dst / "custom-tool.exe.old")
      removeDir(src); removeDir(dst)

when not defined(windows):
  suite "update: flat release archive":
    ## Release archives are flat since e938c59: members sit at the
    ## archive root, no `3code-<platform>/` wrapper dir. The extractor
    ## must locate the binary there and `swapInstall` must install from
    ## the archive root. Members mirror the linux CI pack list.
    test "extracts flat tarball, installs from archive root":
      let tmp = getTempDir() / "3code-update-flat"
      removeDir(tmp)
      let stage = tmp / "stage"
      let outDir = tmp / "out"
      createDir(stage)
      createDir(outDir)
      writeFile(stage / "3code", "fake-flat-bin")
      writeFile(stage / "VERSION", "0.8.5\n")
      writeFile(stage / "BUILD_INFO", "build")
      writeFile(stage / "LICENSE", "lic")
      writeFile(stage / "README.md", "readme")
      let tarball = tmp / "3code-linux-amd64.tar.gz"
      let cmd = "tar -C " & stage.quoteShell & " -czf " & tarball.quoteShell &
                " 3code VERSION BUILD_INFO LICENSE README.md"
      check execCmdEx(cmd).exitCode == 0
      let extractDir = tmp / "extract"
      let srcDir = extractArchive(tarball, extractDir)
      check srcDir == extractDir  # binary at the archive root, not nested
      check fileExists(extractDir / "3code")
      let dest = outDir / "3code"
      check swapInstall(srcDir, dest)
      check readFile(dest) == "fake-flat-bin"
      check fpUserExec in getFilePermissions(dest)
      check not fileExists(outDir / "README.md")
      check not fileExists(outDir / "LICENSE")
      check not fileExists(outDir / "VERSION")
      removeDir(tmp)

suite "update: renamed destination":
  ## `swapInstall` must replace the exact destination file, whatever its
  ## name: a renamed install (`custom-code`, `/usr/local/bin/cc`) gets
  ## the new bytes in place and no canonical `3code` sibling appears.
  ## Sibling runtime libs still land beside the target; README/LICENSE/
  ## VERSION stay skipped.
  test "renamed target is replaced in place, no canonical sibling":
    let src = getTempDir() / "3code-update-rename-src"
    let dst = getTempDir() / "3code-update-rename-dst"
    removeDir(src); removeDir(dst)
    createDir(src); createDir(dst)
    # fake bundle: canonical binary + sibling runtime lib + the three
    # doc/metadata files
    writeFile(src / "3code", "new-bin-bytes")
    writeFile(src / "libruntime.so", "new-lib-bytes")
    writeFile(src / "README.md", "readme")
    writeFile(src / "LICENSE", "license")
    writeFile(src / "VERSION", "9.9.9")
    let target = dst / "custom-code"
    writeFile(target, "old-bin-bytes")
    check swapInstall(src, target)
    check readFile(target) == "new-bin-bytes"
    when not defined(windows):
      check fpUserExec in getFilePermissions(target)
    check not fileExists(dst / "3code")
    check readFile(dst / "libruntime.so") == "new-lib-bytes"
    check not fileExists(dst / "README.md")
    check not fileExists(dst / "LICENSE")
    check not fileExists(dst / "VERSION")
    removeDir(src); removeDir(dst)

  test "bundle missing the canonical binary fails before mutation":
    let src = getTempDir() / "3code-update-nobin-src"
    let dst = getTempDir() / "3code-update-nobin-dst"
    removeDir(src); removeDir(dst)
    createDir(src); createDir(dst)
    writeFile(src / "libruntime.so", "new-lib-bytes")
    writeFile(src / "README.md", "readme")
    let target = dst / "custom-code"
    writeFile(target, "old-bin-bytes")
    check not swapInstall(src, target)
    check readFile(target) == "old-bin-bytes"
    check not fileExists(dst / "libruntime.so")
    check not fileExists(dst / "README.md")
    removeDir(src); removeDir(dst)

  test "target colliding with a bundle member is rejected before mutation":
    # directory iteration order must not decide the outcome: a bundle
    # member named like the destination could overwrite the installed
    # binary, so the combination is rejected up front.
    let src = getTempDir() / "3code-update-collide-src"
    let dst = getTempDir() / "3code-update-collide-dst"
    removeDir(src); removeDir(dst)
    createDir(src); createDir(dst)
    writeFile(src / "3code", "new-bin-bytes")
    writeFile(src / "custom-code", "member-bytes")
    let target = dst / "custom-code"
    writeFile(target, "old-bin-bytes")
    check not swapInstall(src, target)
    check readFile(target) == "old-bin-bytes"
    check not fileExists(dst / "3code")
    removeDir(src); removeDir(dst)

when defined(windows):
  suite "update: renamed .exe on windows":
    test "stale backup path follows the renamed destination":
      let src = getTempDir() / "3code-update-rename-src"
      let dst = getTempDir() / "3code-update-rename-dst"
      removeDir(src); removeDir(dst)
      createDir(src); createDir(dst)
      writeFile(src / "3code.exe", "new-bin-bytes")
      writeFile(src / "libruntime.dll", "new-lib-bytes")
      writeFile(src / "README.md", "readme")
      let target = dst / "custom-code.exe"
      writeFile(target, "old-bin-bytes")
      check swapInstall(src, target)
      check readFile(target) == "new-bin-bytes"
      # the in-use exe moves to `<renamed>.old`, cleaned up at next
      # launch by cleanupStaleBinaries — never under the canonical name
      check readFile(target & ".old") == "old-bin-bytes"
      check not fileExists(dst / "3code.exe")
      check not fileExists(dst / "3code.exe.old")
      check readFile(dst / "libruntime.dll") == "new-lib-bytes"
      check not fileExists(dst / "README.md")
      removeDir(src); removeDir(dst)

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
              "[settings]\nauto-update = \"true\"\n")
    check autoUpdateEnabled()

  test "config false wins":
    writeFile(tmpHome / ".config" / "3code" / "config",
              "[settings]\nauto-update = \"false\"\n")
    check not autoUpdateEnabled()

  test "alt truthy spellings":
    for v in ["yes", "on", "1"]:
      writeFile(tmpHome / ".config" / "3code" / "config",
                "[settings]\nauto-update = \"" & v & "\"\n")
      check autoUpdateEnabled()

  test "alt falsy spellings":
    for v in ["no", "off", "0"]:
      writeFile(tmpHome / ".config" / "3code" / "config",
                "[settings]\nauto-update = \"" & v & "\"\n")
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
