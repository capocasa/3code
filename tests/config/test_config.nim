import std/[json, options, os, strutils, tables, unittest]
import threecode/[config, minline, types, ui, util]

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

suite "config: [params]":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-params.ini"
    activeParams = @[]

  teardown:
    removeFile(tmp)
    activeParams = @[]

  test "parseConfigFile accumulates [params] sections with their scope":
    writeFile(tmp, """
[provider]
name = "zai"
url = "https://z.ai/v1"
key = "k"
models = "glm-5.2"

[params]
provider = "zai"
model = "glm-5.2"
temperature = "0.4"
max-tokens = "16384"
think-back = "none"
context-window = "250000"

[params]
provider = "openai"
model = "gpt-5.5"
think-back = "all"
""")
    discard parseConfigFile(tmp)
    check activeParams.len == 2
    check activeParams[0].provider == "zai"
    check activeParams[0].model == "glm-5.2"
    check activeParams[0].params.temperature.get == 0.4
    check activeParams[0].params.maxTokens.get == 16384
    check activeParams[0].params.thinkBack.get == tbNone
    check activeParams[0].params.contextWindow.get == 250000
    check activeParams[1].params.thinkBack.get == tbAllTurns
    check activeParams[1].params.temperature.isNone

  test "empty model scopes the entry to the whole provider":
    writeFile(tmp, """
[params]
provider = "zai"
think-back = "turn"
""")
    discard parseConfigFile(tmp)
    check activeParams.len == 1
    check activeParams[0].model == ""
    check activeParams[0].params.thinkBack.get == tbCurrentTurn

  test "underscore spellings are accepted":
    writeFile(tmp, """
[params]
provider = "zai"
think_back = "turn"
max_tokens = "4096"
context_window = "128000"
""")
    discard parseConfigFile(tmp)
    check activeParams[0].params.thinkBack.get == tbCurrentTurn
    check activeParams[0].params.maxTokens.get == 4096
    check activeParams[0].params.contextWindow.get == 128000

  test "resolveParams: model-scoped beats provider-wide, last wins":
    var wide = ParamsRec(provider: "zai", model: "")
    wide.params.temperature = some(0.2)
    var scoped = ParamsRec(provider: "zai", model: "glm-5.2")
    scoped.params.temperature = some(0.4)
    var other = ParamsRec(provider: "zai", model: "glm-5.3")
    other.params.temperature = some(0.8)
    var list = @[wide, scoped, other]
    check resolveParams(list, "zai", "glm-5.2").temperature.get == 0.4
    check resolveParams(list, "zai", "glm-5.3").temperature.get == 0.8
    check resolveParams(list, "zai", "glm-5.1").temperature.get == 0.2
    check resolveParams(list, "openai", "glm-5.2").temperature.isNone
    var again = ParamsRec(provider: "zai", model: "glm-5.2")
    again.params.temperature = some(0.9)
    list.add again
    check resolveParams(list, "zai", "glm-5.2").temperature.get == 0.9

  test "resolveParams layers per field, unset fields pass through":
    var wide = ParamsRec(provider: "zai", model: "")
    wide.params.temperature = some(0.2)
    wide.params.maxTokens = some(4096)
    var scoped = ParamsRec(provider: "zai", model: "glm-5.2")
    scoped.params.temperature = some(0.4)
    let r = resolveParams(@[wide, scoped], "zai", "glm-5.2")
    check r.temperature.get == 0.4   # model-scoped wins
    check r.maxTokens.get == 4096    # provider-wide supplies the rest
    check r.thinkBack.isNone         # nobody sets it

  test "resolveParams matches lenient model spellings":
    var e = ParamsRec(provider: "nvidia", model: "glm-5.2")
    e.params.maxTokens = some(2048)
    check resolveParams(@[e], "nvidia", "z-ai/glm-5.2").maxTokens.get == 2048

  test "writeConfigFile roundtrips [params]":
    var pm = ParamsRec(provider: "zai", model: "glm-5.2")
    pm.params.temperature = some(0.4)
    pm.params.maxTokens = some(16384)
    pm.params.thinkBack = some(tbNone)
    pm.params.contextWindow = some(250000)
    activeParams = @[pm]
    let pr = ProviderRec(name: "zai", url: "https://z.ai/v1", key: "k",
                         models: @["glm-5.2"])
    writeConfigFile(tmp, "zai.glm-5.2", @[pr])
    discard parseConfigFile(tmp)
    check activeParams.len == 1
    check activeParams[0].provider == "zai"
    check activeParams[0].model == "glm-5.2"
    check activeParams[0].params.temperature.get == 0.4
    check activeParams[0].params.maxTokens.get == 16384
    check activeParams[0].params.thinkBack.get == tbNone
    check activeParams[0].params.contextWindow.get == 250000

  test "writeConfigFile omits the section when no params are set":
    activeParams = @[]
    let pr = ProviderRec(name: "zai", url: "https://z.ai/v1", key: "k",
                         models: @["glm-5.2"])
    writeConfigFile(tmp, "zai.glm-5.2", @[pr])
    check readFile(tmp).find("[params]") < 0

  test "buildProfile carries the matching params into the Profile":
    writeFile(tmp, """
[settings]
current = "zai.glm-5.2"

[provider]
name = "zai"
url = "https://z.ai/v1"
key = "k"
models = "glm-5.2 glm-5.3"

[params]
provider = "zai"
temperature = "0.6"

[params]
provider = "zai"
model = "glm-5.2"
think-back = "none"
""")
    let (_, providers, _, _, _, _) = parseConfigFile(tmp)
    let prof = buildProfile("zai.glm-5.2", providers, "")
    check prof.params.temperature.get == 0.6
    check prof.params.thinkBack.get == tbNone
    let prof3 = buildProfile("zai.glm-5.3", providers, "")
    check prof3.params.temperature.get == 0.6
    check prof3.params.thinkBack.isNone

suite "config: per-provider current model":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-currentmodel.ini"
    activeProviders = @[]
    activeCurrent = ""
    activeParams = @[]

  teardown:
    removeFile(tmp)
    activeProviders = @[]
    activeCurrent = ""
    activeParams = @[]

  test "parseConfigFile reads current_model and the hyphen spelling":
    writeFile(tmp, """
[settings]
current = "a.m1"

[provider]
name = "a"
url = "https://a/v1"
key = "k"
models = "m1 m2"
current_model = "m2"

[provider]
name = "b"
url = "https://b/v1"
key = "k"
models = "n1 n2"
current-model = "n1"
""")
    let (_, providers, _, _, _, _) = parseConfigFile(tmp)
    check providers[0].currentModel == "m2"
    check providers[1].currentModel == "n1"

  test "parseConfigFile seeds the current provider's selection from current":
    # Old configs have no current_model; the active provider inherits the
    # model part of `current` so stickiness survives the migration.
    writeFile(tmp, """
[settings]
current = "a.m2"

[provider]
name = "a"
url = "https://a/v1"
key = "k"
models = "m1 m2"

[provider]
name = "b"
url = "https://b/v1"
key = "k"
models = "n1 n2"
""")
    let (_, providers, _, _, _, _) = parseConfigFile(tmp)
    check providers[0].currentModel == "m2"
    check providers[1].currentModel == ""

  test "explicit current_model wins over the current migration seed":
    writeFile(tmp, """
[settings]
current = "a.m1"

[provider]
name = "a"
url = "https://a/v1"
key = "k"
models = "m1 m2"
current_model = "m2"
""")
    let (_, providers, _, _, _, _) = parseConfigFile(tmp)
    check providers[0].currentModel == "m2"

  test "stale model part does not seed a selection":
    writeFile(tmp, """
[settings]
current = "a.gone"

[provider]
name = "a"
url = "https://a/v1"
key = "k"
models = "m1 m2"
""")
    let (_, providers, _, _, _, _) = parseConfigFile(tmp)
    check providers[0].currentModel == ""

  test "writeConfigFile round-trips current_model and skips empty":
    var a = ProviderRec(name: "a", url: "https://a/v1", key: "k",
                        models: @["m1", "m2"], currentModel: "m2")
    var b = ProviderRec(name: "b", url: "https://b/v1", key: "k",
                        models: @["n1", "n2"])
    writeConfigFile(tmp, "a.m2", @[a, b])
    check readFile(tmp).contains("current_model = \"m2\"")
    check readFile(tmp).count("current_model") == 1
    let (_, providers, _, _, _, _) = parseConfigFile(tmp)
    check providers[0].currentModel == "m2"
    check providers[1].currentModel == ""

  test "writeConfigFile keeps the provider prefix of current":
    # Regression: normalizing the whole "provider.model" string used to
    # strip everything before the model's last slash, losing the provider.
    var a = ProviderRec(name: "baseten", url: "https://b/v1", key: "k",
                        models: @["zai-org/GLM-4.7"],
                        currentModel: "zai-org/GLM-4.7")
    writeConfigFile(tmp, "baseten.zai-org/GLM-4.7", @[a])
    check readFile(tmp).contains("current = \"baseten.glm-4.7\"")

  test "rememberedModel prefers the stored selection and survives staleness":
    let a = ProviderRec(name: "a", models: @["m1", "m2"],
                        currentModel: "m2")
    check rememberedModel(a) == "m2"
    let stale = ProviderRec(name: "a", models: @["m1", "m2"],
                            currentModel: "gone")
    check rememberedModel(stale) == "m1"
    let fresh = ProviderRec(name: "a", models: @["m1", "m2"])
    check rememberedModel(fresh) == "m1"

  test "setCurrentModel resolves the value against the models list":
    activeProviders = @[ProviderRec(name: "a", models: @["m1", "org/m2"])]
    setCurrentModel("a", "m2")  # short name resolves to the full list id
    check activeProviders[0].currentModel == "org/m2"
    setCurrentModel("a", "unheard-of")  # unmatched passes through as-is
    check activeProviders[0].currentModel == "unheard-of"

suite "config: sticky model across provider switches":
  var
    savedXdg = ""
    hadXdg = false
    tempRoot = ""
    savedCurrent = ""
    savedProviders: seq[ProviderRec]

  setup:
    savedCurrent = activeCurrent
    savedProviders = activeProviders
    hadXdg = existsEnv("XDG_CONFIG_HOME")
    savedXdg = getEnv("XDG_CONFIG_HOME")
    tempRoot = getTempDir() / ("3code-test-sticky-" & $getCurrentProcessId())
    putEnv("XDG_CONFIG_HOME", tempRoot)
    activeParams = @[]
    activeProviders = @[
      ProviderRec(name: "zai", url: "https://api.z.ai/v1", key: "k",
                  models: @["glm-5.2", "glm-5.3"]),
      ProviderRec(name: "baseten", url: "https://inference.baseten.co/v1",
                  key: "k", models: @["zai-org/GLM-4.7"])]
    activeCurrent = "zai.glm-5.2"

  teardown:
    activeCurrent = savedCurrent
    activeProviders = savedProviders
    activeParams = @[]
    if hadXdg:
      putEnv("XDG_CONFIG_HOME", savedXdg)
    else:
      delEnv("XDG_CONFIG_HOME")
    try: removeDir(tempRoot)
    except OSError: discard

  var messages = %*[]
  var session = Session()
  var prof = Profile()
  var editor: LineEditor

  proc run(cmd: string): CommandResult =
    handleCommandResult(cmd, messages, session, prof, editor)

  test ":model selection survives switching away and back":
    prof = buildProfile(activeCurrent, activeProviders, "")
    discard run(":model glm-5.3")
    check prof.model == "glm-5.3"
    discard run(":provider baseten")
    check prof.name == "baseten.zai-org/GLM-4.7"
    discard run(":provider zai")
    check prof.model == "glm-5.3"

  test ":model selection persists to the config per provider":
    prof = buildProfile(activeCurrent, activeProviders, "")
    discard run(":model glm-5.3")
    discard run(":provider baseten")
    let cfg = readFile(configPath())
    check cfg.contains("current_model = \"glm-5.3\"")
    # writeConfigFile stores normalized ids; buildProfile maps back to wire.
    check cfg.contains("current = \"baseten.glm-4.7\"")

  test "provider without a recorded selection lands on its first model":
    prof = buildProfile(activeCurrent, activeProviders, "")
    discard run(":provider baseten")
    check prof.model == "zai-org/GLM-4.7"
    # and the switch records it (normalized), so a reload keeps the state
    let (_, providers, _, _, _, _) = parseConfigFile(configPath())
    check providers[1].currentModel == "glm-4.7"
    check rememberedModel(providers[1]) == "glm-4.7"
