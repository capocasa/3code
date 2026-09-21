import std/[tables, unittest]
import threecode/[config, types]

suite "config: shortModel":
  test "strips everything before last slash":
    check shortModel("openai/gpt-oss-120b") == "gpt-oss-120b"

  test "returns full string when no slash":
    check shortModel("gpt-oss-120b") == "gpt-oss-120b"

  test "handles nested paths":
    check shortModel("accounts/fireworks/models/glm-5p1") == "glm-5.1"

  test "canonicalizes the slash-stripped name":
    check shortModel("openai/GPT-OSS-120B") == "gpt-oss-120b"

  test "mistral's dash-flattened author strips too":
    check shortModel("zai-glm-5-3") == "glm-5.3"
    check shortModel("zai-glm-5-2") == "glm-5.2"
    check shortModel("z-ai-glm-5-3-flash") == "glm-5.3-flash"
    check shortModel("mistral-ai-mistral-large-2512") == "mistral-large-2512"

  test "ids no family parses keep the slash-stripped spelling":
    check shortModel("mistralai/codestral-2501") == "codestral-2501"
    check shortModel("SomeVendor/Weird-Model-9") == "weird-model-9"

suite "config: dedupModels":
  test "twin spellings of one model collapse, first wins":
    check dedupModels(@["glm-5-2", "zai-glm-5-2"]) == @["glm-5-2"]
    check dedupModels(@["zai-glm-5-2", "glm-5-2"]) == @["zai-glm-5-2"]

  test "exact duplicates collapse":
    check dedupModels(@["glm-5.3", "glm-5.3", "kimi-k3"]) ==
      @["glm-5.3", "kimi-k3"]

  test "distinct models are untouched":
    check dedupModels(@["glm-5.3", "glm-5.3-flash", "glm-5.3:free"]) ==
      @["glm-5.3", "glm-5.3-flash", "glm-5.3:free"]

suite "config: shortToFull":
  test "maps short to full":
    let t = shortToFull(@["openai/gpt-oss-120b", "meta/llama-4"])
    check t["gpt-oss-120b"] == "openai/gpt-oss-120b"
    check t["llama-4"] == "meta/llama-4"

  test "first occurrence wins on collision":
    let t = shortToFull(@["org/model", "model"])
    check t["model"] == "org/model"

  test "twin spellings collapse to one entry":
    let t = shortToFull(@["glm-5-2", "zai-glm-5-2"])
    check t.len == 1
    check t["glm-5.2"] == "glm-5-2"

  test "empty input returns empty table":
    let t = shortToFull(@[])
    check t.len == 0

suite "config: findModel":
  test "finds by full name":
    let p = ProviderRec(name: "test", models: @["org/model-a", "org/model-b"])
    check p.findModel("org/model-a") == 0

  test "finds by short name":
    let p = ProviderRec(name: "test", models: @["org/model-a", "org/model-b"])
    check p.findModel("model-b") == 1

  test "returns -1 when not found":
    let p = ProviderRec(name: "test", models: @["org/model-a"])
    check p.findModel("nonexistent") == -1

suite "config: inferProvider":
  test "recognizes sk-ant- as anthropic":
    check inferProvider("sk-ant-api03-xxx") == "anthropic"

  test "recognizes sk-or- as openrouter":
    check inferProvider("sk-or-v1-xxx") == "openrouter"

  test "recognizes nvapi- as nvidia":
    check inferProvider("nvapi-xxx") == "nvidia"

  test "returns empty for unknown prefix":
    check inferProvider("my-custom-key") == ""

  test "recognizes the z.ai hex.hex key shape":
    check inferProvider(
      "0123456789abcdef0123456789abcdef.fedcba9876543210") == "zaicode"

  test "rejects near-miss z.ai shapes":
    # Halves too short, non-hex characters, multiple dots.
    check inferProvider("abcdefg.fedcba") == ""
    check inferProvider("zzzzzzzzzzzzzzzz.yyyyyyyyyyyyyyyy") == ""
    check inferProvider(
      "0123456789abcdef.0123456789abcdef.fedcba9876543210") == ""

suite "config: curatedFor":
  test "returns models for known provider":
    let models = curatedFor("zai")
    check models.len > 0

  test "returns empty for unknown provider":
    check curatedFor("nonexistent").len == 0

suite "config: resolveFamily":
  test "known-good combo returns its family":
    let prov = ProviderRec(name: "zai", models: @["glm-5.1"])
    let prof = Profile(name: "zai.glm-5.1", model: "glm-5.1")
    check resolveFamily(prov, prof) == "glm"

  test "unknown model defaults to glm":
    let prov = ProviderRec(name: "test", models: @["unknown-model"])
    let prof = Profile(name: "test.unknown-model", model: "unknown-model")
    check resolveFamily(prov, prof) == "glm"

suite "config: resolveReasoning":
  test "provider config reasoning wins":
    let prov = ProviderRec(reasoning: "high")
    let prof = Profile(name: "test.model", model: "model")
    check resolveReasoning(prov, prof) == "high"

  test "falls back to known-good default":
    let prov = ProviderRec(name: "zai")
    let prof = Profile(name: "zai.glm-5.1", model: "glm-5.1")
    check resolveReasoning(prov, prof) == "on"

  test "returns empty when nothing set":
    let prov = ProviderRec()
    let prof = Profile(name: "unknown.model", model: "model")
    check resolveReasoning(prov, prof) == ""

  test "experimental skips known-good default":
    let prov = ProviderRec(name: "zai")
    let prof = Profile(name: "zai.glm-5.1", model: "glm-5.1")
    experimentalEnabled = true
    check resolveReasoning(prov, prof) == ""
    experimentalEnabled = false

  test "experimental still honors provider config":
    let prov = ProviderRec(name: "zai", reasoning: "high")
    let prof = Profile(name: "zai.glm-5.1", model: "glm-5.1")
    experimentalEnabled = true
    check resolveReasoning(prov, prof) == "high"
    experimentalEnabled = false

  test "experimental: availableReasonings is empty (free-form)":
    let prov = ProviderRec(name: "zai")
    experimentalEnabled = true
    var empty: seq[string]
    check availableReasonings(prov, "glm", "glm-5.1") == empty
    experimentalEnabled = false

suite "config: buildProfile":
  test "builds profile for valid provider and model":
    let prov = ProviderRec(name: "test", url: "https://api.test.com",
                           key: "sk-test", models: @["model-a"])
    let prof = buildProfile("test", @[prov], "test.model-a")
    check prof.name == "test.model-a"
    check prof.model == "model-a"
    check prof.url == "https://api.test.com"

  test "returns empty profile for unknown provider":
    let prof = buildProfile("", @[], "nonexistent.model")
    check prof.name == ""

  test "explicit current is honored even when not known-good":
    # [settings] current is the user's word: a curated combo elsewhere in
    # the config must not silently replace it (stefani 20260921: current
    # deepseek.deepseek-v4-flash was swapped for novita.tencent/hy3 at
    # every startup because the catalog had dropped the deepseek combo).
    let zai = ProviderRec(name: "zai", url: "https://api.z.ai",
                          key: "sk-test", models: @["glm-5.1"])
    let mine = ProviderRec(name: "mine", url: "https://api.mine/v1",
                           key: "sk-test", models: @["weird-model"])
    experimentalEnabled = false
    let prof = buildProfile("mine.weird-model", @[zai, mine], "")
    check prof.name == "mine.weird-model"
    check prof.url == "https://api.mine/v1"

  test "picks first model when no model specified":
    let prov = ProviderRec(name: "test", url: "https://api.test.com",
                           key: "sk-test", models: @["model-a", "model-b"])
    let prof = buildProfile("test", @[prov], "test")
    check prof.model == "model-a"

suite "config: gateExperimental":
  test "allows known-good profile":
    let p = Profile(name: "zai.glm-5.1", family: "glm", model: "glm-5.1")
    check gateExperimental(p) == true

  test "blocks unknown profile when not experimental":
    let p = Profile(name: "unknown.model", model: "model")
    check gateExperimental(p) == false

  test "allows empty profile":
    check gateExperimental(Profile()) == true

suite "config: orderedModels":
  test "wizard-entered order is preserved":
    let prov = ProviderRec(name: "zai", models: @["unknown", "glm-5.1"])
    check orderedModels(prov) == @["unknown", "glm-5.1"]
  test "firstModel is the first entered model":
    let prov = ProviderRec(name: "zai", models: @["unknown", "glm-5.1"])
    check firstModel(prov) == "unknown"
  test "firstModel on empty provider":
    check firstModel(ProviderRec(name: "zai")) == ""
