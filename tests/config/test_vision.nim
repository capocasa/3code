## Vision capability flag: [params] vision parsing, resolution,
## persistence, and the known-good curated flag.
import std/[options, os, strutils, unittest]
import threecode/[config, prompts, types]

suite "vision: [params] parsing":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-vision.ini"
    activeParams = @[]

  teardown:
    removeFile(tmp)
    activeParams = @[]

  test "parses the on/off dialect":
    writeFile(tmp, """
[params]
provider = "zai"
model = "glm-5.2"
vision = "on"
""")
    discard parseConfigFile(tmp)
    check activeParams.len == 1
    check activeParams[0].params.vision == some(true)

  test "writeConfigFile round-trips vision":
    var e = ParamsRec(provider: "zai", model: "glm-5.2")
    e.params.vision = some(true)
    activeParams = @[e]
    writeConfigFile(tmp, "zai.glm-5.2", @[])
    check readFile(tmp).contains("vision = \"true\"")
    activeParams = @[]
    discard parseConfigFile(tmp)
    check activeParams[0].params.vision == some(true)

  test "validateConfig rejects a bad boolean":
    writeFile(tmp, "[params]\nprovider = \"zai\"\nvision = \"maybe\"\n")
    check "bad value 'maybe'" in validateConfig(tmp,
      @[("params", "vision", "maybe", 3)])

suite "vision: known-good curation":
  test "every combo row carries the vision field":
    # Arity is compile-checked; what matters is that the seeded rows are
    # exactly the probed-live ones, not a broad family sweep.
    var visionRows = 0
    for combo in KnownGoodCombos:
      if combo.vision: inc visionRows
    check visionRows == 7

  test "glm-5.3-flash is vision on the first-party gateways":
    check knownGoodVision("zai", "glm-5.3-flash")
    check knownGoodVision("zaicode", "glm-5.3-flash")

  test "third-party hostings wait for a probe":
    check not knownGoodVision("openrouter", "z-ai/glm-5.3-flash")
    check not knownGoodVision("novita", "zai-org/glm-5.3-flash")

  test "the deepseek vision-exp hostings are curated":
    check knownGoodVision("deepseek", "deepseek-flash")
    check knownGoodVision("openrouter", "deepseek/deepseek-v4-flash-vision-exp")
    check knownGoodVision("novita", "deepseek/deepseek-v4-flash-vision-exp")
    check knownGoodVision("nanogpt", "deepseek/deepseek-v4-flash-vision-exp")
    check knownGoodVision("opencodego", "deepseek-v4-flash-vision-exp")

  test "text-only combos are not vision":
    check not knownGoodVision("zai", "glm-5.3")
    check not knownGoodVision("zai", "glm-5.2")
    check not knownGoodVision("deepseek", "deepseek-v4-flash")
    check not knownGoodVision("made-up", "whatever")

suite "vision: visionCapable":
  test "explicit params beat the curated flag, both ways":
    var p = Profile(name: "zai.glm-5.3-flash", model: "glm-5.3-flash")
    check visionCapable(p)  # curated
    p.params.vision = some(false)
    check not visionCapable(p)  # revoked explicitly
    var t = Profile(name: "zai.glm-5.2", model: "glm-5.2")
    check not visionCapable(t)  # not curated
    t.params.vision = some(true)
    check visionCapable(t)  # opted in (third-party hosting of vision weights)

  test "empty profile is not vision-capable":
    check not visionCapable(Profile())

suite "vision: system prompt":
  test "vision profiles learn they can inspect images":
    var p = Profile(name: "zai.glm-5.3-flash", model: "glm-5.3-flash",
                    family: "glm")
    p.vision = true
    let vp = buildSystemPrompt(p)
    check "You can see images. `read` on an image file" in vp
    check "# Images" in vp
    p.vision = false
    let tp = buildSystemPrompt(p)
    check "# Images" notin tp
    check "You can see images" notin tp

  test "prompt identity includes the vision flag":
    var p = Profile(name: "zai.glm-5.3-flash", model: "glm-5.3-flash")
    let base = profileIdentity(p)
    p.vision = true
    check profileIdentity(p) != base
