import std/[os, strutils, unittest]
import threecode/[config, web]

suite "config: parseConfigFile round-trip":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-roundtrip.ini"

  teardown:
    removeFile(tmp)

  test "write then read preserves providers":
    let providers = @[
      ProviderRec(name: "test", url: "https://api.test.com",
                  key: "sk-test", models: @["model-a", "model-b"]),
      ProviderRec(name: "other", url: "https://api.other.com",
                  key: "sk-other", models: @["model-x"])
    ]
    writeConfigFile(tmp, "test.model-a", providers)
    let (current, _, readProvs) = parseConfigFile(tmp)
    check current == "test.model-a"
    check readProvs.len == 2
    check readProvs[0].name == "test"
    check readProvs[0].models == @["model-a", "model-b"]
    check readProvs[1].name == "other"
    check readProvs[1].models == @["model-x"]

  test "write then read preserves reasoning":
    let providers = @[
      ProviderRec(name: "test", url: "https://api.test.com",
                  key: "sk-test", models: @["model-a"],
                  reasoning: "high",
                  reasonings: @["low", "medium", "high"])
    ]
    writeConfigFile(tmp, "test.model-a", providers)
    let (_, _, readProvs) = parseConfigFile(tmp)
    check readProvs[0].reasoning == "high"
    check readProvs[0].reasonings == @["low", "medium", "high"]

  test "write then read preserves family":
    let providers = @[
      ProviderRec(name: "custom", url: "https://api.custom.com",
                  key: "sk-custom", models: @["model-c"],
                  family: "glm")
    ]
    writeConfigFile(tmp, "custom.model-c", providers)
    let (_, _, readProvs) = parseConfigFile(tmp)
    check readProvs[0].family == "glm"

suite "config: parseConfigFile model prefix expansion":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-prefix.ini"

  teardown:
    removeFile(tmp)

  test "old-style model_prefix is expanded into model ids":
    writeFile(tmp, """
[settings]
current = "test.gpt-oss-120b"

[provider]
name = "test"
url = "https://api.test.com"
key = "sk-test"
model_prefix = "openai/"
models = "gpt-oss-120b llama-4"
""")
    let (_, _, provs) = parseConfigFile(tmp)
    check provs.len == 1
    check provs[0].models == @["openai/gpt-oss-120b", "openai/llama-4"]
    check provs[0].modelPrefix == ""  # expanded away

suite "config: parseConfigFile env expansion":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-env.ini"

  teardown:
    removeFile(tmp)

  test "expands $VAR in key field":
    putEnv("THREECODE_TEST_KEY", "sk-from-env-123")
    writeFile(tmp, """
[provider]
name = "test"
url = "https://api.test.com"
key = "$THREECODE_TEST_KEY"
models = "model-a"
""")
    let (_, _, provs) = parseConfigFile(tmp)
    check provs[0].key == "sk-from-env-123"
    delEnv("THREECODE_TEST_KEY")

suite "config: splitModels / formatModels":
  test "splitModels handles comma-separated":
    check splitModels("a, b, c") == @["a", "b", "c"]

  test "splitModels handles whitespace-separated":
    check splitModels("alpha beta gamma") == @["alpha", "beta", "gamma"]

  test "splitModels handles mixed separators":
    check splitModels("a, b c") == @["a", "b", "c"]

  test "formatModels joins with space":
    check formatModels(@["a", "b", "c"]) == "a b c"

suite "config: firstKnownGoodCombo":
  test "finds first known-good combo":
    let providers = @[
      ProviderRec(name: "test", url: "", key: "", models: @["model-a"]),
      ProviderRec(name: "zai", url: "https://api.test.com",
                  key: "sk-test", models: @["glm-5.1"])
    ]
    let combo = firstKnownGoodCombo(providers)
    check combo.len > 0
    check combo.contains("zai")

  test "returns empty when no providers have known-good models":
    let providers = @[
      ProviderRec(name: "unknown", url: "https://api.test.com",
                  key: "sk-test", models: @["model-x"])
    ]
    check firstKnownGoodCombo(providers) == ""

suite "config: currentProvider":
  test "returns matching provider":
    activeCurrent = "test.model-a"
    activeProviders = @[
      ProviderRec(name: "test", models: @["model-a"]),
      ProviderRec(name: "other", models: @["model-x"])
    ]
    let p = currentProvider()
    check p.name == "test"
    # reset globals
    activeCurrent = ""
    activeProviders = @[]

  test "returns empty when no match":
    activeCurrent = "nonexistent.model"
    activeProviders = @[
      ProviderRec(name: "test", models: @["model-a"])
    ]
    let p = currentProvider()
    check p.name == ""
    # reset globals
    activeCurrent = ""
    activeProviders = @[]
