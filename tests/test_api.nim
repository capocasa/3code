import std/[json, strutils, unittest]
import threecode/[api, prompts, types]

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

  test "nvidia glm sends chat_template_kwargs.enable_thinking":
    var body = %*{"stream": true}
    let p = Profile(name: "nvidia.z-ai/glm4.7", family: "glm",
                    model: "z-ai/glm4.7", reasoning: "low")
    applyReasoning(p, body)
    check body{"chat_template_kwargs"}{"enable_thinking"}.getBool == false

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

  test "fallback flag is per-known-good entry":
    check xmlToolCallsFallback(Profile(name: "nvidia.z-ai/glm4.7",
      model: "z-ai/glm4.7", family: "glm")) == true
    check xmlToolCallsFallback(Profile(name: "zai.glm-5.1",
      model: "glm-5.1", family: "glm")) == false
    check xmlToolCallsFallback(Profile(name: "nvidia.openai/gpt-oss-120b",
      model: "openai/gpt-oss-120b", family: "gpt-oss")) == false
