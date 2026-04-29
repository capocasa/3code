import std/[algorithm, atomics, json, locks, os, osproc, sequtils, streams, strformat, strutils, tables, terminal, times]
import types, util, prompts, compact, display, statusbar

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

var pendingHint*: tuple[active: bool, usage: Usage, window: int, elapsed: int]
  ## Carries the previous turn's accurate token usage forward so the
  ## **token receipt** can be rendered at the start of the next
  ## user-driven turn instead of at the end of the call that produced
  ## the data. Lets the **token bar** drawn by `streamHttp` stay
  ## visible as the per-turn record while the user reads/types; the
  ## receipt only "settles" once the next user message hits
  ## `runTurns` → `settlePendingHint`. Cleared after rendering.
  ## (See `## Token UI` in `CLAUDE.md` for the full lifecycle.)

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
  ## Status-bar mode: writes the animated frame to the **token bar**
  ## row (H-1) via `writeAtBar`. While reasoning is streaming, the
  ## bar slot temporarily shows the reasoning ticker instead of the
  ## token slots — the next frame after `setSpinTicker("")` repaints
  ## the slots back, so no row reservation is needed for thinking.
  ##
  ## Fallback (no status bar — non-TTY or terminal too small): writes
  ## inline using \r overwrite of the current row (legacy behavior,
  ## still uses a second row below for the ticker since we don't have
  ## anchored slots there).
  const frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  let start = epochTime()
  var i = 0
  var tickerActive = false  # inline-mode only; tracks 2-line layout
  while not spinnerStop.load(moRelaxed):
    let elapsed = epochTime() - start
    let label = getSpinLabel()
    let ticker = getSpinTicker()
    try:
      let frame = frames[i mod frames.len]
      if statusbar.isActive():
        # When the ticker has reasoning text, overlay it on the bar
        # row in dim style so it visually distinct from the bright
        # token-slot mode. As soon as `ticker` empties (content has
        # started → main set it to ""), the next frame paints the
        # bright token slots back.
        let payload =
          if ticker.len > 0:
            "\x1b[36m\x1b[1m" & frame & "\x1b[0m\x1b[2m  " & ticker & "\x1b[0m"
          else:
            "\x1b[36m\x1b[1m" & frame & "\x1b[0m\x1b[36m\x1b[1m  " &
            label & " " & $elapsed.int & "s\x1b[0m"
        writeAtBar(payload)
      else:
        let barText = "\x1b[36m\x1b[1m" & frame & "\x1b[0m\x1b[36m\x1b[1m  " &
                      label & " " & $elapsed.int & "s\x1b[0m"
        # Inline fallback: same two-line dance the legacy code did.
        stdout.write "\r\x1b[2K"
        stdout.write barText
        if ticker.len > 0:
          stdout.write "\n\x1b[2K\x1b[2m"
          stdout.write ticker
          stdout.write "\x1b[0m\r\x1b[1A"
          tickerActive = true
        elif tickerActive:
          stdout.write "\n\x1b[2K\r\x1b[1A"
          tickerActive = false
        stdout.flushFile
    except CatchableError: discard
    sleep 80
    inc i
  try:
    if statusbar.isActive():
      # Leave the bar where it was — the post-stream `drawLiveStatus`
      # redraws it with the static (no-glyph) shape as soon as content
      # finishes. No thinking row to clear; the ticker overlay was on
      # the bar row and gets repainted by `drawLiveStatus`.
      discard
    else:
      stdout.write "\r\x1b[2K"
      if tickerActive:
        stdout.write "\n\x1b[2K\r\x1b[1A"
      stdout.flushFile
  except CatchableError: discard

proc liveLabel*(base: string, slurped: int): string =
  ## Spinner label whose token slots match the per-call summary's shape:
  ## icon hugs value, slots joined by two spaces. ↑/↻ read as `0` until
  ## the final usage event closes the response; the spinner thread
  ## renders this in fgCyan + styleBright.
  let up = tokenSlot("↑", 0)
  let cached = tokenSlot("↻", 0)
  let down = tokenSlot("↓", slurped div 4)
  if base.len > 0: base & "  " & up & "  " & cached & "  " & down
  else: up & "  " & cached & "  " & down


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
  # Agent text streams at column 0 with no icon. `fgWhite + styleDim`
  # reads as a soft off-white, distinct from user input (terminal
  # default, brighter) and from the dim greyish-cyan used for harness
  # FYI text. Inline `**bold**` and `` `code` `` flip intensity within
  # this envelope without changing hue, so bold is bright-white-bold,
  # not yellow.
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
  # The lead bullet is printed at column 0 without a trailing newline,
  # so the first emitted line of content starts on the same row.
  # `MarkdownState.firstEmit = false` here means: don't suppress the
  # 2-space indent on the first line. We flip it to `true` when the
  # bullet is printed so the first chunk lands directly after `● `.
  # Same per-line handlers as the replay path so live and resumed
  # output stay byte-identical.
  var pendingLine = ""
  var mdState = initMarkdownState(firstEmit = false)
  # Live **token bar** updates: in status-bar mode, drawn at the bar
  # row (H-1) via `writeAtBar`, so it stays put while content scrolls
  # in the region above. In fallback mode (non-TTY / tiny terminal),
  # drawn inline below the most-recent content line and overwritten by
  # subsequent emits via `\x1b[2K`. `liveLineEmitted` gates the legacy
  # inline path so we don't corrupt the bullet row before the first
  # \n (status-bar mode doesn't have this concern — the bar row is
  # separate).
  var liveStatusActive = false
  var liveLineEmitted = false
  let streamT0 = epochTime()
  proc clearLiveStatus() =
    if not liveStatusActive: return
    if statusbar.isActive():
      clearBar()
    else:
      stdout.write "\x1b[2K"
    liveStatusActive = false
  proc drawLiveStatus(slurpedNow: int) =
    # **Token bar** in stopped/streaming state: same cyan + bright
    # palette as the spinner, but the animated braille frame slot is
    # blanked (3 spaces, matching the frame's visual width) so the row
    # reads as quiet — animation lives only with the actual spinner
    # while the model is thinking. The dim **token receipt** (different
    # element) lands at the start of the next user turn via
    # `settlePendingHint`, just before new output streams.
    let elapsed = (epochTime() - streamT0).int
    let lbl = liveLabel(baseLabel, slurpedNow) & "  " & $elapsed & "s"
    let payload = "\x1b[36m\x1b[1m   " & lbl & "\x1b[0m"
    if statusbar.isActive():
      writeAtBar(payload)
    else:
      stdout.write payload & "\r"
      stdout.flushFile
    liveStatusActive = true
  proc handleLine(l: string) =
    # Status row gets cleared before any content write so the new line
    # overwrites it cleanly. Cheap if status was already inactive.
    clearLiveStatus()
    if handleMdLine(mdState, l, stdout):
      liveLineEmitted = true
  proc emitContent(c: string, slurpedNow: int) =
    for ch in c:
      if ch == '\n':
        handleLine(pendingLine)
        pendingLine = ""
      else:
        pendingLine.add ch
    if liveLineEmitted and pendingLine.len == 0:
      drawLiveStatus(slurpedNow)
  proc finishContent() =
    if pendingLine.len > 0:
      handleLine(pendingLine)
      pendingLine = ""
    clearLiveStatus()
    discard finishMd(mdState, stdout)
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
              # `setSpinTicker("")` flips the bar back to token-slot mode
              # for the last spinner frame; `drawLiveStatus` then takes
              # over once content actually streams.
              setSpinTicker("")
              stopSpinner()
              stdout.styledWrite(fgWhite, styleBright, "● ", resetStyle)
              contentStarted = true
              mdState.firstEmit = true
            accContent &= c
            slurped += c.len
            emitContent(c, slurped)
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
    if statusbar.isActive():
      # Bar lives on its own row (H-1), so there's nothing to "make
      # room for" below the content. Redraw it with the final paused-
      # glyph state — the spinner thread already stopped on first
      # content, so without this redraw the bar would still show the
      # last animated frame. Cursor stays in the scroll region.
      drawLiveStatus(slurped)
      liveStatusActive = false
    else:
      # Inline (no status bar) path: bar sits on the row right below
      # content. Collapse any trailing blank rows the model emitted so
      # the bar lands flush, then redraw + advance cursor past with \n.
      var trailingNl = 0
      for i in countdown(accContent.len - 1, 0):
        if accContent[i] == '\n': inc trailingNl
        else: break
      if trailingNl > 1:
        for _ in 0 ..< trailingNl - 1:
          stdout.write "\x1b[1A\x1b[2K"
      drawLiveStatus(slurped)
      stdout.write "\n"
      liveStatusActive = false
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

proc settlePendingHint*() =
  ## Render the deferred **token receipt** saved by the previous
  ## `callModel`. Intended to be called from `runTurns` at the start
  ## of every new user-driven turn so the receipt appears only when
  ## the user sends the next message, not between tool-chain follow-
  ## ups within the same turn. No-op when nothing is pending.
  if pendingHint.active:
    renderTokenLine(pendingHint.usage, pendingHint.window, pendingHint.elapsed)
    pendingHint.active = false

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
  # Inline mode wants a blank row above the upcoming spinner so the
  # animated frame doesn't run flush against prior content. Status-
  # bar mode doesn't need it — the spinner draws on its dedicated row
  # (H-1), not in the scroll region — and the extra `\n` would just
  # add a stray blank above the response.
  if not statusbar.isActive():
    stdout.write "\n"
  setSpinLabel(liveLabel(baseLabel, 0))
  # Hide the cursor for the duration of the turn — the steady-block
  # cursor would otherwise be visible inside the scroll region
  # wherever the bar/thinking save-and-restore parks it. Restored at
  # the next input boundary by `readInput`.
  statusbar.hideCursor()
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
    # Defer the **token receipt** render to the start of the next
    # user-driven turn. The **token bar** from `streamHttp` is still
    # on screen with the streaming rough values; the receipt lands
    # just before the next turn's leading blank line via
    # `settlePendingHint`. Auto-compaction warnings still fire
    # immediately so the user can act on them before the next turn.
    pendingHint = (active: true, usage: usage, window: window, elapsed: elapsed.int)
    if window > 0 and usage.promptTokens.float > 0.7 * window.float and
       usage.promptTokens.float <= CompactThresholdFrac * window.float:
      stdout.styledWriteLine(styleDim,
        &"  · context at {humanTokens(usage.promptTokens)}/{humanTokens(window)} — auto-compaction will fire near {humanTokens(int(CompactThresholdFrac * window.float))}; :compact or :summarize to act now",
        resetStyle)
  else:
    hint &"  · {elapsed.int}s", resetStyle, "\n"
  stdout.flushFile
  if outcome.assistantMsg != nil and usage.totalTokens > 0:
    # Attach this turn's usage inline so replay can render the same
    # token line without a parallel array that drifts under summarization.
    outcome.assistantMsg["usage"] = %*{
      "promptTokens": usage.promptTokens,
      "completionTokens": usage.completionTokens,
      "totalTokens": usage.totalTokens,
      "cachedTokens": usage.cachedTokens,
    }
  outcome.assistantMsg

proc verifyProfile*(p: Profile): (bool, string) =
  let body = $(%*{
    "model": p.modelPrefix & p.model,
    "messages": [%*{"role": "user", "content": "ping"}],
    "max_tokens": 1,
    "stream": false
  })
  let r = curlRequest(p.url & "/chat/completions", key = p.key,
                      post = true, jsonBody = body)
  if r.err.len > 0: return (false, r.err)
  if r.status == 200:
    let j = try: parseJson(r.body)
            except CatchableError: return (false, "bad json in response")
    if "error" in j: return (false, $j["error"])
    return (true, "")
  let snip = r.body[0 ..< min(200, r.body.len)]
  (false, $r.status & ": " & snip)

proc fetchModels*(url, key: string): seq[string] =
  ## GET /models on the provider — that endpoint name is OpenAI's; what it
  ## returns is the list of model ids this provider exposes.
  let r = curlRequest(url & "/models", key = key)
  if r.err.len > 0 or r.status != 200: return @[]
  let j = try: parseJson(r.body) except CatchableError: return @[]
  let arr = if j.kind == JArray: j
            elif "data" in j and j["data"].kind == JArray: j["data"]
            else: return @[]
  for item in arr:
    if item.kind == JString: result.add item.getStr
    elif item.kind == JObject and "id" in item: result.add item["id"].getStr

proc installInterruptHook*() =
  setControlCHook(proc() {.noconv.} = interrupted = true)
