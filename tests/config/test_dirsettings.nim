## Directory-specific settings: the `.3code` store, the parent cascade,
## the sandbox policy selection, the sandbox authority rule (project
## stores tighten, user-owned stores decide), and the writeConfigFile
## no-leak guard.

import std/[os, sequtils, sets, strutils, tables, unittest]
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

suite "dirsettings: sandbox authority":
  # Project-local stores may tighten a security boolean (false -> true)
  # but may never weaken one (true -> false): disabling the sandbox or
  # silencing its warnings is a user-owned decision, made in the user
  # config or, under `dirconfig = "user"`, in the stores the user config
  # selected. Ordinary preferences keep nearest-wins.

  test "a local store cannot disable an enabled sandbox":
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
    writeStoreConfig(f.proj, "[settings]\nsandbox = \"off\"\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    check not dirsettings.dirSandboxOverridden
    sandboxEnabled = true

  test "an ancestor store cannot disable an enabled sandbox":
    let f = newFixture("sboffanc")
    defer: dropFixture(f.base)
    sandboxEnabled = true
    writeStoreConfig(f.base, "[settings]\nsandbox_enabled = \"off\"\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    check not dirsettings.dirSandboxOverridden
    sandboxEnabled = true

  test "every false spelling is refused, on both alias spellings":
    let f = newFixture("sbfalse")
    defer: dropFixture(f.base)
    for key in ["sandbox", "sandbox_enabled"]:
      for word in ["off", "false", "no", "0"]:
        sandboxEnabled = true
        writeStoreConfig(f.proj,
          "[settings]\n" & key & " = \"" & word & "\"\n")
        dirsettings.applyDirConfig(f.sub)
        check sandboxEnabled
        check not dirsettings.dirSandboxOverridden
    sandboxEnabled = true

  test "a store cannot silence the sandbox warning":
    let f = newFixture("sbwarn")
    defer: dropFixture(f.base)
    sandboxWallWarn = true
    writeStoreConfig(f.proj, "[settings]\nsandbox_wall_warn = \"off\"\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxWallWarn
    check not dirsettings.dirWallWarnOverridden
    sandboxWallWarn = true

  test "a nearer refusal does not undo a farther tightening":
    let f = newFixture("sbmix")
    defer: dropFixture(f.base)
    sandboxEnabled = false  # the user config said off
    writeStoreConfig(f.base, "[settings]\nsandbox = \"on\"\n")
    writeStoreConfig(f.proj, "[settings]\nsandbox = \"off\"\n")
    dirsettings.applyDirConfig(f.sub)
    # The far store tightens; the near store's disable is refused.
    check sandboxEnabled
    check dirsettings.dirSandboxOverridden
    check not dirsettings.globalSandboxEnabled
    sandboxEnabled = true

  test "a nearer tightening wins over a farther one":
    let f = newFixture("sbtight")
    defer: dropFixture(f.base)
    sandboxEnabled = false
    writeStoreConfig(f.base, "[settings]\nsandbox = \"off\"\n")
    writeStoreConfig(f.proj, "[settings]\nsandbox = \"on\"\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    check dirsettings.dirSandboxOverridden
    sandboxEnabled = true

  test "conflicting aliases resolve to the primary spelling":
    let f = newFixture("sbalias")
    defer: dropFixture(f.base)
    sandboxEnabled = true
    writeStoreConfig(f.proj,
      "[settings]\nsandbox = \"on\"\nsandbox_enabled = \"off\"\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    check not dirsettings.dirSandboxOverridden
    # Even flipped, the refused spelling cannot win through the alias.
    writeStoreConfig(f.proj,
      "[settings]\nsandbox = \"off\"\nsandbox_enabled = \"on\"\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    sandboxEnabled = true

  test "missing and malformed store configs stay harmless":
    # No store, no authority, no flags; a broken config reads as empty.
    let f = newFixture("sbmiss")
    defer: dropFixture(f.base)
    sandboxEnabled = true
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    check not dirsettings.dirSandboxOverridden
    createDir(f.proj / ".3code")
    writeFile(f.proj / ".3code" / "config",
      "[settings]\nsandbox = = garbage\n")
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    check not dirsettings.dirSandboxOverridden
    sandboxEnabled = true

  test "dirconfig = user makes the store's disable authoritative":
    let f = newFixture("sbuser")
    defer: dropFixture(f.base)
    dirsettings.dirConfigLocation = "user"
    sandboxEnabled = true
    let store = dirsettings.storeDirFor(f.proj)
    createDir(store)
    writeFile(store / "config", "[settings]\nsandbox = \"off\"\n")
    dirsettings.applyDirConfig(f.sub)
    check not sandboxEnabled
    check dirsettings.dirSandboxOverridden
    # The warning switch obeys the same authority.
    sandboxWallWarn = true
    writeFile(store / "config",
      "[settings]\nsandbox_wall_warn = \"off\"\n")
    dirsettings.applyDirConfig(f.sub)
    check not sandboxWallWarn
    check dirsettings.dirWallWarnOverridden
    # Back to project mode, the same file content has no authority.
    dirsettings.dirConfigLocation = "project"
    sandboxEnabled = true
    sandboxWallWarn = true
    dirsettings.applyDirConfig(f.sub)
    check sandboxEnabled
    check sandboxWallWarn
    sandboxEnabled = true
    sandboxWallWarn = true

  test "the overlay survives a re-parse of the user config":
    # Startup applies the overlay before and again after the full parse;
    # the parse must not hand the refusal a second chance.
    let f = newFixture("sbreparse")
    defer: dropFixture(f.base)
    let cfgPath = f.base / "cfg" / "3code" / "config"
    createDir(cfgPath.parentDir)
    writeFile(cfgPath, "[settings]\nsandbox = \"off\"\n")
    writeStoreConfig(f.proj, "[settings]\nsandbox = \"on\"\n")
    discard tryLoadStateOrEmpty(cfgPath)
    check not sandboxEnabled
    dirsettings.applyDirConfig(f.proj)
    check sandboxEnabled  # tightened
    discard tryLoadStateOrEmpty(cfgPath)  # the full parse re-applies off
    dirsettings.applyDirConfig(f.proj)
    check sandboxEnabled
    sandboxEnabled = true
    dirsettings.dirConfigLocation = "project"

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

  test "a refused disable is never hoisted into the user config":
    # The full startup contract: user config on, project store off. The
    # session runs confined, and every config write round-trip (other
    # instances re-parse the file) stays confined too.
    let f = newFixture("sbnohoist")
    defer: dropFixture(f.base)
    let cfgPath = f.base / "cfg" / "3code" / "config"
    createDir(cfgPath.parentDir)
    writeFile(cfgPath, "[settings]\ncurrent = \"x.y\"\n")
    writeStoreConfig(f.proj, "[settings]\nsandbox = \"off\"\n")
    discard tryLoadStateOrEmpty(cfgPath)
    dirsettings.applyDirConfig(f.proj)
    check sandboxEnabled
    writeConfigFile(cfgPath, "x.y", @[])
    check "sandbox" notin readFile(cfgPath)
    # And the reload lands where the round started.
    discard tryLoadStateOrEmpty(cfgPath)
    dirsettings.applyDirConfig(f.proj)
    check sandboxEnabled
    sandboxEnabled = true

  test "a tightening persists the user's off, not the store's on":
    let f = newFixture("sbtightsave")
    defer: dropFixture(f.base)
    let cfgPath = f.base / "cfg" / "3code" / "config"
    createDir(cfgPath.parentDir)
    writeFile(cfgPath, "[settings]\ncurrent = \"x.y\"\n")
    writeStoreConfig(f.proj, "[settings]\nsandbox = \"on\"\n")
    discard tryLoadStateOrEmpty(cfgPath)  # no switch in the user config
    sandboxEnabled = false  # as if an earlier parse had said off
    dirsettings.applyDirConfig(f.proj)
    check sandboxEnabled
    check dirsettings.dirSandboxOverridden
    writeConfigFile(cfgPath, "x.y", @[])
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

suite "dirsettings: settings cascade":
  # Every [settings] key follows the ladder: compiled default < user
  # config < nearest store. The two security switches keep their clamp
  # (suite above); `current` stays owned by the sticky-current resolver
  # and `dirconfig` by the user config, so neither cascades from a
  # store.

  proc resetSettingsGlobals() =
    notifyEnabled = true
    streamingEnabled = true
    maxTimeoutSetting = 0
    bannerLinesSetting = 1
    colorModePref = cmAuto
    verifierEnabled = false
    verifierModelSpec = ""
    providerWhitelist = @[]
    storeOverlayKeys = initHashSet[string]()
    userSettingsRaw = initTable[string, string]()
    activeProviders = @[]
    activeCurrent = ""

  test "every settings key cascades, nearest store winning":
    let f = newFixture("allkeys")
    defer:
      resetSettingsGlobals()
      dropFixture(f.base)
    let cfgPath = f.base / "cfg" / "3code" / "config"
    createDir(cfgPath.parentDir)
    writeFile(cfgPath,
      "[settings]\nnotify = \"off\"\nmax_timeout = \"111\"\n" &
      "tone = \"dark\"\n")
    writeStoreConfig(f.base,
      "[settings]\nbanner_lines = \"7\"\ntone = \"light\"\n")
    writeStoreConfig(f.proj, "[settings]\nnotify = \"on\"\n")
    discard tryLoadStateOrEmpty(cfgPath)
    check not notifyEnabled        # the user config's own line
    check maxTimeoutSetting == 111 # user config
    check colorModePref == cmDark  # user config
    applyDirSettingsOverlay(f.sub)
    check notifyEnabled            # nearest store overrides the user line
    check maxTimeoutSetting == 111 # store silent: the user value stands
    check bannerLinesSetting == 7  # store only
    check colorModePref == cmLight # nearer store's tone over the farther

  test "a store value never leaks into the user config":
    let f = newFixture("noleakall")
    defer:
      resetSettingsGlobals()
      dropFixture(f.base)
    let cfgPath = f.base / "cfg" / "3code" / "config"
    createDir(cfgPath.parentDir)
    writeFile(cfgPath, "[settings]\ncurrent = \"x.y\"\nstreaming = \"on\"\n")
    writeStoreConfig(f.proj,
      "[settings]\nstreaming = \"off\"\nnotify = \"off\"\n" &
      "max_timeout = \"555\"\n")
    discard tryLoadStateOrEmpty(cfgPath)
    applyDirSettingsOverlay(f.proj)
    check not streamingEnabled
    check not notifyEnabled
    check maxTimeoutSetting == 555
    writeConfigFile(cfgPath, "x.y", @[])
    let body = readFile(cfgPath)
    check "streaming" notin body  # the user's on == default: omitted
    check "notify" notin body
    check "max_timeout" notin body

  test "claimSetting persists the in-session choice":
    let f = newFixture("claim")
    defer:
      resetSettingsGlobals()
      dropFixture(f.base)
    let cfgPath = f.base / "cfg" / "3code" / "config"
    createDir(cfgPath.parentDir)
    writeFile(cfgPath, "[settings]\ncurrent = \"x.y\"\n")
    writeStoreConfig(f.proj, "[settings]\nstreaming = \"off\"\n")
    discard tryLoadStateOrEmpty(cfgPath)
    applyDirSettingsOverlay(f.proj)
    check not streamingEnabled
    streamingEnabled = false
    claimSetting("streaming")
    writeConfigFile(cfgPath, "x.y", @[])
    check "streaming = \"off\"" in readFile(cfgPath)

  test "a store's verifier_model enables the verifier":
    let f = newFixture("vstore")
    defer:
      resetSettingsGlobals()
      dropFixture(f.base)
    let cfgPath = f.base / "cfg" / "3code" / "config"
    createDir(cfgPath.parentDir)
    writeFile(cfgPath, "[settings]\ncurrent = \"x.y\"\n")
    writeStoreConfig(f.proj,
      "[settings]\nverifier_model = \"openrouter.typesafe/jev-latest\"\n")
    discard tryLoadStateOrEmpty(cfgPath)
    check not verifierEnabled
    applyDirSettingsOverlay(f.proj)
    check verifierEnabled
    check verifierModelSpec == "openrouter.typesafe/jev-latest"
    # An explicit user `verifier = off` still wins over the store pick.
    writeFile(cfgPath,
      "[settings]\ncurrent = \"x.y\"\nverifier = \"off\"\n" &
      "verifier_model = \"openrouter.typesafe/jev-latest\"\n")
    resetSettingsGlobals()
    discard tryLoadStateOrEmpty(cfgPath)
    applyDirSettingsOverlay(f.proj)
    check not verifierEnabled

  test "limitproviders cascades and narrows the selectable set":
    let f = newFixture("limit")
    defer:
      resetSettingsGlobals()
      dropFixture(f.base)
    let cfgPath = f.base / "cfg" / "3code" / "config"
    createDir(cfgPath.parentDir)
    writeFile(cfgPath, "[settings]\ncurrent = \"x.y\"\nlimitproviders = \"zai\"\n")
    writeStoreConfig(f.proj, "[settings]\nlimitproviders = \"zai, mistral\"\n")
    discard tryLoadStateOrEmpty(cfgPath)
    check providerWhitelist == @["zai"]
    activeProviders = @[
      ProviderRec(name: "zai", url: "https://z.ai", key: "k",
                  models: @["glm-5.2"]),
      ProviderRec(name: "mistral", url: "https://api.mistral.ai", key: "k",
                  models: @["glm-5.2"]),
      ProviderRec(name: "venice", url: "https://venice.ai", key: "k",
                  models: @["glm-5.2"])]
    applyDirSettingsOverlay(f.sub)
    check providerWhitelist == @["zai", "mistral"]
    check selectableProviders().mapIt(it.name) == @["zai", "mistral"]
    check providerAllowed("zai")
    check not providerAllowed("venice")
    # Hand-edited key: a config write must not persist the store's list.
    writeConfigFile(cfgPath, "", @[])
    check "limitproviders" notin readFile(cfgPath)
