## Directory-specific settings: the `.3code` store, the parent cascade,
## the sandbox policy selection, the sandbox-off overlay, and the
## writeConfigFile no-leak guard.

import std/[os, strutils, unittest]
import threecode/[dirsettings, sandbox, config, types]

proc newFixture(name: string): tuple[base, proj, sub: string] =
  let base = getTempDir() / ("3code_dirstest_" & name & "_" &
    $getCurrentProcessId())
  if dirExists(base): removeDir(base)
  result = (base, base / "proj", base / "proj" / "sub")
  createDir(result.proj)
  createDir(result.sub)
  putEnv("XDG_CONFIG_HOME", base / "cfg")
  putEnv("XDG_DATA_HOME", base / "data")
  dirsettings.dirConfigLocation = "project"

proc dropFixture(base: string) =
  dirsettings.dirConfigLocation = "project"
  delEnv("XDG_CONFIG_HOME")
  delEnv("XDG_DATA_HOME")
  removeDir(base)

proc writeStoreConfig(dir, body: string) =
  createDir(dir / ".3code")
  writeFile(dir / ".3code" / "config", body)

suite "dirsettings: store resolution":
  test "project location is <dir>/.3code":
    let f = newFixture("loc")
    defer: dropFixture(f.base)
    check dirsettings.storeDirFor(f.proj) == f.proj / ".3code"

  test "user location is under the config root, keyed by dir":
    let f = newFixture("locuser")
    defer: dropFixture(f.base)
    dirsettings.dirConfigLocation = "user"
    let store = dirsettings.storeDirFor(f.proj)
    check store.startsWith(f.base / "cfg" / "3code" / "dirs")
    # Distinct dirs map to distinct stores even after mangling.
    check dirsettings.storeDirFor(f.sub) != store

suite "dirsettings: config cascade":
  test "nearest store wins per key":
    let f = newFixture("cascade")
    defer: dropFixture(f.base)
    writeStoreConfig(f.base, "[settings]\ncurrent = \"root.glm-5.2\"\n")
    check dirsettings.cascadeConfigValue(f.sub, "current") == "root.glm-5.2"
    writeStoreConfig(f.proj, "[settings]\ncurrent = \"mid.gpt-4o\"\n")
    check dirsettings.cascadeConfigValue(f.sub, "current") == "mid.gpt-4o"
    check dirsettings.cascadeConfigValue(f.proj, "current") == "mid.gpt-4o"
    check dirsettings.cascadeConfigValue(f.base, "current") == "root.glm-5.2"

  test "a store without the key does not block a farther one":
    let f = newFixture("gap")
    defer: dropFixture(f.base)
    writeStoreConfig(f.sub, "[settings]\nsandbox = \"off\"\n")
    writeStoreConfig(f.base, "[settings]\ncurrent = \"root.glm-5.2\"\n")
    check dirsettings.cascadeConfigValue(f.sub, "current") == "root.glm-5.2"
    check dirsettings.cascadeConfigValue(f.sub, "sandbox") == "off"

suite "dirsettings: sandbox authority in the store cascade":
  # Project-local stores may tighten a security boolean from off to on
  # but never weaken on to off: the repository controls those files, the
  # user controls the sandbox. Only stores the user config selects
  # (`dirconfig = "user"` puts them under the config root) may carry an
  # explicit disablement.

  test "a project store cannot disable an enabled sandbox":
    let f = newFixture("sboff")
    defer: dropFixture(f.base)
    for spelling in ["off", "false", "no", "0", "OFF"]:
      sandboxEnabled = true
      dirsettings.dirSandboxOverridden = false
      writeStoreConfig(f.proj, "[settings]\nsandbox = \"" & spelling & "\"\n")
      dirsettings.applyDirConfig(f.sub)
      check sandboxEnabled
      check not dirsettings.dirSandboxOverridden
    sandboxEnabled = true

  test "the sandbox_enabled alias cannot disable an enabled sandbox":
    let f = newFixture("sbalias")
    defer: dropFixture(f.base)
    sandboxEnabled = true
    writeStoreConfig(f.proj, "[settings]\nsandbox_enabled = \"off\"\n")
    dirsettings.applyDirConfig(f.proj)
    check sandboxEnabled
    check not dirsettings.dirSandboxOverridden
    sandboxEnabled = true

  test "ancestor stores cannot disable an enabled sandbox":
    let f = newFixture("sbanc")
    defer: dropFixture(f.base)
    sandboxEnabled = true
    writeStoreConfig(f.base, "[settings]\nsandbox = \"off\"\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    check not dirsettings.dirSandboxOverridden
    sandboxEnabled = true

  test "warning suppression from a project store is ignored too":
    let f = newFixture("sbwarn")
    defer: dropFixture(f.base)
    sandboxWallWarn = true
    writeStoreConfig(f.proj, "[settings]\nsandbox_wall_warn = \"off\"\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxWallWarn
    check not dirsettings.dirWallWarnOverridden
    sandboxWallWarn = true

  test "a project store can re-enable a user-disabled sandbox":
    let f = newFixture("sbon")
    defer: dropFixture(f.base)
    sandboxEnabled = false
    writeStoreConfig(f.proj, "[settings]\nsandbox = \"on\"\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    check dirsettings.dirSandboxOverridden
    # The tightening is a project preference: writeConfigFile must
    # persist the user's own off (the pre-overlay snapshot), not hoist
    # the effective on.
    let cfgPath = f.base / "cfg" / "3code" / "config"
    createDir(cfgPath.parentDir)
    writeConfigFile(cfgPath, "", @[])
    check "sandbox = \"off\"" in readFile(cfgPath)
    sandboxEnabled = true

  test "nearer re-enable wins after a farther denied disable":
    let f = newFixture("sbmix")
    defer: dropFixture(f.base)
    sandboxEnabled = true
    writeStoreConfig(f.base, "[settings]\nsandbox = \"off\"\n")
    writeStoreConfig(f.proj, "[settings]\nsandbox = \"on\"\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    sandboxEnabled = true

  test "a nearer disable loses to an enabled sandbox even after a farther enable":
    let f = newFixture("sbmix2")
    defer: dropFixture(f.base)
    sandboxEnabled = true
    writeStoreConfig(f.base, "[settings]\nsandbox = \"on\"\n")
    writeStoreConfig(f.sub, "[settings]\nsandbox = \"off\"\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    sandboxEnabled = true

  test "conflicting aliases resolve to the canonical spelling":
    let f = newFixture("sbconf")
    defer: dropFixture(f.base)
    sandboxEnabled = false
    writeStoreConfig(f.proj,
      "[settings]\nsandbox_enabled = \"off\"\nsandbox = \"on\"\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    # Same file, alias first: canonical still wins.
    sandboxEnabled = false
    writeStoreConfig(f.proj,
      "[settings]\nsandbox = \"on\"\nsandbox_enabled = \"off\"\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    sandboxEnabled = true

  test "missing and malformed store configs change nothing":
    let f = newFixture("sbmissing")
    defer: dropFixture(f.base)
    sandboxEnabled = true
    sandboxWallWarn = true
    # No store at all.
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    check sandboxWallWarn
    check not dirsettings.dirSandboxOverridden
    # A store whose config file does not parse.
    createDir(f.proj / ".3code")
    writeFile(f.proj / ".3code" / "config", "[settings\nsandbox = \"off\"\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    check sandboxWallWarn
    sandboxEnabled = true

  test "applyDirConfig is idempotent":
    let f = newFixture("sbidem")
    defer: dropFixture(f.base)
    sandboxEnabled = false
    writeStoreConfig(f.proj, "[settings]\nsandbox = \"on\"\n")
    dirsettings.applyDirConfig(f.sub)
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    sandboxEnabled = true

  test "the full parse cannot undo the security rule":
    # Startup order: early parse, full parse, then the overlay. The
    # parse re-applies the user switches; the overlay after it must
    # still refuse a project disablement.
    let f = newFixture("sbparse")
    defer: dropFixture(f.base)
    sandboxEnabled = true
    let cfgPath = f.base / "cfg" / "3code" / "config"
    createDir(cfgPath.parentDir)
    writeFile(cfgPath, "[settings]\nsandbox = \"on\"\n")
    discard tryLoadStateOrEmpty(cfgPath)
    writeStoreConfig(f.proj, "[settings]\nsandbox = \"off\"\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    sandboxEnabled = true

  test "dirconfig=user stores may disable, and the project store is then unread":
    let f = newFixture("sbuser")
    defer: dropFixture(f.base)
    sandboxEnabled = true
    dirsettings.dirConfigLocation = "user"
    let store = dirsettings.storeFileFor(f.proj, dirsettings.StoreConfigFile)
    createDir(store.parentDir)
    writeFile(store, "[settings]\nsandbox = \"off\"\n")
    # A project-local store next door must not be consulted as authority.
    writeStoreConfig(f.proj, "[settings]\nsandbox_enabled = \"off\"\n")
    dirsettings.applyDirConfig(f.sub)
    check not sandboxEnabled
    check dirsettings.dirSandboxOverridden
    # And the user-owned disablement does not leak into the user config:
    # the overlay snapshot holds the pre-overlay on.
    let cfgPath = f.base / "cfg" / "3code" / "config"
    createDir(cfgPath.parentDir)
    writeConfigFile(cfgPath, "", @[])
    check "sandbox" notin readFile(cfgPath)
    sandboxEnabled = true

  test "writeConfigFile does not leak the directory override":
    let f = newFixture("noleak")
    defer: dropFixture(f.base)
    sandboxEnabled = false
    dirsettings.dirSandboxOverridden = true
    dirsettings.globalSandboxEnabled = true
    let cfgPath = f.base / "cfg" / "3code" / "config"
    createDir(cfgPath.parentDir)
    writeConfigFile(cfgPath, "", @[])
    check "sandbox" notin readFile(cfgPath)
    # Without the override, off persists as before.
    dirsettings.dirSandboxOverridden = false
    writeConfigFile(cfgPath, "", @[])
    check "sandbox = \"off\"" in readFile(cfgPath)
    sandboxEnabled = true

suite "dirsettings: sandbox policy selection":
  test "the store sandbox file is the repo policy slot":
    let f = newFixture("policyslot")
    defer: dropFixture(f.base)
    check sandbox.repoPolicyPath(f.proj) == f.proj / ".3code" / "sandbox"
    check sandbox.activePolicyPath(f.proj) ==
      getConfigDir() / "3code" / "sandbox"

  test "legacy .sandbox still reads, the store file wins":
    let f = newFixture("legacysb")
    defer: dropFixture(f.base)
    writeFile(f.proj / ".sandbox", "allow /\n")
    check sandbox.repoPolicyPath(f.proj) == f.proj / ".sandbox"
    check sandbox.activePolicyPath(f.proj) == f.proj / ".sandbox"
    createDir(f.proj / ".3code")
    writeFile(f.proj / ".3code" / "sandbox", "deny /\n")
    check sandbox.repoPolicyPath(f.proj) == f.proj / ".3code" / "sandbox"
    check sandbox.activePolicyPath(f.proj) == f.proj / ".3code" / "sandbox"

  test "the policy cascade walks parents, nearest first":
    let f = newFixture("policycascade")
    defer: dropFixture(f.base)
    writeFile(f.base / ".sandbox", "allow /\n")
    # A parent's legacy .sandbox covers a subdirectory session.
    check sandbox.activePolicyPath(f.sub) == f.base / ".sandbox"
    check sandbox.activePolicyRoot(f.sub) == f.base
    # A nearer store file wins over the farther legacy file.
    createDir(f.proj / ".3code")
    writeFile(f.proj / ".3code" / "sandbox", "deny /\n")
    check sandbox.activePolicyPath(f.sub) == f.proj / ".3code" / "sandbox"
    check sandbox.activePolicyRoot(f.sub) == f.proj

  test "store policy ./ targets resolve against the store's owner":
    let f = newFixture("policyroot")
    defer: dropFixture(f.base)
    createDir(f.proj / ".3code")
    writeFile(f.proj / ".3code" / "sandbox", "allow ./\n")
    let pol = parsePolicy(
      readFile(sandbox.activePolicyPath(f.sub)),
      sandbox.activePolicyRoot(f.sub))
    check pol.checkPath(f.proj / "src") == akWritable
    check pol.checkPath(f.base / "elsewhere") != akWritable

suite "dirsettings: dirconfig validation":
  test "bad dirconfig value is a config error":
    let f = newFixture("badval")
    defer: dropFixture(f.base)
    let cfgPath = f.base / "cfg" / "3code" / "config"
    createDir(cfgPath.parentDir)
    writeFile(cfgPath, "[settings]\ndirconfig = \"somewhere\"\n")
    let (cur, provs, _, err) = tryLoadStateOrEmpty(cfgPath)
    check err.contains("dirconfig")

  test "dirconfig = user round-trips through writeConfigFile":
    let f = newFixture("rt")
    defer: dropFixture(f.base)
    let cfgPath = f.base / "cfg" / "3code" / "config"
    createDir(cfgPath.parentDir)
    writeFile(cfgPath, "[settings]\ndirconfig = \"user\"\n")
    discard tryLoadStateOrEmpty(cfgPath)
    check dirsettings.dirConfigLocation == "user"
    writeConfigFile(cfgPath, "", @[])
    check "dirconfig = \"user\"" in readFile(cfgPath)
    dirsettings.dirConfigLocation = "project"
