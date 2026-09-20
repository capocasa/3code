import std/[os, sequtils, strutils, tables, unittest]
import threecode/[config, prompts, types]

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
    let (current, readProvs, _, _, _, _) = parseConfigFile(tmp)
    check current == "test.model-a"
    check readProvs.len == 2
    check readProvs[0].name == "test"
    check readProvs[0].models == @["model-a", "model-b"]
    check readProvs[1].name == "other"
    check readProvs[1].models == @["model-x"]

  test "[search] exa-key round-trips through writeConfigFile":
    activeSearchKeys = initTable[string, string]()
    activeSearchKeys["exa"] = "exa-roundtrip"
    writeConfigFile(tmp, "test.model-a", @[])
    activeSearchKeys = initTable[string, string]()
    let raw = readFile(tmp)
    check raw.find("[search]") >= 0
    check raw.find("exa-key = \"exa-roundtrip\"") >= 0
    let (_, _, _, searchKeys, _, _) = parseConfigFile(tmp)
    check searchKeys["exa"] == "exa-roundtrip"

  test "[search] brave-key round-trips alongside exa-key":
    activeSearchKeys = initTable[string, string]()
    activeSearchKeys["exa"] = "e"
    activeSearchKeys["brave"] = "b"
    writeConfigFile(tmp, "test.model-a", @[])
    activeSearchKeys = initTable[string, string]()
    let raw = readFile(tmp)
    check raw.find("exa-key = \"e\"") >= 0
    check raw.find("brave-key = \"b\"") >= 0

  test "[search] engine round-trips through writeConfigFile":
    activeSearchKeys = initTable[string, string]()
    activeSearchEngine = "parallel"
    writeConfigFile(tmp, "test.model-a", @[])
    activeSearchEngine = "exa"
    let raw = readFile(tmp)
    check raw.find("[search]") >= 0
    check raw.find("engine = \"parallel\"") >= 0
    let (_, _, _, _, searchEngine, _) = parseConfigFile(tmp)
    check searchEngine == "parallel"

  test "writeConfigFile omits [search] when no keys and engine exa":
    activeSearchKeys = initTable[string, string]()
    activeSearchEngine = "exa"
    writeConfigFile(tmp, "test.model-a", @[])
    let raw = readFile(tmp)
    check raw.find("[search]") < 0

  test "patient_retry off persists and round-trips":
    patientRetryEnabled = false
    writeConfigFile(tmp, "test.model-a", @[])
    let raw = readFile(tmp)
    check raw.find("patient_retry = \"off\"") >= 0
    discard parseConfigFile(tmp)
    check patientRetryEnabled == false
    # default-on state is omitted from the config (clean config invariant)
    patientRetryEnabled = true
    writeConfigFile(tmp, "test.model-a", @[])
    check readFile(tmp).find("patient_retry") < 0

  test "write then read preserves reasoning":
    let providers = @[
      ProviderRec(name: "test", url: "https://api.test.com",
                  key: "sk-test", models: @["model-a"],
                  reasoning: "high",
                  reasonings: @["low", "medium", "high"])
    ]
    writeConfigFile(tmp, "test.model-a", providers)
    let (_, readProvs, _, _, _, _) = parseConfigFile(tmp)
    check readProvs[0].reasoning == "high"
    check readProvs[0].reasonings == @["low", "medium", "high"]

  test "write then read preserves family":
    let providers = @[
      ProviderRec(name: "custom", url: "https://api.custom.com",
                  key: "sk-custom", models: @["model-c"],
                  family: "glm")
    ]
    writeConfigFile(tmp, "custom.model-c", providers)
    let (_, readProvs, _, _, _, _) = parseConfigFile(tmp)
    check readProvs[0].family == "glm"

  test "write then read preserves auth=oauth":
    let providers = @[
      ProviderRec(name: "supergrok", url: "https://api.x.ai/v1",
                  key: "", auth: "oauth", models: @["grok-4.5"])
    ]
    writeConfigFile(tmp, "supergrok.grok-4.5", providers)
    let raw = readFile(tmp)
    check raw.find("auth = \"oauth\"") >= 0
    let (_, readProvs, _, _, _, _) = parseConfigFile(tmp)
    check readProvs[0].name == "supergrok"
    check readProvs[0].auth == "oauth"
    check readProvs[0].key == ""

  test "empty-key subscription twin without auth line re-marks as oauth":
    # Configs written by a binary that dropped `auth = "oauth"` leave the
    # subscription twins looking like empty-key API-key providers, which
    # buildProfile rejects as incomplete. The parser re-marks them.
    writeFile(tmp, """
[settings]
current = "supergrok.grok-4.5"

[provider]
name = "supergrok"
url = "https://api.x.ai/v1"
key = ""
models = "grok-4.5"

[provider]
name = "chatgpt"
url = "https://api.openai.com/v1"
key = ""
models = "gpt-5.6-luna"
""")
    let (_, readProvs, _, _, _, _) = parseConfigFile(tmp)
    check readProvs.len == 2
    check readProvs[0].auth == "oauth"
    check readProvs[1].auth == "oauth"

  test "empty key does not re-mark ordinary providers":
    writeFile(tmp, """
[provider]
name = "xai"
url = "https://api.x.ai/v1"
key = ""
models = "grok-4.5"
""")
    let (_, readProvs, _, _, _, _) = parseConfigFile(tmp)
    check readProvs[0].auth == ""

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
    let (_, provs, _, _, _, _) = parseConfigFile(tmp)
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
    let (_, provs, _, _, _, _) = parseConfigFile(tmp)
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

suite "config: known-good lookup with normalized pretty names":
  test "isKnownGood accepts the normalized form of a prefixed wire id":
    let p = Profile(name: "nebius.glm-5.1", model: "glm-5.1")
    check isKnownGood(p)

  test "knownGoodFamily matches on normalized name":
    check knownGoodFamily("nebius", "glm-5.1") == "glm"
    check knownGoodFamily("together", "kimi-k2.6") == "kimi"

  test "knownGoodFamily still matches the raw wire id":
    check knownGoodFamily("nebius", "zai-org/GLM-5.1") == "glm"

  test "unknown models stay experimental":
    check knownGoodFamily("zai", "glm-9.9-nope") == ""
    check not isKnownGood(Profile(name: "zai.glm-9.9-nope", model: "glm-9.9-nope"))

  test "tags, reasoning, generation and window follow the normalized name":
    check knownGoodTags("zai", "glm-5.3") == ("glm", "5", "3")
    check knownGoodReasoning("zai", "glm-5.3") == "high"
    let g = knownGoodGeneration("zai", "glm-5.3")
    check (g.temperature, g.maxTokens) == (0.2, 65536)
    check knownGoodContextWindow("zai", "glm-5.3") == 1_000_000

  test "knownGoodWireModel repairs listed-but-unserved variants":
    check knownGoodWireModel("kimicode", "kimi-k3-256k") == "k3"
    check knownGoodWireModel("kimicode", "kimi-k3") == "k3"
    check knownGoodWireModel("kimicode", "k3") == "k3"
    check knownGoodWireModel("kimi", "kimi-k3-256k") == "kimi-k3"
    check knownGoodWireModel("openrouter", "qwen-3.8-27b") == "qwen/qwen3.8-27b"
    # Distinct models and unknown ids are not rewritten. kimi-k2.6 is a
    # listed kimicode combo (litellm direct-gateway row), so it resolves to
    # itself, not ""; only off-table ids stay empty.
    check knownGoodWireModel("kimicode", "kimi-k2.6") == "kimi-k2.6"
    check knownGoodWireModel("kimicode", "kimi-k2.5") == ""
    check knownGoodWireModel("kimicode", "weird-model") == ""
    # A designator sibling is not a qualifier tail of the base combo.
    check knownGoodWireModel("zai", "glm-5.3-flash") == "glm-5.3-flash"
    check knownGoodWireModel("zai", "glm-5.3") == "glm-5.3"
    check knownGoodWireModel("openrouter", "z-ai/glm-5.3-flash") == "z-ai/glm-5.3-flash"
    # platte namespacing: the bare id is what configs persist, the wire
    # id is prefixed (the bare id 404s on their endpoint).
    check knownGoodWireModel("platte", "glm-5.3") == "z-ai/glm-5.3"
    check knownGoodWireModel("platte", "z-ai/glm-5.3") == "z-ai/glm-5.3"
    check knownGoodFamily("platte", "glm-5.3") == "glm"
    check knownGoodWireModel("novita", "glm-5.3-flash") == "zai-org/glm-5.3-flash"
    check knownGoodWireModel("venice", "glm-5.3-flash") == "z-ai-glm-5-3-flash"

  test "orderedModels keeps entered order regardless of known-good rank":
    let prov = ProviderRec(name: "zai", url: "https://api.z.ai",
                           key: "k", models: @["weird-model", "glm-5.3"])
    check orderedModels(prov) == @["weird-model", "glm-5.3"]

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
  var savedCurrent: string
  var savedProviders: seq[ProviderRec]

  setup:
    savedCurrent = activeCurrent
    savedProviders = activeProviders

  teardown:
    activeCurrent = savedCurrent
    activeProviders = savedProviders

  test "returns matching provider":
    activeCurrent = "test.model-a"
    activeProviders = @[
      ProviderRec(name: "test", models: @["model-a"]),
      ProviderRec(name: "other", models: @["model-x"])
    ]
    let p = currentProvider()
    check p.name == "test"

  test "returns empty when no match":
    activeCurrent = "nonexistent.model"
    activeProviders = @[
      ProviderRec(name: "test", models: @["model-a"])
    ]
    let p = currentProvider()
    check p.name == ""

suite "config: [shortcuts] round-trip":
  var tmp = ""
  var savedShortcuts: Table[string, string]

  setup:
    tmp = getTempDir() / "3code-test-shortcuts.ini"
    savedShortcuts = activeShortcuts

  teardown:
    removeFile(tmp)
    activeShortcuts = savedShortcuts

  test "write then read preserves [shortcuts]":
    activeShortcuts = initTable[string, string]()
    activeShortcuts["cancel"] = "CtrlC"
    activeShortcuts["clear"] = "ESC"
    activeShortcuts["quit-if-empty"] = "CtrlD"
    writeConfigFile(tmp, "test.model-a", @[])
    activeShortcuts = initTable[string, string]()
    let raw = readFile(tmp)
    check raw.find("[shortcuts]") >= 0
    check raw.find("cancel = \"CtrlC\"") >= 0
    check raw.find("clear = \"ESC\"") >= 0
    check raw.find("quit-if-empty = \"CtrlD\"") >= 0
    let (_, _, _, _, _, shortcuts) = parseConfigFile(tmp)
    check shortcuts["cancel"] == "CtrlC"
    check shortcuts["clear"] == "ESC"
    check shortcuts["quit-if-empty"] == "CtrlD"

  test "writeConfigFile omits [shortcuts] when activeShortcuts empty":
    activeShortcuts = initTable[string, string]()
    writeConfigFile(tmp, "test.model-a", @[])
    let raw = readFile(tmp)
    check raw.find("[shortcuts]") < 0

suite "config: applyEarlySandboxSettings":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-earlysandbox.ini"
    sandboxEnabled = true
    sandboxWallWarn = true

  teardown:
    removeFile(tmp)
    sandboxEnabled = true
    sandboxWallWarn = true

  test "applies the two switches like the full parse":
    type Case = tuple[text: string; wantEnabled, wantWarn: bool]
    let cases: seq[Case] = @[
      (text: "[settings]\nsandbox = \"off\"\nsandbox_wall_warn = \"off\"\n",
       wantEnabled: false, wantWarn: false),
      (text: "[settings]\nsandbox = \"on\"\nsandbox_wall_warn = \"on\"\n",
       wantEnabled: true, wantWarn: true),
      (text: "[settings]\nsandbox = \"true\"\nsandbox_wall_warn = \"0\"\n",
       wantEnabled: true, wantWarn: false),
      (text: "[settings]\ncurrent = \"x\"\n",
       wantEnabled: true, wantWarn: true)]
    for c in cases:
      writeFile(tmp, c.text)
      sandboxEnabled = true
      sandboxWallWarn = true
      applyEarlySandboxSettings(tmp)
      check sandboxEnabled == c.wantEnabled
      check sandboxWallWarn == c.wantWarn
      # the full parse must land on the same values the early pass did
      sandboxEnabled = true
      sandboxWallWarn = true
      discard parseConfigFile(tmp)
      check sandboxEnabled == c.wantEnabled
      check sandboxWallWarn == c.wantWarn

  test "missing or malformed file leaves defaults, no raise":
    applyEarlySandboxSettings(tmp)  # does not exist
    check sandboxEnabled
    check sandboxWallWarn
    writeFile(tmp, "[settings\nsandbox = \"off\"\n")  # broken section line
    applyEarlySandboxSettings(tmp)
    check sandboxEnabled
    check sandboxWallWarn

suite "config: concurrent instances don't clobber each other":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-concurrent.ini"
    removeFile(tmp)

  teardown:
    removeFile(tmp)

  proc loadLikeStartup(path: string): (string, seq[ProviderRec]) =
    # Model an instance's startup: parse the file AND record the baseline
    # loadStateOrEmpty would have captured.
    let (cur, provs, _, _, _, _) = parseConfigFile(path)
    baselineCurrent = cur
    baselineProviders = provs
    (cur, provs)

  test "a stale instance's write keeps another instance's provider edit":
    # Two instances load the same config; instance A edits a provider's
    # models; instance B (still holding its startup snapshot) then writes
    # for an unrelated reason. B's write must not revert A's edit.
    let providers = @[
      ProviderRec(name: "alpha", url: "https://a.test", key: "sk-a",
                  models: @["model-a"]),
      ProviderRec(name: "beta", url: "https://b.test", key: "sk-b",
                  models: @["model-b"])
    ]
    writeConfigFile(tmp, "alpha.model-a", providers)
    # Both instances load the file at startup.
    let (aCurrent, aProviders) = loadLikeStartup(tmp)
    let (bCurrent, bProviders) = loadLikeStartup(tmp)
    check aCurrent == "alpha.model-a"
    check bProviders.len == 2
    # Instance A edits alpha's models (in-memory then persist).
    var aEdited = aProviders
    aEdited[0].models = @["model-a", "model-a2"]
    writeConfigFile(tmp, aCurrent, aEdited)
    # Instance B switches its current (unrelated write, stale snapshot).
    writeConfigFile(tmp, "beta.model-b", bProviders)
    # The merged file must keep A's edit AND B's current switch.
    let (current, merged, _, _, _, _) = parseConfigFile(tmp)
    check current == "beta.model-b"
    check merged.len == 2
    check merged[0].name == "alpha"
    check merged[0].models == @["model-a", "model-a2"]
    check merged[1].name == "beta"

  test "a stale instance's write keeps another instance's provider add":
    writeConfigFile(tmp, "alpha.model-a", @[
      ProviderRec(name: "alpha", url: "https://a.test", key: "sk-a",
                  models: @["model-a"])])
    let (_, bProviders) = loadLikeStartup(tmp)
    # Instance A adds a brand-new provider.
    writeConfigFile(tmp, "alpha.model-a", @[
      ProviderRec(name: "alpha", url: "https://a.test", key: "sk-a",
                  models: @["model-a"]),
      ProviderRec(name: "gamma", url: "https://g.test", key: "sk-g",
                  models: @["model-g"])])
    # Instance B writes its stale one-provider snapshot.
    writeConfigFile(tmp, "alpha.model-a", bProviders)
    let (_, merged, _, _, _, _) = parseConfigFile(tmp)
    check merged.len == 2
    check merged.mapIt(it.name) == @["alpha", "gamma"]

  test "a stale instance's write keeps another instance's provider rm":
    writeConfigFile(tmp, "alpha.model-a", @[
      ProviderRec(name: "alpha", url: "https://a.test", key: "sk-a",
                  models: @["model-a"]),
      ProviderRec(name: "gamma", url: "https://g.test", key: "sk-g",
                  models: @["model-g"])])
    let (_, bProviders) = loadLikeStartup(tmp)
    # Instance A removes gamma.
    writeConfigFile(tmp, "alpha.model-a", @[
      ProviderRec(name: "alpha", url: "https://a.test", key: "sk-a",
                  models: @["model-a"])])
    # Instance B writes its stale two-provider snapshot.
    writeConfigFile(tmp, "alpha.model-a", bProviders)
    let (_, merged, _, _, _, _) = parseConfigFile(tmp)
    check merged.mapIt(it.name) == @["alpha"]

  test "an edit made after this instance's own startup still wins":
    # The merge must not resurrect disk state this instance itself
    # deliberately changed after loading: baseline-diff means only
    # providers that differ from BOTH baseline and disk are foreign.
    writeConfigFile(tmp, "alpha.model-a", @[
      ProviderRec(name: "alpha", url: "https://a.test", key: "sk-a",
                  models: @["model-a"])])
    let (baseCurrent, baseProviders) = loadLikeStartup(tmp)
    # This instance edits alpha in memory (differs from baseline).
    var edited = baseProviders
    edited[0].models = @["model-a", "model-a2"]
    writeConfigFile(tmp, baseCurrent, edited)
    # A second write of the same in-memory state must be stable.
    writeConfigFile(tmp, baseCurrent, edited)
    let (_, merged, _, _, _, _) = parseConfigFile(tmp)
    check merged[0].models == @["model-a", "model-a2"]

  test "a stale instance's write keeps another instance's current switch":
    # Instance A switches to beta and persists; instance B (started
    # earlier, never switched in-session) then writes for an unrelated
    # reason. B still holds its startup current, so the different disk
    # value is A's switch and must survive B's write.
    let providers = @[
      ProviderRec(name: "alpha", url: "https://a.test", key: "sk-a",
                  models: @["model-a"]),
      ProviderRec(name: "beta", url: "https://b.test", key: "sk-b",
                  models: @["model-b"])
    ]
    writeConfigFile(tmp, "alpha.model-a", providers)
    let (bCurrent, bProviders) = loadLikeStartup(tmp)
    check bCurrent == "alpha.model-a"
    writeConfigFile(tmp, "beta.model-b", providers)  # instance A switches
    writeConfigFile(tmp, bCurrent, bProviders)        # instance B writes stale
    let (current, merged, _, _, _, _) = parseConfigFile(tmp)
    check current == "beta.model-b"
    check merged.len == 2

  test "this instance's own current switch wins over the disk value":
    # Both the disk and this instance moved current after startup; the
    # in-session switch (differs from baseline) is this instance's own
    # edit, so it wins instead of being reverted to the disk value.
    let providers = @[
      ProviderRec(name: "alpha", url: "https://a.test", key: "sk-a",
                  models: @["model-a", "model-a2"]),
      ProviderRec(name: "beta", url: "https://b.test", key: "sk-b",
                  models: @["model-b"])
    ]
    writeConfigFile(tmp, "alpha.model-a", providers)
    let (bCurrent, bProviders) = loadLikeStartup(tmp)
    writeConfigFile(tmp, "beta.model-b", providers)  # another instance
    writeConfigFile(tmp, "alpha.model-a2", bProviders)  # own switch
    let (current, _, _, _, _, _) = parseConfigFile(tmp)
    check current == "alpha.model-a2"

  test "a write is skipped when the disk config is unreadable":
    # A config that went bad on disk (hand edit, truncation) must be left
    # alone: overwriting it with the in-memory list would destroy whatever
    # the user still has there. The write is dropped, file bytes unchanged.
    let providers = @[
      ProviderRec(name: "alpha", url: "https://a.test", key: "sk-a",
                  models: @["model-a"])
    ]
    writeConfigFile(tmp, "alpha.model-a", providers)
    let (bCurrent, bProviders) = loadLikeStartup(tmp)
    writeFile(tmp, "[settings]\nnope = \"x\"\n")
    let before = readFile(tmp)
    writeConfigFile(tmp, bCurrent, bProviders)
    check readFile(tmp) == before

  test "a fresh config with no disk file still writes":
    # The skip only applies to a file that exists but cannot be parsed;
    # the first-ever write (no file) must keep working.
    let providers = @[
      ProviderRec(name: "alpha", url: "https://a.test", key: "sk-a",
                  models: @["model-a"])
    ]
    writeConfigFile(tmp, "alpha.model-a", providers)
    check fileExists(tmp)
    let (current, merged, _, _, _, _) = parseConfigFile(tmp)
    check current == "alpha.model-a"
    check merged.len == 1
