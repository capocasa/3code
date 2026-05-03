import std/[json, unittest]
import threecode/[api, types]

suite "api request shaping":
  test "z.ai glm enables streamed tool deltas":
    var body = %*{"stream": true}
    let p = Profile(name: "zai.glm-5.1", family: "glm", model: "glm-5.1")

    applyStreamingOptions(p, body)

    check body{"tool_stream"}.getBool(false)

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
