import std/[options, os, strutils, tables, unittest]
import threecode/[config, types, util]

suite "config: [search]":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-search.ini"
    activeSearchKey = ""
    activeSearchKeys = initTable[string, string]()
    activeSearchEngine = "exa"

  teardown:
    removeFile(tmp)
    activeSearchKey = ""
    activeSearchKeys = initTable[string, string]()
    activeSearchEngine = "exa"

  test "parseConfigFile collects engine-specific keys":
    writeFile(tmp, "[search]\nexa-key = \"e1\"\nbrave-key = \"b1\"\n")
    let (_, _, _, searchKeys, _, _) = parseConfigFile(tmp)
    check searchKeys["exa"] == "e1"
    check searchKeys["brave"] == "b1"

  test "parseConfigFile returns empty table when no keys set":
    writeFile(tmp, "[settings]\ncurrent = \"some-provider\"\n")
    let (_, _, _, searchKeys, _, _) = parseConfigFile(tmp)
    check searchKeys.len == 0

  test "legacy bare key is filed under the active engine":
    writeFile(tmp, "[search]\nengine = \"brave\"\nkey = \"legacy\"\n")
    let (_, _, _, searchKeys, _, _) = parseConfigFile(tmp)
    check searchKeys["brave"] == "legacy"

  test "legacy bare key defaults to exa when no engine set":
    writeFile(tmp, "[search]\nkey = \"legacy\"\n")
    let (_, _, _, searchKeys, _, _) = parseConfigFile(tmp)
    check searchKeys["exa"] == "legacy"

  test "parseConfigFile returns the [search] engine when set":
    writeFile(tmp, "[search]\nengine = \"parallel\"\n")
    let (_, _, _, _, searchEngine, _) = parseConfigFile(tmp)
    check searchEngine == "parallel"

  test "parseConfigFile lowercases the engine value":
    writeFile(tmp, "[search]\nengine = \"Brave\"\n")
    let (_, _, _, _, searchEngine, _) = parseConfigFile(tmp)
    check searchEngine == "brave"

  test "parseConfigFile returns empty engine when absent":
    writeFile(tmp, "[settings]\ncurrent = \"p.m\"\n")
    let (_, _, _, _, searchEngine, _) = parseConfigFile(tmp)
    check searchEngine == ""

  test "loadStateOrEmpty resolves the active engine's key":
    writeFile(tmp, "[search]\nengine = \"brave\"\nbrave-key = \"bk\"\nexa-key = \"ek\"\n")
    discard loadStateOrEmpty(tmp)
    check activeSearchEngine == "brave"
    check activeSearchKey == "bk"
    check activeSearchKeys["exa"] == "ek"

  test "activeSearchKey/Keys/Engine default to exa/empty":
    check activeSearchKey == ""
    check activeSearchKeys.len == 0
    check activeSearchEngine == "exa"

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

  test "parseConfigFile reads tone = light as cmLight":
    writeFile(tmp, "[settings]\ntone = \"light\"\n")
    discard parseConfigFile(tmp)
    check colorModePref == cmLight

  test "parseConfigFile accepts legacy mode/bright spellings":
    for kv in ["mode = \"bright\"", "mode = \"light\"", "tone = \"bright\""]:
      writeFile(tmp, "[settings]\n" & kv & "\n")
      discard parseConfigFile(tmp)
      check colorModePref == cmLight
      colorModePref = cmAuto

  test "parseConfigFile reads tone = dark as cmDark":
    writeFile(tmp, "[settings]\ntone = \"dark\"\n")
    discard parseConfigFile(tmp)
    check colorModePref == cmDark

  test "parseConfigFile leaves the default cmAuto when tone is absent":
    writeFile(tmp, "[settings]\ncurrent = \"p.m\"\n")
    discard parseConfigFile(tmp)
    check colorModePref == cmAuto

  test "writeConfigFile persists tone only when forced (auto is the default)":
    colorModePref = cmLight
    writeConfigFile(tmp, "p.m", @[])
    let raw = readFile(tmp)
    check raw.find("tone = \"light\"") >= 0
    colorModePref = cmAuto
    writeConfigFile(tmp, "p.m", @[])
    let raw2 = readFile(tmp)
    check raw2.find("tone") < 0  # auto is the default — clean config

suite "config: [colors] section":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-colors.ini"

  teardown:
    removeFile(tmp)

  test "parseConfigFile collects [colors] keys verbatim (suffix kept)":
    writeFile(tmp, "[colors]\nbright-white = \"\\x1b[37m\"\nbright-white-light = \"\\x1b[90m\"\n")
    let (_, _, colors, _, _, _) = parseConfigFile(tmp)
    # parsecfg interprets the backslash escape, so the value is the real
    # ESC byte, not the literal text "\x1b".
    check colors["bright-white"] == "\x1b[37m"
    check colors["bright-white-light"] == "\x1b[90m"

  test "parseConfigFile returns empty table when no [colors] section":
    writeFile(tmp, "[settings]\ncurrent = \"p.m\"\n")
    let (_, _, colors, _, _, _) = parseConfigFile(tmp)
    check colors.len == 0

  test "loadStateOrEmpty returns the colors map":
    writeFile(tmp, "[colors]\ndim-white = \"\\x1b[38;5;240m\"\n")
    let (_, _, colors) = loadStateOrEmpty(tmp)
    check colors["dim-white"] == "\x1b[38;5;240m"

suite "config: [provider.params]":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-pparams.ini"

  teardown:
    removeFile(tmp)

  test "params attach to the nearest preceding [provider]":
    writeFile(tmp, """
[provider]
name = "zai"
url = "https://z.ai/v1"
key = "k"
models = "glm-5.2"

[provider.params]
temperature = "0.4"
max-tokens = "16384"
think-back = "none"
context-window = "250000"

[provider]
name = "openai"
url = "https://api.openai.com/v1"
key = "k"
models = "gpt-5.5"
""")
    let (_, providers, _, _, _, _) = parseConfigFile(tmp)
    check providers.len == 2
    check providers[0].params.temperature.get == 0.4
    check providers[0].params.maxTokens.get == 16384
    check providers[0].params.thinkBack.get == tbNone
    check providers[0].params.contextWindow.get == 250000
    check providers[1].params.temperature.isNone
    check providers[1].params.maxTokens.isNone
    check providers[1].params.thinkBack.isNone
    check providers[1].params.contextWindow.isNone

  test "underscore spellings are accepted":
    writeFile(tmp, """
[provider]
name = "zai"
url = "https://z.ai/v1"
key = "k"
models = "glm-5.2"

[provider.params]
think_back = "turn"
max_tokens = "4096"
context_window = "128000"
""")
    let (_, providers, _, _, _, _) = parseConfigFile(tmp)
    check providers[0].params.thinkBack.get == tbCurrentTurn
    check providers[0].params.maxTokens.get == 4096
    check providers[0].params.contextWindow.get == 128000

  test "each param is optional":
    writeFile(tmp, """
[provider]
name = "zai"
url = "https://z.ai/v1"
key = "k"
models = "glm-5.2"

[provider.params]
think-back = "all"
""")
    let (_, providers, _, _, _, _) = parseConfigFile(tmp)
    check providers[0].params.thinkBack.get == tbAllTurns
    check providers[0].params.temperature.isNone

  test "writeConfigFile roundtrips [provider.params]":
    var pr = ProviderRec(name: "zai", url: "https://z.ai/v1", key: "k",
                         models: @["glm-5.2"])
    pr.params.temperature = some(0.4)
    pr.params.maxTokens = some(16384)
    pr.params.thinkBack = some(tbNone)
    pr.params.contextWindow = some(250000)
    writeConfigFile(tmp, "zai.glm-5.2", @[pr])
    let (_, back, _, _, _, _) = parseConfigFile(tmp)
    check back.len == 1
    check back[0].params.temperature.get == 0.4
    check back[0].params.maxTokens.get == 16384
    check back[0].params.thinkBack.get == tbNone
    check back[0].params.contextWindow.get == 250000

  test "writeConfigFile omits the section when no params are set":
    let pr = ProviderRec(name: "zai", url: "https://z.ai/v1", key: "k",
                         models: @["glm-5.2"])
    writeConfigFile(tmp, "zai.glm-5.2", @[pr])
    check readFile(tmp).find("provider.params") < 0

  test "buildProfile carries params into the Profile":
    writeFile(tmp, """
[settings]
current = "zai.glm-5.2"

[provider]
name = "zai"
url = "https://z.ai/v1"
key = "k"
models = "glm-5.2"

[provider.params]
temperature = "0.6"
think-back = "none"
""")
    let (_, providers, _, _, _, _) = parseConfigFile(tmp)
    let prof = buildProfile("zai.glm-5.2", providers, "")
    check prof.params.temperature.get == 0.6
    check prof.params.thinkBack.get == tbNone
