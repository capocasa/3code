import std/[json, options, os, osproc, strutils, unittest]
import threecode/[api, config, modelname, prompts, types, util]
import stub_helpers

# Subprocess probes compile a small `probe.nim` and exec it. On Windows the
# nim compiler appends `.exe` to `-o:probe`, so the run path must include it
# or execCmdEx gets a file-not-found.
const Exe = when defined(windows): ".exe" else: ""

# One probe binary for every subprocess scenario: tests/api/probe.nim takes
# the mode as argv[1]. It used to be 16 separate probe.nim files, each
# compiled with its own throwaway nimcache (~18s each, ~300s for this file);
# now the binary is compiled once per process into a shared cache and every
# scenario runs the same executable with a different mode.
let probeBin = getCurrentDir() / "build" / ("api_probe" & Exe)
let probePlainBin = getCurrentDir() / "build" / ("api_probe_plainhttp" & Exe)
let probeNimcache = getCurrentDir() / "build" / "api_probe_nimcache"
let probePlainNimcache = getCurrentDir() / "build" / "api_probe_plainhttp_nimcache"
var
  probeBuilt = false
  probePlainBuilt = false

proc compileProbe(binPath, defines, cache: string) =
  createDir(cache)
  let compileCmd = "nim c " & defines & " --threads:on --path:src " &
    nimbleDepFlags() & " --nimcache:" & cache.quoteShell &
    " -o:" & binPath.quoteShell & " tests/api/probe.nim"
  let (compileOut, compileCode) = execCmdEx(compileCmd)
  check compileCode == 0
  if compileCode != 0:
    checkpoint compileOut

proc probeCommand(mode: string; plainHttp = false): string =
  if plainHttp:
    if not probePlainBuilt:
      compileProbe(probePlainBin, "-d:ssl -d:testPlainHttp",
                    probePlainNimcache)
      probePlainBuilt = true
    probePlainBin.quoteShell & " " & mode
  else:
    if not probeBuilt:
      compileProbe(probeBin, "-d:ssl -d:providerStub", probeNimcache)
      probeBuilt = true
    probeBin.quoteShell & " " & mode

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

  test "space bunny on openrouter gets include_reasoning (stealth route omits it)":
    # The stealth route drops reasoning deltas from the SSE stream unless
    # include_reasoning is set; every other openrouter model streams them
    # unasked, so the flag is mount-specific.
    var body = %*{"stream": true}
    let p = Profile(name: "openrouter.stealth/space-bunny-alpha",
                    family: "minimax", model: "stealth/space-bunny-alpha")

    applyStreamingOptions(p, body)

    check body{"include_reasoning"}.getBool == true

  test "space bunny on zen streams reasoning natively (no include_reasoning)":
    var body = %*{"stream": true}
    let p = Profile(name: "opencode.space-bunny-free", family: "minimax",
                    model: "space-bunny-free")

    applyStreamingOptions(p, body)

    check "include_reasoning" notin body

  test "plain openrouter models do not get include_reasoning":
    var body = %*{"stream": true}
    let p = Profile(name: "openrouter.minimax/minimax-m3", family: "minimax",
                    model: "minimax/minimax-m3")

    applyStreamingOptions(p, body)

    check "include_reasoning" notin body

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
    let p = Profile(name: "openai.gpt-5.4", family: "gpt", model: "gpt-5.4")

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
    # openai itself no longer serves gpt-oss (registry rows dropped
    # after a live 404); groq still lists and serves it.
    let p = Profile(name: "groq.openai/gpt-oss-120b", family: "gpt-oss",
                    model: "openai/gpt-oss-120b")

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

  test "kimi k3.1 rows omit temperature (upstream pins it to 1.0)":
    block novita:
      var body = %*{"stream": true}
      let p = Profile(name: "novita.moonshotai/kimi-k3.1-pro", family: "kimi",
                      model: "moonshotai/kimi-k3.1-pro")
      applyGenerationDefaults(p, body)
      check "temperature" notin body
      check body{"max_tokens"}.getInt == 8192
    block firstParty:
      var body = %*{"stream": true}
      let p = Profile(name: "kimi.kimi-k3.1-pro-highspeed", family: "kimi",
                      model: "kimi-k3.1-pro-highspeed")
      applyGenerationDefaults(p, body)
      check "temperature" notin body
      check body{"max_tokens"}.getInt == 8192
    block baseten:
      var body = %*{"stream": true}
      let p = Profile(name: "baseten.moonshotai/Kimi-K3.1-Pro", family: "kimi",
                      model: "moonshotai/Kimi-K3.1-Pro")
      applyGenerationDefaults(p, body)
      check "temperature" notin body
      check body{"max_tokens"}.getInt == 8192
    block neuralwatt:
      var body = %*{"stream": true}
      let p = Profile(name: "neuralwatt.kimi-k3.1-pro", family: "kimi",
                      model: "kimi-k3.1-pro")
      applyGenerationDefaults(p, body)
      check "temperature" notin body
      check body{"max_tokens"}.getInt == 8192

  test "mimo ultraspeed rides the v2.6-pro generation defaults":
    var body = %*{"stream": true}
    let p = Profile(name: "xiaomi.mimo-v2.6-pro-ultraspeed", family: "mimo",
                    model: "mimo-v2.6-pro-ultraspeed")
    applyGenerationDefaults(p, body)
    check body{"temperature"}.getFloat == 0.2
    check body{"max_tokens"}.getInt == 8192

  test "kimi effort levels send top-level reasoning_effort":
    block aggregator:
      var body = %*{"stream": true}
      let p = Profile(name: "novita.moonshotai/kimi-k3.1-pro", family: "kimi",
                      model: "moonshotai/kimi-k3.1-pro", reasoning: "high")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "high"
      check "chat_template_kwargs" notin body
    block firstPartyMax:
      var body = %*{"stream": true}
      let p = Profile(name: "kimicode.k3.1-pro", family: "kimi",
                      model: "k3.1-pro", reasoning: "max")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "max"
      check "chat_template_kwargs" notin body
    block k2StillToggles:
      var body = %*{"stream": true}
      let p = Profile(name: "together.moonshotai/Kimi-K2.6", family: "kimi",
                      model: "moonshotai/Kimi-K2.6", reasoning: "on")
      applyReasoning(p, body)
      check body{"chat_template_kwargs"}{"enable_thinking"}.getBool
      check "reasoning_effort" notin body
    block firstPartyK2SendsNothing:
      var body = %*{"stream": true}
      let p = Profile(name: "kimi.kimi-k2.6", family: "kimi",
                      model: "kimi-k2.6", reasoning: "on")
      applyReasoning(p, body)
      check "chat_template_kwargs" notin body
      check "reasoning_effort" notin body

  test "litellm k3 omits temperature (same as kimicode)":
    var body = %*{"stream": true}
    let p = Profile(name: "litellm.k3", family: "kimi", model: "k3")

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

  test "opencode gateways send top-level reasoning_effort (zen rejects the object)":
    block glm53zenV1:
      var body = %*{"stream": true}
      let p = Profile(name: "opencode.glm-5.3", family: "glm",
                      version: "5", variant: "3",
                      model: "glm-5.3", reasoning: "low")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "low"
      check "reasoning" notin body
    block glm52off:
      # thinking-only upstream: off cannot be honored, nothing sent
      var body = %*{"stream": true}
      let p = Profile(name: "opencodego.glm-5.2", family: "glm",
                      version: "5", variant: "2",
                      model: "glm-5.2", reasoning: "off")
      applyReasoning(p, body)
      check "reasoning" notin body
      check "reasoning_effort" notin body
    block glm52max:
      var body = %*{"stream": true}
      let p = Profile(name: "opencodego.glm-5.2", family: "glm",
                      version: "5", variant: "2",
                      model: "glm-5.2", reasoning: "max")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "max"
      check "reasoning" notin body

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

  test "qwen4-max grades effort, keeps the qwen3.x line binary":
    check knownGoodReasonings("qwen", "qwen4-max") == @["off", "low", "high", "xhigh"]
    check knownGoodReasonings("openrouter", "qwen/qwen4-max") == @["off", "low", "high", "xhigh"]
    check knownGoodReasonings("qwen", "qwen3.8-max") == @["off", "on"]
    check knownGoodContextWindow("qwen", "qwen4-max") == 1_000_000
    check knownGoodContextWindow("openrouter", "qwen/qwen4-max") == 1_000_000
    # output cap (thinking + answer share 262,144) sits under the 1M window
    check maxOutputTokensFor(Profile(name: "openrouter.qwen/qwen4-max",
      model: "qwen/qwen4-max", family: "qwen")) == 262_144

  test "hy4 narrows the knob to two levels":
    # Hy4's chat template accepts exactly high and no_think; Hy3 keeps low.
    check knownGoodReasonings("openrouter", "tencent/hy4-preview") == @["no_think", "high"]
    check knownGoodReasonings("tencent", "hy4-preview") == @["no_think", "high"]
    check knownGoodReasonings("deepinfra", "tencent/Hy4-preview") == @["no_think", "high"]
    check knownGoodReasonings("openrouter", "tencent/hy3") == @["no_think", "low", "high"]
    check knownGoodContextWindow("deepinfra", "tencent/Hy4-preview") == 1_000_000

  test "mistral: medium/large-4 none/high, large-3 no knob":
    check knownGoodReasonings("mistral", "mistral-medium-3-5") == @["none", "high"]
    check knownGoodReasonings("openrouter", "mistralai/mistral-medium-3-5") == @["none", "high"]
    check knownGoodReasonings("mistral", "mistral-large-4") == @["none", "high"]
    check knownGoodReasonings("mistral", "mistral-large-2512").len == 0
    check knownGoodReasonings("mistral", "mistral-vibe-cli-latest") == @["none", "high"]
    check knownGoodReasonings("mistral", "mistral-vibe-cli-fast") == @["none", "high"]
    check knownGoodReasoning("mistral", "mistral-large-4") == "high"
    check knownGoodReasoning("mistral", "mistral-vibe-cli-latest") == "high"
    check knownGoodReasoning("mistral", "mistral-vibe-cli-fast") == "none"
    block vibeGeneration:
      # The Vibe CLI sends temperature 1.0 (platform default) and
      # 32768 output tokens; the curated rows carry both so
      # `:temperature`-less profiles match what mistral-vibe itself
      # sends (b59d1e6 mined the bump from the CLI).
      let g = knownGoodGeneration("mistral", "mistral-vibe-cli-latest")
      check g.temperature == 1.0
      check g.maxTokens == 32768
    block vibePreamble:
      # The Mistral preamble is the economical 3code prompt: terse
      # discipline sections, 3code tool surface, thinking-channel
      # awareness for the none/high reasoning_effort ladder.
      let p = Profile(name: "mistral.mistral-vibe-cli-latest", family: "mistral",
                      variant: "vibe", model: "mistral-vibe-cli-latest")
      let (prompt, _) = setup(p)
      check "Instruction hierarchy" in prompt
      check "Blast radius" in prompt
      check "Every token costs" in prompt
      check "thinking in its own channel" in prompt
      check "red -> green" in prompt
      check "read(path, offset?, limit?)" in prompt
      check "# Knowledge" in prompt
      check "# Long context" in prompt
      check "524K window" in prompt
      check "{{skills}}" in prompt  # spliced at build time
      check "{{header}}" notin prompt  # no header splice anymore
      check "{{reasoning}}" notin prompt  # no reasoning splice anymore
    check knownGoodContextWindow(Profile(name: "mistral.test",
        family: "mistral", version: "4", variant: "large",
        model: "mistral-large-4")) == 524_288
    block familyPreamble:
      # One prompt for the whole family, tuned for Large 4.
      let p = Profile(name: "mistral.mistral-large-4", family: "mistral",
                      version: "4", variant: "large", model: "mistral-large-4")
      let (prompt, _) = setup(p)
      check "Mistral Large 4" in prompt
      check "reasoning_effort" in prompt
      check "Large 3" notin prompt
    block olderMemberSamePrompt:
      # Large 3 gets the same prompt (no family split).
      let p = Profile(name: "mistral.mistral-large-2512", family: "mistral",
                      model: "mistral-large-2512")
      let (prompt, _) = setup(p)
      check "Mistral Large 4" in prompt  # same header
      check "reasoning_effort" in prompt
    block firstParty:
      var body = %*{"stream": true}
      let p = Profile(name: "mistral.mistral-medium-3-5", family: "mistral",
                      variant: "medium", model: "mistral-medium-3-5",
                      reasoning: "high")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "high"
    block openrouterRoute:
      var body = %*{"stream": true}
      let p = Profile(name: "openrouter.mistralai/mistral-medium-3-5",
                      family: "mistral", variant: "medium",
                      model: "mistralai/mistral-medium-3-5", reasoning: "high")
      applyReasoning(p, body)
      check body{"reasoning"}{"effort"}.getStr == "high"

  # mistralvibe (parked with the provider; see KnownGoodCombos): the
  # vibe-cli aliases are usable through plain `mistral` in user config,
  # so the twin has no catalog rows to test until the plan gets its own
  # key. Blocks kept for the re-add.
  # test "mistralvibe rides the vibe-cli aliases on Medium's none/high ladder":
  #   # The Vibe Code coding-plan twin: same api.mistral.ai/v1 endpoint,
  #   # plan-billed usage, vibe-cli routing aliases over Medium 3.5
  #   # (`-latest`) and Small 4 (`-fast`). Both keep the platform
  #   # reasoning_effort ladder at exactly none/high (400 otherwise).
  #   check knownGoodReasonings("mistralvibe", "mistral-vibe-cli-latest") ==
  #     @["none", "high"]
  #   check knownGoodReasonings("mistralvibe", "mistral-vibe-cli-fast") ==
  #     @["none", "high"]
  #   block latestHigh:
  #     var body = %*{"stream": true}
  #     let p = Profile(name: "mistralvibe.mistral-vibe-cli-latest",
  #                     family: "mistral", variant: "vibe",
  #                     model: "mistral-vibe-cli-latest", reasoning: "high")
  #     applyReasoning(p, body)
  #     check body{"reasoning_effort"}.getStr == "high"
  #   block fastNone:
  #     var body = %*{"stream": true}
  #     let p = Profile(name: "mistralvibe.mistral-vibe-cli-fast",
  #                     family: "mistral", variant: "vibe-fast",
  #                     model: "mistral-vibe-cli-fast", reasoning: "none")
  #     applyReasoning(p, body)
  #     check body{"reasoning_effort"}.getStr == "none"
  #     check "reasoning" notin body

  test "mistral-hosted glm-5.2 rides the platform reasoning_effort ladder":
    # api.mistral.ai serves `zai-glm-5-2` with its own top-level
    # reasoning_effort (none/minimal/low/medium/high/xhigh/max; the z.ai
    # `thinking` object is extra_forbidden). Our off/high/max maps onto
    # none/high/max.
    check knownGoodReasonings("mistral", "zai-glm-5-2") == @["off", "high", "max"]
    block offn:
      var body = %*{"stream": true}
      let p = Profile(name: "mistral.zai-glm-5-2", family: "glm",
                      version: "5", variant: "2",
                      model: "zai-glm-5-2", reasoning: "off")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "none"
      check "thinking" notin body
    block highn:
      var body = %*{"stream": true}
      let p = Profile(name: "mistral.zai-glm-5-2", family: "glm",
                      version: "5", variant: "2",
                      model: "zai-glm-5-2", reasoning: "high")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "high"
    block maxn:
      var body = %*{"stream": true}
      let p = Profile(name: "mistral.zai-glm-5-2", family: "glm",
                      version: "5", variant: "2",
                      model: "zai-glm-5-2", reasoning: "max")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "max"

  test "mistral-hosted glm-5.3 keeps the forced-thinking ladder":
    # `zai-glm-5-3` on api.mistral.ai rejects reasoning_effort values
    # outside low/high/max (400 naming exactly those three) and still
    # 422s the z.ai `thinking` object, so 5.3 rides the platform knob
    # without an off position: a stale `off` sends nothing rather than
    # the fatal `none` the 5.2 mapping would produce.
    check knownGoodReasonings("mistral", "zai-glm-5-3") == @["low", "high", "max"]
    block effort:
      var body = %*{"stream": true}
      let p = Profile(name: "mistral.zai-glm-5-3", family: "glm",
                      version: "5", variant: "3",
                      model: "zai-glm-5-3", reasoning: "low")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "low"
      check "thinking" notin body
    block offDropped:
      var body = %*{"stream": true}
      let p = Profile(name: "mistral.zai-glm-5-3", family: "glm",
                      version: "5", variant: "3",
                      model: "zai-glm-5-3", reasoning: "off")
      applyReasoning(p, body)
      check "reasoning_effort" notin body
      check "thinking" notin body

  test "glm reasoning ladders per provider and generation":
    # Full matrix from `knownGoodReasonings` plus the wire mapping each
    # provider gets, checked against the verified live surfaces.
    block zaiBinary:
      # glm-4.7 / glm5 / glm-5.1: thinking.type toggle only.
      check knownGoodReasonings("zai", "glm-4.7") == @["off", "on"]
      check knownGoodReasonings("zaicode", "glm-5.1") == @["off", "on"]
      var body = %*{"stream": true}
      let p = Profile(name: "zai.glm-5.1", family: "glm",
                      version: "5", variant: "1",
                      model: "glm-5.1", reasoning: "off")
      applyReasoning(p, body)
      check body{"thinking"}{"type"}.getStr == "disabled"
      check "reasoning_effort" notin body
    block zai52:
      # z.ai maps low/medium->high and xhigh->max, so the distinct set is
      # off/high/max; none/minimal skip thinking.
      check knownGoodReasonings("zai", "glm-5.2") == @["off", "high", "max"]
      var body = %*{"stream": true}
      let p = Profile(name: "zaicode.glm-5.2", family: "glm",
                      version: "5", variant: "2",
                      model: "glm-5.2", reasoning: "max")
      applyReasoning(p, body)
      check body{"thinking"}{"type"}.getStr == "enabled"
      check body{"thinking"}{"effort"}.getStr == "max"
    block together53:
      # 5.3 is forced-thinking everywhere: top-level reasoning_effort,
      # no off (Together rejects the literal `off` with a validator
      # naming exactly low/high/max).
      check knownGoodReasonings("together", "zai-org/GLM-5.3") == @["low", "high", "max"]
      check knownGoodReasonings("together", "zai-org/GLM-5.3-Flash") == @["low", "high", "max"]
      var body = %*{"stream": true}
      let p = Profile(name: "together.zai-org/GLM-5.3", family: "glm",
                      version: "5", variant: "3",
                      model: "zai-org/GLM-5.3", reasoning: "high")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "high"
      check "reasoning" notin body
      check "thinking" notin body
    block openrouter53:
      check knownGoodReasonings("openrouter", "z-ai/glm-5.3") == @["low", "high", "max"]
      var body = %*{"stream": true}
      let p = Profile(name: "openrouter.z-ai/glm-5.3", family: "glm",
                      version: "5", variant: "3",
                      model: "z-ai/glm-5.3", reasoning: "max")
      applyReasoning(p, body)
      check body{"reasoning"}{"effort"}.getStr == "max"
      check "reasoning_effort" notin body

  test "glm-5.4 grades low/high/max with no true off":
    # Disabled thinking answers 200 on the coding endpoint but the model
    # still thinks lightly (z.ai maps Claude-Code thinking-off to effort
    # low), so off is not offered: the cheapest real setting is low.
    check knownGoodReasonings("zaicode", "glm-5.4") == @["low", "high", "max"]
    check knownGoodReasonings("zai", "glm-5.4") == @["low", "high", "max"]
    block zaiOffMapsToLow:
      var body = %*{"stream": true}
      let p = Profile(name: "zaicode.glm-5.4", family: "glm",
                      version: "5", variant: "4",
                      model: "glm-5.4", reasoning: "off")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "low"
      check "thinking" notin body
    block zaiEffort:
      var body = %*{"stream": true}
      let p = Profile(name: "zaicode.glm-5.4", family: "glm",
                      version: "5", variant: "4",
                      model: "glm-5.4", reasoning: "max")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "max"
      check "thinking" notin body

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
      check body{"reasoning_effort"}.getStr == "low"
      check "reasoning" notin body
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
    block xhigh:
      var body = %*{"stream": true}
      let p = Profile(name: "xai.grok-4.7", family: "grok",
                      version: "4", variant: "7",
                      model: "grok-4.7", reasoning: "xhigh")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "xhigh"
      check "reasoning" notin body

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

  test "hosted glm-5.3 sends top-level reasoning_effort":
    block baseten:
      var body = %*{"stream": true}
      let p = Profile(name: "baseten.zai-org/GLM-5.3", family: "glm",
                      version: "5", variant: "3",
                      model: "zai-org/GLM-5.3", reasoning: "low")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "low"
      check "thinking" notin body
    block novita:
      var body = %*{"stream": true}
      let p = Profile(name: "novita.zai-org/GLM-5.3", family: "glm",
                      version: "5", variant: "3",
                      model: "zai-org/GLM-5.3", reasoning: "high")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "high"
    block nvidia:
      var body = %*{"stream": true}
      let p = Profile(name: "nvidia.z-ai/glm-5.3", family: "glm",
                      version: "5", variant: "3",
                      model: "z-ai/glm-5.3", reasoning: "max")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "max"
    block together:
      var body = %*{"stream": true}
      let p = Profile(name: "together.zai-org/GLM-5.3", family: "glm",
                      version: "5", variant: "3",
                      model: "zai-org/GLM-5.3", reasoning: "low")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "low"
      check "reasoning" notin body

  test "knownGoodReasonings for openai gpt: per-model effort ladder":
    # Per OpenAI's docs: o-series low/medium/high; gpt-5.0 minimal..high;
    # 5.1+ adds none; 5.4/5.5 add xhigh; 5.6 adds max; pros reason
    # unconditionally; gpt-4.x has no knob at all.
    check knownGoodReasonings("openai", "o3") == @["low", "medium", "high"]
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
    # gpt-5.3-codex stops at xhigh (per its model page); the 5.6 pro
    # tiers keep the family ladder minus none (pro always reasons).
    check knownGoodReasonings("openai", "gpt-5.3-codex") ==
      @["low", "medium", "high", "xhigh"]
    check knownGoodReasonings("openai", "gpt-5.6-sol-pro") ==
      @["low", "medium", "high", "xhigh", "max"]
    check knownGoodReasonings("openai", "gpt-5.6-terra-pro") ==
      @["low", "medium", "high", "xhigh", "max"]
    check knownGoodReasonings("openrouter", "openai/gpt-5.6-luna-pro") ==
      @["low", "medium", "high", "xhigh", "max"]
    check knownGoodReasonings("openai", "gpt-5.6-luna") ==
      @["none", "low", "medium", "high", "xhigh", "max"]
    # gpt-6-astra and gpt-6.1-sol drop "none": reasoning cannot be
    # disabled; gpt-6-sol/luna keep it.
    check knownGoodReasonings("openai", "gpt-6-astra") ==
      @["low", "medium", "high", "xhigh", "max"]
    check knownGoodReasonings("openai", "gpt-6.1-sol") ==
      @["low", "medium", "high", "xhigh", "max"]
    check knownGoodReasonings("openai", "gpt-6-sol") ==
      @["none", "low", "medium", "high", "xhigh", "max"]
    check knownGoodReasonings("openai", "gpt-6-luna") ==
      @["none", "low", "medium", "high", "xhigh", "max"]
    check knownGoodReasonings("openai", "gpt-4o") == newSeq[string](0)
    check knownGoodReasonings("openai", "gpt-4.1") == newSeq[string](0)
    # chatgpt (Codex backend) resolves to the openai catalog.
    check knownGoodReasonings("chatgpt", "gpt-5.6-sol") ==
      @["none", "low", "medium", "high", "xhigh", "max"]
    check knownGoodReasonings("chatgpt", "gpt-6-astra") ==
      @["low", "medium", "high", "xhigh", "max"]
    check knownGoodReasonings("chatgpt", "gpt-6.1-sol") ==
      @["low", "medium", "high", "xhigh", "max"]
    # 6.2 Astra keeps the astra contract: no `none`, low..max; the
    # pro tier rides the same pro-mode ladder as 6.1's.
    check knownGoodReasonings("openai", "gpt-6.2-astra") ==
      @["low", "medium", "high", "xhigh", "max"]
    check knownGoodReasonings("chatgpt", "gpt-6.2-astra") ==
      @["low", "medium", "high", "xhigh", "max"]
    check knownGoodReasonings("openrouter", "openai/gpt-6.2-astra-pro") ==
      @["low", "medium", "high", "xhigh", "max"]

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

  test "gpt-6-astra chat body uses max_completion_tokens and reasoning_effort":
    # Same gpt-family wire surface: chat/completions rejects max_tokens
    # and takes reasoning_effort passthrough (astra accepts low..max, no
    # none, but the wire mapping is shared).
    var body = %*{"stream": true}
    let p = Profile(name: "openai.gpt-6-astra", family: "gpt",
                    model: "gpt-6-astra", reasoning: "xhigh")

    applyGenerationDefaults(p, body)
    applyReasoning(p, body)

    check body{"max_completion_tokens"}.getInt == 8192
    check body{"reasoning_effort"}.getStr == "xhigh"
    check "max_tokens" notin body

  test "gpt-6.2-astra rides the shared gpt wire surfaces":
    # Same completions shape as 6-astra (max_completion_tokens,
    # reasoning_effort passthrough) and the /responses shape the
    # first-party row and the chatgpt twin both use (effort under
    # reasoning.effort, no temperature for the gpt family).
    var body = %*{"stream": true}
    let p = Profile(name: "openai.gpt-6.2-astra", family: "gpt",
                    model: "gpt-6.2-astra", reasoning: "low")
    applyGenerationDefaults(p, body)
    applyReasoning(p, body)
    check body{"max_completion_tokens"}.getInt == 8192
    check body{"reasoning_effort"}.getStr == "low"
    let rbody = buildResponsesBody(p, %*[{"role": "user", "content": "go"}])
    check rbody{"model"}.getStr == "gpt-6.2-astra"
    check rbody{"reasoning"}{"effort"}.getStr == "low"
    check "temperature" notin rbody

  test "chatgpt gpt-6-astra verify body hits the Codex backend shape":
    # The subscription twin posts to chatgpt.com/backend-api/codex with
    # the codex gates; the astra model id passes through untouched.
    let p = Profile(name: "chatgpt.gpt-6-astra", family: "gpt",
                    model: "gpt-6-astra",
                    url: "https://api.openai.com/v1")
    check requestUrl(p) == "https://chatgpt.com/backend-api/codex"
    let body = buildResponsesBody(p, %*[{"role": "system", "content": "sys"},
                                        {"role": "user", "content": "go"}])
    check body{"model"}.getStr == "gpt-6-astra"
    check body{"store"}.getBool == false
    check "max_output_tokens" notin body
    check body{"instructions"}.getStr == "sys"

  test "responses requests pin prompt-cache affinity (gh #58)":
    # OpenAI's prompt cache is sharded: without a stable per-conversation
    # key (and the session_id header on the Codex backend) consecutive
    # turns land on different shards and cached_tokens stays near zero —
    # the sporadic ↻ bar the issue reports. The key is the conversation
    # id, stable across turns and resume; one-shots send nothing.
    let msgs = %*[{"role": "user", "content": "go"}]
    conversationId = "20260903T101415"
    defer: conversationId = ""
    let cg = Profile(name: "chatgpt.gpt-5.6", family: "gpt", model: "gpt-5.6")
    let oa = Profile(name: "openai.gpt-5.6", family: "gpt", model: "gpt-5.6")
    let gw = Profile(name: "openrouter.openai/gpt-5.6", family: "gpt",
                     model: "openai/gpt-5.6")
    check buildResponsesBody(cg, msgs){"prompt_cache_key"}.getStr ==
      "20260903T101415"
    check buildResponsesBody(oa, msgs){"prompt_cache_key"}.getStr ==
      "20260903T101415"
    # Non-Responses gateways never see the field even with a live
    # conversation (strict backends may reject unknown parameters).
    check "prompt_cache_key" notin buildResponsesBody(gw, msgs)
    # The Codex backend additionally shards by the session_id header the
    # Codex CLI sends; first-party /responses needs no header.
    check ("session_id", "20260903T101415") in
      requestHeaders(cg, "k", "text/event-stream")
    block:
      var names: seq[string]
      for kv in requestHeaders(oa, "k", "text/event-stream"): names.add kv[0]
      check "session_id" notin names
    # One-shot calls (no conversation published) send neither.
    conversationId = ""
    check "prompt_cache_key" notin buildResponsesBody(cg, msgs)
    block:
      var names: seq[string]
      for kv in requestHeaders(cg, "k", "text/event-stream"): names.add kv[0]
      check "session_id" notin names

  test "knownGoodReasonings for grok: 4.7/4.6 add xhigh, 4.20 adds off":
    check knownGoodReasonings("xai", "grok-4.7") == @["low", "medium", "high", "xhigh"]
    check knownGoodReasonings("xai", "grok-4.6") == @["low", "medium", "high", "xhigh"]
    check knownGoodReasonings("openrouter", "x-ai/grok-4.7") == @["low", "medium", "high", "xhigh"]
    check knownGoodReasonings("xai", "grok-4.5") == @["low", "medium", "high"]
    check knownGoodReasonings("xai", "grok-4.3") == @["low", "medium", "high"]
    check knownGoodReasonings("xai", "grok-4.20-0309-non-reasoning") == @["off", "low", "medium", "high"]
    check knownGoodReasonings("openrouter", "x-ai/grok-4.20") == @["off", "low", "medium", "high"]
    check knownGoodReasonings("openrouter", "x-ai/grok-4.5") == @["low", "medium", "high"]

  test "gpt-6 sol/luna and gpt-6.1 sol are known-good for openai and chatgpt":
    # Same 1.05M context and 128k architectural output cap as Astra;
    # the subscription twin resolves through the openai catalog.
    for model in ["gpt-6-sol", "gpt-6-luna", "gpt-6.1-sol"]:
      check isKnownGood(Profile(name: "openai." & model, model: model))
      check isKnownGood(Profile(name: "chatgpt." & model, model: model))
      check knownGoodContextWindow("openai", model) == 1_050_000
      check knownGoodContextWindow("chatgpt", model) == 1_050_000
      check maxOutputTokensFor(Profile(name: "openai." & model,
        model: model)) == 128_000
    check knownGoodGeneration("openai", "gpt-6-sol").maxTokens == 8192
    check knownGoodGeneration("openai", "gpt-6-luna").maxTokens == 4096

  test "gpt-6 sol/luna/6.1 sol are known-good on the third-party gateways":
    # openrouter, opencode, nanogpt, venice (dash-flattened ids there).
    check isKnownGood(Profile(name: "openrouter.openai/gpt-6-sol",
                              model: "openai/gpt-6-sol"))
    check isKnownGood(Profile(name: "openrouter.openai/gpt-6-luna",
                              model: "openai/gpt-6-luna"))
    check isKnownGood(Profile(name: "openrouter.openai/gpt-6.1-sol",
                              model: "openai/gpt-6.1-sol"))
    check isKnownGood(Profile(name: "opencode.gpt-6-sol", model: "gpt-6-sol"))
    check isKnownGood(Profile(name: "opencode.gpt-6-luna", model: "gpt-6-luna"))
    check isKnownGood(Profile(name: "opencode.gpt-6.1-sol", model: "gpt-6.1-sol"))
    check isKnownGood(Profile(name: "nanogpt.openai/gpt-6-sol",
                              model: "openai/gpt-6-sol"))
    check isKnownGood(Profile(name: "venice.openai-gpt-6-sol",
                              model: "openai-gpt-6-sol"))
    check isKnownGood(Profile(name: "venice.openai-gpt-61-sol",
                              model: "openai-gpt-61-sol"))
    # venice flattens the dot: 61 stays glued like its 56 rows, so the
    # normalized form keeps the two-digit version
    check normalizeModelName("openai-gpt-61-sol") == "gpt-61-sol"

  test "gpt-6-astra is known-good for openai and chatgpt":
    # The subscription twin resolves through the openai catalog; same
    # context window, same 128k architectural output cap (1.05M context
    # but a single generation tops out at 128k).
    check isKnownGood(Profile(name: "openai.gpt-6-astra", model: "gpt-6-astra"))
    check isKnownGood(Profile(name: "chatgpt.gpt-6-astra", model: "gpt-6-astra"))
    check knownGoodContextWindow("openai", "gpt-6-astra") == 1_050_000
    check knownGoodContextWindow("chatgpt", "gpt-6-astra") == 1_050_000
    check knownGoodGeneration("openai", "gpt-6-astra").maxTokens == 8192
    check maxOutputTokensFor(Profile(name: "openai.gpt-6-astra",
      model: "gpt-6-astra")) == 128_000

  test "gpt-6.2-astra is known-good first-party and on its day-one hosts":
    # Same line as 6-astra: 1.05M context, 8192 table generation default,
    # 128k architectural output cap. chatgpt resolves through the
    # openai catalog; openrouter and nano-gpt carry base + pro (public
    # catalogs, no key here to ping a completion).
    check isKnownGood(Profile(name: "openai.gpt-6.2-astra",
                              model: "gpt-6.2-astra"))
    check isKnownGood(Profile(name: "chatgpt.gpt-6.2-astra",
                              model: "gpt-6.2-astra"))
    check knownGoodContextWindow("openai", "gpt-6.2-astra") == 1_050_000
    check knownGoodContextWindow("chatgpt", "gpt-6.2-astra") == 1_050_000
    check knownGoodGeneration("openai", "gpt-6.2-astra").maxTokens == 8192
    check maxOutputTokensFor(Profile(name: "openai.gpt-6.2-astra",
      model: "gpt-6.2-astra")) == 128_000
    check isKnownGood(Profile(name: "openrouter.openai/gpt-6.2-astra",
                              model: "openai/gpt-6.2-astra"))
    check isKnownGood(Profile(name: "openrouter.openai/gpt-6.2-astra-pro",
                              model: "openai/gpt-6.2-astra-pro"))
    check isKnownGood(Profile(name: "nanogpt.openai/gpt-6.2-astra",
                              model: "openai/gpt-6.2-astra"))
    check isKnownGood(Profile(name: "nanogpt.openai/gpt-6.2-astra-pro",
                              model: "openai/gpt-6.2-astra-pro"))
    # venice and cheaperinference have not listed it yet: no rows.
    check not isKnownGood(Profile(name: "venice.openai-gpt-6.2-astra",
                                  model: "openai-gpt-6.2-astra"))
    check not isKnownGood(Profile(name: "cheaperinference.gpt-6.2-astra",
                                  model: "gpt-6.2-astra"))

  test "grok-4.7 is known-good for xai and supergrok":
    # The subscription twin resolves through the xai catalog; same
    # 500k context window and high effort default.
    check isKnownGood(Profile(name: "xai.grok-4.7", model: "grok-4.7"))
    check isKnownGood(Profile(name: "supergrok.grok-4.7", model: "grok-4.7"))
    check knownGoodContextWindow("xai", "grok-4.7") == 500_000
    check knownGoodContextWindow("supergrok", "grok-4.7") == 500_000
    check knownGoodGeneration("xai", "grok-4.7").maxTokens == 8192

  test "maxOutputTokensFor caps the escalation ladder at model output limits":
    # GLM-5.3 and DeepSeek-V4 sit in 1M contexts but cap a single
    # generation far lower; the ladder must not ask for more output than
    # the model can produce.
    check maxOutputTokensFor(Profile(name: "zai.glm-5.3-flash",
      model: "glm-5.3-flash")) == 131_072
    check maxOutputTokensFor(Profile(name: "openrouter.z-ai/glm-5.3",
      model: "z-ai/glm-5.3")) == 131_072
    check maxOutputTokensFor(Profile(name: "openrouter.deepseek/deepseek-v4-flash",
      model: "deepseek/deepseek-v4-flash")) == 384_000
    # Everything else falls back to the context window.
    check maxOutputTokensFor(Profile(name: "zai.glm-5.1",
      model: "glm-5.1")) == 200_000

  test "glm-5.3/5.3-flash and deepseek-v4-flash carry raised budgets":
    # These reasoning models burn the old 8k/4k budgets on thinking alone
    # and starve into empty "length" replies.
    check knownGoodGeneration("zai", "glm-5.3-flash").maxTokens == 65_536
    check knownGoodGeneration("openrouter", "z-ai/glm-5.3").maxTokens == 65_536
    check knownGoodGeneration("openrouter", "deepseek/deepseek-v4-flash").maxTokens == 65_536

  test "grok known-good: isKnownGood + context windows":
    check isKnownGood(Profile(name: "xai.grok-4.5", model: "grok-4.5"))
    check isKnownGood(Profile(name: "openrouter.x-ai/grok-4.5", model: "x-ai/grok-4.5"))
    check knownGoodContextWindow("xai", "grok-4.5") == 500_000
    check knownGoodContextWindow("xai", "grok-4.3") == 1_000_000
    check knownGoodContextWindow("xai", "grok-4.20-0309-non-reasoning") == 2_000_000

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

  test "gemini known-good: isKnownGood, context windows, output caps":
    check isKnownGood(Profile(name: "google.gemini-3.8-flash", model: "gemini-3.8-flash"))
    check isKnownGood(Profile(name: "google.gemini-3.1-pro-preview", model: "gemini-3.1-pro-preview"))
    check knownGoodContextWindow("google", "gemini-3.8-flash") == 1_048_576
    check knownGoodContextWindow("google", "gemini-3.7-flash") == 1_048_576
    check maxOutputTokensFor(Profile(name: "google.gemini-3.8-flash",
                                     model: "gemini-3.8-flash")) == 65_536

  test "gemini-4-argon is known-good everywhere it is live":
    # First-party plus the three aggregators serving it today (checked
    # live against each /models). Same wire surface as 3.8 Flash, so the
    # entries share the family defaults; only the levels differ.
    for combo in [("google", "gemini-4-argon"),
                  ("openrouter", "google/gemini-4-argon"),
                  ("opencode", "gemini-4-argon"),
                  ("nanogpt", "google/gemini-4-argon")]:
      let (prov, model) = combo
      check isKnownGood(Profile(name: prov & "." & model, model: model))
      check knownGoodFamily(prov, model) == "gemini"
      check knownGoodContextWindow(prov, model) == 1_048_576
    # 64k is the default AND max synchronous output; more than that 400s
    # without the background long-decode flag, so the escalation ladder
    # must cap at 64k, not the 1M window.
    check maxOutputTokensFor(Profile(name: "google.gemini-4-argon",
                                     model: "gemini-4-argon")) == 65_536
    check knownGoodReasoning("google", "gemini-4-argon") == "medium"

  test "gemini-4 carbon/neon/hydrogen are known-good on google":
    # Nov 2026 additions: Carbon (flagship, default high), Neon (Nov 18,
    # agent workflows) and Hydrogen (Flash successor) share Argon's wire
    # surface — 1M unified window, 64k streamed output — so they share
    # the row shape; only the thinking ladders and defaults differ.
    for model in ["gemini-4-carbon", "gemini-4-neon", "gemini-4-hydrogen"]:
      check isKnownGood(Profile(name: "google." & model, model: model))
      check knownGoodFamily("google", model) == "gemini"
      check knownGoodContextWindow("google", model) == 1_048_576
      check maxOutputTokensFor(Profile(name: "google." & model,
                                       model: model)) == 65_536
    check knownGoodReasoning("google", "gemini-4-carbon") == "high"
    check knownGoodReasoning("google", "gemini-4-neon") == "medium"
    check knownGoodReasoning("google", "gemini-4-hydrogen") == "medium"

  test "gemma-4 pair rides family other with no knob":
    # Open weights on the same endpoint: 262k window, 32k architectural
    # output, no thinking surface — no reasoning level offered or sent.
    for combo in [("google", "gemma-4-31b-it"),
                  ("google", "gemma-4-26b-a4b-it"),
                  ("venice", "google-gemma-4-31b-it"),
                  ("venice", "google-gemma-4-26b-a4b-it")]:
      let (prov, model) = combo
      check isKnownGood(Profile(name: prov & "." & model, model: model))
      check knownGoodFamily(prov, model) == "other"
      check knownGoodContextWindow(prov, model) == 262_144
      check knownGoodReasonings(prov, model).len == 0
      check knownGoodReasoning(prov, model) == ""
    check maxOutputTokensFor(Profile(name: "google.gemma-4-31b-it",
                                     model: "gemma-4-31b-it")) == 32_768
    block noKnob:
      var body = %*{"stream": true}
      let p = Profile(name: "google.gemma-4-31b-it", family: "other",
                      version: "4", variant: "31b",
                      model: "gemma-4-31b-it", reasoning: "")
      applyReasoning(p, body)
      check "reasoning_effort" notin body
      check "reasoning" notin body
      check "thinking" notin body

  test "geminicli aliases google known-good entries":
    check canonicalKnownGoodProvider("geminicli") == "google"
    check isKnownGood(Profile(name: "geminicli.gemini-3.8-flash", model: "gemini-3.8-flash"))
    check isKnownGood(Profile(name: "geminicli.gemini-4-argon", model: "gemini-4-argon"))
    check knownGoodFamily("geminicli", "gemini-3.8-flash") == "gemini"
    check curatedFor("geminicli") == curatedFor("google")

  test "gemini reasoning_effort: 3.8 levels, no off, no minimal on 3.8":
    check knownGoodReasonings("google", "gemini-3.8-flash") == @["low", "medium", "high"]
    check knownGoodReasonings("google", "gemini-3.7-flash") == @["minimal", "low", "medium", "high"]
    check knownGoodReasonings("google", "gemini-3.1-pro-preview") == @["minimal", "low", "medium", "high"]
    # 4 Argon: low/medium/high only; `minimal` is not a level (the
    # compat endpoint would silently map it down to low).
    check knownGoodReasonings("google", "gemini-4-argon") == @["low", "medium", "high"]
    check knownGoodReasonings("opencode", "gemini-4-argon") == @["low", "medium", "high"]
    # 4 Carbon matches Argon; Neon/Hydrogen add xhigh (still no off,
    # and no minimal on the 4 family).
    check knownGoodReasonings("google", "gemini-4-carbon") == @["low", "medium", "high"]
    check knownGoodReasonings("google", "gemini-4-neon") ==
      @["low", "medium", "high", "xhigh"]
    check knownGoodReasonings("google", "gemini-4-hydrogen") ==
      @["low", "medium", "high", "xhigh"]
    block effort:
      var body = %*{"stream": true}
      let p = Profile(name: "google.gemini-3.8-flash", family: "gemini",
                      version: "3", variant: "8-flash",
                      model: "gemini-3.8-flash", reasoning: "high")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "high"
      check "reasoning" notin body
      check "thinking" notin body
    block minimal:
      var body = %*{"stream": true}
      let p = Profile(name: "google.gemini-3.7-flash", family: "gemini",
                      version: "3", variant: "7-flash",
                      model: "gemini-3.7-flash", reasoning: "minimal")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "minimal"
    block xhigh:
      var body = %*{"stream": true}
      let p = Profile(name: "google.gemini-4-neon", family: "gemini",
                      version: "4", variant: "neon",
                      model: "gemini-4-neon", reasoning: "xhigh")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "xhigh"
      check "reasoning" notin body
      check "thinking" notin body

  test "gemini omits deprecated temperature":
    let body = %*{"stream": true}
    let p = Profile(name: "google.gemini-3.8-flash", family: "gemini",
                    model: "gemini-3.8-flash", reasoning: "medium")
    applyGenerationDefaults(p, body)
    check "temperature" notin body
    check body{"max_tokens"}.getInt == 65536

  test "geminicli requestUrl pins Code Assist, not AI Studio":
    let p = Profile(name: "geminicli.gemini-3.8-flash",
                    model: "gemini-3.8-flash", family: "gemini",
                    url: "https://generativelanguage.googleapis.com/v1beta/openai")
    check geminicliProfile(p)
    check requestUrl(p) == "https://cloudcode-pa.googleapis.com"
    check endpointUrl(p, false, true).endsWith(
      "/v1internal:streamGenerateContent?alt=sse")
    check endpointUrl(p, false, false).endsWith(
      "/v1internal:generateContent")
    check not geminicliProfile(Profile(name: "google.gemini-3.8-flash",
                                      model: "gemini-3.8-flash"))

  test "google rides the native generateContent wire":
    let p = Profile(name: "google.gemini-4-neon", family: "gemini",
                    model: "gemini-4-neon",
                    url: "https://generativelanguage.googleapis.com/v1beta/openai")
    check googleProfile(p)
    check geminiWire(p)
    # The `/openai` suffix selects the compat surface; the native base is
    # the same host without it, and existing configs keep working.
    check endpointUrl(p, false, true) ==
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-4-neon:streamGenerateContent?alt=sse"
    check endpointUrl(p, false, false) ==
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-4-neon:generateContent"
    let hdrs = requestHeaders(p, "AIza-test", "text/event-stream")
    check hdrs.contains(("x-goog-api-key", "AIza-test"))
    var hasBearer = false
    for (k, _) in hdrs:
      if k == "Authorization": hasBearer = true
    check not hasBearer

  test "google verify ping is a native body":
    let p = Profile(name: "google.gemini-4-neon", family: "gemini",
                    model: "gemini-4-neon")
    let j = parseJson(verifyBody(p))
    check not j.hasKey("model")
    check not j.hasKey("request")
    check j{"contents"}[0]{"parts"}[0]{"text"}.getStr == "ping"
    check j{"generationConfig"}{"maxOutputTokens"}.getInt == 1
    check j{"generationConfig"}{"thinkingConfig"}{"thinkingLevel"}.getStr == "low"

  test "geminicli still rides the Code Assist envelope":
    let p = Profile(name: "geminicli.gemini-4-neon", family: "gemini",
                    model: "gemini-4-neon")
    check geminiWire(p)
    check not googleProfile(p)
    let j = parseJson(verifyBody(p))
    check j{"model"}.getStr == "gemini-4-neon"
    check j{"request"}{"contents"}[0]{"parts"}[0]{"text"}.getStr == "ping"

  test "gemini setup resolves to GeminiPreamble + bash/patch tools":
    let p = Profile(name: "google.gemini-3.8-flash", family: "gemini",
                    model: "gemini-3.8-flash")
    let s = setup(p)
    check s.prompt.startsWith("You are the Gemini edition of 3code")
    var names: seq[string]
    for t in s.tools:
      names.add t{"function"}{"name"}.getStr
    check "bash" in names
    check "patch" in names
    check "apply_patch" notin names

  test "mimo on xiaomi sends thinking.type enabled/disabled":
    block onn:
      var body = %*{"stream": true}
      let p = Profile(name: "xiaomi.mimo-v2.6-pro", family: "mimo",
                      model: "mimo-v2.6-pro", reasoning: "on")
      applyReasoning(p, body)
      check body{"thinking"}{"type"}.getStr == "enabled"
    block offn:
      var body = %*{"stream": true}
      let p = Profile(name: "xiaomi.mimo-v2.6-pro", family: "mimo",
                      model: "mimo-v2.6-pro", reasoning: "off")
      applyReasoning(p, body)
      check body{"thinking"}{"type"}.getStr == "disabled"

  test "mimo on openrouter sends reasoning.enabled bool":
    block onn:
      var body = %*{"stream": true}
      let p = Profile(name: "openrouter.xiaomi/mimo-v2.6-flash", family: "mimo",
                      model: "xiaomi/mimo-v2.6-flash", reasoning: "on")
      applyReasoning(p, body)
      check body{"reasoning"}{"enabled"}.getBool == true
    block offn:
      var body = %*{"stream": true}
      let p = Profile(name: "openrouter.xiaomi/mimo-v2.6-flash", family: "mimo",
                      model: "xiaomi/mimo-v2.6-flash", reasoning: "off")
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
    check knownGoodReasonings("xiaomi", "mimo-v2.6-pro") == @["off", "on"]
    check knownGoodReasonings("xiaomi", "mimo-v2.6-flash") == @["off", "on"]
    check knownGoodReasonings("openrouter", "xiaomi/mimo-v2.5-pro") == @["off", "on"]
    check knownGoodReasonings("openrouter", "xiaomi/mimo-v2.6-flash") == @["off", "on"]
    check knownGoodReasonings("opencodego", "mimo-v2.6-pro") == @["off", "on"]
    check knownGoodReasonings("opencode", "mimo-v2.6-flash-free") == @["off", "on"]

  test "mimo setup resolves to MimoPreamble and glmAndQwenTools":
    let p = Profile(name: "xiaomi.mimo-v2.5-pro", family: "mimo",
                    model: "mimo-v2.5-pro")
    let s = setup(p)
    check s.prompt.startsWith "You are the MiMo edition of 3code"
    check s.tools.len == 8

  test "provider stub returns before next API call when autosend is queued during tool":
    let probeDir = getTempDir() / ("tc_autosend_probe_" & $getCurrentProcessId())
    createDir(probeDir)
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
      "arguments": "{\"command\":\"touch started; sleep 0.3; echo tooldone\"}"
    }
  }]
},{
  "role": "assistant",
  "content": "SHOULD_NOT_BE_CALLED"
}]""")
    let (runOut, runCode) = execCmdEx(probeCommand("autosend"),
                                      workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut

  test "runTurns flags a mid-loop yield so a queued system command can resume the turn":
    # A deferred system command (`:!`, mutating `:cmd`) queued while a tool
    # runs must yield the turn at the tool boundary - but the yield has to
    # be distinguishable from a finished turn, or the drain that runs the
    # command strands the conversation on unanswered tool results until
    # the next prompt. `turnYieldedToQueue` is that signal.
    let probeDir = getTempDir() / ("tc_syscmd_yield_probe_" & $getCurrentProcessId())
    createDir(probeDir)
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
      "arguments": "{\"command\":\"touch started; sleep 0.3; echo tooldone\"}"
    }
  }]
},{
  "role": "assistant",
  "content": "SECOND_REPLY"
}]""")
    let (runOut, runCode) = execCmdEx(probeCommand("syscmd-yield"),
                                      workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut

  test "resuming after the queued system command's drain continues the turn":
    # The interactive drain's exact sequence, driven headlessly: the turn
    # yields at the tool boundary for the deferred command, the drain runs
    # it (a no-op here - its output never reaches the model anyway), then
    # sends the model back in. The follow-up call must happen and the
    # conversation must end on the assistant's reply, not on the dangling
    # tool result.
    let probeDir = getTempDir() / ("tc_syscmd_resume_probe_" & $getCurrentProcessId())
    createDir(probeDir)
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
      "arguments": "{\"command\":\"touch started; sleep 0.3; echo tooldone\"}"
    }
  }]
},{
  "role": "assistant",
  "content": "SECOND_REPLY"
}]""")
    let (runOut, runCode) = execCmdEx(probeCommand("syscmd-resume"),
                                      workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut

  test "runTurns keeps running when an inline command was queued during a tool":
    # A safe command (`:tokens`, ...) typed during a turn runs inline on
    # the input thread the moment it is submitted; its un-echoed ieCommand
    # waits for nothing, so the turn must not stop for it - the model gets
    # its follow-up call and the reply lands.
    let probeDir = getTempDir() / ("tc_syscmd_inline_probe_" & $getCurrentProcessId())
    createDir(probeDir)
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
      "arguments": "{\"command\":\"touch started; sleep 0.3; echo tooldone\"}"
    }
  }]
},{
  "role": "assistant",
  "content": "SECOND_REPLY"
}]""")
    let (runOut, runCode) = execCmdEx(probeCommand("syscmd-inline"),
                                      workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut

  test "provider stub runs pending tools when autosend is queued during API call":
    let probeDir = getTempDir() / ("tc_autosend_api_probe_" & $getCurrentProcessId())
    createDir(probeDir)
    defer:
      try: removeDir(probeDir) except OSError: discard

    writeFile(probeDir / "stub_responses.json", """[{
  "role": "assistant",
  "content": null,
  "preStreamDelayMs": 300,
  "markerPath": "started",
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
    let (runOut, runCode) = execCmdEx(probeCommand("autosend-api"),
                                      workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut

  test "provider stub finishes current tool batch before buffered prompt":
    let probeDir = getTempDir() / ("tc_autosend_batch_probe_" & $getCurrentProcessId())
    createDir(probeDir)
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
      "arguments": "{\"command\":\"touch started; sleep 0.3; echo first-tool\"}"
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
    let (runOut, runCode) = execCmdEx(probeCommand("autosend-batch"),
                                      workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut

  test "provider stub keeps the turn going when a safe command ran inline during a tool":
    # A safe command (`:tokens`, `:help`, ...) submitted mid-turn runs inline
    # via activeCommandHook the moment Enter is pressed; the ieCommand event
    # stays in the queue as an un-echoed tombstone the drain skips. The turn
    # loop must not read that tombstone as queued work: hasQueuedAutosend()
    # used to count any ieCommand, so the turn ended right after the tool
    # exec — back at the prompt, silently, the model never seeing the tool
    # result (regression against 0.8.0, which only counted ieLine).
    let probeDir = getTempDir() / ("tc_autosend_cmd_tombstone_" & $getCurrentProcessId())
    createDir(probeDir)
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
      "arguments": "{\"command\":\"touch started; sleep 0.3; echo tooldone\"}"
    }
  }]
},{
  "role": "assistant",
  "content": "SECOND_REPLY"
}]""")
    let (runOut, runCode) = execCmdEx(probeCommand("cmd-tombstone"),
                                      workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut

  test "provider stub still yields before next call for a deferred mid-turn command":
    # The counterpart: a MUTATING command typed mid-turn is deferred (echoed
    # ieCommand, hourglass item pinned, drain runs it after the turn). The
    # turn loop must still stop before the model-initiated follow-up call so
    # the command runs at the boundary — the tombstone fix must not have
    # swallowed the legitimate yield.
    let probeDir = getTempDir() / ("tc_autosend_cmd_deferred_" & $getCurrentProcessId())
    createDir(probeDir)
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
      "arguments": "{\"command\":\"touch started; sleep 0.3; echo tooldone\"}"
    }
  }]
},{
  "role": "assistant",
  "content": "SHOULD_NOT_BE_CALLED"
}]""")
    let (runOut, runCode) = execCmdEx(probeCommand("cmd-deferred"),
                                      workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut

  test "provider stub covers common network failure aliases":
    let probeDir = getTempDir() / ("tc_stub_failures_" & $getCurrentProcessId())
    createDir(probeDir)
    defer:
      try: removeDir(probeDir) except OSError: discard
    let (runOut, runCode) = execCmdEx(probeCommand("stub-failures"),
                                      workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut

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

  test "parses Hermes JSON body (kolibri leak shape)":
    # Kolibri's native emission is Hermes-style JSON inside the tags;
    # a vLLM stack that leaks it into content does it in this shape.
    let raw = "<tool_call>\n{\"name\": \"bash\", \"arguments\": " &
              "{\"command\": \"echo hi\"}}\n</tool_call>"
    let r = parseXmlToolCalls(raw)
    check r.calls.len == 1
    check r.calls[0]{"function"}{"name"}.getStr == "bash"
    let args = parseJson(r.calls[0]{"function"}{"arguments"}.getStr)
    check args{"command"}.getStr == "echo hi"
    check r.cleaned.strip() == ""

  test "Hermes body with nested empty array arguments":
    let raw = "<tool_call>{\"name\": \"patch\", \"arguments\": " &
              "{\"path\": \"a.nim\", \"edits\": []}" &
              "}</tool_call>"
    let r = parseXmlToolCalls(raw)
    check r.calls[0]{"function"}{"name"}.getStr == "patch"
    let args = parseJson(r.calls[0]{"function"}{"arguments"}.getStr)
    check args{"path"}.getStr == "a.nim"

  test "GLM arg_key body still parses after Hermes addition":
    let raw = "<tool_call>bash<arg_key>command</arg_key>" &
              "<arg_value>true</arg_value></tool_call>"
    let r = parseXmlToolCalls(raw)
    check r.calls.len == 1
    check r.calls[0]{"function"}{"name"}.getStr == "bash"
    let args = parseJson(r.calls[0]{"function"}{"arguments"}.getStr)
    check args{"command"}.getStr == "true"

  test "non-JSON, non-arg_key body falls back to bare-name call":
    let raw = "<tool_call>update_plan</tool_call>"
    let r = parseXmlToolCalls(raw)
    check r.calls.len == 1
    check r.calls[0]{"function"}{"name"}.getStr == "update_plan"
    check r.calls[0]{"function"}{"arguments"}.getStr == "{}"

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

  test "gpt-5.6 pro slugs ride first-party /responses as reasoning.mode":
    # The 5.6/6 pro tiers are `reasoning.mode` on the first-party API,
    # not model ids: a bare pro slug ships as the base model plus
    # mode: pro. The Codex backend and prefixed gateway ids serve the
    # slugs natively and keep them. `gpt-5.5-pro` and older are real
    # ids and never get rewritten.
    check proModeWire("gpt-5.6-sol-pro") == "gpt-5.6-sol"
    check proModeWire("gpt-5.5-pro") == ""
    check proModeWire("gpt-5.6-sol") == ""
    let msgs = %*[{"role": "user", "content": "go"}]
    let p = Profile(name: "openai.gpt-5.6-sol-pro", family: "gpt",
                    model: "gpt-5.6-sol-pro", reasoning: "high",
                    url: "https://api.openai.com/v1")
    let body = buildResponsesBody(p, msgs)
    check body{"model"}.getStr == "gpt-5.6-sol"
    check body{"reasoning"}{"mode"}.getStr == "pro"
    check body{"reasoning"}{"effort"}.getStr == "high"
    # No effort picked: mode alone still ships.
    let bare = buildResponsesBody(Profile(name: "openai.gpt-5.6-sol-pro",
      family: "gpt", model: "gpt-5.6-sol-pro"), msgs)
    check bare{"model"}.getStr == "gpt-5.6-sol"
    check bare{"reasoning"}{"mode"}.getStr == "pro"
    check "effort" notin bare{"reasoning"}
    # Codex backend: slug native, no mode field.
    let cg = buildResponsesBody(Profile(name: "chatgpt.gpt-5.6-sol-pro",
      family: "gpt", model: "gpt-5.6-sol-pro", reasoning: "high"), msgs)
    check cg{"model"}.getStr == "gpt-5.6-sol-pro"
    check cg{"reasoning"}{"mode"} == nil
    check cg{"reasoning"}{"effort"}.getStr == "high"
    # Gateway id: slug native, untouched, no reasoning object at all.
    let orp = buildResponsesBody(Profile(name: "openrouter.openai/gpt-5.6-sol-pro",
      family: "gpt", model: "openai/gpt-5.6-sol-pro"), msgs)
    check orp{"model"}.getStr == "openai/gpt-5.6-sol-pro"
    check orp{"reasoning"} == nil
    # A real pro id is a model, not a mode: never rewritten.
    let real = buildResponsesBody(Profile(name: "openai.gpt-5.5-pro",
      family: "gpt", model: "gpt-5.5-pro", reasoning: "high"), msgs)
    check real{"model"}.getStr == "gpt-5.5-pro"
    check real{"reasoning"}{"mode"} == nil
    # The verify ping names the servable base model too, or the wizard
    # would reject the selection on a first-party 400.
    let vp = Profile(name: "openai.gpt-5.6-sol-pro", family: "gpt",
                     model: "gpt-5.6-sol-pro", url: "https://api.openai.com/v1")
    check parseJson(verifyBody(vp)){"model"}.getStr == "gpt-5.6-sol"
    check parseJson(verifyBody(Profile(name: "chatgpt.gpt-5.6-sol-pro",
      family: "gpt", model: "gpt-5.6-sol-pro"))){"model"}.getStr ==
      "gpt-5.6-sol-pro"

  test "gpt-5.3-codex is known-good for openai and openrouter":
    # Codex-tuned slug on the key paths; family gpt keeps the wire
    # shape (no temperature, effort knob) of the rest of the lineup.
    let msgs = %*[{"role": "user", "content": "go"}]
    check knownGoodFamily("openai", "gpt-5.3-codex") == "gpt"
    check knownGoodFamily("openrouter", "openai/gpt-5.3-codex") == "gpt"
    check knownGoodFamily("openai", "gpt-5.6-terra-pro") == "gpt"
    check knownGoodFamily("openrouter", "openai/gpt-5.6-luna-pro") == "gpt"
    let body = buildResponsesBody(Profile(name: "openai.gpt-5.3-codex",
      family: "gpt", model: "gpt-5.3-codex", reasoning: "xhigh"), msgs)
    check body{"model"}.getStr == "gpt-5.3-codex"
    check body{"reasoning"}{"effort"}.getStr == "xhigh"
    check "temperature" notin body

  test "fallback flag is per-known-good entry":
    check xmlToolCallsFallback(Profile(name: "nvidia.z-ai/glm-5.3-flash",
      model: "z-ai/glm-5.3-flash", family: "glm")) == true
    check xmlToolCallsFallback(Profile(name: "zai.glm-5.1",
      model: "glm-5.1", family: "glm")) == false
    check xmlToolCallsFallback(Profile(name: "nvidia.openai/gpt-oss-120b",
      model: "openai/gpt-oss-120b", family: "gpt-oss")) == false

  test "thinkBack replays for deepseek, glm and kimi rows, strips elsewhere":
    check knownGoodThinkBack(Profile(name: "deepseek.deepseek-v4-pro",
      model: "deepseek-v4-pro", family: "deepseek")) == tbAllTurns
    check knownGoodThinkBack(Profile(name: "zai.glm-5.2",
      model: "glm-5.2", family: "glm")) == tbNone
    check knownGoodThinkBack(Profile(name: "kimicode.k3",
      model: "k3", family: "kimi")) == tbAllTurns
    check knownGoodThinkBack(Profile(name: "together.moonshotai/Kimi-K2.6",
      model: "moonshotai/Kimi-K2.6", family: "kimi")) == tbAllTurns
    check knownGoodThinkBack(Profile(name: "openai.gpt-5.5",
      model: "gpt-5.5", family: "gpt")) == tbNone
    check knownGoodThinkBack(Profile(name: "together.Qwen/Qwen3.8-Flash",
      model: "Qwen/Qwen3.8-Flash", family: "qwen")) == tbNone
    check knownGoodThinkBack(Profile(name: "local.unknown",
      model: "unknown", family: "glm")) == tbNone

  test "thinkBack keeps reasoning_content on the wire for opted-in families":
    let messages = %*[
      {"role": "user", "content": "hi"},
      {"role": "assistant", "content": "hello",
       "reasoning_content": "private chain of thought"},
      {"role": "user", "content": "continue"}
    ]
    block keep:
      let p = Profile(name: "zaicode.glm-5.2", family: "glm", model: "glm-5.2")
      check knownGoodThinkBack(p) == tbAllTurns
      let wire = stripInternalFields(messages)
      # same strip path as callModel: the zaicode glm row keeps its
      # reasoning; the zai (standard API) row does not
      check knownGoodThinkBack(Profile(name: "zai.glm-5.2", family: "glm",
        model: "glm-5.2")) == tbNone
      stripThinkBack(knownGoodThinkBack(p), wire)
      check wire[1]{"reasoning_content"}.getStr == "private chain of thought"
    block strip:
      let p = Profile(name: "openai.gpt-5.5", family: "gpt", model: "gpt-5.5")
      let wire = stripInternalFields(messages)
      check knownGoodThinkBack(p) == tbNone
      stripThinkBack(knownGoodThinkBack(p), wire)
      check "reasoning_content" notin wire[1]

  test "stripThinkBack keeps current turn, drops older turns":
    # every assistant message carries reasoning_content (possibly empty);
    # current turn = messages after the last user message
    let messages = %*[
      {"role": "user", "content": "go"},
      {"role": "assistant", "content": "step",
       "reasoning_content": "old"},
      {"role": "user", "content": "continue"},
      {"role": "assistant", "content": "tool call coming",
       "reasoning_content": "fresh"}
    ]
    block none:
      let wire = parseJson($messages)
      stripThinkBack(tbNone, wire)
      check "reasoning_content" notin wire[1]
      check "reasoning_content" notin wire[3]
    block currentTurn:
      let wire = parseJson($messages)
      stripThinkBack(tbCurrentTurn, wire)
      check "reasoning_content" notin wire[1]
      check wire[3]{"reasoning_content"}.getStr == "fresh"
    block allTurns:
      let wire = parseJson($messages)
      stripThinkBack(tbAllTurns, wire)
      check wire[1]{"reasoning_content"}.getStr == "old"
      check wire[3]{"reasoning_content"}.getStr == "fresh"
    # tbCurrentTurn never touches the live history, only the wire copy
    check messages[1]{"reasoning_content"}.getStr == "old"

  test "chat wire keeps image content arrays verbatim":
    # The completions path forwards `messages` through stripInternalFields /
    # repairToolCallPairing / stripThinkBack into the body untouched; the
    # array must survive all three with bytes intact (providers' prompt
    # caches key on content bytes).
    let uri = "data:image/jpeg;base64," & "QUJD".repeat(64)
    let messages = %*[
      {"role": "user", "content": [
        {"type": "text", "text": "describe this"},
        {"type": "image_url", "image_url": {"url": uri}}]},
      {"role": "assistant", "content": "a mockup"},
      {"role": "user", "content": [
        {"type": "text", "text": "and now?"},
        {"type": "image_url", "image_url": {"url": uri}}]}
    ]
    let wire = repairToolCallPairing(stripInternalFields(messages))
    stripThinkBack(tbNone, wire)
    check wire[0]{"content"}.kind == JArray
    check wire[0]{"content"}[1]{"image_url"}{"url"}.getStr == uri
    check wire[2]{"content"}[0]{"text"}.getStr == "and now?"
    check $wire[0]{"content"} == $messages[0]{"content"}

  test "responses input translates image blocks to input_text + input_image":
    let uri = "data:image/png;base64,iVBOR"
    let p = Profile(name: "openai.gpt-5.6", family: "gpt", model: "gpt-5.6")
    let body = buildResponsesBody(p, %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": [
        {"type": "text", "text": "look"},
        {"type": "image_url", "image_url": {"url": uri}},
        {"type": "text", "text": "twice"}]}
    ])
    let input = body{"input"}
    check input[1]{"role"}.getStr == "user"
    let c = input[1]{"content"}
    check c.len == 3
    check c[0] == %*{"type": "input_text", "text": "look"}
    check c[1] == %*{"type": "input_image", "image_url": uri}
    check c[2] == %*{"type": "input_text", "text": "twice"}

  test "responses input passes string user content through":
    let p = Profile(name: "openai.gpt-5.6", family: "gpt", model: "gpt-5.6")
    let body = buildResponsesBody(p, %*[{"role": "user", "content": "go"}])
    check body{"input"}[0]{"content"}.getStr == "go"

  test "applyThinkBack sends explicit knobs on z.ai and kimi":
    block zai:
      # standard-API rows strip: no preserved-thinking knob is sent
      var body = %*{"stream": true}
      let p = Profile(name: "zai.glm-5.2", family: "glm", model: "glm-5.2")
      applyThinkBack(p, body)
      check "clear_thinking" notin body
    block zaicode:
      var body = %*{"stream": true}
      let p = Profile(name: "zaicode.glm-5.2", family: "glm", model: "glm-5.2")
      applyThinkBack(p, body)
      check body{"clear_thinking"}.getBool == false
    block kimi:
      # k2.6 needs `keep: "all"` to replay anything historical
      var body = %*{"stream": true}
      let p = Profile(name: "kimi.kimi-k2.6", family: "kimi",
                      model: "kimi-k2.6")
      check knownGoodThinkBack(p) == tbAllTurns
      applyThinkBack(p, body)
      check body{"thinking"}{"keep"}.getStr == "all"
      check body{"thinking"}{"type"}.getStr == "enabled"
    block kimik3:
      # k3 row: inert keep-all, thinking untouched otherwise
      var body = %*{"stream": true}
      let p = Profile(name: "kimicode.k3", family: "kimi", model: "k3")
      applyThinkBack(p, body)
      check body{"thinking"}{"keep"}.getStr == "all"
    block zaiflash:
      # standard-API glm rows strip (tbNone): no preserved-thinking knob
      var body = %*{"stream": true}
      let p = Profile(name: "zai.glm-5.3-flash", family: "glm",
                      model: "glm-5.3-flash")
      check knownGoodThinkBack(p) == tbNone
      applyThinkBack(p, body)
      check "clear_thinking" notin body
    block kimicurrent:
      # kimi row trialling current-turn replay: thinking knob still
      # needed to enable thinking, but no `keep` so history is not kept
      var body = %*{"stream": true}
      let p = Profile(name: "kimicode.kimi-for-coding", family: "kimi",
                      model: "kimi-for-coding")
      check knownGoodThinkBack(p) == tbCurrentTurn
      applyThinkBack(p, body)
      check body{"thinking"}{"type"}.getStr == "enabled"
      check "keep" notin body{"thinking"}
    block off:
      var body = %*{"stream": true}
      let p = Profile(name: "openai.gpt-5.5", family: "gpt", model: "gpt-5.5")
      applyThinkBack(p, body)
      check "clear_thinking" notin body
      check "thinking" notin body

suite "api: [params] overrides":
  test "generation defaults patch per field, unset fields keep the table value":
    let base = Profile(name: "zai.glm-5.2", model: "glm-5.2", family: "glm")
    check knownGoodGeneration(base).temperature == 0.2
    check knownGoodGeneration(base).maxTokens == 8192
    var p = base
    p.params.temperature = some(0.7)
    check knownGoodGeneration(p).temperature == 0.7
    check knownGoodGeneration(p).maxTokens == 8192
    var q = base
    q.params.maxTokens = some(32768)
    check knownGoodGeneration(q).temperature == 0.2
    check knownGoodGeneration(q).maxTokens == 32768

  test "generation overrides apply to off-table pairs too":
    var p = Profile(name: "local.custom", model: "custom", family: "glm")
    p.params.temperature = some(0.0)
    p.params.maxTokens = some(4096)
    let d = knownGoodGeneration(p)
    check d.temperature == 0.0
    check d.maxTokens == 4096

  test "think_back override wins in both directions":
    var p = Profile(name: "zaicode.glm-5.2", model: "glm-5.2", family: "glm")
    check knownGoodThinkBack(p) == tbAllTurns
    p.params.thinkBack = some(tbNone)
    check knownGoodThinkBack(p) == tbNone
    var q = Profile(name: "openai.gpt-5.5", model: "gpt-5.5", family: "gpt")
    check knownGoodThinkBack(q) == tbNone
    q.params.thinkBack = some(tbAllTurns)
    check knownGoodThinkBack(q) == tbAllTurns

  test "think_back override drives the history strip like callModel does":
    let messages = %*[
      {"role": "user", "content": "hi"},
      {"role": "assistant", "content": "hello",
       "reasoning_content": "private chain of thought"},
      {"role": "user", "content": "continue"}
    ]
    var p = Profile(name: "zai.glm-5.2", family: "glm", model: "glm-5.2")
    p.params.thinkBack = some(tbNone)
    let wire = stripInternalFields(messages)
    stripThinkBack(knownGoodThinkBack(p), wire)
    check "reasoning_content" notin wire[1]

  test "think_back override drives applyThinkBack wire fields":
    block glmNone:
      var p = Profile(name: "zai.glm-5.2", family: "glm", model: "glm-5.2")
      p.params.thinkBack = some(tbNone)
      let body = %*{}
      applyThinkBack(p, body)
      check "clear_thinking" notin body
    block glmAll:
      var p = Profile(name: "zai.glm-5.2", family: "glm", model: "glm-5.2")
      p.params.thinkBack = some(tbAllTurns)
      let body = %*{}
      applyThinkBack(p, body)
      check body{"clear_thinking"}.getBool == false
    block kimiAll:
      var p = Profile(name: "kimicode.kimi-for-coding", family: "kimi",
                      model: "kimi-for-coding")
      p.params.thinkBack = some(tbAllTurns)
      let body = %*{}
      applyThinkBack(p, body)
      check body{"thinking"}{"keep"}.getStr == "all"

  test "context_window override wins over the table":
    var p = Profile(name: "zai.glm-5.2", model: "glm-5.2", family: "glm")
    check knownGoodContextWindow(p) == 1_000_000
    p.params.contextWindow = some(123_456)
    check knownGoodContextWindow(p) == 123_456

  test "applyGenerationDefaults sends the overrides":
    var p = Profile(name: "zai.glm-5.2", model: "glm-5.2", family: "glm")
    p.params.temperature = some(0.9)
    p.params.maxTokens = some(999)
    let body = %*{}
    applyGenerationDefaults(p, body)
    check body{"temperature"}.getFloat == 0.9
    check body{"max_tokens"}.getInt == 999

  test "explicit temperature survives the kimicode/gemini omit quirks":
    block kimicodeOverride:
      var p = Profile(name: "kimicode.kimi-for-coding", family: "kimi",
                      model: "kimi-for-coding")
      p.params.temperature = some(0.6)
      let body = %*{}
      applyGenerationDefaults(p, body)
      check body{"temperature"}.getFloat == 0.6
    block kimicodeTableValueStillOmitted:
      let p = Profile(name: "kimicode.kimi-for-coding", family: "kimi",
                      model: "kimi-for-coding")
      let body = %*{}
      applyGenerationDefaults(p, body)
      check "temperature" notin body
    block geminiOverride:
      var p = Profile(name: "google.gemini-3.8-flash", family: "gemini",
                      model: "gemini-3.8-flash")
      p.params.temperature = some(0.5)
      let body = %*{}
      applyGenerationDefaults(p, body)
      check body{"temperature"}.getFloat == 0.5
    block geminiTableValueStillOmitted:
      let p = Profile(name: "google.gemini-3.8-flash", family: "gemini",
                      model: "gemini-3.8-flash")
      let body = %*{}
      applyGenerationDefaults(p, body)
      check "temperature" notin body

suite "runTurns empty-content auto-handling":

  test "runTurns escalates max_tokens then recovers on empty length reply":
    # The headline bug: GLM/Qwen/gpt-oss return 200 OK with content empty and
    # finish_reason "length" (reasoning ate the whole budget). runTurns must
    # NOT dead-end here: it escalates max_tokens and retries within the same
    # turn, recovering when the second response carries real content. This is
    # a turns-layer concern (the transport retry block stays untouched).
    let probeDir = getTempDir() / ("tc_empty_esc_" & $getCurrentProcessId())
    createDir(probeDir)
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
    let (runOut, runCode) = execCmdEx(probeCommand("empty-escalate"),
                                      workingDir = probeDir)
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
    # The bumped budget for 8192 is min(8192 * 2, 131072) = 16384 = "16.4k"
    check "16.4k" in runOut

  test "runTurns demotes reasoning effort before raising the budget on length":
    # A forced-thinking model at effort high burns any budget on reasoning
    # and returns empty content with finish_reason length. Doubling
    # max_tokens just buys another starved turn (and past the model's real
    # output cap it buys nothing at all); demoting effort first is the
    # cheap fix. This profile carries reasoning: "high" like glm-5.3.
    let probeDir = getTempDir() / ("tc_empty_demote_" & $getCurrentProcessId())
    createDir(probeDir)
    defer:
      try: removeDir(probeDir) except OSError: discard
    writeFile(probeDir / "stub_responses.json", """[{
  "role": "assistant",
  "content": "",
  "stream": false,
  "finish_reason": "length"
},{
  "role": "assistant",
  "content": "RECOVERED_AFTER_DEMOTE",
  "stream": false
}]""")
    let (runOut, runCode) = execCmdEx(probeCommand("empty-demote"),
                                      workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut
    check "retrying with lower reasoning effort" in runOut
    check "token budget" notin runOut

  test "runTurns steers on a reasoning-loop cut, then recovers":
    # The stream guard (api.nim) cuts a wedged thinking stream and returns
    # an empty assistant turn tagged finish_reason "reasoning-loop". That
    # must take the loop steer, not the budget escalation (the model is
    # stuck, not starved): a re-prompt naming the failure, then recovery
    # when the next response carries content. Field shape: tensorx
    # glm-5.3-flash 20261007T114126.
    let probeDir = getTempDir() / ("tc_loop_steer_" & $getCurrentProcessId())
    createDir(probeDir)
    defer:
      try: removeDir(probeDir) except OSError: discard
    writeFile(probeDir / "stub_responses.json", """[{
  "role": "assistant",
  "content": "",
  "reasoning_content": "- Die Schule loop Die Schule loop Die Schule loop",
  "stream": false,
  "finish_reason": "reasoning-loop"
},{
  "role": "assistant",
  "content": "RECOVERED_AFTER_LOOP_STEER",
  "stream": false
}]""")
    let (runOut, runCode) = execCmdEx(probeCommand("loop-steer"),
                                      workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut
    # The steer renders as its `»` item alone; the grey "auto:" context
    # row is gone.
    check BoldOn & "» " & Reset &
        "Your last reply was cut because your reasoning" in runOut
    check "auto: reasoning repeated itself" notin runOut

  test "runTurns gives up after two loop steers, ending the turn cleanly":
    # A model that re-wedges after every steer cannot be talked out of the
    # loop; the turn must end with a notice instead of feeding the
    # empty-resend machinery a cut stream forever.
    let probeDir = getTempDir() / ("tc_loop_giveup_" & $getCurrentProcessId())
    createDir(probeDir)
    defer:
      try: removeDir(probeDir) except OSError: discard
    writeFile(probeDir / "stub_responses.json", """[{
  "role": "assistant",
  "content": "",
  "reasoning_content": "loop one",
  "stream": false,
  "finish_reason": "reasoning-loop"
},{
  "role": "assistant",
  "content": "",
  "reasoning_content": "loop two",
  "stream": false,
  "finish_reason": "reasoning-loop"
},{
  "role": "assistant",
  "content": "",
  "reasoning_content": "loop three",
  "stream": false,
  "finish_reason": "reasoning-loop"
}]""")
    let (runOut, runCode) = execCmdEx(probeCommand("loop-giveup"),
                                      workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut
    check "reasoning loop - giving up after 2 re-prompts" in runOut

  test "runTurns demotes within the model's own reasoning ladder on length":
    # Mistral Medium 3.5 exposes reasoning_effort none/high only; demoting
    # the hardcoded way (high -> low) sends a value the API rejects with
    # 400 ("reasoning_effort low is not supported for this model"), so the
    # length-retry killed the turn instead of recovering. The demote must
    # step one rung down the model's own supported ladder: high -> none.
    let probeDir = getTempDir() / ("tc_empty_demote_ladder_" & $getCurrentProcessId())
    createDir(probeDir)
    defer:
      try: removeDir(probeDir) except OSError: discard
    writeFile(probeDir / "stub_responses.json", """[{
  "role": "assistant",
  "content": "",
  "stream": false,
  "finish_reason": "length"
},{
  "role": "assistant",
  "content": "RECOVERED_AFTER_DEMOTE",
  "stream": false
}]""")
    let (runOut, runCode) = execCmdEx(probeCommand("empty-demote-ladder"),
                                      workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut
    check "retrying with lower reasoning effort" in runOut
    check "token budget" notin runOut

  test "runTurns retries then recovers on a bare empty reply (no finish_reason)":
    # A 200 OK that comes back with no content, no tool calls, and no
    # finish_reason is not budget-starved and not steerable. runTurns must
    # still not dead-end: it resends the bare call, printing the reason and
    # a retry counter, and recovers when a later response carries content.
    let probeDir = getTempDir() / ("tc_empty_resend_" & $getCurrentProcessId())
    createDir(probeDir)
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
    let (runOut, runCode) = execCmdEx(probeCommand("empty-resend"),
                                      workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut
    # The bare-resend notice must carry the reason, the retry counter and
    # the backoff delay: "empty reply: <reason>. retrying N/12 in Xs".
    check "empty reply: no content, no tool calls. retrying 1/12 in 2s" in runOut
    # The steer autosend renders as a `»` agent-prompt item (the actual
    # prompt text sent as the user-role steer); the `»` item alone carries
    # it, no grey "auto:" context row above.
    check "auto: empty reply, re-prompting" notin runOut
    check BoldOn & "» " & Reset &
        "Your last reply came back empty." in runOut
    # The old dead-end string must NOT appear when recovery succeeds.
    check "empty reply - no content, no tool calls" notin runOut

suite "runTurns request-size 400 recovery":
  test "runTurns summarizes and retries when a gateway 400s a byte-large request":
    # Issue #48: OpenCode Zen rejects oversized request bodies with an
    # opaque `inference_failed` 400 while the token count is still far
    # under the context window, so the proactive summarize never fires.
    # Every resend carried the same history and 400'd again, and :summarize
    # could not rescue either because its meta-call replayed the same
    # oversized payload. runTurns must now collapse the history once and
    # retry; if the summarizer meta-call also fails, the middle is dropped
    # locally so the session still recovers. The stub provider can't drive
    # this (summarizeHistory goes through real HTTP), so the probe runs
    # the real non-stream transport against a local byte-envelope server.
    let probeDir = getTempDir() / ("tc_size400_" & $getCurrentProcessId())
    createDir(probeDir)
    defer:
      try: removeDir(probeDir) except OSError: discard
    # -d:testPlainHttp: the probe's provider is a loopback HTTP server.
    # config.nims supplies it for in-repo builds, but the probe lives in a
    # temp dir, so Nim never loads the repo's config from there.
    let (runOut, runCode) = execCmdEx(
      probeCommand("size400", plainHttp = true), workingDir = probeDir,
      options = {poStdErrToStdOut})
    check runCode == 0
    if runCode != 0:
      checkpoint runOut
    # Scenario A: recap via summarizer meta-call, retry succeeds.
    check "SCENARIO_A_OK" in runOut
    # Scenario B: summarizer itself rejected, local fallback recap.
    check "SCENARIO_B_OK" in runOut
    # Scenario C: proactive guard collapses without any 400 at all.
    check "SCENARIO_C_OK" in runOut
    check "request rejected as too large" in runOut
    check "collapsed 12 messages into a recap" in runOut
    check "collapsed 12 messages without a recap" in runOut
    check "gateway byte guard" in runOut
    # Scenario D: message-count guard collapses on the count axis; the
    # hint must report the pre-collapse count (72), not the post-collapse
    # length (10).
    check "SCENARIO_D_OK" in runOut
    check "(72 messages; tesseracted message-count guard)" in runOut
