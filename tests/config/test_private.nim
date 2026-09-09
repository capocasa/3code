## Private mode: [params] allow-private parsing, resolution, persistence,
## the known-good curated flag, the `:private` command, and the bar color.
import std/[json, options, os, strutils, tables, unittest]
import threecode/[config, display, fatprompt/rendering, minline, prompts, types,
  ui, util]

suite "config: [params] allow-private":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-private.ini"
    activeParams = @[]

  teardown:
    removeFile(tmp)
    activeParams = @[]

  test "parses the on/off dialect and the underscore spelling":
    writeFile(tmp, """
[params]
provider = "zai"
allow-private = "on"

[params]
provider = "together"
allow_private = "off"
""")
    discard parseConfigFile(tmp)
    check activeParams.len == 2
    check activeParams[0].params.allowPrivate == some(true)
    check activeParams[1].params.allowPrivate == some(false)

  test "resolveParams: provider-wide applies, model-scoped beats it":
    writeFile(tmp, """
[params]
provider = "zai"
allow-private = "true"

[params]
provider = "zai"
model = "glm-5.2"
allow-private = "false"
""")
    discard parseConfigFile(tmp)
    check resolveParams(activeParams, "zai", "glm-5.3").allowPrivate == some(true)
    check resolveParams(activeParams, "zai", "glm-5.2").allowPrivate == some(false)
    check resolveParams(activeParams, "other", "glm-5.2").allowPrivate.isNone

  test "writeConfigFile round-trips allow-private sections":
    var e = ParamsRec(provider: "zai", model: "glm-5.2")
    e.params.allowPrivate = some(true)
    activeParams = @[e]
    writeConfigFile(tmp, "zai.glm-5.2", @[])
    check readFile(tmp).contains("allow-private = \"true\"")
    activeParams = @[]
    discard parseConfigFile(tmp)
    check activeParams.len == 1
    check activeParams[0].provider == "zai"
    check activeParams[0].model == "glm-5.2"
    check activeParams[0].params.allowPrivate == some(true)

  test "validateConfig rejects a bad boolean":
    writeFile(tmp, "[params]\nprovider = \"zai\"\nallow-private = \"maybe\"\n")
    check "bad value 'maybe'" in validateConfig(tmp,
      @[("params", "allow-private", "maybe", 3)])

suite "private mode: known-good curation":
  test "curated zero-training providers are allowed":
    check knownGoodAllowsPrivate("together", "zai-org/GLM-5.2")
    check knownGoodAllowsPrivate("fireworks", "accounts/fireworks/models/gpt-oss-120b")
    check knownGoodAllowsPrivate("ovh", "gpt-oss-120b")
    check knownGoodAllowsPrivate("novita", "zai-org/glm-5.2")

  test "everyone else, including first-party labs, is not":
    check not knownGoodAllowsPrivate("zai", "glm-5.2")
    check not knownGoodAllowsPrivate("openai", "gpt-5.5")
    check not knownGoodAllowsPrivate("made-up", "whatever")

  test "privateAllowed: explicit params beat the curated flag":
    var p = Profile(name: "together.x", model: "zai-org/GLM-5.2")
    check privateAllowed(p)  # curated
    p.params.allowPrivate = some(false)
    check not privateAllowed(p)  # revoked explicitly
    var z = Profile(name: "zai.glm-5.2", model: "glm-5.2")
    check not privateAllowed(z)  # not curated
    z.params.allowPrivate = some(true)
    check privateAllowed(z)  # opted in
    check privateAllowed(Profile())  # empty profile: caller bails separately

suite "private mode: :private command":
  var
    savedXdg = ""
    hadXdg = false
    tempRoot = ""
    savedCurrent = ""
    savedProviders: seq[ProviderRec]
    savedMode = false

  setup:
    savedCurrent = activeCurrent
    savedProviders = activeProviders
    savedMode = privateMode
    privateMode = false
    hadXdg = existsEnv("XDG_CONFIG_HOME")
    savedXdg = getEnv("XDG_CONFIG_HOME")
    tempRoot = getTempDir() / ("3code-test-private-cmd-" & $getCurrentProcessId())
    putEnv("XDG_CONFIG_HOME", tempRoot)
    activeProviders = @[ProviderRec(name: "zai", url: "https://api.z.ai/v1",
      key: "k", models: @["glm-5.2", "glm-5.3"])]
    activeCurrent = "zai.glm-5.2"
    activeParams = @[]

  teardown:
    activeCurrent = savedCurrent
    activeProviders = savedProviders
    privateMode = savedMode
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

  test ":private reports off and the current profile state":
    prof = buildProfile("zai.glm-5.2", activeProviders, "")
    let r = run(":private")
    check r.recognized
    check "private: off" in r.body
    check "not allowed" in r.body

  test ":private on is session-only and warns for a gated profile":
    prof = buildProfile("zai.glm-5.2", activeProviders, "")
    check classifyCommand(":private on") == ckMutating
    let r = run(":private on")
    check privateMode
    check "is not allow-private" in r.body
    # nothing persisted: the config file has no private key
    if fileExists(configPath()):
      check not readFile(configPath()).contains("private")
    discard run(":private off")
    check not privateMode

  test ":private allow <provider> persists provider-wide and refreshes prof":
    prof = buildProfile("zai.glm-5.2", activeProviders, "")
    let r = run(":private allow zai")
    check r.ok
    check "private allow zai" in r.body
    check readFile(configPath()).contains("allow-private")
    check prof.params.allowPrivate == some(true)
    check privateAllowed(prof)

  test ":private allow with a model scopes to it":
    prof = buildProfile("zai.glm-5.2", activeProviders, "")
    let r = run(":private allow zai glm-5.3")
    check r.ok
    check privateAllowed(prof) == false  # glm-5.2 stays gated
    let p53 = buildProfile("zai.glm-5.3", activeProviders, "")
    check p53.params.allowPrivate == some(true)

  test ":private allow rejects unknown names":
    check "unknown provider: nope" in run(":private allow nope").body
    check "unknown model: nope" in run(":private allow zai nope").body

  test ":private deny revokes and reuses the same section":
    discard run(":private allow zai")
    let n = activeParams.len
    let r = run(":private deny zai")
    check r.ok
    check activeParams.len == n  # upsert, not duplicate
    check activeParams[0].params.allowPrivate == some(false)
    check not privateAllowed(buildProfile("zai.glm-5.2", activeProviders, ""))

  test ":model refuses a gated model while private":
    privateMode = true
    let r = run(":model glm-5.3")
    check "is not allow-private" in r.body
    discard run(":private off")

suite "private mode: token bar color":
  setup:
    resetPalettes()

  teardown:
    privateMode = false
    resetPalettes()

  test "bar is cyan normally, magenta in private mode":
    privateMode = false
    check tokenBarFg() == CyanFg
    check liveBarBytes("○1%").startsWith CyanFg
    privateMode = true
    check tokenBarFg() == MagentaFg
    check liveBarBytes("○1%").startsWith MagentaFg
    check spinnerBarBytes("◐", "thinking", 3).contains MagentaFg

  test "the private bar color is configurable like other colors":
    var dark = initTable[string, string]()
    dark["private-bar"] = "\x1b[38;5;99m"
    applyColorOverrides(dark, initTable[string, string]())
    privateMode = true
    check tokenBarFg() == "\x1b[38;5;99m"
    check liveBarBytes("○1%").startsWith "\x1b[38;5;99m"

  test "profileLinesS shows the private row only in private mode":
    privateMode = false
    let p = Profile(name: "zai.glm-5.2", model: "glm-5.2")
    check "private" notin profileLinesS(p)
    privateMode = true
    check "private" in profileLinesS(p)
    check "NOT allowed" in profileLinesS(p)
