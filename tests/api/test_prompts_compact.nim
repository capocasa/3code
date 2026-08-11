import std/[json, strutils, unittest]
import threecode/[prompts, compact, types]

suite "prompts: knownGoodFamily":
  test "returns family for known-good combo":
    check knownGoodFamily("zai", "glm-5.1") == "glm"

  test "returns empty for unknown combo":
    check knownGoodFamily("unknown", "model") == ""

  test "Profile overload returns family":
    let p = Profile(name: "zai.glm-5.1", model: "glm-5.1")
    check knownGoodFamily(p) == "glm"

  test "Profile overload returns empty for empty profile":
    check knownGoodFamily(Profile()) == ""

  test "case-insensitive match":
    check knownGoodFamily("ZAI", "GLM-5.1") == "glm"

  test "MiniMax M3 is known-good on the first-party provider":
    check knownGoodFamily("minimax", "MiniMax-M3") == "minimax"

  test "MiniMax M2.7 is known-good on the first-party provider":
    check knownGoodFamily("minimax", "MiniMax-M2.7") == "minimax"

  test "MiniMax M2.7-highspeed is known-good":
    check knownGoodFamily("minimax", "MiniMax-M2.7-highspeed") == "minimax"

suite "prompts: isKnownGood":
  test "true for known-good profile":
    let p = Profile(name: "zai.glm-5.1", model: "glm-5.1")
    check isKnownGood(p)

  test "false for unknown profile":
    let p = Profile(name: "unknown.model", model: "model")
    check not isKnownGood(p)

  test "false for empty profile":
    check not isKnownGood(Profile())

suite "prompts: knownGoodTags":
  test "returns tags for known-good combo":
    let (family, ver, vrt) = knownGoodTags("zai", "glm-5.1")
    check family == "glm"
    check ver.len > 0 or vrt.len > 0

  test "returns empty strings for unknown":
    let (f, v, r) = knownGoodTags("unknown", "model")
    check f == ""
    check v == ""
    check r == ""

  test "MiniMax M3 tags are version=3, variant=empty":
    let (family, ver, vrt) = knownGoodTags("minimax", "MiniMax-M3")
    check family == "minimax"
    check ver == "3"
    check vrt == ""

  test "MiniMax M2.7 tags are version=2, variant=7":
    let (family, ver, vrt) = knownGoodTags("minimax", "MiniMax-M2.7")
    check family == "minimax"
    check ver == "2"
    check vrt == "7"

suite "prompts: knownGoodReasoning":
  test "returns reasoning level for known-good combo":
    let r = knownGoodReasoning("zai", "glm-5.1")
    check r in ["", "low", "medium", "high", "on", "off", "max"]
    check r == "on"  # glm 5.1 defaults to on

  test "returns empty for unknown":
    check knownGoodReasoning("unknown", "model") == ""

suite "prompts: defaultReasoningsFor":
  test "glm 4.7/5/5.1 expose off/on":
    check defaultReasoningsFor("zai", "glm-5.1", "glm") == @["off", "on"]
    check defaultReasoningsFor("zai", "glm-5", "glm") == @["off", "on"]
    check defaultReasoningsFor("zai", "glm-4.7", "glm") == @["off", "on"]
    check defaultReasoningsFor("nebius", "zai-org/GLM-5.1", "glm") == @["off", "on"]

  test "glm-5.2 on z.ai exposes off/high/max":
    check defaultReasoningsFor("zai", "glm-5.2", "glm") == @["off", "high", "max"]

  test "kimi exposes off/on":
    check defaultReasoningsFor("nvidia", "moonshotai/kimi-k2.6", "kimi") ==
      @["off", "on"]
    check defaultReasoningsFor("together", "moonshotai/Kimi-K2.6", "kimi") ==
      @["off", "on"]
    check defaultReasoningsFor("deepinfra", "moonshotai/Kimi-K2.6", "kimi") ==
      @["off", "on"]

  test "level-based families still use ReasoningLevels":
    check defaultReasoningsFor("openai", "gpt-oss-1", "gpt-oss") ==
      @["low", "medium", "high"]
    check defaultReasoningsFor("deepseek", "deepseek-v4-pro", "deepseek") ==
      @["low", "medium", "high"]
    check defaultReasoningsFor("nebius", "deepseek-ai/DeepSeek-V3.2", "deepseek") ==
      @["low", "medium", "high"]

  test "minimax exposes off/on (same binary knob as kimi/longcat)":
    check defaultReasoningsFor("minimax", "MiniMax-M3", "minimax") ==
      @["off", "on"]
    check defaultReasoningsFor("minimax", "MiniMax-M2.7", "minimax") ==
      @["off", "on"]

suite "prompts: setup — minimax":
  test "M3 returns the MiniMax preamble":
    let p = Profile(name: "minimax.MiniMax-M3", url: "x", key: "k",
                    model: "MiniMax-M3", family: "minimax")
    let s = setup(p)
    check "MiniMax" in s.prompt
    check "M-series" in s.prompt

  test "M2.7 also returns the MiniMax preamble (not the old GLM alias)":
    let p = Profile(name: "minimax.MiniMax-M2.7", url: "x", key: "k",
                    model: "MiniMax-M2.7", family: "minimax")
    let s = setup(p)
    check "MiniMax" in s.prompt
    check "M-series" in s.prompt
    # The old M2.x entries aliased to GlmPreamble; verify the new prompt
    # is the MiniMax one for both versions.
    check "M-series" in s.prompt
    check "Tool discipline" in s.prompt

  test "tools are glmAndQwenTools (bash/read/write/patch)":
    let p = Profile(name: "minimax.MiniMax-M3", url: "x", key: "k",
                    model: "MiniMax-M3", family: "minimax")
    let s = setup(p)
    check s.tools.kind == JArray
    check s.tools.len == 8
    # Spot-check that the bash tool is present, with the expected
    # parameter shape.
    var foundBash = false
    for t in s.tools:
      if t{"function"}{"name"}.getStr == "bash":
        foundBash = true
        check t{"function"}{"parameters"}{"properties"}.hasKey("command")
    check foundBash

  test "falls back to level-based set for unsupported family":
    check defaultReasoningsFor("x", "y", "llama") == @ReasoningLevels

suite "prompts: setup — kimi":
  test "returns the Kimi preamble":
    let p = Profile(name: "opencode.kimi-k2.7-code", url: "x", key: "k",
                    model: "kimi-k2.7-code", family: "kimi")
    let s = setup(p)
    check "Kimi" in s.prompt
    check "Moonshot" in s.prompt

  test "tools are glmAndQwenTools (bash/read/write/patch)":
    let p = Profile(name: "opencode.kimi-k2.7-code", url: "x", key: "k",
                    model: "kimi-k2.7-code", family: "kimi")
    let s = setup(p)
    check s.tools.kind == JArray
    check s.tools.len == 8
    var foundBash = false
    for t in s.tools:
      if t{"function"}{"name"}.getStr == "bash":
        foundBash = true
        check t{"function"}{"parameters"}{"properties"}.hasKey("command")
    check foundBash

suite "prompts: buildCredit":
  test "builds attribution for valid profile":
    let p = Profile(name: "zai.glm-5.1", model: "glm-5.1")
    let credit = buildCredit(p)
    check "glm-5.1" in credit
    check "zai" in credit

  test "uses fallback for empty profile":
    let credit = buildCredit(Profile())
    check "Credit" in credit
    check credit.contains("whoever trained")

suite "compact: contextWindowFor":
  test "glm returns 200000":
    check contextWindowFor("glm-5.1") == 200_000

  test "claude returns 200000":
    check contextWindowFor("claude-3.5-sonnet") == 200_000

  test "deepseek returns 128000":
    check contextWindowFor("deepseek-v3") == 128_000

  test "gemini returns 1000000":
    check contextWindowFor("gemini-2.0-pro") == 1_000_000

  test "gpt-5 returns 400000":
    check contextWindowFor("gpt-5") == 400_000

  test "gpt-4 returns 128000":
    check contextWindowFor("gpt-4o") == 128_000

  test "qwen returns 128000":
    check contextWindowFor("qwen-2.5") == 128_000

  test "llama returns 128000":
    check contextWindowFor("llama-3.1") == 128_000

  test "unknown returns 128000 (default)":
    check contextWindowFor("unknown-model") == 128_000

  test "qwen3-coder returns 262144":
    check contextWindowFor("qwen3-coder-480b") == 262_144

  test "case insensitive":
    check contextWindowFor("GLM-5.1") == 200_000

  test "o1/o3/o4 models return 200000":
    check contextWindowFor("o1-preview") == 200_000
    check contextWindowFor("o3-mini") == 200_000

  test "kimi-k2 returns 262144":
    check contextWindowFor("kimi-k2") == 262_144

  test "minimax-m3 returns 1000000":
    check contextWindowFor("MiniMax-M3") == 1_000_000
    check contextWindowFor("minimaxai/MiniMax-M3") == 1_000_000

  test "minimax-m2.7 falls back to 204800":
    check contextWindowFor("MiniMax-M2.7") == 204_800
    check contextWindowFor("minimaxai/MiniMax-M2.7") == 204_800

suite "compact: contextWindowFor (known-good)":
  test "glm-5.2 profile returns 1000000":
    let p = Profile(name: "zai.test", model: "glm-5.2", family: "glm")
    check contextWindowFor(p) == 1_000_000

  test "glm-5.1 profile returns 200000":
    let p = Profile(name: "zai.test", model: "glm-5.1", family: "glm")
    check contextWindowFor(p) == 200_000

  test "kimi profile returns 262144":
    let p = Profile(name: "nebius.test", model: "moonshotai/Kimi-K2.6",
                    family: "kimi")
    check contextWindowFor(p) == 262_144

  test "deepseek-v4 profile returns 1000000":
    let p = Profile(name: "deepseek.test", model: "deepseek-v4-pro",
                    family: "deepseek")
    check contextWindowFor(p) == 1_000_000

  test "minimax M3 profile returns 1000000":
    let p = Profile(name: "minimax.MiniMax-M3", model: "MiniMax-M3",
                    family: "minimax")
    check contextWindowFor(p) == 1_000_000

  test "minimax M2.7 profile returns 204800":
    let p = Profile(name: "minimax.MiniMax-M2.7", model: "MiniMax-M2.7",
                    family: "minimax")
    check contextWindowFor(p) == 204_800

  test "off-table profile falls back to heuristic":
    # Not a known-good (provider, model) pair, so heuristic kicks in.
    let p = Profile(name: "acme.test", model: "gpt-5", family: "")
    check contextWindowFor(p) == 400_000

suite "prompts: inkling family":
  test "known-good on baseten / together / fireworks":
    check knownGoodFamily("baseten", "thinkingmachines/inkling") == "inkling"
    check knownGoodFamily("together", "thinkingmachines/Inkling") == "inkling"
    check knownGoodFamily("fireworks",
      "accounts/fireworks/models/inkling") == "inkling"

  test "case-insensitive match":
    check knownGoodFamily("BASETEN", "THINKINGMACHINES/INKLING") == "inkling"

  test "version/variant tags":
    let (f, v, vr) = knownGoodTags("together", "thinkingmachines/Inkling")
    check f == "inkling"
    check v == "1"
    check vr == ""

  test "default reasoning level is medium":
    check knownGoodReasoning("together", "thinkingmachines/Inkling") == "medium"

  test "exposes the level-based low/medium/high set":
    check defaultReasoningsFor("together", "thinkingmachines/Inkling",
      "inkling") == @["low", "medium", "high"]

  test "setup returns the Inkling preamble with the bash/write/patch tools":
    let p = Profile(name: "together.thinkingmachines/Inkling", url: "x",
                    key: "k", model: "thinkingmachines/Inkling",
                    family: "inkling")
    let s = setup(p)
    check "Inkling" in s.prompt
    # same tool surface as glm/qwen/deepseek (bash, write, patch, ...)
    var names: seq[string]
    for t in s.tools:
      names.add t{"function"}{"name"}.getStr
    check "bash" in names
    check "write" in names
    check "patch" in names

  test "context windows per provider":
    check knownGoodContextWindow("baseten",
      "thinkingmachines/inkling") == 256_000
    check knownGoodContextWindow("together",
      "thinkingmachines/Inkling") == 1_000_000
    check knownGoodContextWindow("fireworks",
      "accounts/fireworks/models/inkling") == 1_040_000

suite "compact: decideContextAction":
  test "returns caNone when under threshold":
    check decideContextAction(1000, 128_000, 10) == caNone

  test "returns caSummarize when over threshold and enough messages":
    check decideContextAction(110_000, 128_000, 20) == caSummarize

  test "returns caNone when over threshold but too few messages to summarize":
    check decideContextAction(110_000, 128_000, 5) == caNone

  test "returns caNone for zero tokens":
    check decideContextAction(0, 128_000, 20) == caNone

  test "returns caNone for zero window":
    check decideContextAction(100_000, 0, 20) == caNone

  test "custom threshold":
    check decideContextAction(70_000, 128_000, 20, threshold = 0.5) == caSummarize
