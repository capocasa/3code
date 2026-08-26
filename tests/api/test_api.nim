import std/[json, os, osproc, strutils, unittest]
import threecode/[api, config, prompts, types]
import stub_helpers

# Subprocess probes compile a small `probe.nim` and exec it. On Windows the
# nim compiler appends `.exe` to `-o:probe`, so the run path must include it
# or execCmdEx gets a file-not-found.
const Exe = when defined(windows): ".exe" else: ""

suite "api request shaping":
  test "z.ai glm sets tool_stream (streamhttp TLS truncation fixed)":
    # tool_stream makes GLM stream tool-call arguments as per-token deltas.
    # It was disabled as a workaround for a streamhttp TLS truncation bug
    # that truncated the deltas mid-stream. That bug is fixed (streamhttp
    # >= 0.2.0 drains OpenSSL's internal buffer before polling), so
    # tool_stream is re-enabled for the first-party z.ai API. Streamed tool
    # args now arrive complete.
    var body = %*{"stream": true}
    let p = Profile(name: "zai.glm-5.1", family: "glm", model: "glm-5.1")

    applyStreamingOptions(p, body)

    check body{"tool_stream"}.getBool == true

  test "non-z.ai glm does not get z.ai-only tool_stream":
    var body = %*{"stream": true}
    let p = Profile(name: "together.zai-org/GLM-5.1", family: "glm",
                    model: "zai-org/GLM-5.1")

    applyStreamingOptions(p, body)

    check "tool_stream" notin body

  test "known-good combo gets hardcoded generation defaults":
    var body = %*{"stream": true}
    let p = Profile(name: "zai.glm-5.1", family: "glm", model: "glm-5.1")

    applyGenerationDefaults(p, body)

    check body{"temperature"}.getFloat == 0.2
    check body{"max_tokens"}.getInt == 8192

  test "experimental combo omits generation defaults":
    var body = %*{"stream": true}
    let p = Profile(name: "local.unknown", family: "glm", model: "unknown")

    applyGenerationDefaults(p, body)

    check "temperature" notin body
    check "max_tokens" notin body

  test "gpt family sends max_completion_tokens, not max_tokens":
    # OpenAI's post-4o chat lineup (o-series, gpt-5.x) rejects max_tokens
    # outright; the budget field is max_completion_tokens.
    var body = %*{"stream": true}
    let p = Profile(name: "openai.gpt-5.6", family: "gpt", model: "gpt-5.6")

    applyGenerationDefaults(p, body)

    check body{"max_completion_tokens"}.getInt == 8192
    check "max_tokens" notin body

  test "family-less gpt model still sends max_completion_tokens":
    # The wizard's verify ping builds a bare Profile (no family) for models
    # the known-good table doesn't list yet; the budget field must still be
    # derived from the model id so the ping doesn't 400 on max_tokens.
    var body = %*{"stream": true}
    let p = Profile(name: "openai.gpt-9.9", family: "", model: "gpt-9.9")

    applyGenerationDefaults(p, body)

    # No known-good row, so no budget at all; the field name choice is what
    # verifyBody exercises. Check it directly there.
    check "max_tokens" notin body
    check "max_completion_tokens" notin body
    let vb = parseJson(verifyBody(p))
    # openai speaks the Responses API: input items + max_output_tokens.
    check vb{"max_output_tokens"}.getInt == 1
    check vb{"input"}.kind == JArray
    check "max_tokens" notin vb
    check "messages" notin vb

  test "gpt-oss family keeps plain max_tokens":
    var body = %*{"stream": true}
    let p = Profile(name: "openai.gpt-oss-120b", family: "gpt-oss",
                    model: "gpt-oss-120b")

    applyGenerationDefaults(p, body)

    check body{"max_tokens"}.getInt == 8192
    check "max_completion_tokens" notin body

  test "kimi combos send Moonshot's calibrated temperature":
    var body = %*{"stream": true}
    let p = Profile(name: "together.moonshotai/Kimi-K2.6", family: "kimi",
                    model: "moonshotai/Kimi-K2.6")

    applyGenerationDefaults(p, body)

    check body{"temperature"}.getFloat == 0.6
    check body{"max_tokens"}.getInt == 8192

  test "kimicode k3 omits temperature (server rejects != 1.0)":
    var body = %*{"stream": true}
    let p = Profile(name: "kimicode.k3", family: "kimi", model: "k3")

    applyGenerationDefaults(p, body)

    check "temperature" notin body
    check body{"max_tokens"}.getInt == 8192

  test "nvidia glm sends chat_template_kwargs.enable_thinking":
    var body = %*{"stream": true}
    let p = Profile(name: "nvidia.z-ai/glm-5.2", family: "glm",
                    model: "z-ai/glm-5.2", reasoning: "low")
    applyReasoning(p, body)
    check body{"chat_template_kwargs"}{"enable_thinking"}.getBool == false

  test "hy on novita sends chat_template_kwargs.reasoning_effort":
    var body = %*{"stream": true}
    let p = Profile(name: "novita.tencent/hy3", family: "hy",
                    model: "tencent/hy3", reasoning: "high")
    applyReasoning(p, body)
    check body{"chat_template_kwargs"}{"reasoning_effort"}.getStr == "high"

  test "hy on openrouter normalizes to reasoning.effort":
    var body = %*{"stream": true}
    let p = Profile(name: "openrouter.tencent/hy3", family: "hy",
                    model: "tencent/hy3", reasoning: "low")
    applyReasoning(p, body)
    check body{"reasoning"}{"effort"}.getStr == "low"

  test "together glm-5.2 sends reasoning_effort for high/max":
    block high:
      var body = %*{"stream": true}
      let p = Profile(name: "together.zai-org/GLM-5.2", family: "glm",
                      version: "5", variant: "2",
                      model: "zai-org/GLM-5.2", reasoning: "high")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "high"
      check "reasoning" notin body
    block maxn:
      var body = %*{"stream": true}
      let p = Profile(name: "together.zai-org/GLM-5.2", family: "glm",
                      version: "5", variant: "2",
                      model: "zai-org/GLM-5.2", reasoning: "max")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "max"
    block offn:
      var body = %*{"stream": true}
      let p = Profile(name: "together.zai-org/GLM-5.2", family: "glm",
                      version: "5", variant: "2",
                      model: "zai-org/GLM-5.2", reasoning: "off")
      applyReasoning(p, body)
      check body{"reasoning"}{"enabled"}.getBool == false
      check "reasoning_effort" notin body

  test "openrouter glm-5.2 sends reasoning.effort, max->xhigh":
    block high:
      var body = %*{"stream": true}
      let p = Profile(name: "openrouter.z-ai/glm-5.2", family: "glm",
                      version: "5", variant: "2",
                      model: "z-ai/glm-5.2", reasoning: "high")
      applyReasoning(p, body)
      check body{"reasoning"}{"effort"}.getStr == "high"
    block maxn:
      var body = %*{"stream": true}
      let p = Profile(name: "openrouter.z-ai/glm-5.2", family: "glm",
                      version: "5", variant: "2",
                      model: "z-ai/glm-5.2", reasoning: "max")
      applyReasoning(p, body)
      check body{"reasoning"}{"effort"}.getStr == "xhigh"
    block offn:
      var body = %*{"stream": true}
      let p = Profile(name: "openrouter.z-ai/glm-5.2", family: "glm",
                      version: "5", variant: "2",
                      model: "z-ai/glm-5.2", reasoning: "off")
      applyReasoning(p, body)
      check body{"reasoning"}{"enabled"}.getBool == false

  test "together non-5.2 glm sends no effort knob":
    var body = %*{"stream": true}
    let p = Profile(name: "together.zai-org/GLM-5.1", family: "glm",
                    version: "5", variant: "1",
                    model: "zai-org/GLM-5.1", reasoning: "high")
    applyReasoning(p, body)
    check "reasoning_effort" notin body
    check "reasoning" notin body

  test "knownGoodReasonings offers high/max for third-party 5.2":
    check knownGoodReasonings("together", "zai-org/GLM-5.2") == @["off", "high", "max"]
    check knownGoodReasonings("openrouter", "z-ai/glm-5.2") == @["off", "high", "max"]
    check knownGoodReasonings("nebius", "zai-org/GLM-5.2") == @["off", "high", "max"]
    check knownGoodReasonings("zai", "glm-5.2") == @["off", "high", "max"]
    check knownGoodReasonings("together", "zai-org/GLM-5.1") == @["off", "on"]
    check knownGoodReasonings("together", "zai-org/GLM-5") == @["off", "on"]

  test "glm-5.3 forces thinking: low/high/max, no off":
    # 5.3 replaced the thinking toggle with a top-level reasoning_effort
    # knob (z.ai) normalized to reasoning.effort on gateways. Off is gone.
    check knownGoodReasonings("zaicode", "glm-5.3") == @["low", "high", "max"]
    check knownGoodReasonings("opencodego", "glm-5.3") == @["low", "high", "max"]
    check knownGoodReasonings("zai", "glm-5.3") == @["low", "high", "max"]
    check knownGoodReasonings("zai", "glm-5.3-flash") == @["low", "high", "max"]
    check knownGoodReasonings("zaicode", "glm-5.3-flash") == @["low", "high", "max"]
    check knownGoodReasonings("opencodego", "glm-5.3-flash") == @["low", "high", "max"]
    check knownGoodReasonings("openrouter", "z-ai/glm-5.3-flash") == @["low", "high", "max"]
    block zaiEffort:
      var body = %*{"stream": true}
      let p = Profile(name: "zaicode.glm-5.3", family: "glm",
                      version: "5", variant: "3",
                      model: "glm-5.3", reasoning: "max")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "max"
      check "thinking" notin body
    block zaiOff:
      var body = %*{"stream": true}
      let p = Profile(name: "zaicode.glm-5.3", family: "glm",
                      version: "5", variant: "3",
                      model: "glm-5.3", reasoning: "off")
      applyReasoning(p, body)
      check "thinking" notin body
      check "reasoning_effort" notin body
    block gatewayEffort:
      var body = %*{"stream": true}
      let p = Profile(name: "opencodego.glm-5.3", family: "glm",
                      version: "5", variant: "3",
                      model: "glm-5.3", reasoning: "low")
      applyReasoning(p, body)
      check body{"reasoning"}{"effort"}.getStr == "low"
    block flashEffort:
      var body = %*{"stream": true}
      let p = Profile(name: "zai.glm-5.3-flash", family: "glm",
                      version: "5", variant: "3-flash",
                      model: "glm-5.3-flash", reasoning: "low")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "low"
      check "thinking" notin body
    block zaicodeFlash:
      var body = %*{"stream": true}
      let p = Profile(name: "zaicode.glm-5.3-flash", family: "glm",
                      version: "5", variant: "3-flash",
                      model: "glm-5.3-flash", reasoning: "high")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "high"
      check "thinking" notin body

  test "hy with empty reasoning sends no wire knob":
    var body = %*{"stream": true}
    let p = Profile(name: "novita.tencent/hy3", family: "hy",
                    model: "tencent/hy3", reasoning: "")
    applyReasoning(p, body)
    check "chat_template_kwargs" notin body
    check "reasoning" notin body

  test "grok-4.5 sends reasoning_effort, cannot disable":
    block high:
      var body = %*{"stream": true}
      let p = Profile(name: "xai.grok-4.5", family: "grok",
                      version: "4", variant: "5",
                      model: "grok-4.5", reasoning: "high")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "high"
      check "reasoning" notin body
    block low:
      var body = %*{"stream": true}
      let p = Profile(name: "xai.grok-4.5", family: "grok",
                      version: "4", variant: "5",
                      model: "grok-4.5", reasoning: "low")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "low"

  test "grok-4.20 off disables reasoning, levels send reasoning_effort":
    block offn:
      var body = %*{"stream": true}
      let p = Profile(name: "xai.grok-4.20", family: "grok",
                      version: "4", variant: "20",
                      model: "grok-4.20", reasoning: "off")
      applyReasoning(p, body)
      check body{"reasoning"}{"enabled"}.getBool == false
      check "reasoning_effort" notin body
    block high:
      var body = %*{"stream": true}
      let p = Profile(name: "xai.grok-4.20", family: "grok",
                      version: "4", variant: "20",
                      model: "grok-4.20", reasoning: "high")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "high"

  test "grok with empty reasoning sends no wire knob":
    var body = %*{"stream": true}
    let p = Profile(name: "xai.grok-4.5", family: "grok",
                    version: "4", variant: "5",
                    model: "grok-4.5", reasoning: "")
    applyReasoning(p, body)
    check "reasoning_effort" notin body
    check "reasoning" notin body

  test "knownGoodReasonings for openai gpt: per-model effort ladder":
    # Per OpenAI's docs: o-series low/medium/high; gpt-5.0 minimal..high;
    # 5.1+ adds none; 5.4/5.5 add xhigh; 5.6 adds max; pros reason
    # unconditionally; gpt-4.x has no knob at all.
    check knownGoodReasonings("openai", "o3") == @["low", "medium", "high"]
    check knownGoodReasonings("openai", "o4-mini") == @["low", "medium", "high"]
    check knownGoodReasonings("openai", "gpt-5") ==
      @["minimal", "low", "medium", "high"]
    check knownGoodReasonings("openai", "gpt-5-mini") ==
      @["minimal", "low", "medium", "high"]
    check knownGoodReasonings("openai", "gpt-5.4") ==
      @["none", "low", "medium", "high", "xhigh"]
    check knownGoodReasonings("openai", "gpt-5.5") ==
      @["none", "low", "medium", "high", "xhigh"]
    check knownGoodReasonings("openai", "gpt-5.5-pro") ==
      @["medium", "high", "xhigh"]
    check knownGoodReasonings("openai", "gpt-5.6") ==
      @["none", "low", "medium", "high", "xhigh", "max"]
    check knownGoodReasonings("openai", "gpt-5.6-luna") ==
      @["none", "low", "medium", "high", "xhigh", "max"]
    check knownGoodReasonings("openai", "gpt-4o") == newSeq[string](0)
    check knownGoodReasonings("openai", "gpt-4.1") == newSeq[string](0)
    # chatgpt (Codex backend) resolves to the openai catalog.
    check knownGoodReasonings("chatgpt", "gpt-5.6-sol") ==
      @["none", "low", "medium", "high", "xhigh", "max"]

  test "openai chat body sends reasoning_effort passthrough":
    for level in ["none", "low", "medium", "high", "xhigh", "max"]:
      var body = %*{"stream": true}
      let p = Profile(name: "openai.gpt-5.6", family: "gpt",
                      model: "gpt-5.6", reasoning: level)
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == level

  test "openai responses body sends reasoning effort passthrough":
    for level in ["none", "xhigh", "max"]:
      let p = Profile(name: "openai.gpt-5.6", family: "gpt",
                      model: "gpt-5.6", reasoning: level)
      let body = buildResponsesBody(p, %*[{"role": "user", "content": "go"}])
      check body{"reasoning"}{"effort"}.getStr == level

  test "knownGoodReasonings for grok: 4.5 levels, 4.20 adds off":
    check knownGoodReasonings("xai", "grok-4.5") == @["low", "medium", "high"]
    check knownGoodReasonings("xai", "grok-4.3") == @["low", "medium", "high"]
    check knownGoodReasonings("xai", "grok-4.20") == @["off", "low", "medium", "high"]
    check knownGoodReasonings("xai", "grok-build-0.1") == @["low", "medium", "high"]
    check knownGoodReasonings("openrouter", "x-ai/grok-4.5") == @["low", "medium", "high"]

  test "grok known-good: isKnownGood + context windows":
    check isKnownGood(Profile(name: "xai.grok-4.5", model: "grok-4.5"))
    check isKnownGood(Profile(name: "openrouter.x-ai/grok-4.5", model: "x-ai/grok-4.5"))
    check knownGoodContextWindow("xai", "grok-4.5") == 500_000
    check knownGoodContextWindow("xai", "grok-4.3") == 1_000_000
    check knownGoodContextWindow("xai", "grok-4.20") == 2_000_000
    check knownGoodContextWindow("xai", "grok-build-0.1") == 256_000

  test "supergrok aliases xai known-good entries":
    check canonicalKnownGoodProvider("supergrok") == "xai"
    check isKnownGood(Profile(name: "supergrok.grok-4.5", model: "grok-4.5"))
    check knownGoodFamily("supergrok", "grok-4.5") == "grok"
    check knownGoodContextWindow("supergrok", "grok-4.5") == 500_000
    check knownGoodReasonings("supergrok", "grok-4.5") == @["low", "medium", "high"]
    check curatedFor("supergrok") == curatedFor("xai")

  test "grok setup resolves to GrokPreamble + bash/patch tools":
    let p = Profile(name: "xai.grok-4.5", family: "grok", model: "grok-4.5")
    let s = setup(p)
    check s.prompt.startsWith("You are the Grok edition of 3code")
    var names: seq[string]
    for t in s.tools:
      names.add t{"function"}{"name"}.getStr
    check "bash" in names
    check "patch" in names
    check "apply_patch" notin names

  test "mimo on xiaomi sends thinking.type enabled/disabled":
    block onn:
      var body = %*{"stream": true}
      let p = Profile(name: "xiaomi.mimo-v2.5-pro", family: "mimo",
                      model: "mimo-v2.5-pro", reasoning: "on")
      applyReasoning(p, body)
      check body{"thinking"}{"type"}.getStr == "enabled"
    block offn:
      var body = %*{"stream": true}
      let p = Profile(name: "xiaomi.mimo-v2.5-pro", family: "mimo",
                      model: "mimo-v2.5-pro", reasoning: "off")
      applyReasoning(p, body)
      check body{"thinking"}{"type"}.getStr == "disabled"

  test "mimo on openrouter sends reasoning.enabled bool":
    block onn:
      var body = %*{"stream": true}
      let p = Profile(name: "openrouter.xiaomi/mimo-v2.5-pro", family: "mimo",
                      model: "xiaomi/mimo-v2.5-pro", reasoning: "on")
      applyReasoning(p, body)
      check body{"reasoning"}{"enabled"}.getBool == true
    block offn:
      var body = %*{"stream": true}
      let p = Profile(name: "openrouter.xiaomi/mimo-v2.5-pro", family: "mimo",
                      model: "xiaomi/mimo-v2.5-pro", reasoning: "off")
      applyReasoning(p, body)
      check body{"reasoning"}{"enabled"}.getBool == false

  test "mimo on vllm stack sends chat_template_kwargs.enable_thinking only when off":
    block onn:
      var body = %*{"stream": true}
      let p = Profile(name: "novita.xiaomimimo/mimo-v2.5-pro", family: "mimo",
                      model: "xiaomimimo/mimo-v2.5-pro", reasoning: "on")
      applyReasoning(p, body)
      check "chat_template_kwargs" notin body
    block offn:
      var body = %*{"stream": true}
      let p = Profile(name: "novita.xiaomimimo/mimo-v2.5-pro", family: "mimo",
                      model: "xiaomimimo/mimo-v2.5-pro", reasoning: "off")
      applyReasoning(p, body)
      check body{"chat_template_kwargs"}{"enable_thinking"}.getBool == false

  test "mimo knownGoodReasonings offers off/on":
    check knownGoodReasonings("xiaomi", "mimo-v2.5-pro") == @["off", "on"]
    check knownGoodReasonings("xiaomi", "mimo-v2.5") == @["off", "on"]
    check knownGoodReasonings("openrouter", "xiaomi/mimo-v2.5-pro") == @["off", "on"]

  test "mimo setup resolves to MimoPreamble and glmAndQwenTools":
    let p = Profile(name: "xiaomi.mimo-v2.5-pro", family: "mimo",
                    model: "mimo-v2.5-pro")
    let s = setup(p)
    check s.prompt.startsWith "You are the MiMo edition of 3code"
    check s.tools.len == 8

  test "provider stub returns before next API call when autosend is queued during tool":
    let pid = $getCurrentProcessId()
    let probeDir = getTempDir() / ("tc_autosend_probe_" & pid)
    let probePath = probeDir / "probe.nim"
    let outPath = probeDir / ("probe" & Exe)
    let cacheDir = probeDir / "nimcache"
    createDir(probeDir)
    createDir(cacheDir)
    defer:
      try: removeDir(probeDir) except OSError: discard

    writeFile(probeDir / "stub_responses.json", """[{
  "role": "assistant",
  "content": null,
  "tool_calls": [{
    "id": "call_1",
    "type": "function",
    "function": {
      "name": "bash",
      "arguments": "{\"command\":\"sleep 0.3; echo tooldone\"}"
    }
  }]
},{
  "role": "assistant",
  "content": "SHOULD_NOT_BE_CALLED"
}]""")
    writeFile(probePath, """
import std/[json, locks, os, strutils]
import threecode

var messages = %*[
  {"role": "system", "content": "sys"},
  {"role": "user", "content": "first"}
]
var session: Session
session.savePath = ""
session.readCache = newReadCache()
let profile = Profile(name: "stub", family: "glm", model: "stub-model")

proc queueAutosend() {.thread, gcsafe.} =
  sleep 100
  {.cast(gcsafe).}:
    pushInputEvent(InputEvent(kind: ieLine, text: "queued", echoRows: 1))

var t: Thread[void]
createThread(t, queueAutosend)
discard runTurns(profile, messages, session)
joinThread(t)

let queued = hasQueuedAutosend()
doAssert queued
doAssert messages.len == 4
doAssert messages[2]{"role"}.getStr == "assistant"
doAssert messages[3]{"role"}.getStr == "tool"
doAssert "SHOULD_NOT_BE_CALLED" notin $messages
""")
    let compileCmd = "nim c -d:ssl -d:providerStub --threads:on --path:src " & nimbleDepFlags() & " --nimcache:" &
      cacheDir.quoteShell & " -o:" & outPath.quoteShell & " " &
      probePath.quoteShell
    let (compileOut, compileCode) = execCmdEx(compileCmd)
    check compileCode == 0
    if compileCode != 0:
      checkpoint compileOut
    let (runOut, runCode) = execCmdEx(outPath.quoteShell, workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut

  test "provider stub runs pending tools when autosend is queued during API call":
    let pid = $getCurrentProcessId()
    let probeDir = getTempDir() / ("tc_autosend_api_probe_" & pid)
    let probePath = probeDir / "probe.nim"
    let outPath = probeDir / ("probe" & Exe)
    let cacheDir = probeDir / "nimcache"
    createDir(probeDir)
    createDir(cacheDir)
    defer:
      try: removeDir(probeDir) except OSError: discard

    writeFile(probeDir / "stub_responses.json", """[{
  "role": "assistant",
  "content": null,
  "preStreamDelayMs": 300,
  "tool_calls": [{
    "id": "call_1",
    "type": "function",
    "function": {
      "name": "bash",
      "arguments": "{\"command\":\"echo SHOULD_RUN\"}"
    }
  }]
},{
  "role": "assistant",
  "content": "SHOULD_NOT_BE_CALLED"
}]""")
    writeFile(probePath, """
import std/[json, locks, os, strutils]
import threecode

var messages = %*[
  {"role": "system", "content": "sys"},
  {"role": "user", "content": "first"}
]
var session: Session
session.savePath = ""
session.readCache = newReadCache()
let profile = Profile(name: "stub", family: "glm", model: "stub-model")

proc queueAutosend() {.thread, gcsafe.} =
  sleep 100
  {.cast(gcsafe).}:
    pushInputEvent(InputEvent(kind: ieLine, text: "queued", echoRows: 1))

var t: Thread[void]
createThread(t, queueAutosend)
discard runTurns(profile, messages, session)
joinThread(t)

let queued = hasQueuedAutosend()
doAssert queued
doAssert messages.len == 4
doAssert messages[2]{"role"}.getStr == "assistant"
doAssert messages[3]{"role"}.getStr == "tool"
doAssert "SHOULD_RUN" in messages[3]{"content"}.getStr
doAssert "skipped" notin messages[3]{"content"}.getStr
doAssert "SHOULD_NOT_BE_CALLED" notin $messages
""")
    let compileCmd = "nim c -d:ssl -d:providerStub --threads:on --path:src " & nimbleDepFlags() & " --nimcache:" &
      cacheDir.quoteShell & " -o:" & outPath.quoteShell & " " &
      probePath.quoteShell
    let (compileOut, compileCode) = execCmdEx(compileCmd)
    check compileCode == 0
    if compileCode != 0:
      checkpoint compileOut
    let (runOut, runCode) = execCmdEx(outPath.quoteShell, workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut

  test "provider stub finishes current tool batch before buffered prompt":
    let pid = $getCurrentProcessId()
    let probeDir = getTempDir() / ("tc_autosend_batch_probe_" & pid)
    let probePath = probeDir / "probe.nim"
    let outPath = probeDir / ("probe" & Exe)
    let cacheDir = probeDir / "nimcache"
    createDir(probeDir)
    createDir(cacheDir)
    defer:
      try: removeDir(probeDir) except OSError: discard

    writeFile(probeDir / "stub_responses.json", """[{
  "role": "assistant",
  "content": null,
  "tool_calls": [{
    "id": "call_1",
    "type": "function",
    "function": {
      "name": "bash",
      "arguments": "{\"command\":\"sleep 0.3; echo first-tool\"}"
    }
  },{
    "id": "call_2",
    "type": "function",
    "function": {
      "name": "bash",
      "arguments": "{\"command\":\"echo second-tool\"}"
    }
  }]
},{
  "role": "assistant",
  "content": "SHOULD_NOT_BE_CALLED"
}]""")
    writeFile(probePath, """
import std/[json, locks, os, strutils]
import threecode

var messages = %*[
  {"role": "system", "content": "sys"},
  {"role": "user", "content": "first"}
]
var session: Session
session.savePath = ""
session.readCache = newReadCache()
let profile = Profile(name: "stub", family: "glm", model: "stub-model")

proc queueAutosend() {.thread, gcsafe.} =
  sleep 100
  {.cast(gcsafe).}:
    pushInputEvent(InputEvent(kind: ieLine, text: "queued", echoRows: 1))

var t: Thread[void]
createThread(t, queueAutosend)
discard runTurns(profile, messages, session)
joinThread(t)

let queued = hasQueuedAutosend()
doAssert queued
doAssert messages.len == 5
doAssert messages[2]{"role"}.getStr == "assistant"
doAssert messages[3]{"role"}.getStr == "tool"
doAssert messages[4]{"role"}.getStr == "tool"
doAssert "first-tool" in messages[3]{"content"}.getStr
doAssert "second-tool" in messages[4]{"content"}.getStr
doAssert "skipped" notin messages[4]{"content"}.getStr
doAssert "SHOULD_NOT_BE_CALLED" notin $messages
""")
    let compileCmd = "nim c -d:ssl -d:providerStub --threads:on --path:src " & nimbleDepFlags() & " --nimcache:" &
      cacheDir.quoteShell & " -o:" & outPath.quoteShell & " " &
      probePath.quoteShell
    let (compileOut, compileCode) = execCmdEx(compileCmd)
    check compileCode == 0
    if compileCode != 0:
      checkpoint compileOut
    let (runOut, runCode) = execCmdEx(outPath.quoteShell, workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut

  test "provider stub covers common network failure aliases":
    let pid = $getCurrentProcessId()
    let probePath = getTempDir() / ("tc_stub_failures_" & pid & ".nim")
    let outPath = getTempDir() / ("tc_stub_failures_" & pid & Exe)
    let cacheDir = getTempDir() / ("tc_stub_failures_cache_" & pid)
    createDir(cacheDir)
    defer:
      try: removeFile(probePath) except OSError: discard
      try: removeFile(outPath) except OSError: discard
      try: removeDir(cacheDir) except OSError: discard
    writeFile(probePath, """
import threecode/api

doAssert parseStubFailure("dns") == sfDns
doAssert parseStubFailure("network-unreachable") == sfNetworkUnreachable
doAssert parseStubFailure("connection-refused") == sfConnectionRefused
doAssert parseStubFailure("connect-timeout") == sfConnectTimeout
doAssert parseStubFailure("certificate") == sfCertificate
doAssert parseStubFailure("broken-pipe") == sfBrokenPipe
doAssert parseStubFailure("connection-reset") == sfConnectionReset
doAssert parseStubFailure("eof") == sfEof
doAssert parseStubFailure("read-timeout") == sfReadTimeout
doAssert parseStubFailure("silent-then-ok") == sfSilentThenOk
doAssert parseStubFailure("malformed-sse") == sfMalformedSse
doAssert parseStubFailure("invalid-json") == sfInvalidJson
doAssert stubHttpStatus(parseStubFailure("400")) == 400
doAssert stubHttpStatus(parseStubFailure("401")) == 401
doAssert stubHttpStatus(parseStubFailure("403")) == 403
doAssert stubHttpStatus(parseStubFailure("408")) == 408
doAssert stubHttpStatus(parseStubFailure("409")) == 409
doAssert stubHttpStatus(parseStubFailure("425")) == 425
doAssert stubHttpStatus(parseStubFailure("429")) == 429
doAssert stubHttpStatus(parseStubFailure("500")) == 500
doAssert stubHttpStatus(parseStubFailure("502")) == 502
doAssert stubHttpStatus(parseStubFailure("503")) == 503
doAssert stubHttpStatus(parseStubFailure("504")) == 504
""")
    let compileCmd = "nim c -d:ssl -d:providerStub --path:src " & nimbleDepFlags() & " --nimcache:" &
      cacheDir.quoteShell & " -o:" & outPath.quoteShell & " " &
      probePath.quoteShell
    let (compileOut, compileCode) = execCmdEx(compileCmd)
    check compileCode == 0
    if compileCode != 0:
      checkpoint compileOut

suite "xml tool_call fallback":
  test "parses a single bash call":
    let raw = "Sure. <tool_call>bash<arg_key>command</arg_key>" &
              "<arg_value>ls -la</arg_value></tool_call> done."
    let r = parseXmlToolCalls(raw)
    check r.calls.len == 1
    check r.calls[0]{"function"}{"name"}.getStr == "bash"
    let args = parseJson(r.calls[0]{"function"}{"arguments"}.getStr)
    check args{"command"}.getStr == "ls -la"

  test "parses multiple args and multiple calls":
    let raw = "<tool_call>write<arg_key>path</arg_key><arg_value>a.txt" &
              "</arg_value><arg_key>body</arg_key><arg_value>hi" &
              "</arg_value></tool_call>" &
              "<tool_call>bash<arg_key>command</arg_key>" &
              "<arg_value>cat a.txt</arg_value></tool_call>"
    let r = parseXmlToolCalls(raw)
    check r.calls.len == 2
    let a0 = parseJson(r.calls[0]{"function"}{"arguments"}.getStr)
    check a0{"path"}.getStr == "a.txt"
    check a0{"body"}.getStr == "hi"
    check r.calls[1]{"function"}{"name"}.getStr == "bash"
    check r.cleaned.strip() == ""

  test "leaves content untouched when no tags":
    let raw = "Just some prose."
    let r = parseXmlToolCalls(raw)
    check r.calls.len == 0
    check r.cleaned == raw

  test "tolerates unterminated block":
    let raw = "ok <tool_call>bash<arg_key>command</arg_key>"
    let r = parseXmlToolCalls(raw)
    check r.calls.len == 0
    check "<tool_call>" in r.cleaned

  test "arg_value preserves embedded newlines":
    let raw = "<tool_call>write<arg_key>path</arg_key><arg_value>x</arg_value>" &
              "<arg_key>body</arg_key><arg_value>line1\nline2</arg_value></tool_call>"
    let r = parseXmlToolCalls(raw)
    let args = parseJson(r.calls[0]{"function"}{"arguments"}.getStr)
    check args{"body"}.getStr == "line1\nline2"

  test "verifyBody sends stream:true matching callModel":
    let p = Profile(name: "zai.glm-5.1", model: "glm-5.1", family: "glm")
    let body = parseJson(verifyBody(p))
    check body{"stream"}.getBool == true
    check body{"model"}.getStr == "glm-5.1"
    check body{"max_tokens"}.getInt == 1
    check body{"messages"}.len == 1
    check body{"messages"}[0]{"role"}.getStr == "user"

  test "openai builds a Responses body: input items, flat tools, max_output_tokens":
    # First-party openai speaks /responses, not /chat/completions. The
    # body must translate messages -> input (system -> developer),
    # flatten chat tool schemas, and use the Responses budget field.
    let p = Profile(name: "openai.gpt-5.4", family: "gpt", model: "gpt-5.4",
                    reasoning: "medium")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "go"},
      {"role": "assistant", "content": "", "tool_calls": [
        {"id": "fc_1", "type": "function",
         "function": {"name": "bash", "arguments": "{}"}}]},
      {"role": "tool", "tool_call_id": "fc_1", "content": "ok"},
    ]
    let body = buildResponsesBody(p, msgs)
    check body{"model"}.getStr == "gpt-5.4"
    check "messages" notin body
    check "max_tokens" notin body
    check "max_completion_tokens" notin body
    check body{"max_output_tokens"}.getInt == 8192
    check body{"input"}[0]{"role"}.getStr == "developer"
    # The assistant tool_call is a standalone function_call item, answered
    # by a function_call_output item paired via call_id.
    check body{"input"}[2]{"type"}.getStr == "function_call"
    check body{"input"}[2]{"call_id"}.getStr == "fc_1"
    check body{"input"}[2]{"name"}.getStr == "bash"
    check body{"input"}[2]{"arguments"}.getStr == "{}"
    check "tool_calls" notin body{"input"}[2]
    check body{"input"}[3]{"type"}.getStr == "function_call_output"
    check body{"input"}[3]{"call_id"}.getStr == "fc_1"
    check body{"input"}[3]{"output"}.getStr == "ok"
    let tools = body{"tools"}
    check tools.kind == JArray and tools.len > 0
    check tools[0]{"type"}.getStr == "function"
    check "function" notin tools[0]
    check tools[0]{"name"}.getStr.len > 0
    check "parameters" in tools[0]
    check body{"reasoning"}{"effort"}.getStr == "medium"
    # gpt on /responses rejects temperature != 1: it must be omitted.
    check "temperature" notin body
    # Dispatch is provider-level: every first-party openai combo goes to
    # /responses; hosted stacks keep chat completions.
    check responsesApi(Profile(name: "openai.gpt-oss-120b", family: "gpt-oss",
      model: "gpt-oss-120b")) == true
    check responsesApi(Profile(name: "nvidia.openai/gpt-oss-120b",
      family: "gpt-oss", model: "openai/gpt-oss-120b")) == false

  test "chatgpt speaks Responses at the Codex backend with codex body gates":
    # The ChatGPT subscription twin: same models as first-party openai,
    # but the token only works against chatgpt.com/backend-api/codex,
    # which demands stream:true, store:false, and a top-level
    # `instructions` string (hoisted out of the system/developer item).
    let p = Profile(name: "chatgpt.gpt-5.4", family: "gpt",
                    model: "gpt-5.4", url: "https://api.openai.com/v1")
    check responsesApi(p) == true
    check requestUrl(p) == "https://chatgpt.com/backend-api/codex"
    check requestUrl(Profile(name: "openai.chatgpt.gpt-5.4",
      model: "gpt-5.4", url: "https://api.openai.com/v1")) ==
      "https://chatgpt.com/backend-api/codex"
    check requestUrl(Profile(name: "openai.gpt-5.4", model: "gpt-5.4",
      url: "https://api.openai.com/v1")) == "https://api.openai.com/v1"
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "go"},
    ]
    let body = buildResponsesBody(p, msgs)
    check body{"stream"}.getBool == true
    check body{"store"}.getBool == false
    # The Codex backend 400s on max_output_tokens even though known-good
    # gpt-5.4 carries a cap; chatgpt profiles must omit it.
    check "max_output_tokens" notin body
    check body{"instructions"}.getStr == "sys"
    check body{"input"}.len == 1
    check body{"input"}[0]{"role"}.getStr == "user"
    # No system prompt in history: a placeholder keeps the field non-empty.
    let noSys = buildResponsesBody(p, %*[{"role": "user", "content": "go"}])
    check noSys{"instructions"}.getStr.len > 0
    # First-party openai keeps its body untouched.
    let first = buildResponsesBody(
      Profile(name: "openai.gpt-5.4", family: "gpt", model: "gpt-5.4"), msgs)
    check "store" notin first
    check "instructions" notin first
    check first{"input"}[0]{"role"}.getStr == "developer"
    # Verify ping obeys the same gates.
    let vb = parseJson(verifyBody(p))
    check vb{"stream"}.getBool == true
    check vb{"store"}.getBool == false
    check "max_output_tokens" notin vb
    check vb{"instructions"}.getStr.len > 0

  test "fallback flag is per-known-good entry":
    check xmlToolCallsFallback(Profile(name: "nvidia.z-ai/glm-5.2",
      model: "z-ai/glm-5.2", family: "glm")) == true
    check xmlToolCallsFallback(Profile(name: "zai.glm-5.1",
      model: "glm-5.1", family: "glm")) == false
    check xmlToolCallsFallback(Profile(name: "nvidia.openai/gpt-oss-120b",
      model: "openai/gpt-oss-120b", family: "gpt-oss")) == false

suite "runTurns empty-content auto-handling":

  test "runTurns escalates max_tokens then recovers on empty length reply":
    # The headline bug: GLM/Qwen/gpt-oss return 200 OK with content empty and
    # finish_reason "length" (reasoning ate the whole budget). runTurns must
    # NOT dead-end here: it escalates max_tokens and retries within the same
    # turn, recovering when the second response carries real content. This is
    # a turns-layer concern (the transport retry block stays untouched).
    let pid = $getCurrentProcessId()
    let probeDir = getTempDir() / ("tc_empty_esc_" & pid)
    let probePath = probeDir / "probe.nim"
    let outPath = probeDir / ("probe" & Exe)
    let cacheDir = probeDir / "nimcache"
    createDir(probeDir)
    createDir(cacheDir)
    defer:
      try: removeDir(probeDir) except OSError: discard
    # First response: empty content, finish_reason length (budget starved).
    # Second response: real content, proving the turn recovered.
    writeFile(probeDir / "stub_responses.json", """[{
  "role": "assistant",
  "content": "",
  "stream": false,
  "finish_reason": "length"
},{
  "role": "assistant",
  "content": "RECOVERED_AFTER_ESCALATION",
  "stream": false
}]""")
    writeFile(probePath, """
import std/[json, strutils]
import threecode
import threecode/api except callModel

var messages = %*[
  {"role": "system", "content": "sys"},
  {"role": "user", "content": "go"}
]
var session: Session
session.savePath = ""
session.readCache = newReadCache()
# Known-good combo so knownGoodGeneration returns a real budget (8192) for
# the escalation math; runTurnsInteractive's gateExperimental requires it.
let profile = Profile(name: "nebius.zai-org/GLM-5.2", url: "stub://", key: "k",
  family: "glm", model: "zai-org/GLM-5.2")

discard runTurnsInteractive(profile, messages, session)

# The empty turn is NOT added to history on a length-escalation retry (it
# would pollute context); only the recovered content lands. The escalation
# must have bumped max_tokens above the known-good 8192.
let lastAssistant = messages[^1]
doAssert lastAssistant{"role"}.getStr == "assistant",
  "last msg role: " & lastAssistant{"role"}.getStr
doAssert lastAssistant{"content"}.getStr == "RECOVERED_AFTER_ESCALATION",
  "content: " & lastAssistant{"content"}.getStr
doAssert lastStubMaxTokensOverride() > 8192,
  "override was " & $lastStubMaxTokensOverride() & " (no escalation happened)"
echo "OK"
""")
    let compileCmd = "nim c -d:ssl -d:providerStub --threads:on --path:src " &
      nimbleDepFlags() & " --nimcache:" & cacheDir.quoteShell &
      " -o:" & outPath.quoteShell & " " & probePath.quoteShell
    let (compileOut, compileCode) = execCmdEx(compileCmd)
    check compileCode == 0
    if compileCode != 0:
      checkpoint compileOut
    let (runOut, runCode) = execCmdEx(outPath.quoteShell, workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut
    # The hint line must use the new phrasing and the placeholder must be
    # filled with the actual budget, not the literal template text. The
    # retry must also carry the backoff delay (instant resends burned
    # tokens on a hostile provider).
    check "finished by length, retrying with" in runOut
    check "token budget in 1s" in runOut
    check "{humanTokens(maxTokensOverride)}" notin runOut
    # The bumped budget for 8192 is min(16384, 200000) = 16384 = "16.4k"
    check "16.4k" in runOut

  test "runTurns retries then recovers on a bare empty reply (no finish_reason)":
    # A 200 OK that comes back with no content, no tool calls, and no
    # finish_reason is not budget-starved and not steerable. runTurns must
    # still not dead-end: it resends the bare call, printing the reason and
    # a retry counter, and recovers when a later response carries content.
    let pid = $getCurrentProcessId()
    let probeDir = getTempDir() / ("tc_empty_resend_" & pid)
    let probePath = probeDir / "probe.nim"
    let outPath = probeDir / ("probe" & Exe)
    let cacheDir = probeDir / "nimcache"
    createDir(probeDir)
    createDir(cacheDir)
    defer:
      try: removeDir(probeDir) except OSError: discard
    # Response 1: bare empty (no finish_reason) -> steering retry.
    # Response 2: bare empty -> empty-resend 1.
    # Response 3: real content, proving recovery.
    writeFile(probeDir / "stub_responses.json", """[{
  "role": "assistant",
  "content": "",
  "stream": false
},{
  "role": "assistant",
  "content": "",
  "stream": false
},{
  "role": "assistant",
  "content": "RECOVERED_AFTER_RESEND",
  "stream": false
}]""")
    writeFile(probePath, """
import std/[json, strutils, times]
import threecode
import threecode/api except callModel

var messages = %*[
  {"role": "system", "content": "sys"},
  {"role": "user", "content": "go"}
]
var session: Session
session.savePath = ""
session.readCache = newReadCache()
let profile = Profile(name: "nebius.zai-org/GLM-5.2", url: "stub://", key: "k",
  family: "glm", model: "zai-org/GLM-5.2")

let t0 = epochTime()
discard runTurnsInteractive(profile, messages, session)
# The steer (1s) + bare resend (2s) backoffs must actually elapse: an
# instant retry loop is the bug this guards against.
doAssert epochTime() - t0 >= 2.5,
  "empty-reply retries took no backoff: " & $(epochTime() - t0) & "s"

let lastAssistant = messages[^1]
doAssert lastAssistant{"role"}.getStr == "assistant",
  "last msg role: " & lastAssistant{"role"}.getStr
doAssert lastAssistant{"content"}.getStr == "RECOVERED_AFTER_RESEND",
  "content: " & lastAssistant{"content"}.getStr
echo "OK"
""")
    let compileCmd = "nim c -d:ssl -d:providerStub --threads:on --path:src " &
      nimbleDepFlags() & " --nimcache:" & cacheDir.quoteShell &
      " -o:" & outPath.quoteShell & " " & probePath.quoteShell
    let (compileOut, compileCode) = execCmdEx(compileCmd)
    check compileCode == 0
    if compileCode != 0:
      checkpoint compileOut
    let (runOut, runCode) = execCmdEx(outPath.quoteShell, workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut
    # The bare-resend notice must carry the reason, the retry counter and
    # the backoff delay: "empty reply: <reason>. retrying N/12 in Xs".
    check "empty reply: no content, no tool calls. retrying 1/12 in 2s" in runOut
    # The old dead-end string must NOT appear when recovery succeeds.
    check "empty reply - no content, no tool calls" notin runOut
