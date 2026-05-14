import std/[json, os, osproc, strutils, unittest]
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

  test "provider stub build exercises streaming path":
    let pid = $getCurrentProcessId()
    let outPath = getTempDir() / ("3code_stub_api_" & pid)
    let cacheDir = getTempDir() / ("3code_stub_api_cache_" & pid)
    createDir(cacheDir)
    defer:
      try: removeFile(outPath) except OSError: discard
      try: removeDir(cacheDir) except OSError: discard

    let compileCmd = "nim c -d:providerStub --nimcache:" &
      cacheDir.quoteShell & " -o:" & outPath.quoteShell & " src/threecode.nim"
    let (compileOut, compileCode) = execCmdEx(compileCmd)
    check compileCode == 0
    if compileCode != 0:
      checkpoint compileOut
    check fileExists(outPath)

  test "provider stub returns before next API call when autosend is queued during tool":
    let pid = $getCurrentProcessId()
    let probeDir = getTempDir() / ("tc_autosend_probe_" & pid)
    let probePath = probeDir / "probe.nim"
    let outPath = probeDir / "probe"
    let cacheDir = probeDir / "nimcache"
    createDir(probeDir)
    createDir(cacheDir)
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
      "arguments": "{\"command\":\"sleep 0.3; echo tooldone\"}"
    }
  }]
},{
  "role": "assistant",
  "content": "SHOULD_NOT_BE_CALLED"
}]""")
    writeFile(probePath, """
import std/[json, locks, os, strutils]
import threecode

var messages = %*[
  {"role": "system", "content": "sys"},
  {"role": "user", "content": "first"}
]
var session: Session
session.savePath = ""
session.readCache = newReadCache()
let profile = Profile(name: "stub", family: "glm", model: "stub-model")

proc queueAutosend() {.thread, gcsafe.} =
  sleep 100
  {.cast(gcsafe).}:
    acquire inputStateLock
    try:
      inputState.queuedText = "next prompt"
      inputState.queuedEchoRows = 1
      inputState.autoSend = true
    finally:
      release inputStateLock

var t: Thread[void]
createThread(t, queueAutosend)
runTurns(profile, messages, session)
joinThread(t)

acquire inputStateLock
let queued = inputState.autoSend
release inputStateLock
doAssert queued
doAssert messages.len == 4
doAssert messages[2]{"role"}.getStr == "assistant"
doAssert messages[3]{"role"}.getStr == "tool"
doAssert "SHOULD_NOT_BE_CALLED" notin $messages
""")
    let compileCmd = "nim c -d:ssl -d:providerStub --threads:on --path:src --nimcache:" &
      cacheDir.quoteShell & " -o:" & outPath.quoteShell & " " &
      probePath.quoteShell
    let (compileOut, compileCode) = execCmdEx(compileCmd)
    check compileCode == 0
    if compileCode != 0:
      checkpoint compileOut
    let (runOut, runCode) = execCmdEx(outPath.quoteShell, workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut

  test "provider stub skips pending tools when autosend is queued during API call":
    let pid = $getCurrentProcessId()
    let probeDir = getTempDir() / ("tc_autosend_api_probe_" & pid)
    let probePath = probeDir / "probe.nim"
    let outPath = probeDir / "probe"
    let cacheDir = probeDir / "nimcache"
    createDir(probeDir)
    createDir(cacheDir)
    defer:
      try: removeDir(probeDir) except OSError: discard

    writeFile(probeDir / "stub_responses.json", """[{
  "role": "assistant",
  "content": null,
  "preStreamDelayMs": 300,
  "tool_calls": [{
    "id": "call_1",
    "type": "function",
    "function": {
      "name": "bash",
      "arguments": "{\"command\":\"echo SHOULD_NOT_RUN\"}"
    }
  }]
},{
  "role": "assistant",
  "content": "SHOULD_NOT_BE_CALLED"
}]""")
    writeFile(probePath, """
import std/[json, locks, os, strutils]
import threecode

var messages = %*[
  {"role": "system", "content": "sys"},
  {"role": "user", "content": "first"}
]
var session: Session
session.savePath = ""
session.readCache = newReadCache()
let profile = Profile(name: "stub", family: "glm", model: "stub-model")

proc queueAutosend() {.thread, gcsafe.} =
  sleep 100
  {.cast(gcsafe).}:
    acquire inputStateLock
    try:
      inputState.queuedText = "cut me a release"
      inputState.queuedEchoRows = 1
      inputState.autoSend = true
    finally:
      release inputStateLock

var t: Thread[void]
createThread(t, queueAutosend)
runTurns(profile, messages, session)
joinThread(t)

acquire inputStateLock
let queued = inputState.autoSend
release inputStateLock
doAssert queued
doAssert messages.len == 4
doAssert messages[2]{"role"}.getStr == "assistant"
doAssert messages[3]{"role"}.getStr == "tool"
doAssert "skipped" in messages[3]{"content"}.getStr
doAssert "SHOULD_NOT_RUN" notin messages[3]{"content"}.getStr
doAssert "SHOULD_NOT_BE_CALLED" notin $messages
""")
    let compileCmd = "nim c -d:ssl -d:providerStub --threads:on --path:src --nimcache:" &
      cacheDir.quoteShell & " -o:" & outPath.quoteShell & " " &
      probePath.quoteShell
    let (compileOut, compileCode) = execCmdEx(compileCmd)
    check compileCode == 0
    if compileCode != 0:
      checkpoint compileOut
    let (runOut, runCode) = execCmdEx(outPath.quoteShell, workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut

  test "provider stub covers common network failure aliases":
    let pid = $getCurrentProcessId()
    let probePath = getTempDir() / ("tc_stub_failures_" & pid & ".nim")
    let outPath = getTempDir() / ("tc_stub_failures_" & pid)
    let cacheDir = getTempDir() / ("tc_stub_failures_cache_" & pid)
    createDir(cacheDir)
    defer:
      try: removeFile(probePath) except OSError: discard
      try: removeFile(outPath) except OSError: discard
      try: removeDir(cacheDir) except OSError: discard
    writeFile(probePath, """
import threecode/api

doAssert parseStubFailure("dns") == sfDns
doAssert parseStubFailure("network-unreachable") == sfNetworkUnreachable
doAssert parseStubFailure("connection-refused") == sfConnectionRefused
doAssert parseStubFailure("connect-timeout") == sfConnectTimeout
doAssert parseStubFailure("certificate") == sfCertificate
doAssert parseStubFailure("broken-pipe") == sfBrokenPipe
doAssert parseStubFailure("connection-reset") == sfConnectionReset
doAssert parseStubFailure("eof") == sfEof
doAssert parseStubFailure("read-timeout") == sfReadTimeout
doAssert parseStubFailure("silent-then-ok") == sfSilentThenOk
doAssert parseStubFailure("malformed-sse") == sfMalformedSse
doAssert parseStubFailure("invalid-json") == sfInvalidJson
doAssert stubHttpStatus(parseStubFailure("400")) == 400
doAssert stubHttpStatus(parseStubFailure("401")) == 401
doAssert stubHttpStatus(parseStubFailure("403")) == 403
doAssert stubHttpStatus(parseStubFailure("408")) == 408
doAssert stubHttpStatus(parseStubFailure("409")) == 409
doAssert stubHttpStatus(parseStubFailure("425")) == 425
doAssert stubHttpStatus(parseStubFailure("429")) == 429
doAssert stubHttpStatus(parseStubFailure("500")) == 500
doAssert stubHttpStatus(parseStubFailure("502")) == 502
doAssert stubHttpStatus(parseStubFailure("503")) == 503
doAssert stubHttpStatus(parseStubFailure("504")) == 504
""")
    let compileCmd = "nim c -d:ssl -d:providerStub --path:src --nimcache:" &
      cacheDir.quoteShell & " -o:" & outPath.quoteShell & " " &
      probePath.quoteShell
    let (compileOut, compileCode) = execCmdEx(compileCmd)
    check compileCode == 0
    if compileCode != 0:
      checkpoint compileOut

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
