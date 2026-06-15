import std/[strutils, unittest]
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

suite "prompts: knownGoodReasoning":
  test "returns reasoning level for known-good combo":
    let r = knownGoodReasoning("zai", "glm-5.1")
    check r in ["", "low", "medium", "high", "on", "off", "max"]
    check r == "on"  # glm 5.1 defaults to on

  test "returns empty for unknown":
    check knownGoodReasoning("unknown", "model") == ""

suite "prompts: reasoningSupported":
  test "true for gpt-oss":
    check reasoningSupported("gpt-oss")

  test "true for glm":
    check reasoningSupported("glm")

  test "true for deepseek":
    check reasoningSupported("deepseek")

  test "true for minimax":
    check reasoningSupported("minimax")

  test "false for unknown family":
    check not reasoningSupported("llama")

suite "prompts: defaultReasoningsFor":
  test "glm 4.7/5/5.1 expose off/on":
    check defaultReasoningsFor("zai", "glm-5.1", "glm") == @["off", "on"]
    check defaultReasoningsFor("zai", "glm-5", "glm") == @["off", "on"]
    check defaultReasoningsFor("zai", "glm-4.7", "glm") == @["off", "on"]
    check defaultReasoningsFor("nebius", "zai-org/GLM-5.1", "glm") == @["off", "on"]

  test "glm-5.2 on z.ai exposes off/high/max":
    check defaultReasoningsFor("zai", "glm-5.2", "glm") == @["off", "high", "max"]

  test "level-based families still use ReasoningLevels":
    check defaultReasoningsFor("openai", "gpt-oss-1", "gpt-oss") ==
      @["low", "medium", "high"]

  test "returns empty for unsupported family":
    check defaultReasoningsFor("x", "y", "llama").len == 0

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
  test "glm returns 128000":
    check contextWindowFor("glm-5.1") == 128_000

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
    check contextWindowFor("GLM-5.1") == 128_000

  test "o1/o3/o4 models return 200000":
    check contextWindowFor("o1-preview") == 200_000
    check contextWindowFor("o3-mini") == 200_000

  test "kimi-k2 returns 128000":
    check contextWindowFor("kimi-k2") == 128_000

suite "compact: decideContextAction":
  test "returns caNone when under threshold":
    check decideContextAction(1000, 128_000, 10) == caNone

  test "returns caSummarize when over threshold and enough messages":
    check decideContextAction(110_000, 128_000, 20) == caSummarize

  test "returns caCompact when over threshold but too few messages":
    check decideContextAction(110_000, 128_000, 5) == caCompact

  test "returns caNone for zero tokens":
    check decideContextAction(0, 128_000, 20) == caNone

  test "returns caNone for zero window":
    check decideContextAction(100_000, 0, 20) == caNone

  test "custom threshold":
    check decideContextAction(70_000, 128_000, 20, threshold = 0.5) == caSummarize
