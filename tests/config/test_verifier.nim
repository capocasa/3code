## Verification-class models: the curated decision-model registry, the
## `[settings] verifier` config surface, profile resolution for a
## verifier that is never in the ordinary models list, and the goal-check
## decision path. The `systemOneHook` seam keeps the wire test provider-
## free.

import std/[json, options, os, sequtils, strutils, tempfiles, unittest]
import threecode/[api, config, display, goal, minline, prompts,
  types, ui, util]

proc withVerifierState(body: proc ()) =
  ## The verifier knobs and the provider list are process globals; pin
  ## them for the test and put the default back whatever the body did.
  let (savedOn, savedSpec, savedProviders, savedCurrent,
       savedOverride) = (verifierEnabled, verifierModelSpec,
    activeProviders, activeCurrent, configPathOverride)
  verifierEnabled = false
  verifierModelSpec = ""
  activeProviders = @[]
  activeCurrent = ""
  configPathOverride = getTempDir() / "3code-test-verifier.ini"
  removeFile(configPathOverride)
  body()
  verifierEnabled = savedOn
  verifierModelSpec = savedSpec
  activeProviders = savedProviders
  activeCurrent = savedCurrent
  configPathOverride = savedOverride
  removeFile(getTempDir() / "3code-test-verifier.ini")

let OpenRouter = ProviderRec(name: "openrouter",
  url: "https://openrouter.ai/api/v1", key: "sk-test",
  models: @["z-ai/glm-5.3", "typesafe/jev-latest"])
  ## A provider that serves an ordinary model and (as endpoints do list
  ## it) a decision model. The decision model must vanish from every
  ## ordinary surface even though a user pasted it into the list.

suite "verifier registry":
  test "jev on openrouter is the curated verification-class model":
    check isVerifierCombo("openrouter", "typesafe/jev-latest")
    check isVerifierCombo("openrouter", "jev-latest")
    check not isVerifierCombo("zai", "glm-5.3")
    check not isVerifierCombo("openrouter", "typesafe/other")

  test "wire id repairs the spelling":
    check verifierWireModel("openrouter", "jev-latest") ==
      "typesafe/jev-latest"
    check verifierWireModel("openrouter", "z-ai/glm-5.3") == ""

  test "jev ids are decision models, everything else chats":
    check isDecisionModel("typesafe/jev-latest")
    check isDecisionModel("jev-1.14.0")
    check not isDecisionModel("z-ai/glm-5.3")
    check verifierDialect("typesafe/jev-latest") == "systemone"
    check verifierDialect("z-ai/glm-5.3") == "chat"

  test "decision models never appear in ordinary model lists":
    check orderedModels(OpenRouter) == @["z-ai/glm-5.3"]
    check availableVerifiers(@[OpenRouter]) ==
      @["openrouter.typesafe/jev-latest"]
    check availableVerifiers(@[]).len == 0
    # A provider without the curated verifier hosts none.
    let zai = ProviderRec(name: "zai", url: "https://api.z.ai/v1",
      key: "k", models: @["glm-5.3"])
    check availableVerifiers(@[zai]).len == 0

suite "verifier [settings] config":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-verifier.ini"
    verifierEnabled = false
    verifierModelSpec = ""

  teardown:
    removeFile(tmp)
    verifierEnabled = false
    verifierModelSpec = ""

  test "default is off with no selection":
    writeFile(tmp, "[settings]\ncurrent = \"p.m\"\n")
    discard parseConfigFile(tmp)
    check verifierEnabled == false
    check verifierModelSpec == ""

  test "a selected model is enabled":
    writeFile(tmp,
      "[settings]\nverifier_model = \"openrouter.typesafe/jev-latest\"\n")
    discard parseConfigFile(tmp)
    check verifierModelSpec == "openrouter.typesafe/jev-latest"
    check verifierEnabled == true

  test "explicit off keeps the selection for :verifier on":
    writeFile(tmp, "[settings]\n" &
      "verifier_model = \"openrouter.typesafe/jev-latest\"\n" &
      "verifier = \"off\"\n")
    discard parseConfigFile(tmp)
    check verifierEnabled == false
    check verifierModelSpec == "openrouter.typesafe/jev-latest"

  test "explicit off wins whatever the key order":
    writeFile(tmp, "[settings]\n" &
      "verifier = \"off\"\n" &
      "verifier_model = \"openrouter.typesafe/jev-latest\"\n")
    discard parseConfigFile(tmp)
    check verifierEnabled == false

  test "boolean dialect is accepted":
    writeFile(tmp, "[settings]\nverifier = \"1\"\n")
    discard parseConfigFile(tmp)
    check verifierEnabled == true

  test "malformed selection is a config error":
    writeFile(tmp, "[settings]\nverifier_model = \"jev\"\n")
    expect ValueError:
      discard parseConfigFile(tmp)

  test "writeConfigFile persists selection, off flag, and default-clean":
    verifierModelSpec = "openrouter.typesafe/jev-latest"
    verifierEnabled = true
    writeConfigFile(tmp, "p.m", @[])
    let on = readFile(tmp)
    check on.find("verifier_model = \"openrouter.typesafe/jev-latest\"") >= 0
    check on.find("verifier = ") < 0  # enabled is the default
    verifierEnabled = false
    writeConfigFile(tmp, "p.m", @[])
    let off = readFile(tmp)
    check off.find("verifier = \"off\"") >= 0
    check off.find("verifier_model = \"openrouter.typesafe/jev-latest\"") >= 0
    verifierModelSpec = ""
    verifierEnabled = false
    writeConfigFile(tmp, "p.m", @[])
    check readFile(tmp).find("verifier") < 0

suite "verifier profile resolution":
  test "a verification-class model needs no models-list entry":
    withVerifierState proc () =
      activeProviders = @[ProviderRec(name: "openrouter",
        url: "https://openrouter.ai/api/v1", key: "sk-test",
        models: @["z-ai/glm-5.3"])]
      let (prof, err) = buildVerifierProfile(
        "openrouter.typesafe/jev-latest", activeProviders)
      check err == ""
      check prof.model == "typesafe/jev-latest"
      check prof.url == "https://openrouter.ai/api/v1"
      check prof.key == "sk-test"
      check prof.family == "jev"
      check verifierDialect(prof.model) == "systemone"

  test "an ordinary model from the list is a chat-dialect verifier":
    withVerifierState proc () =
      activeProviders = @[OpenRouter]
      let (prof, err) = buildVerifierProfile("openrouter.z-ai/glm-5.3",
        activeProviders)
      check err == ""
      check prof.model == "z-ai/glm-5.3"
      check verifierDialect(prof.model) == "chat"
      check prof.family == "glm"

  test "unbuildable verifiers report instead of exiting":
    withVerifierState proc () =
      check buildVerifierProfile("ghost.jev-latest",
        @[OpenRouter]).err.contains "not configured"
      check buildVerifierProfile("openrouter.no-such-model",
        @[OpenRouter]).err.contains "neither a verifier model"
      let keyless = ProviderRec(name: "openrouter",
        url: "https://openrouter.ai/api/v1", models: @[])
      check buildVerifierProfile("openrouter.typesafe/jev-latest",
        @[keyless]).err.contains "key not set"
      check buildVerifierProfile("jev-latest", @[OpenRouter]).err ==
        "expected provider.model, got 'jev-latest'"

  test "bare names resolve to the curated verifier, then the list":
    withVerifierState proc () =
      activeProviders = @[OpenRouter]
      check resolveVerifierSpec("jev-latest", activeProviders).spec ==
        "openrouter.typesafe/jev-latest"
      activeCurrent = "openrouter.z-ai/glm-5.3"
      check resolveVerifierSpec("glm-5.3", activeProviders).spec ==
        "openrouter.z-ai/glm-5.3"
      check resolveVerifierSpec("nope", activeProviders).err.len > 0

suite "verifier decision check":
  test "question set: one noul, one choice with labeled criteria":
    let q = decisionQuestions()
    check q{"satisfied", "type"}.getStr == "noul"
    check q{"satisfied", "instructions"}.getStr.len > 0
    check q{"gap", "type"}.getStr == "choice"
    let crit = q{"gap", "criteria"}
    check crit.len == DecisionGapLabels.len
    for (k, label) in DecisionGapLabels:
      check crit{k}.getStr == label

  test "verdict threshold: 0.75 confirms, below feeds back":
    let yes = %*{"satisfied": {"type": "noul", "noul": 0.91},
      "gap": {"type": "choice", "choice": "nothing",
        "probabilities": {"nothing": 0.9}}}
    check verdictFromDecision(yes).kind == gvkSatisfied
    let edge = %*{"satisfied": {"type": "noul", "noul": 0.75}}
    check verdictFromDecision(edge).kind == gvkSatisfied
    let no = %*{"satisfied": {"type": "noul", "noul": 0.12},
      "gap": {"type": "choice", "choice": "tests",
        "probabilities": {"tests": 0.8, "docs": 0.2}}}
    let v = verdictFromDecision(no)
    check v.kind == gvkFeedback
    check "p(satisfied)=0.12" in v.feedback
    check "tests for the goal are missing" in v.feedback

  test "whole-number probabilities parse":
    check decisionSatisfiedP(%*{"satisfied": {"noul": 1}}) == 1.0
    check decisionSatisfiedP(%*{"satisfied": {"noul": 0}}) == 0.0

  test "a missing answer is a failed check, never a pass":
    check decisionSatisfiedP(%*{}) == -1.0
    check verdictFromDecision(%*{"gap": {"choice": "nothing"}}).kind ==
      gvkNone

  test "gap picks the top probability and maps it to its label":
    let a = %*{"gap": {"probabilities": {"docs": 0.3, "evidence": 0.7}}}
    check decisionGap(a) ==
      "claims are made but nothing recorded demonstrates them"
    let b = %*{"gap": {"choice": "implementation"}}
    check decisionGap(b).startsWith "working code"

  test "runGoalCheck rides the decision path end to end":
    withVerifierState proc () =
      activeProviders = @[OpenRouter]
      verifierModelSpec = "openrouter.typesafe/jev-latest"
      verifierEnabled = true
      var askedModel = ""
      var askedState = ""
      systemOneHook = proc (p: Profile, body: JsonNode): JsonNode =
        askedModel = p.model
        askedState = body{"state"}.getStr
        check body{"questions", "satisfied", "type"}.getStr == "noul"
        %*{"answers": {"satisfied": {"type": "noul", "noul": 0.9}},
           "usage": {"input_tokens": 412, "output_tokens": 67}}
      defer: systemOneHook = nil
      var steps: seq[string]
      goalStepHook = proc (step: GoalStep) = steps.add step.prose
      defer: goalStepHook = nil
      let prof = Profile(name: "zai.glm-5.3", model: "glm-5.3")
      let r = runGoalCheck(prof, "ship it", "evidence line")
      check r.ok
      check r.verdict.kind == gvkSatisfied
      check askedModel == "typesafe/jev-latest"
      check "ship it" in askedState and "evidence line" in askedState
      check steps.len == 1 and "p(satisfied)=0.90" in steps[0]

  test "decision failure is ok=false, retried next boundary":
    withVerifierState proc () =
      activeProviders = @[OpenRouter]
      verifierModelSpec = "openrouter.typesafe/jev-latest"
      verifierEnabled = true
      systemOneHook = proc (p: Profile, body: JsonNode): JsonNode =
        raise newException(ApiError, "HTTP 429")
      defer: systemOneHook = nil
      let r = runGoalCheck(Profile(name: "zai.glm-5.3"), "ship it", "")
      check not r.ok
      check "429" in r.err
      check r.verdict.kind == gvkNone

  test "unresolvable verifier falls back to the session model's check":
    withVerifierState proc () =
      verifierModelSpec = "ghost.jev-latest"
      verifierEnabled = true
      var got = ""
      goalCheckHook = proc (p: Profile, goalText, evidence: string):
          tuple[ok: bool, text: string, err: string] =
        got = p.name
        (true, "VERDICT: SATISFIED", "")
      defer: goalCheckHook = nil
      var steps: seq[string]
      goalStepHook = proc (step: GoalStep) = steps.add step.prose
      defer: goalStepHook = nil
      let prof = Profile(name: "zai.glm-5.3", model: "glm-5.3")
      let r = runGoalCheck(prof, "ship it", "")
      check r.ok and r.verdict.kind == gvkSatisfied
      check got == "zai.glm-5.3"
      check steps.len == 1 and "unavailable" in steps[0]

  test "a chat-model verifier receives the side call on its profile":
    withVerifierState proc () =
      activeProviders = @[OpenRouter]
      verifierModelSpec = "openrouter.z-ai/glm-5.3"
      verifierEnabled = true
      var got = ""
      goalCheckHook = proc (p: Profile, goalText, evidence: string):
          tuple[ok: bool, text: string, err: string] =
        got = p.name
        (true, "VERDICT: FEEDBACK: run tests", "")
      defer: goalCheckHook = nil
      let r = runGoalCheck(Profile(name: "zai.glm-5.3"), "ship it", "")
      check r.verdict.kind == gvkFeedback
      check got == "openrouter.z-ai/glm-5.3"

  test "private mode fences an untrusted verifier":
    withVerifierState proc () =
      let savedPrivate = privateMode
      privateMode = true
      defer: privateMode = savedPrivate
      activeProviders = @[OpenRouter]
      verifierModelSpec = "openrouter.typesafe/jev-latest"
      verifierEnabled = true
      # No [params] allow-private and no curated flag: openrouter is not
      # trusted, so the decision model must not see goal or diff.
      var used = ""
      systemOneHook = proc (p: Profile, body: JsonNode): JsonNode =
        used = p.model
        %*{"answers": {"satisfied": {"noul": 0.9}}}
      defer: systemOneHook = nil
      var got = ""
      goalCheckHook = proc (p: Profile, goalText, evidence: string):
          tuple[ok: bool, text: string, err: string] =
        got = p.name
        (true, "VERDICT: SATISFIED", "")
      defer: goalCheckHook = nil
      var steps: seq[string]
      goalStepHook = proc (step: GoalStep) = steps.add step.prose
      defer: goalStepHook = nil
      let r = runGoalCheck(Profile(name: "zai.glm-5.3"), "ship it", "")
      check r.ok and r.verdict.kind == gvkSatisfied
      check used == ""                    # decision model never called
      check got == "zai.glm-5.3"          # session model took the check
      check steps.anyIt("allow-private" in it)

  test "off is exactly the old behavior: the session model checks":
    withVerifierState proc () =
      verifierEnabled = false
      var got = ""
      goalCheckHook = proc (p: Profile, goalText, evidence: string):
          tuple[ok: bool, text: string, err: string] =
        got = p.name
        (true, "VERDICT: SATISFIED", "")
      defer: goalCheckHook = nil
      let prof = Profile(name: "zai.glm-5.3", model: "glm-5.3")
      let r = runGoalCheck(prof, "ship it", "")
      check r.ok and r.verdict.kind == gvkSatisfied
      check got == "zai.glm-5.3"

suite "verifier surfaces":
  test "the intro block carries a verifier row only while enabled":
    withVerifierState proc () =
      let prof = Profile(name: "zai.glm-5.3", model: "glm-5.3",
        reasoning: "high")
      verifierEnabled = false
      verifierModelSpec = "openrouter.typesafe/jev-latest"
      check profileLinesS(prof).find("verifier") < 0
      verifierEnabled = true
      let s = profileLinesS(prof)
      check "verifier  " in s
      check "jev-latest" in s

  test ":verifier selects, lists, toggles, and refuses the unknown":
    withVerifierState proc () =
      var messages = %*[]
      var session = Session()
      var prof = Profile(name: "zai.glm-5.3", model: "glm-5.3",
        reasoning: "high")
      var editor: LineEditor
      activeProviders = @[OpenRouter]
      # select
      let sel = handleCommandResult(":verifier jev-latest", messages,
        session, prof, editor)
      check sel.ok
      check verifierEnabled and
        verifierModelSpec == "openrouter.typesafe/jev-latest"
      check "jev-latest" in sel.body
      # persisted
      check readFile(configPath()).find(
        "verifier_model = \"openrouter.typesafe/jev-latest\"") >= 0
      # list marks the live one
      let list = handleCommandResult(":verifier list", messages, session,
        prof, editor)
      check list.ok
      check "* openrouter.typesafe/jev-latest" in list.body
      # off falls back and keeps the selection
      let off = handleCommandResult(":verifier off", messages, session,
        prof, editor)
      check off.ok
      check not verifierEnabled
      check verifierModelSpec == "openrouter.typesafe/jev-latest"
      check "verifier  " notin off.body
      # on restores it
      discard handleCommandResult(":verifier on", messages, session, prof,
        editor)
      check verifierEnabled
      # unknown
      let bad = handleCommandResult(":verifier nope", messages, session,
        prof, editor)
      check "unknown verifier" in bad.body
      check verifierModelSpec == "openrouter.typesafe/jev-latest"

  test ":model refuses a decision model and points at :verifier":
    withVerifierState proc () =
      var messages = %*[]
      var session = Session()
      var prof = Profile()
      var editor: LineEditor
      activeProviders = @[OpenRouter]
      activeCurrent = "openrouter.z-ai/glm-5.3"
      let r = handleCommandResult(":model typesafe/jev-latest", messages,
        session, prof, editor)
      check "verification-class" in r.body
      check ":verifier" in r.body
      check activeCurrent == "openrouter.z-ai/glm-5.3"

  test ":verifier on with nothing available is a clear error":
    withVerifierState proc () =
      var messages = %*[]
      var session = Session()
      var prof = Profile()
      var editor: LineEditor
      activeProviders = @[]
      let r = handleCommandResult(":verifier on", messages, session, prof,
        editor)
      check "no verifier model" in r.body
      check not verifierEnabled

suite "verifier wire":
  test "the decision endpoint is the provider base + /systemone":
    let p = Profile(name: "openrouter.typesafe/jev-latest",
      url: "https://openrouter.ai/api/v1",
      model: "typesafe/jev-latest", family: "jev")
    check systemOneEndpoint(p) == "https://openrouter.ai/api/v1/systemone"
