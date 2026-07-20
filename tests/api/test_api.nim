discard """
  # Windows: autosend probe tests spawn a child nim compiler + threads;
  # flaky on Windows runners. See docs/windows-testing.md.
  disabled: "win"
"""
import std/[json, os, osproc, strutils, unittest]
import threecode/[api, prompts, types]
import stub_helpers

suite "api request shaping":
  test "z.ai glm sets tool_stream (streamhttp TLS truncation fixed)":
    # tool_stream makes GLM stream tool-call arguments as per-token deltas.
    # It was disabled as a workaround for a streamhttp TLS truncation bug
    # that truncated the deltas mid-stream. That bug is fixed (streamhttp
    # >= 0.2.0 drains OpenSSL's internal buffer before polling), so
    # tool_stream is re-enabled for the first-party z.ai API. Streamed tool
    # args now arrive complete.
    var body = %*{"stream": true}
    let p = Profile(name: "zai.glm-5.1", family: "glm", model: "glm-5.1")

    applyStreamingOptions(p, body)

    check body{"tool_stream"}.getBool == true

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

  test "hy on novita sends chat_template_kwargs.reasoning_effort":
    var body = %*{"stream": true}
    let p = Profile(name: "novita.tencent/hy3", family: "hy",
                    model: "tencent/hy3", reasoning: "high")
    applyReasoning(p, body)
    check body{"chat_template_kwargs"}{"reasoning_effort"}.getStr == "high"

  test "hy on openrouter normalizes to reasoning.effort":
    var body = %*{"stream": true}
    let p = Profile(name: "openrouter.tencent/hy3:free", family: "hy",
                    model: "tencent/hy3:free", reasoning: "low")
    applyReasoning(p, body)
    check body{"reasoning"}{"effort"}.getStr == "low"

  test "together glm-5.2 sends reasoning_effort for high/max":
    block high:
      var body = %*{"stream": true}
      let p = Profile(name: "together.zai-org/GLM-5.2", family: "glm",
                      version: "5", variant: "2",
                      model: "zai-org/GLM-5.2", reasoning: "high")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "high"
      check "reasoning" notin body
    block maxn:
      var body = %*{"stream": true}
      let p = Profile(name: "together.zai-org/GLM-5.2", family: "glm",
                      version: "5", variant: "2",
                      model: "zai-org/GLM-5.2", reasoning: "max")
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == "max"
    block offn:
      var body = %*{"stream": true}
      let p = Profile(name: "together.zai-org/GLM-5.2", family: "glm",
                      version: "5", variant: "2",
                      model: "zai-org/GLM-5.2", reasoning: "off")
      applyReasoning(p, body)
      check body{"reasoning"}{"enabled"}.getBool == false
      check "reasoning_effort" notin body

  test "openrouter glm-5.2 sends reasoning.effort, max->xhigh":
    block high:
      var body = %*{"stream": true}
      let p = Profile(name: "openrouter.z-ai/glm-5.2", family: "glm",
                      version: "5", variant: "2",
                      model: "z-ai/glm-5.2", reasoning: "high")
      applyReasoning(p, body)
      check body{"reasoning"}{"effort"}.getStr == "high"
    block maxn:
      var body = %*{"stream": true}
      let p = Profile(name: "openrouter.z-ai/glm-5.2", family: "glm",
                      version: "5", variant: "2",
                      model: "z-ai/glm-5.2", reasoning: "max")
      applyReasoning(p, body)
      check body{"reasoning"}{"effort"}.getStr == "xhigh"
    block offn:
      var body = %*{"stream": true}
      let p = Profile(name: "openrouter.z-ai/glm-5.2", family: "glm",
                      version: "5", variant: "2",
                      model: "z-ai/glm-5.2", reasoning: "off")
      applyReasoning(p, body)
      check body{"reasoning"}{"enabled"}.getBool == false

  test "together non-5.2 glm sends no effort knob":
    var body = %*{"stream": true}
    let p = Profile(name: "together.zai-org/GLM-5.1", family: "glm",
                    version: "5", variant: "1",
                    model: "zai-org/GLM-5.1", reasoning: "high")
    applyReasoning(p, body)
    check "reasoning_effort" notin body
    check "reasoning" notin body

  test "knownGoodReasonings offers high/max for third-party 5.2":
    check knownGoodReasonings("together", "zai-org/GLM-5.2") == @["off", "high", "max"]
    check knownGoodReasonings("openrouter", "z-ai/glm-5.2") == @["off", "high", "max"]
    check knownGoodReasonings("nebius", "zai-org/GLM-5.2") == @["off", "high", "max"]
    check knownGoodReasonings("zai", "glm-5.2") == @["off", "high", "max"]
    check knownGoodReasonings("together", "zai-org/GLM-5.1") == @["off", "on"]
    check knownGoodReasonings("together", "zai-org/GLM-5") == @["off", "on"]

  test "hy with empty reasoning sends no wire knob":
    var body = %*{"stream": true}
    let p = Profile(name: "novita.tencent/hy3", family: "hy",
                    model: "tencent/hy3", reasoning: "")
    applyReasoning(p, body)
    check "chat_template_kwargs" notin body
    check "reasoning" notin body

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
    pushInputEvent(InputEvent(kind: ieLine, text: "queued", echoRows: 1))

var t: Thread[void]
createThread(t, queueAutosend)
discard runTurns(profile, messages, session)
joinThread(t)

let queued = hasQueuedAutosend()
doAssert queued
doAssert messages.len == 4
doAssert messages[2]{"role"}.getStr == "assistant"
doAssert messages[3]{"role"}.getStr == "tool"
doAssert "SHOULD_NOT_BE_CALLED" notin $messages
""")
    let compileCmd = "nim c -d:ssl -d:providerStub --threads:on --path:src " & nimbleDepFlags() & " --nimcache:" &
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

  test "provider stub runs pending tools when autosend is queued during API call":
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
      "arguments": "{\"command\":\"echo SHOULD_RUN\"}"
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
    pushInputEvent(InputEvent(kind: ieLine, text: "queued", echoRows: 1))

var t: Thread[void]
createThread(t, queueAutosend)
discard runTurns(profile, messages, session)
joinThread(t)

let queued = hasQueuedAutosend()
doAssert queued
doAssert messages.len == 4
doAssert messages[2]{"role"}.getStr == "assistant"
doAssert messages[3]{"role"}.getStr == "tool"
doAssert "SHOULD_RUN" in messages[3]{"content"}.getStr
doAssert "skipped" notin messages[3]{"content"}.getStr
doAssert "SHOULD_NOT_BE_CALLED" notin $messages
""")
    let compileCmd = "nim c -d:ssl -d:providerStub --threads:on --path:src " & nimbleDepFlags() & " --nimcache:" &
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

  test "provider stub finishes current tool batch before buffered prompt":
    let pid = $getCurrentProcessId()
    let probeDir = getTempDir() / ("tc_autosend_batch_probe_" & pid)
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
      "arguments": "{\"command\":\"sleep 0.3; echo first-tool\"}"
    }
  },{
    "id": "call_2",
    "type": "function",
    "function": {
      "name": "bash",
      "arguments": "{\"command\":\"echo second-tool\"}"
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
    pushInputEvent(InputEvent(kind: ieLine, text: "queued", echoRows: 1))

var t: Thread[void]
createThread(t, queueAutosend)
discard runTurns(profile, messages, session)
joinThread(t)

let queued = hasQueuedAutosend()
doAssert queued
doAssert messages.len == 5
doAssert messages[2]{"role"}.getStr == "assistant"
doAssert messages[3]{"role"}.getStr == "tool"
doAssert messages[4]{"role"}.getStr == "tool"
doAssert "first-tool" in messages[3]{"content"}.getStr
doAssert "second-tool" in messages[4]{"content"}.getStr
doAssert "skipped" notin messages[4]{"content"}.getStr
doAssert "SHOULD_NOT_BE_CALLED" notin $messages
""")
    let compileCmd = "nim c -d:ssl -d:providerStub --threads:on --path:src " & nimbleDepFlags() & " --nimcache:" &
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
    let compileCmd = "nim c -d:ssl -d:providerStub --path:src " & nimbleDepFlags() & " --nimcache:" &
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

suite "runTurns empty-content auto-handling":

  test "runTurns escalates max_tokens then recovers on empty length reply":
    # The headline bug: GLM/Qwen/gpt-oss return 200 OK with content empty and
    # finish_reason "length" (reasoning ate the whole budget). runTurns must
    # NOT dead-end here: it escalates max_tokens and retries within the same
    # turn, recovering when the second response carries real content. This is
    # a turns-layer concern (the transport retry block stays untouched).
    let pid = $getCurrentProcessId()
    let probeDir = getTempDir() / ("tc_empty_esc_" & pid)
    let probePath = probeDir / "probe.nim"
    let outPath = probeDir / "probe"
    let cacheDir = probeDir / "nimcache"
    createDir(probeDir)
    createDir(cacheDir)
    defer:
      try: removeDir(probeDir) except OSError: discard
    # First response: empty content, finish_reason length (budget starved).
    # Second response: real content, proving the turn recovered.
    writeFile(probeDir / "stub_responses.json", """[{
  "role": "assistant",
  "content": "",
  "stream": false,
  "finish_reason": "length"
},{
  "role": "assistant",
  "content": "RECOVERED_AFTER_ESCALATION",
  "stream": false
}]""")
    writeFile(probePath, """
import std/[json, strutils]
import threecode
import threecode/api except callModel

var messages = %*[
  {"role": "system", "content": "sys"},
  {"role": "user", "content": "go"}
]
var session: Session
session.savePath = ""
session.readCache = newReadCache()
# Known-good combo so knownGoodGeneration returns a real budget (8192) for
# the escalation math; runTurnsInteractive's gateExperimental requires it.
let profile = Profile(name: "nebius.glm-5.1", url: "stub://", key: "k",
  family: "glm", model: "zai-org/GLM-5.1")

discard runTurnsInteractive(profile, messages, session)

# The empty turn is NOT added to history on a length-escalation retry (it
# would pollute context); only the recovered content lands. The escalation
# must have bumped max_tokens above the known-good 8192.
let lastAssistant = messages[^1]
doAssert lastAssistant{"role"}.getStr == "assistant",
  "last msg role: " & lastAssistant{"role"}.getStr
doAssert lastAssistant{"content"}.getStr == "RECOVERED_AFTER_ESCALATION",
  "content: " & lastAssistant{"content"}.getStr
doAssert lastStubMaxTokensOverride() > 8192,
  "override was " & $lastStubMaxTokensOverride() & " (no escalation happened)"
echo "OK"
""")
    let compileCmd = "nim c -d:ssl -d:providerStub --threads:on --path:src " &
      nimbleDepFlags() & " --nimcache:" & cacheDir.quoteShell &
      " -o:" & outPath.quoteShell & " " & probePath.quoteShell
    let (compileOut, compileCode) = execCmdEx(compileCmd)
    check compileCode == 0
    if compileCode != 0:
      checkpoint compileOut
    let (runOut, runCode) = execCmdEx(outPath.quoteShell, workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut
    # The hint line must use the new phrasing and the placeholder must be
    # filled with the actual budget, not the literal template text.
    check "finished by length, retrying with" in runOut
    check "{humanTokens(maxTokensOverride)}" notin runOut
    # The bumped budget for 8192 is min(16384, 200000) = 16384 = "16.4k"
    check "16.4k" in runOut

  test "runTurns retries then recovers on a bare empty reply (no finish_reason)":
    # A 200 OK that comes back with no content, no tool calls, and no
    # finish_reason is not budget-starved and not steerable. runTurns must
    # still not dead-end: it resends the bare call, printing the reason and
    # a retry counter, and recovers when a later response carries content.
    let pid = $getCurrentProcessId()
    let probeDir = getTempDir() / ("tc_empty_resend_" & pid)
    let probePath = probeDir / "probe.nim"
    let outPath = probeDir / "probe"
    let cacheDir = probeDir / "nimcache"
    createDir(probeDir)
    createDir(cacheDir)
    defer:
      try: removeDir(probeDir) except OSError: discard
    # Response 1: bare empty (no finish_reason) -> steering retry.
    # Response 2: bare empty -> empty-resend 1.
    # Response 3: real content, proving recovery.
    writeFile(probeDir / "stub_responses.json", """[{
  "role": "assistant",
  "content": "",
  "stream": false
},{
  "role": "assistant",
  "content": "",
  "stream": false
},{
  "role": "assistant",
  "content": "RECOVERED_AFTER_RESEND",
  "stream": false
}]""")
    writeFile(probePath, """
import std/[json, strutils]
import threecode
import threecode/api except callModel

var messages = %*[
  {"role": "system", "content": "sys"},
  {"role": "user", "content": "go"}
]
var session: Session
session.savePath = ""
session.readCache = newReadCache()
let profile = Profile(name: "nebius.glm-5.1", url: "stub://", key: "k",
  family: "glm", model: "zai-org/GLM-5.1")

discard runTurnsInteractive(profile, messages, session)

let lastAssistant = messages[^1]
doAssert lastAssistant{"role"}.getStr == "assistant",
  "last msg role: " & lastAssistant{"role"}.getStr
doAssert lastAssistant{"content"}.getStr == "RECOVERED_AFTER_RESEND",
  "content: " & lastAssistant{"content"}.getStr
echo "OK"
""")
    let compileCmd = "nim c -d:ssl -d:providerStub --threads:on --path:src " &
      nimbleDepFlags() & " --nimcache:" & cacheDir.quoteShell &
      " -o:" & outPath.quoteShell & " " & probePath.quoteShell
    let (compileOut, compileCode) = execCmdEx(compileCmd)
    check compileCode == 0
    if compileCode != 0:
      checkpoint compileOut
    let (runOut, runCode) = execCmdEx(outPath.quoteShell, workingDir = probeDir)
    check runCode == 0
    if runCode != 0:
      checkpoint runOut
    # The bare-resend notice must carry the reason and the retry counter,
    # matching the requested format: "empty reply: <reason>. retrying N/12".
    check "empty reply: no content, no tool calls. retrying 1/12" in runOut
    # The old dead-end string must NOT appear when recovery succeeds.
    check "empty reply - no content, no tool calls" notin runOut
