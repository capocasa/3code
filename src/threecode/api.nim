## HTTP client and SSE parsing.
##
## `callModel` is the single outbound call: it sends the messages array as an
## OpenAI-compatible chat completions request, reads the Server-Sent Events
## stream chunk by chunk, and returns a completed assistant `JsonNode` plus
## a `Usage` record.
##
## XML tool call recovery handles a gpt-oss quirk: some nvidia-hosted variants
## leak the model's native `<tool_call>` chat template into `delta.content`
## instead of the OpenAI `tool_calls` field. When `xmlToolCalls` is set for a
## combo, `callModel` promotes those tags to synthetic tool_calls so the rest
## of the pipeline sees a uniform shape.

import std/[algorithm, atomics, hashes, httpclient, json, nativesockets, net, os, sequtils, strformat, strutils, tables, times, uri]
when defined(posix):
  import std/posix except SocketHandle
import streamhttp
import types, util, prompts, compact, streamexec

type
  VerifyProfileHook* = proc(p: Profile): (bool, string) {.closure.}
  FetchModelsHook* = proc(url, key: string): (seq[string], string) {.closure.}

var
  verifyProfileHook*: VerifyProfileHook
  fetchModelsHook*: FetchModelsHook

const providerStub {.booldefine.} = false
when providerStub:
  var stubResponseIdx = 0

  proc emitTestFrameEvent() =
    when defined(posix):
      let fdText = getEnv("THREECODE_TEST_FRAME_FD")
      if fdText.len > 0:
        try:
          let fd = cint(parseInt(fdText))
          var ch = 'f'
          discard posix.write(fd, addr ch, 1)
          let ackText = getEnv("THREECODE_TEST_FRAME_ACK_FD")
          if ackText.len > 0:
            let ackFd = cint(parseInt(ackText))
            var ack: array[1, char]
            discard posix.read(ackFd, addr ack[0], 1)
        except CatchableError:
          discard

  proc testFrameMode(): bool =
    getEnv("THREECODE_TEST_FRAME_FD").len > 0

  proc waitForTestContinue() =
    when defined(posix):
      let fdText = getEnv("THREECODE_TEST_API_CONTINUE_FD")
      if fdText.len == 0:
        return
      try:
        let fd = cint(parseInt(fdText))
        var ch: array[1, char]
        discard posix.read(fd, addr ch[0], 1)
      except CatchableError:
        discard

  type StubFailure* = enum
    sfNone, sfDns, sfNetworkUnreachable, sfConnectionRefused,
    sfConnectTimeout, sfTls, sfCertificate, sfBrokenPipe,
    sfConnectionReset, sfEof, sfReadTimeout, sfSilentThenOk,
    sfMalformedSse, sfInvalidJson, sfHttp400, sfHttp401, sfHttp403,
    sfHttp408, sfHttp409, sfHttp425, sfHttp429, sfHttp500, sfHttp502,
    sfHttp503, sfHttp504

  proc parseStubFailure*(s: string): StubFailure =
    case s.strip.toLowerAscii.replace("_", "-")
    of "", "none": sfNone
    of "dns", "name-resolution", "resolve": sfDns
    of "network-unreachable", "net-unreachable", "unreachable", "enetunreach":
      sfNetworkUnreachable
    of "connection-refused", "refused", "econnrefused": sfConnectionRefused
    of "connect-timeout", "timeout-connect", "etimedout": sfConnectTimeout
    of "tls", "ssl": sfTls
    of "certificate", "cert", "cert-expired", "cert-verify": sfCertificate
    of "broken-pipe", "epipe": sfBrokenPipe
    of "connection-reset", "reset", "econnreset": sfConnectionReset
    of "eof", "closed": sfEof
    of "read-timeout", "timeout-read", "stall": sfReadTimeout
    of "silent-then-ok", "flaky-silent": sfSilentThenOk
    of "malformed-sse", "bad-sse": sfMalformedSse
    of "invalid-json", "bad-json": sfInvalidJson
    of "400", "http-400", "bad-request": sfHttp400
    of "401", "http-401", "unauthorized", "auth": sfHttp401
    of "403", "http-403", "forbidden": sfHttp403
    of "408", "http-408", "request-timeout": sfHttp408
    of "409", "http-409", "conflict": sfHttp409
    of "425", "http-425", "too-early": sfHttp425
    of "429", "http-429", "rate": sfHttp429
    of "500", "http-500": sfHttp500
    of "502", "http-502": sfHttp502
    of "503", "http-503": sfHttp503
    of "504", "http-504": sfHttp504
    else: sfNone

  proc stubFailureName*(f: StubFailure): string =
    case f
    of sfNone: "none"
    of sfConnectTimeout: "connect timeout"
    of sfDns: "dns failure"
    of sfNetworkUnreachable: "network unreachable"
    of sfConnectionRefused: "connection refused"
    of sfTls: "tls failure"
    of sfCertificate: "certificate failure"
    of sfBrokenPipe: "broken pipe"
    of sfConnectionReset: "connection reset"
    of sfEof: "unexpected eof"
    of sfReadTimeout: "read timeout"
    of sfSilentThenOk: "silent connection"
    of sfMalformedSse: "malformed sse"
    of sfInvalidJson: "invalid json"
    of sfHttp400: "api 400"
    of sfHttp401: "api 401"
    of sfHttp403: "api 403"
    of sfHttp408: "api 408"
    of sfHttp409: "api 409"
    of sfHttp425: "api 425"
    of sfHttp429: "api 429"
    of sfHttp500: "api 500"
    of sfHttp502: "api 502"
    of sfHttp503: "api 503"
    of sfHttp504: "api 504"

  proc stubHttpStatus*(f: StubFailure): int =
    case f
    of sfHttp400: 400
    of sfHttp401: 401
    of sfHttp403: 403
    of sfHttp408: 408
    of sfHttp409: 409
    of sfHttp425: 425
    of sfHttp429: 429
    of sfHttp500: 500
    of sfHttp502: 502
    of sfHttp503: 503
    of sfHttp504: 504
    else: 0

  proc stubTransportError*(f: StubFailure): string =
    case f
    of sfDns: "TLS connect failed: name or service not known"
    of sfNetworkUnreachable: "TLS connect failed: network is unreachable"
    of sfConnectionRefused: "TLS connect failed: connection refused"
    of sfConnectTimeout: "TLS connect failed: operation timed out"
    of sfTls: "TLS connect failed: handshake failed"
    of sfCertificate: "TLS connect failed: certificate verify failed"
    of sfBrokenPipe: "request failed: broken pipe"
    of sfConnectionReset: "stream read: connection reset by peer"
    of sfEof: "stream read: EOF before end of response"
    of sfReadTimeout: "stream read: operation timed out"
    of sfMalformedSse: "stream read: malformed chunked transfer encoding"
    of sfInvalidJson: "stream read: invalid JSON in SSE data"
    else: ""

  proc stubDelayMs(j: JsonNode, key: string, fallback = 0): int =
    if j != nil and j.kind == JObject:
      result = j{key}.getInt(fallback)
    else:
      result = fallback

  proc stubRetryAfter(j: JsonNode): string =
    if j != nil and j.kind == JObject:
      result = j{"retryAfter"}.getStr("")

  proc stubErrBody(f: StubFailure, j: JsonNode): string =
    if j != nil and j.kind == JObject and "body" in j:
      return j{"body"}.getStr
    case f
    of sfHttp400: """{"error":"bad request"}"""
    of sfHttp401: """{"error":"unauthorized"}"""
    of sfHttp403: """{"error":"forbidden"}"""
    of sfHttp408: """{"error":"request timeout"}"""
    of sfHttp409: """{"error":"conflict"}"""
    of sfHttp425: """{"error":"too early"}"""
    of sfHttp429: """{"error":"rate limit"}"""
    of sfHttp500: """{"error":"server error"}"""
    of sfHttp502: """{"error":"bad gateway"}"""
    of sfHttp503: """{"error":"service unavailable"}"""
    of sfHttp504: """{"error":"gateway timeout"}"""
    else: ""

  proc loadStubResponses(): seq[JsonNode] =
    ## Read stub_responses.json: a JSON array of assistant-message objects.
    ## Each element is an OpenAI-shape assistant message (role, content,
    ## tool_calls), or `{failure: "...", delayMs: N}` to exercise retry /
    ## flaky-network paths. Re-read on every call so edits take effect
    ## mid-session.
    const path = "stub_responses.json"
    if not fileExists(path):
      stderr.writeLine "3code: stub: " & path & " not found"
      quit 1
    let raw = readFile(path)
    try: parseJson(raw).getElems
    except CatchableError:
      stderr.writeLine "3code: stub: malformed JSON in " & path
      quit 1

  proc stubCallModel(messages: JsonNode): JsonNode =
    let responses = loadStubResponses()
    if stubResponseIdx >= responses.len:
      stderr.writeLine "3code: stub: response index " & $stubResponseIdx &
        " out of range (" & $responses.len & " responses)"
      quit 1
    result = responses[stubResponseIdx]
    inc stubResponseIdx

  proc stubUsage(node: JsonNode, content: string): Usage =
    let u = if node != nil and node.kind == JObject: node{"usage"} else: nil
    if u != nil and u.kind == JObject:
      result.promptTokens =
        u{"promptTokens"}.getInt(u{"prompt_tokens"}.getInt(0))
      result.completionTokens =
        u{"completionTokens"}.getInt(u{"completion_tokens"}.getInt(0))
      result.totalTokens =
        u{"totalTokens"}.getInt(u{"total_tokens"}.getInt(0))
      result.cachedTokens =
        u{"cachedTokens"}.getInt(
          u{"cached_tokens"}.getInt(
            u{"prompt_cache_hit_tokens"}.getInt(0)))
      if result.totalTokens == 0:
        result.totalTokens = result.promptTokens + result.completionTokens
      return
    result.promptTokens = 100
    result.completionTokens = max(1, content.len div 4)
    result.totalTokens = result.promptTokens + result.completionTokens

  proc stubStringChunks(node: JsonNode; key, fallback: string): seq[string] =
    let chunks = node{key}
    if chunks != nil and chunks.kind == JArray:
      for chunk in chunks:
        result.add chunk.getStr("")
    if result.len == 0:
      for ch in fallback:
        result.add $ch

# ---------- Cancellation and stream hooks ----------

var interruptedFlag: Atomic[bool]
  ## Set by the SIGINT hook and buffered prompt key path. Checked between
  ## model/tool steps and during HTTP polling / retry backoff so ctrl-c drops
  ## back to the prompt without killing the process.

proc isInterrupted*(): bool {.gcsafe.} =
  interruptedFlag.load(moAcquire)

proc setInterrupted*(value: bool) {.gcsafe.} =
  interruptedFlag.store(value, moRelease)

proc clearInterrupted*() {.gcsafe.} =
  setInterrupted(false)

type
  ApiStreamHooks* = object
    beforeCall*: proc(lastPromptTokens, window: int): string {.closure.}
    afterCall*: proc() {.closure.}
    progress*: proc(baseLabel: string; slurped: int) {.closure.}
    setStatusLabel*: proc(label: string) {.closure.}
    startSpinner*: proc(label: string) {.closure.}
    stopSpinner*: proc() {.closure.}
    providerActivity*: proc() {.closure.}
    showThinking*: proc(): bool {.closure.}
    reasoningDelta*: proc(reasoning, baseLabel: string; slurped: int;
                          contentStarted: bool) {.closure.}
    contentDelta*: proc(chunk, baseLabel: string; slurped: int): bool {.closure.}
    contentFinished*: proc(fullContent, baseLabel: string;
                           slurped: int): bool {.closure.}
    trimTrailingContent*: proc(fullContent, baseLabel: string;
                               slurped: int) {.closure.}
    afterLiveContent*: proc(baseLabel: string; slurped: int) {.closure.}
    finalUsage*: proc(usage: Usage; window, elapsed: int;
                      assistantContent: string; streamedLive: bool) {.closure.}
    noUsage*: proc(elapsed: int) {.closure.}

var apiStreamHooks*: ApiStreamHooks

proc setApiStreamHooks*(hooks: ApiStreamHooks) =
  apiStreamHooks = hooks

proc hookBeforeCall(lastPromptTokens, window: int): string =
  if apiStreamHooks.beforeCall != nil:
    result = apiStreamHooks.beforeCall(lastPromptTokens, window)

proc hookAfterCall() =
  if apiStreamHooks.afterCall != nil: apiStreamHooks.afterCall()

proc hookProgress(baseLabel: string; slurped: int) =
  if apiStreamHooks.progress != nil:
    apiStreamHooks.progress(baseLabel, slurped)

proc hookSetStatusLabel(label: string) =
  if apiStreamHooks.setStatusLabel != nil:
    apiStreamHooks.setStatusLabel(label)

proc hookStartSpinner(label: string) =
  if apiStreamHooks.startSpinner != nil: apiStreamHooks.startSpinner(label)

proc hookStopSpinner() =
  if apiStreamHooks.stopSpinner != nil: apiStreamHooks.stopSpinner()

proc hookProviderActivity() =
  if apiStreamHooks.providerActivity != nil:
    apiStreamHooks.providerActivity()

proc hookShowThinking(): bool =
  apiStreamHooks.showThinking != nil and apiStreamHooks.showThinking()

proc hookReasoningDelta(reasoning, baseLabel: string; slurped: int;
                        contentStarted: bool) =
  if apiStreamHooks.reasoningDelta != nil:
    apiStreamHooks.reasoningDelta(reasoning, baseLabel, slurped,
                                  contentStarted)

proc hookContentDelta(chunk, baseLabel: string; slurped: int): bool =
  if apiStreamHooks.contentDelta != nil:
    result = apiStreamHooks.contentDelta(chunk, baseLabel, slurped)

proc hookContentFinished(fullContent, baseLabel: string; slurped: int): bool =
  if apiStreamHooks.contentFinished != nil:
    result = apiStreamHooks.contentFinished(fullContent, baseLabel, slurped)

proc hookTrimTrailingContent(fullContent, baseLabel: string; slurped: int) =
  if apiStreamHooks.trimTrailingContent != nil:
    apiStreamHooks.trimTrailingContent(fullContent, baseLabel, slurped)

proc hookAfterLiveContent(baseLabel: string; slurped: int) =
  if apiStreamHooks.afterLiveContent != nil:
    apiStreamHooks.afterLiveContent(baseLabel, slurped)

proc hookFinalUsage(usage: Usage; window, elapsed: int;
                    assistantContent: string; streamedLive: bool) =
  if apiStreamHooks.finalUsage != nil:
    apiStreamHooks.finalUsage(usage, window, elapsed, assistantContent,
                              streamedLive)

proc hookNoUsage(elapsed: int) =
  if apiStreamHooks.noUsage != nil: apiStreamHooks.noUsage(elapsed)


proc parseUsage*(u: JsonNode): Usage =
  ## Parses an OpenAI-compatible `usage` object. Cached-token accounting
  ## differs by provider: OpenAI/DeepInfra/Anthropic report it under
  ## `prompt_tokens_details.cached_tokens`; DeepSeek reports it flat as
  ## `prompt_cache_hit_tokens`. We accept either.
  if u == nil or u.kind != JObject: return
  result.promptTokens = u{"prompt_tokens"}.getInt(0)
  result.completionTokens = u{"completion_tokens"}.getInt(0)
  result.totalTokens = u{"total_tokens"}.getInt(0)
  let details = u{"prompt_tokens_details"}
  if details != nil and details.kind == JObject:
    result.cachedTokens = details{"cached_tokens"}.getInt(0)
  if result.cachedTokens == 0:
    result.cachedTokens = u{"prompt_cache_hit_tokens"}.getInt(0)

proc classifyRetry*(exc: ref CatchableError, code: int): string =
  ## Returns "server" for network errors and 5xx, "rate" for 429, "" for
  ## anything else (not retryable). Pure-logic helper for the callModel
  ## retry block.
  if exc != nil: return "server"
  case code
  of 429: "rate"
  of 500, 502, 503, 504: "server"
  else: ""

proc retryCategory*(errMsg: string, assistantMsg: JsonNode, statusCode: int): string =
  let netFailed = errMsg != "" and assistantMsg == nil
  if netFailed:
    return "server"
  case statusCode
  of 0:
    if assistantMsg == nil: "server" else: ""
  of 429: "rate"
  of 500, 502, 503, 504: "server"
  else: ""

var
  # Retry state split by category — different semantics, different ceilings.
  # A 5xx burst shouldn't inflate the backoff a later 429 sees, and vice versa.
  serverRetryLevel = 0    # network errors + 5xx (server hiccup; recovers fast)
  serverLastTs = 0.0
  rateRetryLevel = 0      # 429 specifically (rate limit / capacity crunch)
  rateLastTs = 0.0

proc decayLevel(level: var int, lastTs: var float, now: float) =
  if level > 0 and lastTs > 0.0:
    let idleMin = int((now - lastTs) / 60.0)
    if idleMin > 0:
      level = max(0, level - idleMin)
      lastTs = now

# ---- Streaming HTTP via streamhttp ----
#
# `streamhttp` is a tiny synchronous TLS HTTP/1.1 client we ship as a
# separate package — it reads chunked SSE bodies line by line on the
# main thread, blocking on `recv` between chunks. The threaded spinner
# paints in its own thread while we block on the socket here.
# Cancellation on Ctrl-C closes `conn` from the signal hook.
#
# Connection reuse: the StreamConn is cached at module scope keyed by
# host:port and reused across turns to the same provider — saving
# the TLS handshake (1-2 RTT + crypto) per turn. After a clean body
# end (chunked terminator), the conn stays alive for the next call.
# If the server has closed its end during the idle window, the next
# `sendRequest`/`readResponseHead` raises; we close the cached conn,
# reconnect once, and retry. Mid-body errors and Ctrl-C also drop the
# cache so the next turn starts on a fresh socket.
var cachedStreamConn: StreamConn
var cachedStreamHostKey: string
# Mirror of the cached conn's fd, kept current so the SIGINT hook and
# the stdin watcher thread can `posix.shutdown` it without touching
# the GC'd `StreamConn` ref. Set/cleared alongside `cachedStreamConn`.
var cachedStreamFd: SocketHandle = osInvalidSocket

proc closeCachedStreamConn() =
  if cachedStreamConn != nil:
    try: cachedStreamConn.close() except CatchableError: discard
    cachedStreamConn = nil
    cachedStreamHostKey = ""
  cachedStreamFd = osInvalidSocket

proc shutdownCachedStreamFd() {.gcsafe.} =
  ## Async-signal-safe: only the `shutdown` syscall, no allocation, no
  ## Nim GC traffic. Forces a blocking `recv` on `cachedStreamConn` to
  ## return so the streamHttp loop observes the interrupt flag and bails.
  ## Safe to call from a SIGINT hook or from the stdin watcher thread.
  when defined(posix):
    let fd = cachedStreamFd
    if fd != osInvalidSocket:
      discard posix.shutdown(posix.SocketHandle(fd), SHUT_RDWR.cint)

proc requestTurnInterrupt*() {.gcsafe.} =
  ## One cancellation path for signal hooks, buffered prompt keys, and
  ## stream/tool stdin watchers. Setting the flag alone is not enough:
  ## blocking HTTP reads must be woken and active tool subprocesses must
  ## be signalled, otherwise Ctrl-C appears to do nothing until the
  ## provider or command produces output.
  setInterrupted(true)
  shutdownCachedStreamFd()
  cancelActiveTool()

type StreamOutcome = object
  statusCode: int
  retryAfter: string
  errMsg: string          # non-empty on transport-level failure
  errBody: string         # non-SSE response body (error responses)
  assistantMsg: JsonNode  # reconstructed from SSE when status=200
  usage: Usage
  streamedLive: bool

proc buildStreamAssistantMsg*(content, reasoning: string,
                              tools: OrderedTable[int, JsonNode],
                              usage: Usage,
                              wasInterrupted = false): JsonNode =
  ## Build the assistant message reconstructed from an SSE stream.
  ## Returns nil when the stream produced no assistant data.
  if content.len == 0 and tools.len == 0 and reasoning.len == 0 and
     usage.totalTokens == 0:
    return nil
  result = %*{"role": "assistant", "content": content}
  # DeepSeek-R1-style reasoning models REQUIRE the `reasoning_content`
  # field on every assistant message in history — even when the model
  # emitted no reasoning on that turn. Drop it and the next API call
  # fails with `invalid_request_error`. Always set it; other providers
  # ignore the extra field.
  result["reasoning_content"] = %reasoning
  if tools.len > 0:
    var tcArr = newJArray()
    var keys = toSeq(tools.keys).sorted
    for k in keys: tcArr.add tools[k]
    result["tool_calls"] = tcArr
  if wasInterrupted:
    result["interrupted"] = %true

proc parseXmlToolCalls*(content: string): tuple[cleaned: string, calls: seq[JsonNode]] =
  ## Extract GLM/Qwen native `<tool_call>NAME<arg_key>K</arg_key>
  ## <arg_value>V</arg_value>...</tool_call>` blocks from `content` and
  ## promote them to OpenAI-style `tool_calls` entries. Returns the
  ## content with those blocks removed and the synthesized calls.
  ##
  ## Some endpoints (e.g. nvidia z-ai/glm4.7 mid-turn) leak the model's
  ## chat-template tokens into the SSE content stream instead of parsing
  ## them into `tool_calls` deltas. This parser is the fallback.
  const
    Open  = "<tool_call>"
    Close = "</tool_call>"
    KOpen = "<arg_key>"
    KClose = "</arg_key>"
    VOpen = "<arg_value>"
    VClose = "</arg_value>"
  var cleaned = ""
  var calls: seq[JsonNode] = @[]
  var i = 0
  while i < content.len:
    let openIdx = content.find(Open, i)
    if openIdx < 0:
      cleaned.add content[i .. ^1]
      break
    cleaned.add content[i ..< openIdx]
    let closeIdx = content.find(Close, openIdx + Open.len)
    if closeIdx < 0:
      # Unterminated: keep tail as content rather than lose data.
      cleaned.add content[openIdx .. ^1]
      break
    let inner = content[openIdx + Open.len ..< closeIdx]
    let firstK = inner.find(KOpen)
    let name =
      if firstK < 0: inner.strip()
      else: inner[0 ..< firstK].strip()
    var args = newJObject()
    var p = (if firstK < 0: inner.len else: firstK)
    while p < inner.len:
      let kStart = inner.find(KOpen, p)
      if kStart < 0: break
      let kEnd = inner.find(KClose, kStart + KOpen.len)
      if kEnd < 0: break
      let key = inner[kStart + KOpen.len ..< kEnd].strip()
      let vStart = inner.find(VOpen, kEnd + KClose.len)
      if vStart < 0: break
      let vEnd = inner.find(VClose, vStart + VOpen.len)
      if vEnd < 0: break
      let value = inner[vStart + VOpen.len ..< vEnd]
      if key.len > 0: args[key] = %value
      p = vEnd + VClose.len
    if name.len > 0:
      calls.add %*{
        "id": "xmltc-" & $calls.len & "-" & toHex(hash(content[openIdx ..< closeIdx + Close.len]).uint64, 8),
        "type": "function",
        "function": {"name": name, "arguments": $args}
      }
    i = closeIdx + Close.len
  result.cleaned = cleaned.strip(leading = false)
  result.calls = calls

proc accumulateToolCall(dst: JsonNode, delta: JsonNode) =
  # Merge a tool_calls delta chunk into the accumulator slot. OpenAI-style
  # providers emit `arguments` as partial strings across chunks; concatenate.
  if delta.kind != JObject: return
  if "id" in delta and delta["id"].getStr != "":
    dst["id"] = delta["id"]
  if "type" in delta and delta["type"].getStr != "":
    dst["type"] = delta["type"]
  let fn = delta{"function"}
  if fn == nil or fn.kind != JObject: return
  if fn{"name"}.getStr("") != "":
    dst["function"]["name"] = %(dst["function"]["name"].getStr & fn{"name"}.getStr)
  if "arguments" in fn:
    dst["function"]["arguments"] = %(dst["function"]["arguments"].getStr & fn{"arguments"}.getStr(""))

type XmlToolFilter = object
  ## Streaming filter that drops `<tool_call>...</tool_call>` blocks from
  ## live content output. State persists across SSE chunks so a tag may
  ## span chunk boundaries.
  pending: string
  inside: bool

const
  XmlOpenTag = "<tool_call>"
  XmlCloseTag = "</tool_call>"

proc feed(f: var XmlToolFilter, c: string): string =
  ## Append `c` to the filter and return the bytes safe to render now.
  ## Bytes inside a `<tool_call>` block are dropped; bytes that might be
  ## the start of an open tag are held back until we know.
  f.pending.add c
  result = ""
  while f.pending.len > 0:
    if f.inside:
      let idx = f.pending.find(XmlCloseTag)
      if idx < 0:
        let keep = min(f.pending.len, XmlCloseTag.len - 1)
        f.pending = f.pending[f.pending.len - keep .. ^1]
        return
      f.pending = f.pending[idx + XmlCloseTag.len .. ^1]
      f.inside = false
    else:
      let idx = f.pending.find(XmlOpenTag)
      if idx < 0:
        let safeUpTo = f.pending.len - min(f.pending.len, XmlOpenTag.len - 1)
        if safeUpTo > 0:
          result.add f.pending[0 ..< safeUpTo]
          f.pending = f.pending[safeUpTo .. ^1]
        return
      if idx > 0: result.add f.pending[0 ..< idx]
      f.pending = f.pending[idx + XmlOpenTag.len .. ^1]
      f.inside = true

proc flushTail(f: var XmlToolFilter): string =
  ## At end-of-stream, anything still pending outside a tool_call block
  ## is real content — emit it. (Pending bytes inside an unterminated
  ## block are dropped; that's expected: the parser will treat the block
  ## as malformed and the post-stream history will retain raw content.)
  if f.inside: return ""
  result = f.pending
  f.pending = ""

proc streamHttp(url, key, bodyStr: string, baseLabel: string,
                slurped: var int, suppressXml: bool): StreamOutcome =
  debugOut "streamHttp start"
  # Post `bodyStr` to `url` and consume SSE chunks until `[DONE]`. `slurped`
  # accumulates an approximate output-character count so the caller can
  # show a live "↓ Nk" on the spinner; update it inline as chunks arrive.
  # `suppressXml` enables a streaming filter that drops the model's
  # `<tool_call>...</tool_call>` chat-template tags from live output for
  # endpoints that leak them into delta.content (see xmlToolCallsFallback).
  let u = try: parseUri(url) except CatchableError as e:
    result.errMsg = "bad url: " & e.msg
    return
  let host = u.hostname
  let plainHttp =
    when defined(testPlainHttp):
      u.scheme == "http" and (host == "127.0.0.1" or host == "localhost")
    else:
      false
  if u.scheme != "https" and not plainHttp:
    result.errMsg = "only https supported, got: " & u.scheme
    return
  let port =
    if u.port.len > 0: Port(parseInt(u.port))
    elif plainHttp: Port(80)
    else: Port(443)
  let pathQuery =
    block:
      var pq = if u.path.len > 0: u.path else: "/"
      if u.query.len > 0: pq.add "?" & u.query
      pq

  let hostKey = host & ":" & $port.uint16
  var conn: StreamConn
  var resp: StreamResponse
  var attempt = 0
  while true:
    if isInterrupted():
      closeCachedStreamConn()
      result.errMsg = "interrupted by user"
      return
    inc attempt
    if cachedStreamConn != nil and cachedStreamHostKey == hostKey:
      conn = cachedStreamConn
    else:
      closeCachedStreamConn()
      try:
        if plainHttp:
          conn = connectPlain(host, port, timeoutMs = 1_200_000)
        else:
          conn = connectTls(host, port, timeoutMs = 1_200_000,
                            caFile = bundledCaFile())
      except CatchableError as e:
        result.errMsg =
          (if plainHttp: "connect failed: " else: "TLS connect failed: ") & e.msg
        return
      cachedStreamConn = conn
      cachedStreamHostKey = hostKey
      cachedStreamFd = conn.getFd
    try:
      conn.sendRequest("POST", pathQuery, host,
                       headers = [("Authorization", "Bearer " & key),
                                  ("Content-Type", "application/json"),
                                  ("Accept", "text/event-stream")],
                       body = bodyStr)
      hookProviderActivity()
      resp = conn.readResponseHead()
      hookProviderActivity()
      break
    except CatchableError as e:
      # Cached conn was stale (server-side keep-alive timeout, etc.) or
      # the fresh connect's first send/head failed. Drop the cache and
      # retry once with a fresh socket; second failure surfaces the
      # error.
      closeCachedStreamConn()
      if attempt >= 2:
        result.errMsg = "request failed: " & e.msg
        return
  result.statusCode = resp.status
  result.retryAfter = resp.headers.getOrDefault("retry-after")

  var accContent = ""
  var accReasoning = ""
  var accTools = initOrderedTable[int, JsonNode]()
  var nonSSE: seq[string]
  var contentStarted = false
  var xmlFilter = XmlToolFilter()
  # Completion signals. A clean upstream EOF without either `[DONE]` or a
  # non-empty `finish_reason` means the SSE stream was cut mid-response
  # (server-side keepalive timeout, LB drop, etc.). We need to detect that
  # because Nim's `readLine` returns `false` on graceful FIN and the loop
  # exits without raising — so partial deltas would otherwise be returned
  # as if they were a complete assistant turn, leaving the bullet `· Xs`
  # marker on screen and stranding the user with an unfinished job.
  var sawDone = false
  var sawFinish = false
  var line = ""
  var streamErr = ""
  while true:
    var hasLine = false
    try: hasLine = conn.readLine(line)
    except CatchableError as e:
      streamErr = e.msg
      closeCachedStreamConn()
      break
    if not hasLine: break
    hookProviderActivity()
    if isInterrupted():
      closeCachedStreamConn()
      break
    if line.startsWith("data: "):
      let payload = line["data: ".len .. ^1]
      if payload.strip == "[DONE]":
        sawDone = true
        continue
      let j = try: parseJson(payload) except CatchableError: continue
      let choices = j{"choices"}
      if choices != nil and choices.kind == JArray and choices.len > 0:
        let fr = choices[0]{"finish_reason"}
        if fr != nil and fr.kind == JString and fr.getStr.len > 0:
          sawFinish = true
        let delta = choices[0]{"delta"}
        if delta != nil and delta.kind == JObject:
          # Reasoning chunks arrive on `reasoning_content` (DeepSeek, Qwen,
          # Kimi) or `reasoning` (a few others). Always accumulate so we can
          # echo back on the next turn; only render the ticker when enabled.
          var r = delta{"reasoning_content"}.getStr("")
          if r.len == 0: r = delta{"reasoning"}.getStr("")
          if r.len > 0:
            accReasoning &= r
            slurped += r.len
            hookProgress(baseLabel, slurped)
            if hookShowThinking() and not contentStarted:
              hookReasoningDelta(accReasoning, baseLabel, slurped, contentStarted)
          let c = delta{"content"}.getStr("")
          if c.len > 0:
            accContent &= c
            slurped += c.len
            hookProgress(baseLabel, slurped)
            let visible =
              if suppressXml: feed(xmlFilter, c)
              else: c
            if visible.len > 0:
              contentStarted = hookContentDelta(visible, baseLabel, slurped)
          let tcDelta = delta{"tool_calls"}
          if tcDelta != nil and tcDelta.kind == JArray:
            for tc in tcDelta:
              let idx = tc{"index"}.getInt(0)
              if idx notin accTools:
                accTools[idx] = %*{
                  "id": "", "type": "function",
                  "function": {"name": "", "arguments": ""}
                }
              accumulateToolCall(accTools[idx], tc)
              # tool args bytes also count as "output" for slurp feel
              let fn = tc{"function"}
              if fn != nil:
                slurped += fn{"arguments"}.getStr("").len
                hookProgress(baseLabel, slurped)
      let u = j{"usage"}
      if u != nil and u.kind == JObject:
        result.usage = parseUsage(u)
    elif line.startsWith("event:") or line.strip.len == 0 or
         line.startsWith(": "):  # SSE comment
      discard
    else:
      nonSSE.add line

  if suppressXml:
    let tail = flushTail(xmlFilter)
    if tail.len > 0:
      contentStarted = hookContentDelta(tail, baseLabel, slurped)

  if contentStarted:
    result.streamedLive = hookContentFinished(accContent, baseLabel, slurped)
    hookTrimTrailingContent(accContent, baseLabel, slurped)
    if result.streamedLive:
      hookAfterLiveContent(baseLabel, slurped)

  if isInterrupted():
    if result.assistantMsg == nil:
      result.assistantMsg = buildStreamAssistantMsg(accContent, accReasoning,
        accTools, result.usage, isInterrupted())
    # Drop the cache: the SIGINT hook / watcher already shut down the
    # fd, so the conn is half-closed. Reusing it on the next turn
    # would fail on first send. The next call will reconnect cleanly.
    closeCachedStreamConn()
    result.errMsg = "interrupted by user"
    return
  if streamErr.len > 0:
    result.errMsg = "stream read: " & streamErr &
      (if nonSSE.len > 0: ": " & nonSSE.join("\n") else: "")
    return

  # Truncation guard: 200 OK with partial choice deltas but neither `[DONE]`
  # nor a `finish_reason` means the upstream socket closed before the model
  # was finished. Surface it as a retryable server error rather than handing
  # the caller a half-formed assistant turn (would otherwise show as a lone
  # `· Xs` line with no token bar and no tool_calls, prompting the user as
  # if the model had simply stopped).
  let gotAnyDelta = accContent.len > 0 or accTools.len > 0 or accReasoning.len > 0
  if result.statusCode == 200 and gotAnyDelta and
     not sawDone and not sawFinish:
    closeCachedStreamConn()
    result.errMsg = "stream truncated before completion"
    return

  # Build assistant message if we saw any SSE content.
  if result.assistantMsg == nil:
    result.assistantMsg = buildStreamAssistantMsg(accContent, accReasoning,
      accTools, result.usage, isInterrupted())
  if result.assistantMsg == nil:
    # No SSE data — provider may have returned a plain JSON error body.
    result.errBody = nonSSE.join("\n")
  debugOut &"streamHttp end — contentStarted={contentStarted} accTools={accTools.len}"

proc stripInternalFields*(messages: JsonNode): JsonNode =
  ## Return a wire-safe copy of `messages` with internal bookkeeping fields
  ## removed. `usage` is stored on assistant messages for local replay but
  ## rejected by strict validators (fireworks, glm-5p1, etc.).
  if messages == nil or messages.kind != JArray: return messages
  result = newJArray()
  for m in messages:
    if m.kind != JObject or ("usage" notin m and "interrupted" notin m):
      result.add m
      continue
    var clean = newJObject()
    for k, v in m.pairs:
      if k != "usage" and k != "interrupted": clean[k] = v
    result.add clean

proc ensureReasoningField(messages: JsonNode) =
  ## DeepSeek-R1 with thinking mode rejects any request whose history
  ## contains an assistant message without a `reasoning_content` field.
  ## Backfill an empty string on every assistant message missing it —
  ## covers sessions persisted before the fix and turns where the model
  ## emitted no reasoning. The field is unknown-but-ignored on other
  ## OpenAI-compatible providers, so this is safe to apply unconditionally.
  if messages == nil or messages.kind != JArray: return
  for m in messages:
    if m.kind != JObject: continue
    if m{"role"}.getStr != "assistant": continue
    if "reasoning_content" notin m:
      m["reasoning_content"] = %""

proc providerOf(p: Profile): string =
  ## Lower-case provider name from `Profile.name` ("nvidia.openai/gpt-oss-120b"
  ## → "nvidia"). "" when no dot.
  let dot = p.name.find('.')
  if dot < 0: "" else: p.name[0 ..< dot].toLowerAscii

proc applyGptOssReasoning(p: Profile, body: JsonNode) =
  body["reasoning_effort"] = %p.reasoning


proc applyGlmReasoning(p: Profile, body: JsonNode) =
  ## `thinking: {type}` is z.ai's first-party knob — accepted on
  ## api.z.ai (provider names `zai` / `zai-coding`) and rejected
  ## elsewhere (nvidia replies "Validation: Unsupported parameter(s):
  ## `thinking`"). NVIDIA NIM exposes the same knob via vLLM's
  ## `chat_template_kwargs.enable_thinking`, and turning thinking off
  ## there has the side benefit of stabilising tool-call template
  ## emission (the streamed reasoning→tool_call transition is what
  ## sometimes leaks `<tool_call>` tags into delta.content). Other
  ## glm-serving providers (baseten, nebius, together, fireworks,
  ## cerebras) get nothing on the wire — they just always think;
  ## `:reasoning low` is silently inert there.
  case providerOf(p)
  of "zai", "zai-coding", "zaicode":
    let on = p.reasoning != "low"
    body["thinking"] = %*{"type": (if on: "enabled" else: "disabled")}
  of "nvidia":
    let on = p.reasoning != "low"
    body["chat_template_kwargs"] = %*{"enable_thinking": on}
  else: discard

proc applyStreamingOptions*(p: Profile, body: JsonNode) =
  ## Provider-specific additions for SSE fidelity. Z.ai only streams
  ## reasoning/tool-call deltas during tool turns when `tool_stream` is set;
  ## without it, GLM-5.1 can buffer the useful progress and emit usage at
  ## the end.
  if p.family == "glm":
    case providerOf(p)
    of "zai", "zai-coding", "zaicode":
      body["tool_stream"] = %true
    else: discard

proc applyGenerationDefaults*(p: Profile, body: JsonNode) =
  ## Known-good generation policy. Temperature is intentionally hardcoded
  ## for now; later a user override can resolve before this writes the field.
  let d = knownGoodGeneration(p)
  if d.temperature >= 0.0:
    body["temperature"] = %d.temperature
  if d.maxTokens > 0:
    body["max_tokens"] = %d.maxTokens

proc applyDeepseekReasoning(p: Profile, body: JsonNode) =
  ## DeepSeek V4 maps thinking on/off + reasoning_effort (high/max only;
  ## low/medium silently become high). For economical coding we follow
  ## DeepSeek’s recommendation for coding tasks: temperature 0.0, which
  ## yields deterministic output and reduces token waste.
  ##   low    → thinking disabled, temperature 0.0
  ##   medium → thinking enabled, effort low,   temperature 0.0
  ##   high   → thinking enabled, effort medium,temperature 0.0
  ## Temperature is overridden here (after applyGenerationDefaults) because
  ## thinking mode ignores it — but we still set it explicitly for all
  ## levels to keep behavior deterministic.
  case p.reasoning
  of "low":
    body["thinking"] = %*{"type": "disabled"}
    body["temperature"] = %0.0
  of "medium":
    body["thinking"] = %*{"type": "enabled"}
    # Map to low reasoning effort for DeepSeek
    body["reasoning_effort"] = %"low"
    body["temperature"] = %0.0
  of "high":
    body["thinking"] = %*{"type": "enabled"}
    # Map to medium reasoning effort for DeepSeek
    body["reasoning_effort"] = %"medium"
    body["temperature"] = %0.0
  else: discard

proc applyMinimaxReasoning(p: Profile, body: JsonNode) =
  ## MiniMax M2.x uses vLLM's `chat_template_kwargs.enable_thinking`
  ## to toggle reasoning. NVIDIA NIM exposes the same knob. Thinking
  ## is disabled at "low" for snappy responses; "medium" and "high"
  ## enable it with increasing effort. Temperature is pinned to 0.2
  ## per MiniMax's recommended deployment settings.
  case p.reasoning
  of "low":
    body["chat_template_kwargs"] = %*{"enable_thinking": false}
  of "medium":
    body["chat_template_kwargs"] = %*{"enable_thinking": true}
  of "high":
    body["chat_template_kwargs"] = %*{"enable_thinking": true}
  else: discard

proc applyReasoning*(p: Profile, body: JsonNode) =
  ## Per-family wire mapping for `Profile.reasoning`. Adding a new
  ## family means: (1) set `reasoning` in the known-good combo table,
  ## (2) write an `applyXReasoning` proc, (3) add a case branch.
  case p.family
  of "gpt-oss": applyGptOssReasoning(p, body)
  of "glm": applyGlmReasoning(p, body)
  of "deepseek": applyDeepseekReasoning(p, body)
  of "minimax": applyMinimaxReasoning(p, body)
  else: discard

proc callModel*(p: Profile, messages: JsonNode, usage: var Usage, lastPromptTokens: int): JsonNode =
  when providerStub:
    block:
      let stubT0 = epochTime()
      let stubWindow = contextWindowFor(p.model)
      let stubBaseLabel = hookBeforeCall(lastPromptTokens, stubWindow)
      defer:
        hookAfterCall()
      const StubMaxAttempts = 8
      var attempt = 0
      var lastFailure = sfNone
      while true:
        inc attempt
        let node = stubCallModel(messages)
        if node.kind == JObject and node{"failure"}.getStr("").len > 0:
          lastFailure = parseStubFailure(node{"failure"}.getStr)
          let delayMs = stubDelayMs(node, "delayMs", 300)
          var remaining = delayMs
          while remaining > 0:
            if isInterrupted():
              hookStopSpinner()
              raise newException(ApiError, "interrupted by user")
            let step = min(100, remaining)
            sleep(step)
            remaining -= step
          let code = stubHttpStatus(lastFailure)
          var errMsg =
            if code > 0: "api " & $code
            else: stubTransportError(lastFailure)
          if errMsg.len == 0:
            errMsg = stubFailureName(lastFailure)
          let category = retryCategory(errMsg, nil, code)
          if category.len == 0 or attempt >= StubMaxAttempts:
            hookStopSpinner()
            raise newException(ApiError,
              errMsg & (if stubErrBody(lastFailure, node).len > 0:
                ": " & stubErrBody(lastFailure, node) else: ""))
          let retryAfter = try: parseInt(stubRetryAfter(node)) except CatchableError: 0
          let backoff =
            if retryAfter > 0: retryAfter
            elif category == "rate": min(1 shl rateRetryLevel, 90)
            else: min(1 shl serverRetryLevel, 16)
          hookStopSpinner()
          stderr.writeLine &"3code: {errMsg}; retry {attempt + 1}/{StubMaxAttempts} in {backoff}s"
          var waitMs = backoff * 1000
          while waitMs > 0:
            if isInterrupted():
              raise newException(ApiError, "interrupted by user during retry backoff")
            let step = min(100, waitMs)
            sleep(step)
            waitMs -= step
          if category == "rate":
            inc rateRetryLevel
            rateLastTs = epochTime()
          else:
            inc serverRetryLevel
            serverLastTs = epochTime()
          hookSetStatusLabel(&"retry {attempt + 1}/{StubMaxAttempts}")
          hookStartSpinner("")
        else:
          result = node
          break
      if result.kind == JObject and "role" notin result:
        result["role"] = %"assistant"
      debugOut &"callModel stub idx={stubResponseIdx-1} failure={stubFailureName(lastFailure)}"
      var slurped = 0
      let preStreamDelay = stubDelayMs(result, "preStreamDelayMs", 0)
      if preStreamDelay > 0 and not testFrameMode():
        var remaining = preStreamDelay
        while remaining > 0:
          if isInterrupted():
            hookStopSpinner()
            raise newException(ApiError, "interrupted by user")
          let step = min(100, remaining)
          sleep(step)
          remaining -= step
      if testFrameMode() and result{"waitForTestContinue"}.getBool(false):
        waitForTestContinue()
      let stubContent = result{"content"}.getStr("")
      var stubStreamedLive = false
      if result{"stream"}.getBool(true):
        var stubReasoning = result{"reasoning_content"}.getStr("")
        if stubReasoning.len == 0:
          stubReasoning = result{"reasoning"}.getStr("")
        var accReasoning = ""
        var contentStarted = false
        for chunk in stubStringChunks(result, "reasoningChunks", stubReasoning):
          accReasoning.add chunk
          slurped += chunk.len
          hookProgress(stubBaseLabel, slurped)
          if hookShowThinking() and not contentStarted:
            hookReasoningDelta(accReasoning, stubBaseLabel, slurped,
                               contentStarted)
          emitTestFrameEvent()
        for chunk in stubStringChunks(result, "contentChunks", stubContent):
          slurped += chunk.len
          hookProgress(stubBaseLabel, slurped)
          contentStarted = hookContentDelta(chunk, stubBaseLabel, slurped)
          emitTestFrameEvent()
        if contentStarted:
          stubStreamedLive = hookContentFinished(stubContent, stubBaseLabel,
                                                 slurped)
          hookTrimTrailingContent(stubContent, stubBaseLabel, slurped)
          if stubStreamedLive:
            hookAfterLiveContent(stubBaseLabel, slurped)
          emitTestFrameEvent()
      hookStopSpinner()
      usage = stubUsage(result, stubContent)
      let stubElapsed =
        if testFrameMode(): 0
        else: (epochTime() - stubT0).int
      hookFinalUsage(usage, stubWindow, stubElapsed, stubContent,
                     stubStreamedLive)
      emitTestFrameEvent()
      if result.kind == JObject:
        result["usage"] = %*{
          "promptTokens": usage.promptTokens,
          "completionTokens": usage.completionTokens,
          "totalTokens": usage.totalTokens,
          "cachedTokens": usage.cachedTokens,
          "elapsed": stubElapsed,
          "ts": now().format("yyyy-MM-dd'T'HH:mm:sszzz"),
        }
      return
  debugOut "callModel start"
  if p.family == "deepseek":
    ensureReasoningField(messages)
  let wireMessages = stripInternalFields(messages)
  if p.family != "deepseek":
    for m in wireMessages:
      if m.kind == JObject and m{"role"}.getStr == "assistant" and m.contains("reasoning_content"):
        m.delete("reasoning_content")
  var body = %*{
    "model": p.model,
    "messages": wireMessages,
    "stream": true,
  }
  # Include usage in streaming responses only for providers that support it (e.g., OpenAI).
  # Fireworks and other non‑OpenAI endpoints reject the `include_usage` field.
  # Include usage in streaming responses for all providers except Fireworks,
  # which rejects the `include_usage` field.
  if providerOf(p) != "fireworks":
    body["stream_options"] = %*{"include_usage": true}
  body["tools"] = setup(p).tools
  body["tool_choice"] = %"auto"
  applyStreamingOptions(p, body)
  applyGenerationDefaults(p, body)
  if p.reasoning.len > 0:
    applyReasoning(p, body)
  let bodyStr = $body
  if "\"usage\"" in bodyStr:
    stderr.writeLine "3code: BUG: usage in wireMessages"
    for i, m in wireMessages:
      if m.kind == JObject and "usage" in m:
        stderr.writeLine "  wireMessages[" & $i & "] has usage role=" & m{"role"}.getStr
    stderr.writeLine "3code: original messages:"
    for i, m in messages:
      if m.kind == JObject and "usage" in m:
        stderr.writeLine "  messages[" & $i & "] has usage role=" & m{"role"}.getStr
  let t0 = epochTime()
  decayLevel(serverRetryLevel, serverLastTs, t0)
  decayLevel(rateRetryLevel, rateLastTs, t0)
  let window = contextWindowFor(p.model)
  let baseLabel = hookBeforeCall(lastPromptTokens, window)
  # Cursor is hidden for the duration of the entire turn by `runTurns`
  # so the prompt placeholder is the only visible caret. callModel
  # itself doesn't toggle visibility — touching DECTCEM here would
  # cause a flicker between callModel iterations within a turn.
  defer:
    hookAfterCall()
  const MaxAttempts = 8
  var outcome: StreamOutcome
  var attempt = 0
  while true:
    inc attempt
    var slurped = 0
    outcome = streamHttp(p.url & "/chat/completions", p.key, bodyStr,
                        baseLabel, slurped, xmlToolCallsFallback(p))
    if outcome.errMsg == "interrupted by user":
      hookStopSpinner()
      if outcome.assistantMsg == nil:
        raise newException(ApiError, "interrupted by user")
      break
    let code = outcome.statusCode
    let category = retryCategory(outcome.errMsg, outcome.assistantMsg, code)
    let retryable = category != ""
    var errMsg = outcome.errMsg
    if errMsg == "" and retryable: errMsg = "api " & $code
    if not retryable:
      hookStopSpinner()
      if outcome.assistantMsg == nil:
        raise newException(ApiError,
          errMsg & (if outcome.errBody.len > 0: ": " & outcome.errBody else: ""))
      # Promote any leaked GLM/Qwen native `<tool_call>...</tool_call>`
      # blocks in the assistant content to synthetic OpenAI tool_calls.
      # Some endpoints (notably nvidia z-ai/glm4.7) don't reliably
      # translate the model's chat template into OpenAI deltas mid-turn.
      if xmlToolCallsFallback(p):
        let msg = outcome.assistantMsg
        let content = msg{"content"}.getStr("")
        if content.contains("<tool_call>"):
          let parsed = parseXmlToolCalls(content)
          if parsed.calls.len > 0:
            msg["content"] = %parsed.cleaned
            var tcArr =
              if "tool_calls" in msg: msg["tool_calls"]
              else: newJArray()
            for call in parsed.calls: tcArr.add call
            msg["tool_calls"] = tcArr
      break
    if attempt >= MaxAttempts:
      hookStopSpinner()
      raise newException(ApiError,
        errMsg & (if outcome.errBody.len > 0: ": " & outcome.errBody else: ""))
    let retryAfter = try: parseInt(outcome.retryAfter) except CatchableError: 0
    let backoff =
      if retryAfter > 0:
        retryAfter
      elif category == "rate":
        let isBusy = "busy" in outcome.errBody or
                     "capacity" in outcome.errBody or
                     "overloaded" in outcome.errBody
        let base = if isBusy: max(rateRetryLevel, 4) else: rateRetryLevel
        min(1 shl base, 90)
      else:
        min(1 shl serverRetryLevel, 16)
    hookStopSpinner()
    stderr.writeLine &"3code: {errMsg}; retry {attempt + 1}/{MaxAttempts} in {backoff}s"
    block wait:
      var remaining = backoff * 1000
      while remaining > 0:
        if isInterrupted(): break wait
        let step = min(100, remaining)
        sleep(step)
        remaining -= step
    if isInterrupted():
      raise newException(ApiError, "interrupted by user during retry backoff")
    hookSetStatusLabel(&"retry {attempt + 1}/{MaxAttempts}")
    hookStartSpinner("")
    if category == "rate":
      inc rateRetryLevel
      rateLastTs = epochTime()
    else:
      inc serverRetryLevel
      serverLastTs = epochTime()
  usage = outcome.usage
  let elapsed = epochTime() - t0
  if usage.totalTokens > 0:
    # Repaint the bar with accurate values now that `usage` is parsed
    # — the live values during streaming were rough estimates
    # (`slurped/4`). `pendingHint` carries the same numbers forward
    # so the next user-submit's receipt repaints this row dim with
    # matching content.
    let assistantContent =
      if outcome.assistantMsg == nil: ""
      else: outcome.assistantMsg{"content"}.getStr("")
    hookFinalUsage(usage, window, elapsed.int, assistantContent,
                   outcome.streamedLive)
  else:
    hookNoUsage(elapsed.int)
  if outcome.assistantMsg != nil and usage.totalTokens > 0:
    # Attach this turn's usage inline so replay can render the same
    # token line without a parallel array that drifts under summarization.
    # `elapsed` and `ts` carry through to the .3log `tokens` record on
    # save so resumed sessions keep their cost ledger.
    outcome.assistantMsg["usage"] = %*{
      "promptTokens": usage.promptTokens,
      "completionTokens": usage.completionTokens,
      "totalTokens": usage.totalTokens,
      "cachedTokens": usage.cachedTokens,
      "elapsed": elapsed.int,
      "ts": now().format("yyyy-MM-dd'T'HH:mm:sszzz"),
    }
  debugOut &"callModel end streamedLive={outcome.streamedLive} usage={usage.totalTokens}"
  return outcome.assistantMsg

proc verifyBody*(p: Profile): string =
  ## JSON body for the provider-verification ping.  Kept as a named proc
  ## so the test suite can assert it matches the streaming convention used
  ## by `callModel` (both must send `"stream": true`).
  $(%*{
    "model": p.model,
    "messages": [%*{"role": "user", "content": "ping"}],
    "max_tokens": 1,
    "stream": true
  })

proc verifyProfile*(p: Profile): (bool, string) =
  if verifyProfileHook != nil:
    return verifyProfileHook(p)
  when providerStub:
    if p.url.startsWith("stub://"):
      return (true, "")
  let body = verifyBody(p)
  try:
    let client = newHttpClient(timeout = 20_000, userAgent = "3code",
                               sslContext = bundledSslContext())
    defer: client.close()
    client.headers["Authorization"] = "Bearer " & p.key
    client.headers["Content-Type"] = "application/json"
    client.headers["Accept"] = "text/event-stream"
    let resp = client.request(p.url & "/chat/completions",
                              httpMethod = HttpPost, body = body)
    if resp.code.int != 200:
      let snip = resp.body[0 ..< min(200, resp.body.len)]
      return (false, $resp.code.int & ": " & snip)
    # Streaming response — look for an error object in the first SSE chunk
    # or just accept any 200 as success (we only need to know the endpoint
    # is reachable and the key works).
    if resp.body.len > 0:
      let sse = resp.body
      if sse.contains("\"error\""):
        let start = max(0, sse.find("{"))
        let snip = sse[start ..< min(start + 200, sse.len)]
        return (false, snip)
    (true, "")
  except CatchableError as e:
    (false, e.msg)

proc fetchModels*(url, key: string): (seq[string], string) =
  ## GET /models on the provider. Returns (models, error) — error is empty on
  ## success. Callers are responsible for displaying the error.
  if fetchModelsHook != nil:
    return fetchModelsHook(url, key)
  when providerStub:
    if url.startsWith("stub://"):
      return (@["stub-model"], "")
  try:
    let client = newHttpClient(timeout = 20_000, userAgent = "3code",
                               sslContext = bundledSslContext())
    defer: client.close()
    client.headers["Authorization"] = "Bearer " & key
    let resp = client.get(url & "/models")
    if resp.code.int != 200:
      return (@[], "HTTP " & $resp.code.int & " — " &
                   resp.body[0 ..< min(120, resp.body.len)])
    let j = parseJson(resp.body)
    let arr = if j.kind == JArray: j
              elif "data" in j and j["data"].kind == JArray: j["data"]
              else:
                return (@[], "unexpected response shape: " &
                             resp.body[0 ..< min(120, resp.body.len)])
    var models: seq[string]
    for item in arr:
      if item.kind == JString: models.add item.getStr
      elif item.kind == JObject and "id" in item: models.add item["id"].getStr
    return (models, "")
  except CatchableError as e:
    return (@[], e.msg)

proc installInterruptHook*() =
  setControlCHook(proc() {.noconv.} =
    requestTurnInterrupt())
