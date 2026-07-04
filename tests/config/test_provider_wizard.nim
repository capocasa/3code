import std/[json, os, sequtils, strutils, unittest]
import threecode/[api, config, minline, types, ui]

proc nvidiaModels(): seq[string] =
  @[
    "z-ai/glm4.7",
    "openai/gpt-oss-120b",
    "openai/gpt-oss-20b",
    "minimaxai/minimax-m2.5",
    "minimaxai/minimax-m2.7",
  ]

suite "provider wizard configuration":
  var
    savedCurrent: string
    savedProviders: seq[ProviderRec]
    savedExperimental: bool
    savedXdg: string
    hadXdg: bool
    tempConfig: string
    inputs: seq[string]
    prompts: seq[string]
    verifiedModels: seq[string]

  setup:
    savedCurrent = activeCurrent
    savedProviders = activeProviders
    savedExperimental = experimentalEnabled
    hadXdg = existsEnv("XDG_CONFIG_HOME")
    savedXdg = getEnv("XDG_CONFIG_HOME")
    tempConfig = getTempDir() / ("3code-provider-wizard-" &
      $getCurrentProcessId())
    putEnv("XDG_CONFIG_HOME", tempConfig)
    activeCurrent = ""
    activeProviders = @[]
    experimentalEnabled = false
    inputs = @[]
    prompts = @[]
    verifiedModels = @[]
    wizardReadLineHook = proc(prompt: string, hidden, noHistory: bool): string =
      prompts.add prompt
      if inputs.len == 0:
        raise newException(AssertionDefect, "missing wizard input for " & prompt)
      result = inputs[0]
      inputs.delete(0)
    verifyProfileHook = proc(p: Profile): (bool, string) =
      check prompts.anyIt(it.startsWith("  models ["))
      verifiedModels.add p.model
      (true, "")
    fetchModelsHook = proc(url, key: string): (seq[string], string) =
      (nvidiaModels(), "")

  teardown:
    wizardReadLineHook = nil
    verifyProfileHook = nil
    fetchModelsHook = nil
    activeCurrent = savedCurrent
    activeProviders = savedProviders
    experimentalEnabled = savedExperimental
    if hadXdg:
      putEnv("XDG_CONFIG_HOME", savedXdg)
    else:
      delEnv("XDG_CONFIG_HOME")
    try: removeDir(tempConfig / "3code")
    except OSError: discard
    try: removeDir(tempConfig)
    except OSError: discard

  test "initial bootstrap prompts for model before verifying detected provider":
    inputs = @["nvapi-initial", "gpt-oss-120b"]
    var editor: LineEditor

    let prof = bootstrapProvider(editor)

    check prof.name == "nvidia.openai/gpt-oss-120b"
    check activeProviders.len == 1
    check activeProviders[0].models == @["openai/gpt-oss-120b"]
    check verifiedModels == @["openai/gpt-oss-120b"]

  test "additional add prompts for model before verifying detected provider":
    activeProviders = @[
      ProviderRec(name: "groq", url: "https://api.groq.com/openai/v1",
                  key: "gsk-existing", models: @["openai/gpt-oss-20b"])
    ]
    activeCurrent = "groq.openai/gpt-oss-20b"
    inputs = @["nvapi-add", "gpt-oss-20b"]
    var editor: LineEditor
    var prof = buildProfile(activeCurrent, activeProviders, "")
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 2
    check activeProviders[1].name == "nvidia"
    check activeProviders[1].models == @["openai/gpt-oss-20b"]
    check activeCurrent == "groq.openai/gpt-oss-20b"
    check verifiedModels == @["openai/gpt-oss-20b"]

  test "add rejects duplicate provider name":
    activeProviders = @[
      ProviderRec(name: "nvidia", url: "https://integrate.api.nvidia.com/v1",
                  key: "nvapi-existing", models: @["openai/gpt-oss-120b"])
    ]
    activeCurrent = "nvidia.openai/gpt-oss-120b"
    inputs = @["nvapi-add", "gpt-oss-20b"]
    var editor: LineEditor
    var prof = buildProfile(activeCurrent, activeProviders, "")
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 1
    check activeProviders[0].name == "nvidia"
    check activeCurrent == "nvidia.openai/gpt-oss-120b"

  test "edit prompts for model before verifying updated provider":
    activeProviders = @[
      ProviderRec(name: "nvidia", url: "https://integrate.api.nvidia.com/v1",
                  key: "nvapi-old", models: @["z-ai/glm4.7"])
    ]
    activeCurrent = "nvidia.z-ai/glm4.7"
    inputs = @["", "", "", "gpt-oss-120b"]
    var editor: LineEditor
    var prof = buildProfile(activeCurrent, activeProviders, "")
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider edit nvidia", messages, session, prof,
                          editor)

    check activeProviders.len == 1
    check activeProviders[0].models == @["openai/gpt-oss-120b"]
    check activeCurrent == "nvidia.openai/gpt-oss-120b"
    check verifiedModels == @["openai/gpt-oss-120b"]
