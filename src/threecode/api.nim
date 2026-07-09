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

import std/[algorithm, atomics, hashes, httpclient, json, locks, nativesockets, net, os, sequtils, strformat, strutils, tables, times, uri]
when defined(posix):
  import std/posix except SocketHandle
import streamhttp
import types, util, prompts, compact, streamexec, netthread

type
  VerifyProfileHook* = proc(p: Profile): (bool, string) {.closure.}
  FetchModelsHook* = proc(url, key: string): (seq[string], string) {.closure.}

var
  verifyProfileHook*: VerifyProfileHook
  fetchModelsHook*: FetchModelsHook

const providerStub {.booldefine.} = false
const httpStub {.booldefine.} = false
  ## Test-only define. When true, `testdata/stub/http.nim` is included and
  ## `callHttp` is replaced by `callHttpStub` so the non-streaming path's
  ## body→assistantMsg reconstruction, usage parsing, retry categorization,
  ## and xml-tool-call promotion can be unit-tested without a network.
  ## Pair with `providerStub=false`: the http stub tests the network layer
  ## (non-streaming), the provider stub tests everything else. Sum = full
  ## coverage.
const ConnectTimeoutMs = 30_000
const QuietRecvWakeMs* {.intdefine.} = 500
  ## How long each blocking `recv` may stall before waking. With
  ## streamhttp's `readTimeoutMs` set to this, `readLine` raises
  ## `StreamTimeoutError` periodically so the stream loop can re-check
  ## the quiet/interrupt flags. Must be well under `QuietTooLongMs`.
  ## Kept at 1s so user interrupts (Ctrl-C) are honored within ~1s;
  ## the extra poll overhead is negligible for trickle-rate streams.
const QuietTooLongMs* {.intdefine.} = 45_000
  ## If a streaming response goes this long with no data from the
  ## provider (45s), the turn is aborted. `posix.shutdown(fd)` from another
  ## thread does not reliably wake a blocked TLS `recv`, so the stream
  ## loop instead relies on `QuietRecvWakeMs`-bounded reads to wake up
  ## and observe this threshold. That bound is enforced twice now:
  ## `poll()` bounds the wait-for-readable step, and `SO_RCVTIMEO` (set
  ## by `setReadTimeoutMs`) hard-bounds the blocking `SSL_read`/`recv`
  ## that follows, closing the race where `poll` returns readable for a
  ## TLS control record (close_notify, ticket, renegotiation) and the
  ## subsequent `SSL_read` then blocks forever immune to the shutdown wake.

proc isInterrupted*(): bool {.gcsafe.}
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

var networkQuietFlag: Atomic[bool]
  ## Set by the quiet-watch thread when no provider data has arrived for
  ## `QuietTooLongMs`. It then shuts down the cached socket fd (same wake
  ## mechanism as ctrl-c) so the blocking `recv` in streamhttp returns and
  ## the stream loop can surface the error instead of hanging forever.

proc isNetworkQuiet*(): bool {.gcsafe.} =
  networkQuietFlag.load(moAcquire)

proc markNetworkQuiet*() {.gcsafe.} =
  networkQuietFlag.store(true, moRelease)

proc clearNetworkQuiet*() {.gcsafe.} =
  networkQuietFlag.store(false, moRelease)

type
  ApiStreamHooks* = object
    beforeCall*: proc(lastPromptTokens, window: int): string {.closure.}
    afterCall*: proc() {.closure.}
    progress*: proc(baseLabel: string; slurped: int) {.closure.}
    setStatusLabel*: proc(label: string) {.closure.}
    startSpinner*: proc(label: string) {.closure.}
    stopSpinner*: proc() {.closure.}
    providerActivity*: proc() {.closure.}
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
    retryNotice*: proc(msg: string) {.closure.}

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

proc hookRetryNotice(msg: string) =
  if apiStreamHooks.retryNotice != nil: apiStreamHooks.retryNotice(msg)


proc parseUsage*(u: JsonNode): Usage =
  ## Parses an OpenAI-compatible `usage` object. Cached-token accounting
  ## differs by provider: OpenAI/DeepInfra/Anthropic report it under
  ## `prompt_tokens_details.cached_tokens`; DeepSeek reports it flat as
  ## `prompt_cache_hit_tokens`. We accept either.
  if u == nil or u.kind != JObject: return
  result.promptTokens = u{"prompt_tokens"}.getInt(0)
  result.completionTokens = u{"completion_tokens"}.getInt(0)
  result.totalTokens = u{"total_tokens"}.getInt(0)
  let promptDetails = u{"prompt_tokens_details"}
  if promptDetails != nil and promptDetails.kind == JObject:
    result.cachedTokens = promptDetails{"cached_tokens"}.getInt(0)
  if result.cachedTokens == 0:
    result.cachedTokens = u{"prompt_cache_hit_tokens"}.getInt(0)
  let completionDetails = u{"completion_tokens_details"}
  if completionDetails != nil and completionDetails.kind == JObject:
    result.reasoningTokens = completionDetails{"reasoning_tokens"}.getInt(0)

proc classifyRetry*(exc: ref CatchableError, code: int): string =
  ## Returns "server" for network errors and 5xx, "rate" for 429, "" for
  ## anything else (not retryable). Pure-logic helper for the callModel
  ## retry block.
  if exc != nil: return "server"
  case code
  of 429: "rate"
  of 500, 502, 503, 504: "server"
  else: ""

proc extractErrorMsg*(errBody: string): string =
  ## Pull a human-readable message from a JSON error body.
  ## Falls back to the raw body if parsing fails.
  if errBody.len == 0: return ""
  let j = try: parseJson(errBody) except CatchableError: nil
  if j == nil or j.kind != JObject: return errBody
  let err = j{"error"}
  if err != nil and err.kind == JObject:
    let msg = err{"message"}.getStr("")
    if msg.len > 0: return msg
  let msg = j{"message"}.getStr("")
  if msg.len > 0: return msg
  return errBody

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

# A connect-in-progress fd, published by streamhttp's `onConnectingFd` hook
# the instant the socket is created, before the blocking connect. Held in
# `cachedStreamFd` so `shutdownCachedStreamFd` can interrupt a connect that
# has not yet produced a `StreamConn` (the connect path only sets the cached
# conn/fd after a successful connect). Cleared by `closeCachedStreamConn`.
# See `installConnectingFdHook`.
proc onConnectingFdHook(fd: SocketHandle) {.gcsafe.} =
  cachedStreamFd = fd

proc installConnectingFdHook*() =
  ## Wire streamhttp's connect-time hook so a Ctrl-C / quiet-watch shutdown
  # can wake a blocking TCP connect or TLS handshake. Without this the fd is
  # unknown to us until connectTls/connectPlain returns, so there is nothing
  # to `shutdown`, and a slow/black-holed remote pins the caller for the full
  # connect budget regardless of any interrupt. Idempotent.
  onConnectingFd = onConnectingFdHook

# Install at module load so every connect path (streaming, non-streaming,
# first turn or retry) publishes its fd before the blocking connect. There is
# no scenario where we want a connect to be uninterruptible, so this is not
# opt-in.
installConnectingFdHook()

proc closeCachedStreamConn*() =
  ## Drop the cached connection. When the connection is known dead (the user
  ## interrupted, or the quiet-watch marked the link dead) the peer is a
  ## black-holed socket, so a graceful TLS `close_notify` would hang forever
  ## waiting for the peer's second leg (and, under the stdlib's `blockSigpipe`,
  ## also block in `sigwait` for a SIGPIPE that never arrives) - the exact
  ## wedge threecode hit on flaky links, where the network worker leaked a
  ## thread stuck in close()/sigwait and Ctrl-C/ESC could not cancel it. In
  ## that case `abruptClose` tears the fd straight down (SO_LINGER=0 +
  ## posix.close) and skips the close_notify. Otherwise a normal graceful
  ## close is fine.
  if cachedStreamConn != nil:
    if isInterrupted() or isNetworkQuiet():
      cachedStreamConn.abruptClose()
    else:
      try: cachedStreamConn.close() except CatchableError: discard
    cachedStreamConn = nil
    cachedStreamHostKey = ""
  cachedStreamFd = osInvalidSocket

proc shutdownCachedStreamFd*() {.gcsafe.} =
  ## Async-signal-safe: only the `shutdown` syscall, no allocation, no
  ## Nim GC traffic. Forces a blocking `recv` on `cachedStreamConn` to
  ## return so the streamHttp loop observes the interrupt/quiet flags and
  ## bails. Safe to call from a SIGINT hook, the quiet-watch thread, or
  ## the stdin watcher thread.
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

proc requestQuietShutdown*() {.gcsafe.} =
  ## Wakes a blocked HTTP read because the provider has been quiet too long,
  ## WITHOUT setting the user-interrupt flag. The streamHttp loop will see
  ## `isNetworkQuiet()` and surface a dedicated error; the user sees a
  ## timeout notice, not "interrupted by user". Kept separate from
  ## `requestTurnInterrupt` because that path sets `interruptedFlag`, which
  ## confuses `callModel`'s retry logic (retries fail immediately as
  ## "interrupted during backoff") and masks the real cause.
  markNetworkQuiet()
  shutdownCachedStreamFd()

proc stripLeadingTrailingBlankLines*(s: string): string =
  ## Drop blank (whitespace-only) lines from the start and end of `s`.
  ## Internal blank lines survive so paragraph spacing and fenced code
  ## stay intact. Normalizes assistant content the model pads with
  ## leading/trailing newlines.
  if s.len == 0: return s
  var lines = s.replace("\r\n", "\n").replace("\r", "\n").splitLines
  var first = 0
  while first < lines.len and lines[first].strip.len == 0:
    inc first
  if first >= lines.len:
    return ""
  var last = lines.len - 1
  while last > first and lines[last].strip.len == 0:
    dec last
  result = lines[first .. last].join("\n")

proc buildStreamAssistantMsg*(content, reasoning: string,
                              tools: OrderedTable[int, JsonNode],
                              usage: Usage,
                              wasInterrupted = false;
                              finishReason = ""): JsonNode =
  ## Build the assistant message reconstructed from an SSE stream.
  ## Returns nil only when the stream produced nothing at all: no
  ## content/tools/reasoning, no usage, no finish_reason, which signals a
  ## transport-level problem the callModel retry block handles. A stream
  ## that produced usage and/or a finish_reason but no visible content
  ## (e.g. the model spent its whole budget on reasoning, finish_reason
  ## "length") is NOT nil: it is handed back carrying `finish_reason` so
  ## the turn loop can branch on it instead of dead-ending.
  if content.len == 0 and tools.len == 0 and reasoning.len == 0 and
     usage.totalTokens == 0 and finishReason.len == 0:
    return nil
  result = %*{"role": "assistant", "content": stripLeadingTrailingBlankLines(content)}
  if finishReason.len > 0:
    result["finish_reason"] = %finishReason
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
                slurped: var int, suppressXml: bool,
                job: NetJob): StreamOutcome =
  debugOut "streamHttp start"
  # Post `bodyStr` to `url` and consume SSE chunks until `[DONE]`. `slurped`
  # accumulates an approximate output-character count so the caller can
  # show a live "↓ Nk" on the spinner; update it inline as chunks arrive.
  # `suppressXml` enables a streaming filter that drops the model's
  # `<tool_call>...</tool_call>` chat-template tags from live output for
  # endpoints that leak them into delta.content (see xmlToolCallsFallback).
  #
  # Side effects (progress, content deltas, reasoning, the final assistant
  # message) are fired as `NetDelta`s into `job` instead of calling the
  # terminal hooks directly. The main thread drains and replays them. This
  # lets the blocking recv loop run on a worker thread while the UI stays
  # responsive.
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
      result.errMsg = InterruptedByUserMsg
      return
    inc attempt
    if cachedStreamConn != nil and cachedStreamHostKey == hostKey:
      conn = cachedStreamConn
    else:
      closeCachedStreamConn()
      try:
        if plainHttp:
          conn = connectPlain(host, port, timeoutMs = ConnectTimeoutMs)
        else:
          conn = connectTls(host, port, timeoutMs = ConnectTimeoutMs,
                            caFile = bundledCaFile())
      except CatchableError as e:
        # Drop the cached IP so the next attempt re-resolves: a stale record
        # pointing at a dead host must not pin every retry.
        invalidateResolved(host, port)
        # A Ctrl-C during connect shuts down the in-progress fd (via the
        # `onConnectingFd` hook), which makes the blocking connect raise. The
        # user cancelled, so surface that, not a misleading connect error —
        # and skip the retry the generic error path would trigger.
        if isInterrupted():
          result.errMsg = InterruptedByUserMsg
          return
        result.errMsg =
          (if plainHttp: "connect failed: " else: "TLS connect failed: ") &
          connectErrorDetail(e)
        return
      cachedStreamConn = conn
      cachedStreamHostKey = hostKey
      cachedStreamFd = conn.getFd
    conn.setReadTimeoutMs(QuietRecvWakeMs)
    try:
      conn.sendRequest("POST", pathQuery, host,
                       headers = [("Authorization", "Bearer " & key),
                                  ("Content-Type", "application/json"),
                                  ("Accept", "text/event-stream")],
                       body = bodyStr)
      fireActivity(job)
      while true:
        try:
          resp = conn.readResponseHead()
          break
        except StreamTimeoutError:
          if isInterrupted() or isNetworkQuiet():
            closeCachedStreamConn()
            break
          continue
      if resp.status == 0 and resp.headers.len == 0:
        if isNetworkQuiet():
          result.errMsg = "network quiet for " &
            $(QuietTooLongMs div 1000) & "s)"
        elif isInterrupted():
          result.errMsg = InterruptedByUserMsg
        else:
          result.errMsg = "network quiet for " &
            $(QuietTooLongMs div 1000) & "s)"
        return
      fireActivity(job)
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
  var finishReason = ""
  var line = ""
  var streamErr = ""
  while true:
    var hasLine = false
    try: hasLine = conn.readLine(line)
    except StreamTimeoutError:
      if isInterrupted() or isNetworkQuiet():
        closeCachedStreamConn()
        break
      continue
    except CatchableError as e:
      streamErr = e.msg
      closeCachedStreamConn()
      break
    if not hasLine: break
    fireActivity(job)
    if isInterrupted():
      closeCachedStreamConn()
      break
    if line.startsWith("data: "):
      let payload = line["data: ".len .. ^1]
      if payload.strip == "[DONE]":
        sawDone = true
        continue
      let j = try: parseJson(payload)
                 except CatchableError as e:
                   # Empty payload or [DONE]-like comment is benign; anything
                   # else that fails to parse is suspicious (truncated JSON).
                   if payload.strip.len > 0:
                     debugOut "malformed SSE data line: " & e.msg & " — " & payload
                   continue
      let choices = j{"choices"}
      if choices != nil and choices.kind == JArray and choices.len > 0:
        let fr = choices[0]{"finish_reason"}
        if fr != nil and fr.kind == JString and fr.getStr.len > 0:
          sawFinish = true
          finishReason = fr.getStr
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
            fireProgress(job, slurped)
            if not contentStarted:
              fireReasoning(job, accReasoning, slurped)
          let c = delta{"content"}.getStr("")
          if c.len > 0:
            accContent &= c
            slurped += c.len
            fireProgress(job, slurped)
            let visible =
              if suppressXml: feed(xmlFilter, c)
              else: c
            if visible.len > 0:
              fireContent(job, visible, slurped)
              contentStarted = true
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
                fireProgress(job, slurped)
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
      fireContent(job, tail, slurped)
      contentStarted = true

  if contentStarted:
    result.streamedLive = true
    fireContentFinished(job, accContent, slurped)
    fireTrimTrailing(job, accContent, slurped)
    fireAfterLive(job, slurped)

  if isNetworkQuiet():
    # The quiet-watch thread marked the connection dead and shut down the
    # cached fd. The recv loop's bounded timeout (StreamTimeoutError) let it
    # wake and check this flag. Surface a non-retryable error so the turn
    # loop shows it and the user can retry, rather than hanging on a dead
    # connection forever.
    closeCachedStreamConn()
    result.errMsg = "network quiet for " &
      $(QuietTooLongMs div 1000) & "s"
    return
  if isInterrupted():
    if result.assistantMsg == nil:
      result.assistantMsg = buildStreamAssistantMsg(accContent, accReasoning,
        accTools, result.usage, isInterrupted())
    # Drop the cache: the SIGINT hook / watcher already shut down the
    # fd, so the conn is half-closed. Reusing it on the next turn
    # would fail on first send. The next call will reconnect cleanly.
    closeCachedStreamConn()
    result.errMsg = InterruptedByUserMsg
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
  #let gotAnyDelta = accContent.len > 0 or accTools.len > 0 or accReasoning.len > 0
  #if result.statusCode == 200 and gotAnyDelta and
  #   not sawDone and not sawFinish:
  #  closeCachedStreamConn()
  #  result.errMsg = "stream truncated before completion"
  #  return

  result.finishReason = finishReason
  # Build assistant message. A stream with usage and/or a finish_reason but
  # no visible content is still a real (if empty) assistant turn: the model
  # may have spent its whole token budget on reasoning (finish_reason
  # "length") or hit a content filter. Build a minimal message carrying the
  # finish_reason so the turn loop can branch on it. Only the case with no
  # content, no usage, and no finish_reason is a transport-level problem
  # surfaced as an error here.
  if result.assistantMsg == nil:
    result.assistantMsg = buildStreamAssistantMsg(accContent, accReasoning,
      accTools, result.usage, isInterrupted(), finishReason)
  if result.assistantMsg == nil:
    # No SSE data at all. Provider may have returned a plain JSON error
    # body. Surface as a retryable transport error so callModel handles it
    # via the network retry block, NOT the empty-content auto-handling mode.
    result.errBody = nonSSE.join("\n")
    result.errMsg = "empty reply - no content, no tool calls"
  debugOut &"streamHttp end contentStarted={contentStarted} accTools={accTools.len} finishReason={finishReason}"

proc buildBatchAssistantMsg*(message, reasoning: string;
                             toolCalls: JsonNode;
                             finishReason = ""): JsonNode =
  ## Build an assistant message from a non-streaming completion's
  ## `choices[0].message`. Mirrors `buildStreamAssistantMsg`'s shape so the
  ## rest of the pipeline (history replay, tool dispatch) sees a uniform
  ## object regardless of transport. Returns nil only when the message is
  ## genuinely empty (no content, no tool_calls, no reasoning) AND has no
  ## finish_reason. The caller treats that as a transport error to surface.
  ## An empty message with a finish_reason (length/content_filter) is NOT
  ## nil so the turn loop can branch on it.
  if message.len == 0 and reasoning.len == 0 and finishReason.len == 0 and
     (toolCalls == nil or toolCalls.kind != JArray or toolCalls.len == 0):
    return nil
  result = %*{"role": "assistant", "content": stripLeadingTrailingBlankLines(message)}
  # Same rationale as buildStreamAssistantMsg: DeepSeek-R1-style models
  # require `reasoning_content` on every assistant message in history.
  result["reasoning_content"] = %reasoning
  if toolCalls != nil and toolCalls.kind == JArray and toolCalls.len > 0:
    result["tool_calls"] = toolCalls
  if finishReason.len > 0:
    result["finish_reason"] = %finishReason

proc readFullBody(conn: StreamConn): string =
  ## Drain the response body into a single string. streamhttp's `readLine`
  ## already handles chunked + content-length + until-close decoding, so we
  ## just concatenate every body line until end-of-body. Used by the
  ## non-streaming path where the whole JSON document arrives in one shot.
  var line = ""
  while conn.readLine(line):
    if result.len > 0: result.add "\n"
    result.add line

when httpStub:
  ## Test-only stub for the non-streaming transport. Included here (before
  ## `callHttp`) so `callHttpStub` is in scope at the `callHttp` dispatch
  ## site. Shares this module's scope (`StreamOutcome`,
  ## `buildBatchAssistantMsg`, `parseUsage`, `hookProgress`, etc.) so the
  ## stub returns the same shape the real `callHttp` builds.
  include "../../testdata/stub/http.nim"

proc callHttp(url, key, bodyStr: string; baseLabel: string;
              slurped: var int): StreamOutcome =
  ## Non-streaming companion to `streamHttp`. Posts `bodyStr` (which carries
  ## `"stream": false`) and reads the complete JSON completion in one shot —
  ## no SSE, no recv-loop race. Same `StreamConn` cache and stale-conn retry
  ## as `streamHttp` so connection reuse and interrupt behavior are uniform.
  ##
  ## Why this exists: streamhttp's TLS read path occasionally treats a
  ## zero-length `recv` as clean EOF while OpenSSL still has buffered
  ## records, cutting the SSE stream mid-response (empty 200 replies, ticker
  ## dying after a few tokens). The straight request/response path reads the
  ## full body before returning, so it is immune to that race. Streaming
  ## stays the default for live output; this is the reliable fallback when
  ## `:streaming off` is set.
  when httpStub:
    return callHttpStub(url, key, bodyStr, baseLabel, slurped)
  debugOut "callHttp start"
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
      result.errMsg = InterruptedByUserMsg
      return
    inc attempt
    if cachedStreamConn != nil and cachedStreamHostKey == hostKey:
      conn = cachedStreamConn
    else:
      closeCachedStreamConn()
      try:
        if plainHttp:
          conn = connectPlain(host, port, timeoutMs = ConnectTimeoutMs)
        else:
          conn = connectTls(host, port, timeoutMs = ConnectTimeoutMs,
                            caFile = bundledCaFile())
      except CatchableError as e:
        # Drop the cached IP so the next attempt re-resolves: a stale record
        # pointing at a dead host must not pin every retry.
        invalidateResolved(host, port)
        if isInterrupted():
          result.errMsg = InterruptedByUserMsg
          return
        result.errMsg =
          (if plainHttp: "connect failed: " else: "TLS connect failed: ") &
          connectErrorDetail(e)
        return
      cachedStreamConn = conn
      cachedStreamHostKey = hostKey
      cachedStreamFd = conn.getFd
    conn.setReadTimeoutMs(QuietRecvWakeMs)
    try:
      conn.sendRequest("POST", pathQuery, host,
                       headers = [("Authorization", "Bearer " & key),
                                  ("Content-Type", "application/json"),
                                  ("Accept", "application/json")],
                       body = bodyStr)
      hookProviderActivity()
      while true:
        try:
          resp = conn.readResponseHead()
          break
        except StreamTimeoutError:
          if isInterrupted() or isNetworkQuiet():
            closeCachedStreamConn()
            break
          continue
      if resp.status == 0 and resp.headers.len == 0:
        if isInterrupted():
          result.errMsg = InterruptedByUserMsg
        else:
          result.errMsg = "network quiet for " &
            $(QuietTooLongMs div 1000) & "s)"
        return
      hookProviderActivity()
      break
    except CatchableError as e:
      # Same stale-cache recovery as streamHttp: drop and retry once.
      closeCachedStreamConn()
      if attempt >= 2:
        result.errMsg = "request failed: " & e.msg
        return
  result.statusCode = resp.status
  result.retryAfter = resp.headers.getOrDefault("retry-after")

  var body = ""
  var readErr = ""
  block readLoop:
    while true:
      try:
        body = readFullBody(conn)
        break readLoop
      except StreamTimeoutError:
        if isInterrupted() or isNetworkQuiet():
          closeCachedStreamConn()
          break readLoop
        continue
      except CatchableError as e:
        readErr = e.msg
        closeCachedStreamConn()
        break readLoop
  hookProviderActivity()

  if isNetworkQuiet():
    closeCachedStreamConn()
    result.errMsg = "network quiet for " &
      $(QuietTooLongMs div 1000) & "s)"
    return
  if isInterrupted():
    closeCachedStreamConn()
    result.errMsg = InterruptedByUserMsg
    return
  if readErr.len > 0:
    result.errMsg = "response read: " & readErr
    return

  if result.statusCode != 200:
    result.errBody = body
    return

  # Parse the single JSON completion object.
  let j = try: parseJson(body)
           except CatchableError:
             result.errBody = body
             result.errMsg = "response parse: " & getCurrentExceptionMsg()
             return
  if j == nil or j.kind != JObject:
    result.errBody = body
    result.errMsg = "response not a JSON object"
    return
  let choices = j{"choices"}
  if choices == nil or choices.kind != JArray or choices.len == 0:
    # Provider returned 200 with no choices — usually an inline error body
    # (e.g. z.ai's overloaded message can slip through on some paths).
    result.errBody = body
    if j{"error"} != nil:
      result.errMsg = "api error in 200 body"
    return
  let message = choices[0]{"message"}
  if message == nil or message.kind != JObject:
    result.errBody = body
    result.errMsg = "response missing choices[0].message"
    return
  let content = message{"content"}.getStr("")
  var reasoning = message{"reasoning_content"}.getStr("")
  if reasoning.len == 0: reasoning = message{"reasoning"}.getStr("")
  var toolCalls =
    if message{"tool_calls"} != nil and message{"tool_calls"}.kind == JArray:
      message{"tool_calls"}
    else: newJArray()
  let frNode = choices[0]{"finish_reason"}
  let finishReason =
    if frNode != nil and frNode.kind == JString and frNode.getStr.len > 0:
      frNode.getStr
    else: ""
  result.finishReason = finishReason
  slurped = content.len + reasoning.len
  hookProgress(baseLabel, slurped)

  result.assistantMsg = buildBatchAssistantMsg(content, reasoning, toolCalls, finishReason)
  if result.assistantMsg == nil:
    # No content, no tool_calls, no reasoning, no finish_reason: a genuine
    # transport anomaly (not a budget-starved empty turn). Surface as a
    # retryable transport error so callModel's network retry block handles
    # it. Empty-with-finish_reason is handled above (non-nil msg).
    result.errBody = body
    result.errMsg = "empty reply - no content, no tool calls"
    return
  let u2 = j{"usage"}
  if u2 != nil and u2.kind == JObject:
    result.usage = parseUsage(u2)
  debugOut &"callHttp end content={content.len} tools={toolCalls.len} finishReason={finishReason}"

proc stripInternalFields*(messages: JsonNode): JsonNode =
  ## Return a wire-safe copy of `messages` with internal bookkeeping fields
  ## removed. `usage` is stored on assistant messages for local replay but
  ## rejected by strict validators (fireworks, glm-5p1, etc.). `finish_reason`
  ## is attached to empty assistant turns so the turn loop can branch on it
  ## but is not a wire field. `interrupted` marks user-cancelled turns.
  if messages == nil or messages.kind != JArray: return messages
  result = newJArray()
  for m in messages:
    if m.kind != JObject or
       ("usage" notin m and "interrupted" notin m and "finish_reason" notin m):
      result.add m
      continue
    var clean = newJObject()
    for k, v in m.pairs:
      if k != "usage" and k != "interrupted" and k != "finish_reason":
        clean[k] = v
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
  ## Wire mapping for GLM reasoning. Values are `off`/`on` (4.7/5/5.1) or
  ## `off`/`high`/`max` (5.2 on z.ai). Two control surfaces:
  ## - `thinking.type` ("enabled"/"disabled") on z.ai's first-party API
  ##   (provider names `zai` / `zai-coding`), plus `thinking.effort`
  ##   (`high` default, `max` deeper) on GLM-5.2 only.
  ## - `chat_template_kwargs.enable_thinking` (bool) on vLLM stacks
  ##   (nvidia); other vLLM GLM providers (nebius, deepinfra, fireworks)
  ##   accept the same knob but always think when it's omitted.
  ## Inert stacks (baseten, together, cerebras) accept nothing and always
  ## think, so `off` is silently a no-op there.
  case providerOf(p)
  of "zai", "zai-coding", "zaicode":
    case p.reasoning
    of "off": body["thinking"] = %*{"type": "disabled"}
    of "on": discard
    of "high": body["thinking"] = %*{"type": "enabled"}
    of "max": body["thinking"] = %*{"type": "enabled", "effort": "max"}
    else: discard
  of "nvidia":
    case p.reasoning
    of "off": body["chat_template_kwargs"] = %*{"enable_thinking": false}
    else: discard
  else: discard

proc applyStreamingOptions*(p: Profile, body: JsonNode) =
  ## Provider-specific additions for SSE fidelity.
  ##
  ## Z.ai's first-party API (provider names `zai`, `zai-coding`, `zaicode`)
  ## gets `tool_stream: true`, which streams tool-call arguments as per-token
  ## deltas. This was disabled for a long time as a workaround for a
  ## streamhttp TLS read bug that truncated the per-token deltas mid-stream;
  ## that bug is fixed in streamhttp >= 0.2.0 (the recv loop drains
  ## OpenSSL's internal buffer before polling), so streamed tool args now
  ## arrive complete. Reasoning/thinking streams live regardless (gated by
  ## `stream:true` + `thinking:enabled`, not `tool_stream`).
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
  ## DeepSeek's reasoning surface differs by serving stack. The
  ## first-party API (provider `deepseek`) exposes `thinking.type`
  ## (disabled/enabled/adaptive) plus `reasoning_effort`
  ## (low/medium/high/max/xhigh); only `disabled` is a true off (0
  ## reasoning tokens). Hosted stacks (nebius, baseten, together, ...)
  ## ignore `thinking.type` and expose only `reasoning_effort`
  ## (low/medium/high), vLLM-style, behaving like gpt-oss. Temperature
  ## is pinned to 0.0 on the first-party API for deterministic coding
  ## output.
  case providerOf(p)
  of "deepseek":
    ## First-party API: thinking.type (disabled/enabled/adaptive) plus
    ## reasoning_effort (low/medium/high/max/xhigh). disabled is the
    ## only true off (0 reasoning tokens); enabled engages heavy
    ## reasoning regardless of effort level. Temperature 0.0 for
    ## deterministic coding output.
    case p.reasoning
    of "low":
      body["thinking"] = %*{"type": "disabled"}
      body["temperature"] = %0.0
    of "medium":
      body["thinking"] = %*{"type": "enabled"}
      body["reasoning_effort"] = %"medium"
      body["temperature"] = %0.0
    of "high":
      body["thinking"] = %*{"type": "enabled"}
      body["reasoning_effort"] = %"high"
      body["temperature"] = %0.0
    else: discard
  else:
    ## Hosted stacks (nebius, baseten, together, deepinfra, fireworks,
    ## sambanova) ignore thinking.type and expose only reasoning_effort
    ## (low/medium/high), vLLM-style. Behaves like gpt-oss.
    body["reasoning_effort"] = %p.reasoning

proc applyMinimaxReasoning(p: Profile, body: JsonNode) =
  ## MiniMax M-series reasoning toggle on the OpenAI-compatible endpoint
  ## (api.minimax.io/v1) and vLLM stacks (nvidia, fireworks, together,
  ## deepinfra, sambanova). The knob is the vLLM-style
  ## `chat_template_kwargs.enable_thinking`:
  ## - M2.x (v2.5, v2.7) is a reasoning-only model: enable_thinking=true
  ##   engages interleaved reasoning, enable_thinking=false cuts it off.
  ## - M3 (frontier) defaults to thinking on; the knob is the same shape
  ##   and works the same way. Anthropic-protocol deployments
  ##   (api.minimax.io/anthropic) also accept
  ##   `thinking.type = "enabled"/"disabled"`, but we only talk to the
  ##   OpenAI-compatible surface, so the vLLM knob is what we send.
  ##
  ## Allowed values are `on` / `off` (set via `:reasoning`). The model
  ## has no graded effort knob on this surface — `low/medium/high` are
  ## rejected by `knownGoodReasonings` for the minimax family and are
  ## only available to unknown models under `--experimental`.
  ##
  ## `reasoning_split = true` (top-level body field) is hardcoded: it
  ## tells the model to return thinking content as a separate
  ## `reasoning_details` block instead of leaking it into the
  ## `content` stream as `<think>...</think>` tags. Without it, the
  ## model's interleaved thinking shows up inline in the visible text
  ## and pollutes both the UI transcript and any text the harness hands
  ## to tools that don't expect it. The split field is also part of
  ## the official Anthropic-compatible format, which the harness
  ## already relies on for the round-trip (the assistant message must
  ## come back with reasoning preserved on history replay).
  case p.reasoning
  of "off":
    body["chat_template_kwargs"] = %*{"enable_thinking": false}
  of "on":
    body["chat_template_kwargs"] = %*{"enable_thinking": true}
  else: discard
  body["reasoning_split"] = %true

proc applyLongcatReasoning(p: Profile, body: JsonNode) =
  ## LongCat-2.0 toggles reasoning via `thinking.type`, a binary
  ## enabled/disabled flag. The default deploy reasons unconditionally,
  ## so `off` must send `{"type": "disabled"}`; `on` relies on the
  ## server default and sends nothing.
  case p.reasoning
  of "off":
    body["thinking"] = %*{"type": "disabled"}
  of "on": discard
  else: discard

proc applyKimiReasoning(p: Profile, body: JsonNode) =
  ## Kimi K2.x is served on vLLM stacks (nebius, together, deepinfra,
  ## baseten, fireworks) and toggles reasoning via
  ## `chat_template_kwargs.enable_thinking`. Most stacks default to
  ## thinking-on (and nebius always reasons regardless of the flag);
  ## baseten defaults off. `on` sends enable_thinking=true, `off` sends
  ## false (inert on nebius, which can't be turned off).
  case p.reasoning
  of "off":
    body["chat_template_kwargs"] = %*{"enable_thinking": false}
  of "on":
    body["chat_template_kwargs"] = %*{"enable_thinking": true}
  else: discard

proc applyHy3Reasoning(p: Profile, body: JsonNode) =
  ## Hy3 (Tencent Hunyuan v3) carries a graded effort knob, not a binary
  ## switch. Values are `no_think` (default direct response), `low`, and
  ## `high`, driven by `:reasoning`. Two wire surfaces:
  ## - vLLM stacks (novita, nvidia, ...): `chat_template_kwargs` with the
  ##   `reasoning_effort` key, matching Hy3's own chat template
  ##   (`reasoning_effort not in ['high', 'low', 'no_think']` raises).
  ## - OpenRouter: normalized `reasoning.effort` (same three levels).
  ## Empty `p.reasoning` means "no wire param" — the server default
  ## (`no_think`) applies, which is the intended cheap path.
  if p.reasoning == "": return
  case providerOf(p)
  of "openrouter":
    body["reasoning"] = %*{"effort": p.reasoning}
  else:
    body["chat_template_kwargs"] = %*{"reasoning_effort": p.reasoning}

proc applyReasoning*(p: Profile, body: JsonNode) =
  ## Per-family wire mapping for `Profile.reasoning`. Adding a new
  ## family means: (1) set `reasoning` in the known-good combo table,
  ## (2) write an `applyXReasoning` proc, (3) add a case branch.
  case p.family
  of "gpt-oss": applyGptOssReasoning(p, body)
  of "glm": applyGlmReasoning(p, body)
  of "deepseek": applyDeepseekReasoning(p, body)
  of "minimax": applyMinimaxReasoning(p, body)
  of "kimi": applyKimiReasoning(p, body)
  of "longcat": applyLongcatReasoning(p, body)
  of "hy": applyHy3Reasoning(p, body)
  else: discard

# ---------- network worker thread (Tier 2) ----------
#
# `streamHttp` fires deltas into a `NetJob` instead of calling hooks. The
# worker runs `streamHttp`; the main thread drains and replays the deltas
# through the (unchanged) hook layer on a ~50ms cadence, keeping the UI
# responsive while the blocking recv loop runs off-thread.
#
# ORC constraint: the worker holds no closures and no refs the main thread
# also mutates. The `NetJobState` is a stack var whose lifetime encloses the
# worker's run; the only ref handed across is the final `assistantMsg`
# `JsonNode`, built solely by the worker and read once by main after join.

const NetWorkerPollMs = 50

type
  NetWorkerArgs = object
    job: NetJob
    url: string
    key: string
    bodyStr: string
    baseLabel: string
    suppressXml: bool

proc networkWorker(a: NetWorkerArgs) {.thread.} =
  ## Runs the full connect+send+SSE loop on a worker thread. Fires deltas
  ## into `job`; publishes the outcome and sets phase=npDone on exit.
  ## GC-safe cast is valid: only this worker touches the module-global
  ## connection cache during a call (calls are serialized one at a time),
  ## and the NetJobState is a stack var whose lifetime encloses this run.
  {.cast(gcsafe).}:
    setPhase(a.job, npConnecting)
    var slurped = 0
    var outcome = streamHttp(a.url, a.key, a.bodyStr, a.baseLabel, slurped,
                             a.suppressXml, a.job)
    # The StreamConn is a ref with internal cycles (Socket + SslContext).
    # Under ORC, freeing it from a different thread than the one that
    # allocated it segfaults the cycle collector. The worker owns the
    # entire connection lifecycle: always close and clear here, on this
    # thread, before returning. This sacrifices cross-turn connection
    # reuse on the threaded path (acceptable for Tier 2; the TLS handshake
    # cost is regained in responsiveness).
    closeCachedStreamConn()
    # Serialize the assistant message and drop the ref before publishing.
    # JsonNode trees form cycles; a ref built on this thread and freed on
    # the main thread after join corrupts ORC's cycle tracker. The string
    # crosses safely; main parses it back into a fresh node.
    if outcome.assistantMsg != nil:
      outcome.assistantMsgJson = $outcome.assistantMsg
      outcome.assistantMsg = nil
    publishOutcome(a.job, outcome)

proc drainAndDispatch(job: NetJob; baseLabel: string) =
  ## Copy unconsumed deltas under the lock, then replay them through the
  ## real hook callbacks on the main thread. Ordering is preserved because
  ## the worker appends in order and we drain in order.
  var batch: seq[NetDelta]
  drainDeltas(job, batch)
  for d in batch:
    case d.kind
    of ndkActivity:
      hookProviderActivity()
    of ndkProgress:
      hookProgress(baseLabel, d.slurped)
    of ndkReasoning:
      hookReasoningDelta(d.reasoning, baseLabel, d.reasoningSlurped, true)
    of ndkContent:
      discard hookContentDelta(d.content, baseLabel, d.contentSlurped)
    of ndkContentFinished:
      discard hookContentFinished(d.fullContent, baseLabel, d.finishedSlurped)
    of ndkTrimTrailing:
      hookTrimTrailingContent(d.trimFullContent, baseLabel, d.trimSlurped)
    of ndkAfterLive:
      hookAfterLiveContent(baseLabel, d.afterSlurped)

proc callModelThreaded*(p: Profile, bodyStr, baseLabel: string;
                        suppressXml: bool): StreamOutcome =
  ## The threaded streaming path. Spawns a worker to run `streamHttp`, polls
  ## the shared state on a ~50ms cadence to replay deltas through the hooks,
  ## and joins the worker once it signals done (or the user interrupts).
  var job: NetJobState
  job.lock.initLock()
  defer: job.lock.deinitLock()
  var t: Thread[NetWorkerArgs]
  let args = NetWorkerArgs(
    job: addr job,
    url: p.url & "/chat/completions",
    key: p.key,
    bodyStr: bodyStr,
    baseLabel: baseLabel,
    suppressXml: suppressXml)
  createThread(t, networkWorker, args)
  while job.phase != npDone and not isInterrupted():
    drainAndDispatch(addr job, baseLabel)
    sleep(NetWorkerPollMs)
  if isInterrupted():
    shutdownCachedStreamFd()
  # Bounded join: every worker syscall is bounded (connect by
  # ConnectTimeoutMs, recv by QuietRecvWakeMs, TLS handshake internally),
  # so the worker returns within a known worst case. The one exception is
  # a first-time getAddrInfo wedge (documented, accepted): if the poll
  # times out we detach rather than block forever.
  var waited = 0
  let joinBudget = ConnectTimeoutMs + QuietTooLongMs + 5_000
  while t.running() and waited < joinBudget:
    sleep(NetWorkerPollMs)
    waited += NetWorkerPollMs
  if t.running():
    discard
  else:
    joinThread(t)
  drainAndDispatch(addr job, baseLabel)
  if job.outcomeWritten:
    result = job.outcome
    if result.assistantMsgJson.len > 0:
      result.assistantMsg = parseJson(result.assistantMsgJson)
      result.assistantMsgJson = ""

when providerStub:
  ## Test-only stub provider. Lives in `testdata/stub/provider.nim` and is
  ## `include`d here so it shares this module's scope (private hook
  ## callbacks, retry state, `ApiError`, etc.) without exporting them.
  include "../../testdata/stub/provider.nim"

proc callModel*(p: Profile, messages: JsonNode, usage: var Usage,
    lastPromptTokens: int, maxTokensOverride = 0): JsonNode =
  ## `maxTokensOverride`, when > 0, replaces the known-good `max_tokens` in
  ## the request body. Used by the turn loop's empty-content auto-handling
  ## to escalate the budget when a `finish_reason: "length"` reply starved
  ## on reasoning tokens. The body is rebuilt fresh on every callModel so
  ## an override takes effect without rebuilding anything externally.
  when providerStub:
    return callModelStub(p, messages, usage, lastPromptTokens, maxTokensOverride)
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
    "stream": streamingEnabled,
  }
  # `stream_options.include_usage` is a streaming-only field; non-streaming
  # completions always carry `usage` in the response body. Fireworks rejects
  # the field outright, so it is gated on both streaming and provider.
  if streamingEnabled and providerOf(p) != "fireworks":
    body["stream_options"] = %*{"include_usage": true}
  body["tools"] = setup(p).tools
  body["tool_choice"] = %"auto"
  applyStreamingOptions(p, body)
  applyGenerationDefaults(p, body)
  if maxTokensOverride > 0:
    body["max_tokens"] = %maxTokensOverride
  if p.reasoning.len > 0:
    applyReasoning(p, body)
  let bodyStr = sanitizeUtf8($body)
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
  let window = contextWindowFor(p)
  let baseLabel = hookBeforeCall(lastPromptTokens, window)
  # Cursor is hidden for the duration of the entire turn by `runTurns`
  # so the prompt placeholder is the only visible caret. callModel
  # itself doesn't toggle visibility — touching DECTCEM here would
  # cause a flicker between callModel iterations within a turn.
  defer:
    hookAfterCall()
  const MaxAttempts = 12
  const networkSync {.booldefine.} = false
    ## Fallback switch for the streaming transport. Default (false) runs
    ## the blocking recv loop on a worker thread so the UI stays
    ## responsive. Set `-d:networkSync=true` to run it inline on the main
    ## thread (the old behavior) for debugging.
  var outcome: StreamOutcome
  var attempt = 0
  while true:
    inc attempt
    var slurped = 0
    outcome =
      if streamingEnabled:
        when networkSync:
          var syncJob: NetJobState
          syncJob.lock.initLock()
          defer: syncJob.lock.deinitLock()
          let o = streamHttp(p.url & "/chat/completions", p.key, bodyStr,
                             baseLabel, slurped, xmlToolCallsFallback(p),
                             addr syncJob)
          drainAndDispatch(addr syncJob, baseLabel)
          o
        else:
          callModelThreaded(p, bodyStr, baseLabel, xmlToolCallsFallback(p))
      else:
        callHttp(p.url & "/chat/completions", p.key, bodyStr,
                 baseLabel, slurped)
    if isInterruptedMsg(outcome.errMsg):
      hookStopSpinner()
      if outcome.assistantMsg == nil:
        raise newException(ApiError, InterruptedByUserMsg)
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
          errMsg & (if outcome.errBody.len > 0: ": " & extractErrorMsg(outcome.errBody) else: ""))
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
        errMsg & (if outcome.errBody.len > 0: ": " & extractErrorMsg(outcome.errBody) else: ""))
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
    let body = extractErrorMsg(outcome.errBody)
    let detail = if body.len > 0: body else: errMsg
    let codeLabel = if code != 0: $(code) & ": " else: ""
    hookRetryNotice codeLabel & detail & ". retry " & $(attempt + 1) &
      "/" & $MaxAttempts & " in " & $backoff & "s"
    block wait:
      var remaining = backoff * 1000
      while remaining > 0:
        if isInterrupted(): break wait
        let step = min(100, remaining)
        sleep(step)
        remaining -= step
    if isInterrupted():
      raise newException(ApiError, "interrupted by user during retry backoff")
    clearNetworkQuiet()
    # don't set retry as status lable- it's show as message
    #hookSetStatusLabel(&"retry {attempt + 1}/{MaxAttempts}")
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
    # so the next user-submit's receipt repaints this row (cyan) with
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
    if isStubUrl(p.url):
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
    if isStubUrl(url):
      return (stubModels(), "")
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
