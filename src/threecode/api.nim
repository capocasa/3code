import std/[algorithm, atomics, httpclient, json, locks, os, osproc, sequtils, streams, strformat, strutils, tables, terminal, times]
import types, util, prompts, compact

# ---------- Spinner ----------

var interrupted*: bool = false
  ## Set by the SIGINT hook. Checked between model/tool steps and during HTTP
  ## polling / retry backoff so ctrl-c drops back to the prompt without
  ## killing the process.

var contentStreamedLive*: bool = false
  ## Set by `callModel` when the assistant's text content has been streamed
  ## to stdout chunk-by-chunk during the SSE read; read (and reset) by
  ## `runTurns` so the same content isn't redrawn a second time at the end
  ## of the turn.

var showThinking*: bool = true
  ## When true, reasoning_content deltas from the provider are rendered as
  ## a one-line ticker embedded in the spinner label. Flipped by `:think on`
  ## / `:think off`. Has no effect if the provider doesn't emit reasoning.

var spinnerStop: Atomic[bool]
var spinnerThread: Thread[string]

# Shared mutable spinner state. The spinner thread reads these every frame;
# the main thread updates them as chunks arrive. Two separate lines:
#   line 1 = the classic spinner (frame + label + elapsed seconds)
#   line 2 = the reasoning ticker, dim, empty when no thinking is streaming
# Both fields live under one lock for simplicity — writes are infrequent.
var
  spinLabelLock: Lock
  spinLabelShared: string
  spinTickerShared: string
spinLabelLock.initLock()

proc setSpinLabel(s: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire spinLabelLock
    spinLabelShared = s
    release spinLabelLock

proc getSpinLabel(): string {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire spinLabelLock
    result = spinLabelShared
    release spinLabelLock

proc setSpinTicker(s: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire spinLabelLock
    spinTickerShared = s
    release spinLabelLock

proc getSpinTicker(): string {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire spinLabelLock
    result = spinTickerShared
    release spinLabelLock

proc spinnerLoop(unused: string) {.thread.} =
  const frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  let start = epochTime()
  var i = 0
  var tickerActive = false  # whether we reserved line 2 below
  while not spinnerStop.load(moRelaxed):
    let elapsed = epochTime() - start
    let label = getSpinLabel()
    let ticker = getSpinTicker()
    try:
      # Line 1: clear and redraw. \x1b[2K keeps ghost chars from stale labels
      # out of view when the label shrinks.
      stdout.styledWrite "\r\x1b[2K", fgCyan, styleBright, frames[i mod frames.len], resetStyle,
        fgCyan, styleBright, &"  {label} {elapsed.int}s", resetStyle
      if ticker.len > 0:
        # Two-line mode: descend to line 2, render dim ticker, return to
        # line 1 start so the next frame's \r lines up.
        stdout.write "\n\x1b[2K\x1b[2m"
        stdout.write ticker
        stdout.write "\x1b[0m\r\x1b[1A"
        tickerActive = true
      elif tickerActive:
        # Ticker went empty (e.g. content started) — clear the line below
        # once and stop reserving it.
        stdout.write "\n\x1b[2K\r\x1b[1A"
        tickerActive = false
      stdout.flushFile
    except CatchableError: discard
    sleep 80
    inc i
  try:
    # Clean up: clear line 1; if we were in two-line mode, also line 2.
    stdout.write "\r\x1b[2K"
    if tickerActive:
      stdout.write "\n\x1b[2K\r\x1b[1A"
    stdout.flushFile
  except CatchableError: discard

proc contextLabel*(promptTokens, window: int): string =
  ## "○ 12%" / "◔ 25%" / … / "● 92%" — same shape used by the live spinner
  ## indicator and the final per-turn token line. Empty string when there's
  ## no useful context number (no window, or no tokens yet).
  if window <= 0 or promptTokens <= 0: return ""
  let pct = int(promptTokens.float / window.float * 100.0)
  let glyph =
    if pct < 20: "○"
    elif pct < 40: "◔"
    elif pct < 60: "◑"
    elif pct < 80: "◕"
    else: "●"
  &"{glyph} {pct}%"

proc liveLabel*(base: string, slurped: int): string =
  ## Spinner label whose token slots match the per-call summary's shape:
  ## icon hugs value, slots joined with extra space (no `·`), ↑/↺ render
  ## as dashes until the response closes (the only place a dash means
  ## "not yet known" rather than "actually zero"). The whole label is
  ## rendered by the spinner thread in fgCyan + styleBright; the
  ## placeholders share that intensity so ↑/↺ stay visible alongside ↓.
  let up = "↑ -"
  let cached = "↺ -"
  let down = tokenSlot("↓", slurped div 4)
  if base.len > 0: base & "   " & up & "   " & cached & "   " & down
  else: up & "   " & cached & "   " & down


var spinnerRunning = false  # only mutated by main thread

proc startSpinner*(label: string) =
  if spinnerRunning: return
  if label.len > 0: setSpinLabel(label)
  spinnerStop.store(false, moRelaxed)
  createThread(spinnerThread, spinnerLoop, "")
  spinnerRunning = true

proc stopSpinner*() =
  if not spinnerRunning: return
  spinnerStop.store(true, moRelaxed)
  joinThread(spinnerThread)
  spinnerRunning = false

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

# ---- Streaming HTTP via curl subprocess ----
#
# Nim's sync httpclient can't stream; its async one is awkward to mix with
# our threaded spinner. `curl --no-buffer` with SSE does streaming cleanly,
# gives us TLS for free, and dies on SIGINT without any extra plumbing
# (terminal SIGINT reaches the whole foreground process group). The
# subprocess reads its body from a file to sidestep shell quoting, and a
# trailing `-w` marker line carries the HTTP status back after the body.
type StreamOutcome = object
  statusCode: int
  retryAfter: string
  errMsg: string          # non-empty on transport-level failure
  errBody: string         # non-SSE response body (error responses)
  assistantMsg: JsonNode  # reconstructed from SSE when status=200
  usage: Usage

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

proc streamHttp(url, key, bodyStr: string, baseLabel: string,
                slurped: var int): StreamOutcome =
  # Post `bodyStr` to `url` and consume SSE chunks until `[DONE]`. `slurped`
  # accumulates an approximate output-character count so the caller can
  # show a live "↓ Nk" on the spinner; update it inline as chunks arrive.
  let tmp = getTempDir() / ("3code_stream_" & $getCurrentProcessId() & "_" & $epochTime().int64)
  createDir(tmp)
  let bodyFile = tmp / "body.json"
  writeFile(bodyFile, bodyStr)
  defer: (try: removeDir(tmp) except CatchableError: discard)

  let args = @[
    "--no-buffer", "-sS", "-X", "POST",
    "-H", "Authorization: Bearer " & key,
    "-H", "Content-Type: application/json",
    "-H", "Accept: text/event-stream",
    "--max-time", "1200",
    "-w", "\n<<3CODE_STATUS>>%{http_code}\n<<3CODE_RETRY>>%header{retry-after}\n",
    "--data-binary", "@" & bodyFile,
    url
  ]

  var p: Process
  try:
    p = startProcess("curl", args = args,
                     options = {poUsePath, poStdErrToStdOut})
  except OSError as e:
    result.errMsg = "curl launch failed: " & e.msg
    return

  var accContent = ""
  var accReasoning = ""
  var accTools = initOrderedTable[int, JsonNode]()
  var nonSSE: seq[string]
  var contentStarted = false
  # Ticker state: the full reasoning text is retained in `accReasoning` (so
  # it can be echoed back to the provider — DeepSeek rejects follow-up
  # requests that drop reasoning_content); the ticker display only shows
  # the tail that fits on one line. Updates are throttled to ~10Hz.
  var lastTickerUpdate = 0.0
  proc refreshTicker() =
    let now = epochTime()
    if now - lastTickerUpdate < 0.1: return
    lastTickerUpdate = now
    let termW = try: terminalWidth() except CatchableError: 80
    let budget = max(20, termW - 6)  # leave margin for indent + glyph
    # flatten newlines for single-line display without mutating accReasoning
    let tail =
      if accReasoning.len > budget: accReasoning[accReasoning.len - budget .. ^1]
      else: accReasoning
    var flat = newStringOfCap(tail.len)
    for ch in tail:
      flat.add(if ch == '\n' or ch == '\r': ' ' else: ch)
    setSpinTicker("  … " & flat)
  # Agent text streams at column 0 with no icon. `fgYellow + styleDim`
  # reads as a soft off-white / very light cream — distinct from user
  # input (terminal default ≈ bright white) and from the dim greyish-
  # cyan used for harness FYI text.
  #
  # Line buffering layers markdown rendering on top:
  #   - tables (`| a | b |` rows) buffer into `tableBuf`, flush as
  #     box-drawn blocks once a non-table line arrives — sub-second
  #     beat for typical 5-20 row tables, but it's the price of
  #     column-width-aware alignment.
  #   - code blocks (between ``` fences) buffer into `codeBuf`, render
  #     with a dim left bar `┃` per line, fences themselves suppressed.
  #   - headers (`# H` … `###### H`) render as bold cream, hashes
  #     stripped.
  #   - inline `**bold**` and `` `code` `` substituted via ANSI flips
  #     inside the cream envelope. Strict matching only — malformed
  #     markers pass through raw.
  var pendingLine = ""
  var tableBuf: seq[string]
  var codeBuf: seq[string]
  var inCode = false
  # The lead bullet is printed at column 0 without a trailing newline,
  # so the first emitted line of content starts on the same row. Track
  # whether the next emit is the first; suppress the 2-space indent for
  # that one only. Block constructs (code/table) close the bullet line
  # with a newline before they render their own indented body.
  var firstEmit = false
  proc emitLine(l: string) =
    let termW = try: terminalWidth() except CatchableError: 80
    let bodyW = max(20, termW - 2)
    let chunks = wrapAnsi(applyInlineMd(l), bodyW)
    var k = 0
    for chunk in chunks:
      let prefix = if firstEmit and k == 0: "" else: "  "
      stdout.styledWrite(fgWhite, styleDim, prefix & chunk & "\n", resetStyle)
      inc k
    firstEmit = false
  proc emitHeader(text: string) =
    let termW = try: terminalWidth() except CatchableError: 80
    let bodyW = max(20, termW - 2)
    let chunks = wrapAnsi(text, bodyW)
    var k = 0
    for chunk in chunks:
      let prefix = if firstEmit and k == 0: "" else: "  "
      stdout.styledWrite(fgWhite, styleBright, prefix & chunk & "\n", resetStyle)
      inc k
    firstEmit = false
  proc emitCodeLine(l: string) =
    if firstEmit:
      stdout.write "\n"
      firstEmit = false
    stdout.styledWrite(styleDim, "  ┃ ", resetStyle)
    stdout.styledWrite(fgWhite, styleDim, l & "\n", resetStyle)
  proc flushTable() =
    if tableBuf.len == 0: return
    if firstEmit:
      stdout.write "\n"
      firstEmit = false
    if tableBuf.len < 2:
      for r in tableBuf: emitLine(r)
    else:
      let termW = try: terminalWidth() except CatchableError: 80
      let rendered = renderMdTable(tableBuf, maxWidth = termW)
      stdout.styledWrite(fgWhite, styleDim, rendered, resetStyle)
    tableBuf.setLen 0
  proc flushCode() =
    if codeBuf.len == 0: return
    for l in codeBuf: emitCodeLine(l)
    codeBuf.setLen 0
  proc handleLine(l: string) =
    if inCode:
      if isMdFenceLine(l):
        flushCode()
        inCode = false
      else:
        codeBuf.add l
      return
    if isMdFenceLine(l):
      flushTable()
      inCode = true
      return
    if isMdTableRow(l):
      tableBuf.add l
      return
    flushTable()
    let (isHdr, hdrText) = detectMdHeader(l)
    if isHdr:
      emitHeader(hdrText)
    else:
      emitLine(l)
  proc emitContent(c: string) =
    for ch in c:
      if ch == '\n':
        handleLine(pendingLine)
        pendingLine = ""
      else:
        pendingLine.add ch
  proc finishContent() =
    if pendingLine.len > 0:
      handleLine(pendingLine)
      pendingLine = ""
    flushCode()
    flushTable()
  let outS = p.outputStream
  var line = ""
  while outS.readLine(line):
    if interrupted:
      try: p.terminate() except OSError: discard
      break
    if line.startsWith("data: "):
      let payload = line["data: ".len .. ^1]
      if payload.strip == "[DONE]": continue
      let j = try: parseJson(payload) except CatchableError: continue
      let choices = j{"choices"}
      if choices != nil and choices.kind == JArray and choices.len > 0:
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
            if showThinking and not contentStarted:
              refreshTicker()
          let c = delta{"content"}.getStr("")
          if c.len > 0:
            if not contentStarted:
              # Stop the spinner and emit the answer bullet at column 0
              # without a newline; the first content line lands on the same
              # row right after `● `, subsequent lines indent two spaces.
              setSpinTicker("")
              stopSpinner()
              stdout.styledWrite(fgWhite, styleBright, "● ", resetStyle)
              contentStarted = true
              firstEmit = true
            accContent &= c
            slurped += c.len
            emitContent(c)
            stdout.flushFile()
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
                setSpinLabel(liveLabel(baseLabel, slurped))
      let u = j{"usage"}
      if u != nil and u.kind == JObject:
        result.usage = parseUsage(u)
    elif line.startsWith("<<3CODE_STATUS>>"):
      let s = line["<<3CODE_STATUS>>".len .. ^1].strip
      result.statusCode = try: parseInt(s) except ValueError: 0
    elif line.startsWith("<<3CODE_RETRY>>"):
      result.retryAfter = line["<<3CODE_RETRY>>".len .. ^1].strip
    elif line.startsWith("event:") or line.strip.len == 0 or
         line.startsWith(": "):  # SSE comment
      discard
    else:
      nonSSE.add line

  let exitCode =
    try: p.waitForExit()
    except OSError: -1
  try: p.close() except OSError: discard

  if contentStarted:
    finishContent()
    # Collapse trailing blank lines so the token line below sits flush
    # against the last visible content line. accContent's trailing \n
    # count is used as a proxy for emitted blank lines (rendered tables
    # always close with a single \n, so this still works when the last
    # content was a table block).
    var trailingNl = 0
    for i in countdown(accContent.len - 1, 0):
      if accContent[i] == '\n': inc trailingNl
      else: break
    if trailingNl > 1:
      for _ in 0 ..< trailingNl - 1:
        stdout.write "\x1b[1A\x1b[2K"
    stdout.flushFile()
    contentStreamedLive = true

  if interrupted:
    result.errMsg = "interrupted by user"
    return
  if exitCode != 0 and exitCode != -1:
    result.errMsg = "curl exit " & $exitCode &
      (if nonSSE.len > 0: ": " & nonSSE.join("\n") else: "")
    return

  # Build assistant message if we saw any SSE content.
  if accContent.len > 0 or accTools.len > 0 or accReasoning.len > 0 or
     result.usage.totalTokens > 0:
    var msg = %*{"role": "assistant", "content": accContent}
    # DeepSeek-R1-style reasoning models REQUIRE the `reasoning_content`
    # field on every assistant message in history — even when the model
    # emitted no reasoning on that turn. Drop it and the next API call
    # fails with `invalid_request_error`. Always set it; other providers
    # ignore the extra field.
    msg["reasoning_content"] = %accReasoning
    if accTools.len > 0:
      var tcArr = newJArray()
      var keys = toSeq(accTools.keys).sorted
      for k in keys: tcArr.add accTools[k]
      msg["tool_calls"] = tcArr
    result.assistantMsg = msg
  else:
    # No SSE data — provider may have returned a plain JSON error body.
    result.errBody = nonSSE.join("\n")

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

template hint(args: varargs[untyped]) =
  stdout.styledWrite(fgCyan, styleBright, args, resetStyle)

proc callModel*(p: Profile, messages: JsonNode, usage: var Usage, lastPromptTokens: int): JsonNode =
  ensureReasoningField(messages)
  var body = %*{
    "model": p.modelPrefix & p.model,
    "messages": messages,
    "stream": true,
    "stream_options": {"include_usage": true}
  }
  body["tools"] = setup(p).tools
  body["tool_choice"] = %"auto"
  let bodyStr = $body
  let t0 = epochTime()
  decayLevel(serverRetryLevel, serverLastTs, t0)
  decayLevel(rateRetryLevel, rateLastTs, t0)
  let window = contextWindowFor(p.model)
  let baseLabel = contextLabel(lastPromptTokens, window)
  # Blank line above the upcoming spinner / bullet so the assistant
  # output isn't flush against the prior content (user prompt or last
  # tool output line). Done once per call — retries reuse the same row.
  stdout.write "\n"
  setSpinLabel(liveLabel(baseLabel, 0))
  startSpinner("")
  const MaxAttempts = 8
  var outcome: StreamOutcome
  var attempt = 0
  while true:
    inc attempt
    var slurped = 0
    outcome = streamHttp(p.url & "/chat/completions", p.key, bodyStr,
                        baseLabel, slurped)
    if outcome.errMsg == "interrupted by user":
      stopSpinner()
      raise newException(ApiError, "interrupted by user")
    let netFailed = outcome.errMsg != "" and outcome.assistantMsg == nil
    let code = outcome.statusCode
    let category =
      if netFailed: "server"
      else:
        case code
        of 0: (if outcome.assistantMsg != nil: "" else: "server")
        of 200: ""
        of 429: "rate"
        of 500, 502, 503, 504: "server"
        else: ""
    let retryable = category != ""
    var errMsg = outcome.errMsg
    if errMsg == "" and retryable: errMsg = "api " & $code
    if not retryable:
      stopSpinner()
      if outcome.assistantMsg == nil:
        raise newException(ApiError,
          errMsg & (if outcome.errBody.len > 0: ": " & outcome.errBody else: ""))
      break
    if attempt >= MaxAttempts:
      stopSpinner()
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
    stopSpinner()
    stderr.writeLine &"3code: {errMsg}; retry {attempt + 1}/{MaxAttempts} in {backoff}s"
    block wait:
      var remaining = backoff * 1000
      while remaining > 0:
        if interrupted: break wait
        let step = min(100, remaining)
        sleep(step)
        remaining -= step
    if interrupted:
      raise newException(ApiError, "interrupted by user during retry backoff")
    setSpinLabel(&"retry {attempt + 1}/{MaxAttempts}")
    startSpinner("")
    if category == "rate":
      inc rateRetryLevel
      rateLastTs = epochTime()
    else:
      inc serverRetryLevel
      serverLastTs = epochTime()
  usage = outcome.usage
  let elapsed = epochTime() - t0
  if usage.totalTokens > 0:
    let fresh = max(0, usage.promptTokens - usage.cachedTokens)
    let ctx = contextLabel(usage.promptTokens, window)
    let line =
      (if ctx.len > 0: ctx & "   " else: "") &
      tokenSlot("↑", fresh) &
      "   " & tokenSlot("↺", usage.cachedTokens) &
      "   " & tokenSlot("↓", usage.completionTokens) &
      "   " & $elapsed.int & "s"
    stdout.styledWrite(styleDim, "  " & line, resetStyle, "\n")
    if window > 0 and usage.promptTokens.float > 0.7 * window.float and
       usage.promptTokens.float <= CompactThresholdFrac * window.float:
      stdout.styledWriteLine(styleDim,
        &"  · context at {humanTokens(usage.promptTokens)}/{humanTokens(window)} — auto-compaction will fire near {humanTokens(int(CompactThresholdFrac * window.float))}; :compact or :summarize to act now",
        resetStyle)
  else:
    hint &"  · {elapsed.int}s", resetStyle, "\n"
  stdout.flushFile
  outcome.assistantMsg

proc verifyProfile*(p: Profile): (bool, string) =
  let client = newHttpClient(timeout = 20000)
  defer: client.close()
  client.headers = newHttpHeaders({
    "Authorization": "Bearer " & p.key,
    "Content-Type": "application/json"
  })
  let body = $(%*{
    "model": p.modelPrefix & p.model,
    "messages": [%*{"role": "user", "content": "ping"}],
    "max_tokens": 1,
    "stream": false
  })
  try:
    let r = client.request(p.url & "/chat/completions", HttpPost, body)
    if r.code == Http200:
      let j = try: parseJson(r.body)
              except CatchableError: return (false, "bad json in response")
      if "error" in j: return (false, $j["error"])
      return (true, "")
    let snip = r.body[0 ..< min(200, r.body.len)]
    return (false, $r.code & ": " & snip)
  except CatchableError as e:
    return (false, e.msg)

proc fetchModels*(url, key: string): seq[string] =
  ## GET /models on the provider — that endpoint name is OpenAI's; what it
  ## returns is the list of model ids this provider exposes.
  let client = newHttpClient(timeout = 20000)
  defer: client.close()
  client.headers = newHttpHeaders({"Authorization": "Bearer " & key})
  try:
    let r = client.request(url & "/models", HttpGet)
    if r.code != Http200: return @[]
    let j = try: parseJson(r.body) except CatchableError: return @[]
    let arr = if j.kind == JArray: j
              elif "data" in j and j["data"].kind == JArray: j["data"]
              else: return @[]
    for item in arr:
      if item.kind == JString: result.add item.getStr
      elif item.kind == JObject and "id" in item: result.add item["id"].getStr
  except CatchableError:
    return @[]

proc installInterruptHook*() =
  setControlCHook(proc() {.noconv.} = interrupted = true)
