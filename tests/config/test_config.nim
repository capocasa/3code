import std/[os, strutils, tables, unittest]
import threecode/[config, types, util]

suite "config: [search] key":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-search.ini"
    activeSearchKey = ""

  teardown:
    removeFile(tmp)
    activeSearchKey = ""

  test "parseConfigFile returns the [search] key when set":
    writeFile(tmp, "[search]\nkey = \"exa-abc123\"\n")
    let (_, _, _, searchKey) = parseConfigFile(tmp)
    check searchKey == "exa-abc123"

  test "parseConfigFile returns empty string when [search] key is absent":
    writeFile(tmp, "[settings]\ncurrent = \"some-provider\"\n")
    let (_, _, _, searchKey) = parseConfigFile(tmp)
    check searchKey == ""

  test "loadStateOrEmpty sets activeSearchKey from [search] key":
    writeFile(tmp, "[search]\nkey = \"exa-from-config\"\n")
    discard loadStateOrEmpty(tmp)
    check activeSearchKey == "exa-from-config"

  test "activeSearchKey defaults to empty":
    check activeSearchKey == ""

suite "config: streaming toggle":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-streaming.ini"
    streamingEnabled = true  # reset to default between tests

  teardown:
    removeFile(tmp)
    streamingEnabled = true

  test "streamingEnabled stays on when [settings] omits the key":
    writeFile(tmp, "[settings]\ncurrent = \"p.m\"\n")
    discard parseConfigFile(tmp)
    check streamingEnabled == true

  test "parseConfigFile sets streaming off when [settings] streaming = off":
    writeFile(tmp, "[settings]\nstreaming = \"off\"\n")
    discard parseConfigFile(tmp)
    check streamingEnabled == false

  test "parseConfigFile keeps streaming on when [settings] streaming = on":
    streamingEnabled = false
    writeFile(tmp, "[settings]\nstreaming = \"on\"\n")
    discard parseConfigFile(tmp)
    check streamingEnabled == true

  test "parseConfigFile accepts boolean dialect (yes/1/false/0)":
    writeFile(tmp, "[settings]\nstreaming = \"no\"\n")
    discard parseConfigFile(tmp)
    check streamingEnabled == false
    writeFile(tmp, "[settings]\nstreaming = \"1\"\n")
    discard parseConfigFile(tmp)
    check streamingEnabled == true

  test "writeConfigFile persists streaming off and not when on":
    streamingEnabled = false
    writeConfigFile(tmp, "p.m", @[])
    let raw = readFile(tmp)
    check raw.find("streaming = \"off\"") >= 0
    streamingEnabled = true
    writeConfigFile(tmp, "p.m", @[])
    let raw2 = readFile(tmp)
    check raw2.find("streaming") < 0  # on is the default — clean config

suite "config: notify toggle":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-notify.ini"
    notifyEnabled = true  # reset to default between tests

  teardown:
    removeFile(tmp)
    notifyEnabled = true

  test "notifyEnabled defaults on":
    check notifyEnabled == true

  test "notifyEnabled stays on when [settings] omits the key":
    writeFile(tmp, "[settings]\ncurrent = \"p.m\"\n")
    discard parseConfigFile(tmp)
    check notifyEnabled == true

  test "parseConfigFile sets notify off when [settings] notify = off":
    writeFile(tmp, "[settings]\nnotify = \"off\"\n")
    discard parseConfigFile(tmp)
    check notifyEnabled == false

  test "parseConfigFile keeps notify on when [settings] notify = on":
    notifyEnabled = false
    writeFile(tmp, "[settings]\nnotify = \"on\"\n")
    discard parseConfigFile(tmp)
    check notifyEnabled == true

  test "writeConfigFile persists notify off and not when on":
    notifyEnabled = false
    writeConfigFile(tmp, "p.m", @[])
    let raw = readFile(tmp)
    check raw.find("notify = \"off\"") >= 0
    notifyEnabled = true
    writeConfigFile(tmp, "p.m", @[])
    let raw2 = readFile(tmp)
    check raw2.find("notify") < 0  # on is the default — clean config

suite "config: sandbox toggle":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-sandbox.ini"
    sandboxEnabled = true  # reset to default between tests

  teardown:
    removeFile(tmp)
    sandboxEnabled = true

  test "sandboxEnabled defaults on":
    check sandboxEnabled == true

  test "sandboxEnabled stays on when [settings] omits the key":
    writeFile(tmp, "[settings]\ncurrent = \"p.m\"\n")
    discard parseConfigFile(tmp)
    check sandboxEnabled == true

  test "parseConfigFile sets sandbox off when [settings] sandbox = off":
    writeFile(tmp, "[settings]\nsandbox = \"off\"\n")
    discard parseConfigFile(tmp)
    check sandboxEnabled == false

  test "parseConfigFile keeps sandbox on when [settings] sandbox = on":
    sandboxEnabled = false
    writeFile(tmp, "[settings]\nsandbox = \"on\"\n")
    discard parseConfigFile(tmp)
    check sandboxEnabled == true

  test "writeConfigFile persists sandbox off and not when on":
    sandboxEnabled = false
    writeConfigFile(tmp, "p.m", @[])
    let raw = readFile(tmp)
    check raw.find("sandbox = \"off\"") >= 0
    sandboxEnabled = true
    writeConfigFile(tmp, "p.m", @[])
    let raw2 = readFile(tmp)
    check raw2.find("sandbox") < 0  # on is the default — clean config

suite "config: [settings] mode":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-mode.ini"
    colorModePref = cmAuto

  teardown:
    removeFile(tmp)
    colorModePref = cmAuto

  test "parseConfigFile reads mode = bright as cmLight":
    writeFile(tmp, "[settings]\nmode = \"bright\"\n")
    discard parseConfigFile(tmp)
    check colorModePref == cmLight

  test "parseConfigFile accepts light as an alias for bright":
    writeFile(tmp, "[settings]\nmode = \"light\"\n")
    discard parseConfigFile(tmp)
    check colorModePref == cmLight

  test "parseConfigFile reads mode = dark as cmDark":
    writeFile(tmp, "[settings]\nmode = \"dark\"\n")
    discard parseConfigFile(tmp)
    check colorModePref == cmDark

  test "parseConfigFile leaves the default cmAuto when mode is absent":
    writeFile(tmp, "[settings]\ncurrent = \"p.m\"\n")
    discard parseConfigFile(tmp)
    check colorModePref == cmAuto

  test "writeConfigFile persists mode only when forced (auto is the default)":
    colorModePref = cmLight
    writeConfigFile(tmp, "p.m", @[])
    let raw = readFile(tmp)
    check raw.find("mode = \"bright\"") >= 0
    colorModePref = cmAuto
    writeConfigFile(tmp, "p.m", @[])
    let raw2 = readFile(tmp)
    check raw2.find("mode") < 0  # auto is the default — clean config

suite "config: [colors] section":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-colors.ini"

  teardown:
    removeFile(tmp)

  test "parseConfigFile collects [colors] keys verbatim (suffix kept)":
    writeFile(tmp, "[colors]\nbright-white = \"\\x1b[37m\"\nbright-white-light = \"\\x1b[90m\"\n")
    let (_, _, colors, _) = parseConfigFile(tmp)
    # parsecfg interprets the backslash escape, so the value is the real
    # ESC byte, not the literal text "\x1b".
    check colors["bright-white"] == "\x1b[37m"
    check colors["bright-white-light"] == "\x1b[90m"

  test "parseConfigFile returns empty table when no [colors] section":
    writeFile(tmp, "[settings]\ncurrent = \"p.m\"\n")
    let (_, _, colors, _) = parseConfigFile(tmp)
    check colors.len == 0

  test "loadStateOrEmpty returns the colors map":
    writeFile(tmp, "[colors]\ndim-white = \"\\x1b[38;5;240m\"\n")
    let (_, _, colors) = loadStateOrEmpty(tmp)
    check colors["dim-white"] == "\x1b[38;5;240m"
