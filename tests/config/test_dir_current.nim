import std/[os, strutils, tables, unittest]
import threecode/[session, util, dirsettings, types]

suite "config: per-directory sticky current":
  var tmpRoot, projA, projB, subA: string

  setup:
    tmpRoot = getTempDir() / "3code-test-dircurrent-" & $getCurrentProcessId()
    projA = tmpRoot / "projA"
    projB = tmpRoot / "projB"
    subA = projA / "sub"
    createDir(projA)
    createDir(projB)
    createDir(subA)
    putEnv("XDG_DATA_HOME", tmpRoot / "data")
    putEnv("XDG_CONFIG_HOME", tmpRoot / "cfg")
    dirsettings.dirConfigLocation = "project"

  teardown:
    dirsettings.dirConfigLocation = "project"
    if getEnv("XDG_DATA_HOME") == tmpRoot / "data":
      delEnv("XDG_DATA_HOME")
    if getEnv("XDG_CONFIG_HOME") == tmpRoot / "cfg":
      delEnv("XDG_CONFIG_HOME")
    removeDir(tmpRoot)

  test "unset directory reads empty":
    check loadDirCurrent(projA) == ""

  test "save then load round-trips per directory":
    saveDirCurrent(projA, "zai.glm-5.2")
    saveDirCurrent(projB, "openai.gpt-4o")
    check loadDirCurrent(projA) == "zai.glm-5.2"
    check loadDirCurrent(projB) == "openai.gpt-4o"

  test "the store's config carries the current entry":
    saveDirCurrent(projA, "zai.glm-5.2")
    check fileExists(projA / ".3code" / "config")
    let t = dirsettings.readStoreSettings(projA / ".3code")
    check t.getOrDefault("current", "") == "zai.glm-5.2"

  test "a parent's current cascades into subdirectories":
    # The fix for "default provider reverts to the first section": a
    # provider picked at a project root sticks in every subdirectory.
    saveDirCurrent(projA, "zai.glm-5.2")
    check loadDirCurrent(subA) == "zai.glm-5.2"
    check loadDirCurrent(projB) == ""

  test "the nearest directory wins over a farther parent":
    saveDirCurrent(projA, "zai.glm-5.2")
    saveDirCurrent(subA, "openai.gpt-4o")
    check loadDirCurrent(subA) == "openai.gpt-4o"
    check loadDirCurrent(projA) == "zai.glm-5.2"

  test "save preserves other lines in the store config":
    createDir(projA / ".3code")
    writeFile(projA / ".3code" / "config",
      "[settings]\nsandbox = \"off\"\n; a note\ncurrent = \"old.x\"\n")
    saveDirCurrent(projA, "zai.glm-5.2")
    let text = readFile(projA / ".3code" / "config")
    check "sandbox = \"off\"" in text
    check "; a note" in text
    check "current = \"zai.glm-5.2\"" in text
    check "old.x" notin text
    check loadDirCurrent(projA) == "zai.glm-5.2"

  test "legacy .current file still reads as fallback":
    let path = dirsettings.legacyDirCurrentPath(projB)
    createDir(path.parentDir)
    writeFile(path, "zai.glm-5.2\n")
    check loadDirCurrent(projB) == "zai.glm-5.2"
    # A store entry, even from a parent, outranks the legacy file.
    saveDirCurrent(tmpRoot, "openai.gpt-4o")
    check loadDirCurrent(projB) == "openai.gpt-4o"

  test "distinct directories never share a slot":
    saveDirCurrent(projA, "zai.glm-5.2")
    check loadDirCurrent(projB) == ""

  test "blank entry reads empty":
    createDir(projA / ".3code")
    writeFile(projA / ".3code" / "config", "[settings]\ncurrent = \"\"\n")
    check loadDirCurrent(projA) == ""

  test "dirconfig = user stores under the config root":
    dirsettings.dirConfigLocation = "user"
    saveDirCurrent(projA, "zai.glm-5.2")
    let store = tmpRoot / "cfg" / "3code" / "dirs" / mangleCwd(projA)
    check fileExists(store / "config")
    check loadDirCurrent(projA) == "zai.glm-5.2"
    check loadDirCurrent(subA) == "zai.glm-5.2"
    check loadDirCurrent(projB) == ""
    # Project stores are invisible while the user location is selected.
    saveDirCurrent(projB, "openai.gpt-4o")
    check loadDirCurrent(projA) == "zai.glm-5.2"
