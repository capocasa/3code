## The provider-usage ledger and the default-provider ladder:
## `bumpProviderUsage` counting, the highest-count-first file order,
## `mostUsedCurrent` picking the no-`current` default (stale entries
## skipped, empty ledger empty), and `resolveDefaultCurrent` walking the
## whole startup ladder — directory store cascade, config `current`,
## most-used ledger — through real `.3code` store fixtures.

import std/[os, unittest]
import threecode/[config, dirsettings, types]

proc newLedgerFixture(name: string): string =
  let base = getTempDir() / ("3code-test-mostused-" & name & "-" &
    $getCurrentProcessId())
  if dirExists(base): removeDir(base)
  createDir(base)
  putEnv("XDG_CONFIG_HOME", base / "cfg")
  putEnv("XDG_DATA_HOME", base / "data")
  dirsettings.dirConfigLocation = "project"
  base

proc dropLedgerFixture(base: string) =
  dirsettings.dirConfigLocation = "project"
  if getEnv("XDG_CONFIG_HOME") == base / "cfg": delEnv("XDG_CONFIG_HOME")
  if getEnv("XDG_DATA_HOME") == base / "data": delEnv("XDG_DATA_HOME")
  removeDir(base)

suite "config: most-used provider default":
  var base: string
  var zai, openai: ProviderRec

  setup:
    base = getTempDir() / "3code-test-mostused-" & $getCurrentProcessId()
    if dirExists(base): removeDir(base)
    createDir(base)
    putEnv("XDG_DATA_HOME", base / "data")
    zai = ProviderRec(name: "zai", url: "https://api.z.ai/api/paas/v4",
                      key: "k", models: @["glm-5.2", "glm-5.3"])
    openai = ProviderRec(name: "openai", url: "https://api.openai.com/v1",
                         key: "k", models: @["gpt-5.4"])

  teardown:
    if getEnv("XDG_DATA_HOME") == base / "data":
      delEnv("XDG_DATA_HOME")
    removeDir(base)

  test "empty ledger reads empty":
    check readProviderUsage().len == 0
    check mostUsedCurrent(@[zai, openai]) == ""

  test "bump writes the ledger and counts up":
    bumpProviderUsage("zai.glm-5.2")
    bumpProviderUsage("zai.glm-5.2")
    bumpProviderUsage("openai.gpt-5.4")
    let entries = readProviderUsage()
    check entries.len == 2
    check entries[0] == ("zai.glm-5.2", 2)
    check entries[1] == ("openai.gpt-5.4", 1)

  test "most-used wins over the first provider section":
    bumpProviderUsage("zai.glm-5.2")
    bumpProviderUsage("openai.gpt-5.4")
    bumpProviderUsage("openai.gpt-5.4")
    check mostUsedCurrent(@[zai, openai]) == "openai.gpt-5.4"

  test "stale entries are skipped":
    bumpProviderUsage("gone.glm-5.2")
    bumpProviderUsage("zai.glm-5.3")
    check mostUsedCurrent(@[zai]) == "zai.glm-5.3"

  test "a stale model on a live provider is skipped":
    bumpProviderUsage("zai.glm-4.7")
    bumpProviderUsage("zai.glm-5.3")
    check mostUsedCurrent(@[zai]) == "zai.glm-5.3"

  test "the picked default resolves through buildProfile":
    bumpProviderUsage("openai.gpt-5.4")
    let pick = mostUsedCurrent(@[zai, openai])
    check buildProfile(pick, @[zai, openai], "").name == "openai.gpt-5.4"

  test "ties keep their prior order":
    bumpProviderUsage("zai.glm-5.2")
    bumpProviderUsage("openai.gpt-5.4")
    let entries = readProviderUsage()
    check entries[0][0] == "zai.glm-5.2"
    bumpProviderUsage("openai.gpt-5.4")
    let after = readProviderUsage()
    check after[0][0] == "openai.gpt-5.4"
    check after[1][0] == "zai.glm-5.2"

  test "malformed ledger lines are skipped":
    createDir(base / "data" / "3code")
    writeFile(base / "data" / "3code" / "provider-usage",
      "garbage\n\nzai.glm-5.2 notanumber\nopenai.gpt-5.4 1\n")
    let entries = readProviderUsage()
    check entries.len == 1
    check entries[0] == ("openai.gpt-5.4", 1)
    check mostUsedCurrent(@[zai, openai]) == "openai.gpt-5.4"

  test "empty current never bumps":
    bumpProviderUsage("")
    check readProviderUsage().len == 0

suite "config: default-provider ladder":
  ## resolveDefaultCurrent: the whole startup ladder through real store
  ## fixtures — directory cascade, config current, most-used ledger,
  ## first-section floor.
  var base, root, sub: string
  var zai, openai: ProviderRec

  setup:
    base = newLedgerFixture("ladder")
    root = base / "proj"
    sub = root / "sub"
    createDir(sub)
    zai = ProviderRec(name: "zai", url: "https://api.z.ai/api/paas/v4",
                      key: "k", models: @["glm-5.2", "glm-5.3"])
    openai = ProviderRec(name: "openai", url: "https://api.openai.com/v1",
                         key: "k", models: @["gpt-5.4"])

  teardown:
    dropLedgerFixture(base)

  test "no stores, no current, no ledger: empty (first-section floor)":
    check resolveDefaultCurrent(sub, "", @[zai, openai]) == ""

  test "no stores, no current: the most-used provider":
    bumpProviderUsage("zai.glm-5.3")
    bumpProviderUsage("openai.gpt-5.4")
    bumpProviderUsage("openai.gpt-5.4")
    check resolveDefaultCurrent(sub, "", @[zai, openai]) == "openai.gpt-5.4"

  test "the config current beats the ledger":
    bumpProviderUsage("openai.gpt-5.4")
    bumpProviderUsage("openai.gpt-5.4")
    check resolveDefaultCurrent(sub, "zai.glm-5.2", @[zai, openai]) ==
      "zai.glm-5.2"

  test "a parent store cascades into subdirectories":
    # The goal's example: a project root's `.3code/config` sets
    # zaicode/glm-5.3-class current; every subdirectory follows it, not
    # the config file's own pick and not the ledger.
    createDir(root / ".3code")
    writeFile(root / ".3code" / "config",
      "[settings]\ncurrent = \"zai.glm-5.3\"\n")
    bumpProviderUsage("openai.gpt-5.4")
    bumpProviderUsage("openai.gpt-5.4")
    check resolveDefaultCurrent(sub, "zai.glm-5.2", @[zai, openai]) ==
      "zai.glm-5.3"
    # The root itself reads its own store too.
    check resolveDefaultCurrent(root, "zai.glm-5.2", @[zai, openai]) ==
      "zai.glm-5.3"

  test "the nearest store wins over a farther parent":
    createDir(root / ".3code")
    writeFile(root / ".3code" / "config",
      "[settings]\ncurrent = \"zai.glm-5.3\"\n")
    createDir(sub / ".3code")
    writeFile(sub / ".3code" / "config",
      "[settings]\ncurrent = \"openai.gpt-5.4\"\n")
    check resolveDefaultCurrent(sub, "", @[zai, openai]) == "openai.gpt-5.4"
    check resolveDefaultCurrent(root, "", @[zai, openai]) == "zai.glm-5.3"

  test "a stale store current falls through to the config current":
    createDir(root / ".3code")
    writeFile(root / ".3code" / "config",
      "[settings]\ncurrent = \"gone.glm-5.3\"\n")
    check resolveDefaultCurrent(sub, "zai.glm-5.2", @[zai, openai]) ==
      "zai.glm-5.2"

  test "a stale config current is passed through untouched":
    check resolveDefaultCurrent(sub, "gone.glm-5.3", @[zai, openai]) ==
      "gone.glm-5.3"
