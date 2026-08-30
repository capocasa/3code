import std/[unittest, strutils]
import threecode/modelname

suite "modelname: normalizeModelName":

  test "glm-5.3-flash":
    check normalizeModelName("zai-org/GLM-5.3-Flash") == "glm-5.3-flash"

  test "dotted provider path stripped to last slash":
    check normalizeModelName("accounts/fireworks/models/glm-5p1") == "glm-5.1"

  test "p-notation normalized to dots":
    check normalizeModelName("kimi-k2p6") == "kimi-2.6"

  test "dash-separated version normalized to dots":
    check normalizeModelName("zai-glm-5-3-flash") == "glm-5.3-flash"

  test "glued family and version":
    check normalizeModelName("hy3") == "hy3"
    check normalizeModelName("qwen3.8-27b") == "qwen-3.8-27b"
    check normalizeModelName("glm5.3-flash") == "glm-5.3-flash"

  test "v-prefixed version":
    check normalizeModelName("deepseek-v4-flash") == "deepseek4-flash"

  test "bare family":
    check normalizeModelName("Inkling") == "inkling"

  test "suffix after colon":
    check normalizeModelName("thinkingmachines/inkling:free") == "inkling:free"

  test "qualifiers kept in order":
    check normalizeModelName("Qwen/Qwen3.6-35B-A3B-FP8") == "qwen-3.6-35b-a3b-fp8"

  test "designator before version":
    check normalizeModelName("poolside/laguna-s-2.1") == "laguna-s-2.1"

  test "single-digit version omits dash":
    check normalizeModelName("tencent/hy3-preview") == "hy3-preview"

  test "unknown family lowercased unchanged":
    check normalizeModelName("SomeVendor/Weird-Model-9") == "somevendor/weird-model-9"

  test "version-only after family":
    check normalizeModelName("glm-5") == "glm5"

  test "version with letter tail keeps dash":
    check normalizeModelName("qwen3.8-2.4t-a95b") == "qwen-3.8-2.4t-a95b"

  test "grok build version":
    check normalizeModelName("grok-build-0.1") == "grok-build-0.1"

  test "gpt-oss family wins over gpt":
    check normalizeModelName("openai/gpt-oss-120b") == "gpt-oss-120b"

  test "o-series maps to gpt":
    check normalizeModelName("o3-mini") == "gpt-o3-mini"

  test "kimi k3":
    check normalizeModelName("moonshotai/Kimi-K3") == "kimi3"

  test "kimi-for-coding alias":
    check normalizeModelName("kimi-for-coding") == "kimi-2.7-code"

  test "kimi-for-coding-highspeed alias":
    check normalizeModelName("kimi-for-coding-highspeed") == "kimi-2.7-code-highspeed"

  test "minimax highspeed qualifier":
    check normalizeModelName("MiniMax-M2.7-highspeed") == "minimax-2.7-highspeed"

  test "longcat":
    check normalizeModelName("meituan/LongCat-2.0") == "longcat-2.0"

  test "ling":
    check normalizeModelName("inclusionAI/Ling-3.0-flash") == "ling-3.0-flash"

  test "mimo":
    check normalizeModelName("XiaomiMiMo/MiMo-V2.5-Pro") == "mimo-2.5-pro"

  test "0xalpha aliases":
    check normalizeModelName("stealth/ox-alpha") == "0xalpha1"
    check normalizeModelName("ox-alpha-free") == "0xalpha1-free"
    check normalizeModelName("x-preview-f-free") == "0xalpha1-f-free"

  test "qwen plus/max/flash variants":
    check normalizeModelName("qwen-3-6-plus") == "qwen-3.6-plus"
    check normalizeModelName("qwen3.7-max") == "qwen-3.7-max"
    check normalizeModelName("qwen-3.7-flash") == "qwen-3.7-flash"

  test "deepseek chat and reasoner specials":
    check normalizeModelName("deepseek-chat") == "deepseek-chat"
    check normalizeModelName("deepseek-reasoner") == "deepseek-reasoner"

  test "deepseek dated qualifier":
    check normalizeModelName("deepseek-ai/DeepSeek-V4-Pro-0813") == "deepseek4-pro-0813"

  test "grok multi-agent":
    check normalizeModelName("x-ai/grok-4.20-multi-agent") == "grok-4.20-multi-agent"

  test "gpt-4o":
    check normalizeModelName("gpt-4o-mini") == "gpt-4o-mini"

  test "gpt-5.6 codenames":
    check normalizeModelName("gpt-5.6-sol") == "gpt-5.6-sol"
    check normalizeModelName("gpt-5.6-luna") == "gpt-5.6-luna"

  test "glm turbo":
    check normalizeModelName("zai-glm-5-turbo") == "glm5-turbo"

  test "nvfp4 qualifier":
    check normalizeModelName("GLM-5.2-NVFP4") == "glm-5.2-nvfp4"

  test "free suffix":
    check normalizeModelName("z-ai/glm-5.2:free") == "glm-5.2:free"

suite "modelname: format":

  test "round trip":
    check format(ModelName(family: "glm", version: "5.3",
                           designator: "flash")) == "glm-5.3-flash"

  test "single digit version":
    check format(ModelName(family: "hy", version: "3")) == "hy3"

  test "suffix":
    check format(ModelName(family: "inkling", version: "1",
                           suffix: "free")) == "inkling1:free"

  test "qualifiers":
    check format(ModelName(family: "qwen", version: "3.8",
                           qualifiers: @["a3b"])) == "qwen-3.8-a3b"
