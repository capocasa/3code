## First-run detection: the bootstrap wizard may open only when no config
## file exists. A config with no usable provider is a warning, not a first
## run. The tty harness's [test]-only config is the one exception: it is
## IPC plumbing, not user configuration.

import std/[os, unittest]
import threecode/config

suite "config: first-run detection":
  var
    tmp, savedXdg, savedProject: string
    savedLayers: seq[string]
    hadXdg, savedCleared: bool

  setup:
    hadXdg = existsEnv("XDG_CONFIG_HOME")
    savedXdg = getEnv("XDG_CONFIG_HOME")
    savedLayers = configLayers
    savedCleared = configCleared
    savedProject = projectLayer
    tmp = getTempDir() / ("3code-test-firstrun-" & $getCurrentProcessId())
    removeDir(tmp)
    createDir(tmp)
    putEnv("XDG_CONFIG_HOME", tmp)
    configLayers = @[]
    configCleared = false
    projectLayer = ""

  teardown:
    configLayers = savedLayers
    configCleared = savedCleared
    projectLayer = savedProject
    if hadXdg: putEnv("XDG_CONFIG_HOME", savedXdg)
    else: delEnv("XDG_CONFIG_HOME")
    removeDir(tmp)

  test "no config file is a first run":
    check firstExistingConfigFile() == ""

  test "a [test]-only config is not user configuration":
    let path = tmp / "3code" / "config"
    createDir(path.parentDir)
    writeFile(path, "[test]\nframe_fd = \"7\"\n")
    check firstExistingConfigFile() == ""

  test "an empty config file is not a first run":
    let path = tmp / "3code" / "config"
    createDir(path.parentDir)
    writeFile(path, "")
    check firstExistingConfigFile() == path

  test "a settings-only config is not a first run":
    let path = tmp / "3code" / "config"
    createDir(path.parentDir)
    writeFile(path, "[settings]\nsandbox = \"off\"\n")
    check firstExistingConfigFile() == path

  test "-C still sees an existing user config":
    let path = tmp / "3code" / "config"
    createDir(path.parentDir)
    writeFile(path, "[settings]\n")
    configCleared = true
    check firstExistingConfigFile() == path
