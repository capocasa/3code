import std/[os, strutils, unittest]
import threecode/[session, util]

suite "config: per-directory sticky current":
  var tmpRoot, projA, projB: string

  setup:
    tmpRoot = getTempDir() / "3code-test-dircurrent-" & $getCurrentProcessId()
    projA = tmpRoot / "projA"
    projB = tmpRoot / "projB"
    createDir(projA)
    createDir(projB)
    putEnv("XDG_DATA_HOME", tmpRoot / "data")

  teardown:
    if getEnv("XDG_DATA_HOME") == tmpRoot / "data":
      delEnv("XDG_DATA_HOME")
    removeDir(tmpRoot)

  test "unset directory reads empty":
    check loadDirCurrent(projA) == ""

  test "save then load round-trips per directory":
    saveDirCurrent(projA, "zai.glm-5.2")
    saveDirCurrent(projB, "openai.gpt-4o")
    check loadDirCurrent(projA) == "zai.glm-5.2"
    check loadDirCurrent(projB) == "openai.gpt-4o"

  test "distinct directories never share a slot":
    saveDirCurrent(projA, "zai.glm-5.2")
    check loadDirCurrent(projB) == ""

  test "path keys on the mangled cwd like sessions and drafts":
    check dirCurrentPathFor(projA).endsWith("dirs" / mangleCwd(projA) & ".current")

  test "blank file reads empty":
    let path = dirCurrentPathFor(projA)
    createDir(path.parentDir)
    writeFile(path, "\n")
    check loadDirCurrent(projA) == ""
