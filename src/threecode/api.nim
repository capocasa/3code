import std/[algorithm, atomics, httpclient, json, locks, net, os, sequtils, strformat, strutils, tables, terminal, times, uri]
import streamhttp
import types, util, prompts, compact, display

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
  ## Carries the latest iteration's accurate usage forward. Two roles:
  ##   1. After each `callModel` iteration, used to repaint the **token
  ##      bar** with accurate values (replacing the live rough ones).
  ##   2. On user submit (next turn), the saved values become the
  ##      **token receipt** — the dim repaint of the previous bar's
  ##      row, leaving the receipt in scroll history while a fresh
  ##      bar (at zeros) takes its place at the new bottom.
  ## See `## Token UI` in `CLAUDE.md` for the full lifecycle.

var currentBarLabel*: string
  ## What's currently shown in the live bar. Updated by every paint
  ## (live during streaming, accurate after `callModel` parses usage,
  ## zero on first turn). Used by `withCleared` to repaint the bar
  ## with the same label after a content write hides it.

var currentBarHasGap*: bool = false
  ## Whether there's a one-row blank "gap" between the bar and the
  ## row above it. Set by `endTurn` (typing-ready state — the gap
  ## sits between the last LLM line and the bar, breathing room
  ## while the user reads). Cleared by every `paintBarPrompt` /
  ## `paintBarBelow` (during streaming, the bar slides flush with
  ## content — no gap mid-turn). Read by `emitUserSubmit` so the
  ## receipt repaints the gap row in place — overwriting the blank,
  ## leaving the receipt flush below the LLM content with no
  ## permanent gap in scroll history.

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

# ---------- Pure byte emitters (testable) ----------
#
# CLAUDE.md "Token UI" section is the spec. The bar and prompt are
# ALWAYS visible — there are no "hidden" states. Tool exec, line emits,
# and inter-iteration transitions clear them just long enough to write
# above, then repaint immediately below. Receipts are NOT separate
# rows — when the user submits, the previous bar's row is repainted
# dim (the "receipt") and stays in scroll history.
#
# Layout (rows at the bottom of the visible content, sliding with the
# cursor):
#
#   row K-1   scratch / thinking-ticker overlay target (always blank
#             between iterations; ticker overlays it while reasoning
#             streams, restoring blank when reasoning ends — the row
#             holds no permanent content).
#   row K     token bar (cyan + bright). Position 0 carries either the
#             spinner braille glyph (during streaming) or a space
#             (idle / between iterations). Position 1 is always a
#             space. Label starts at column 2.
#   row K+1   prompt `❯ ` — dim while typing isn't possible, bright
#             cyan when readline is reading.
#
# Emitters:
#
#   spinnerBarBytes      bar payload with spinner glyph at col 0.
#   liveBarBytes         bar payload with space at col 0 (idle / static).
#   spinnerFooterBytes   per-frame spinner three-row footer.
#   barFooterBytes       bar + prompt, cursor parked at bar row col 0.
#   ClearBarPromptBytes  erase bar + prompt rows, cursor at bar row col 0.
#   SpinnerCleanupBytes  wipes all three spinner footer rows.
#   receiptBarBytes      dim payload of the bar (for the in-place
#                        receipt repaint at user-submit time).
#   submitTransitionBytes  full byte sequence for the user-submit
#                        transition (walk back, paint receipt, echo
#                        user input).

const
  DimPromptColor* = "\x1b[2m\x1b[37m"
    ## Dim white SGR for the prompt (typing not possible).
  BrightPromptColor* = "\x1b[1m\x1b[36m"
    ## Bright cyan SGR for the prompt (readline active / typing-ready).

proc spinnerBarBytes*(frame, label: string, elapsed: int): string =
  ## Bar row payload during the spinner phase: braille glyph at col 0,
  ## one space at col 1, then the label. 2-char prefix total — the same
  ## width as `liveBarBytes`'s "  " so the spinner can be replaced by
  ## a space without shifting the label.
  "\x1b[36m\x1b[1m" & frame & "\x1b[0m\x1b[36m\x1b[1m " &
    label & " " & $elapsed & "s\x1b[0m"

proc liveBarBytes*(label: string): string =
  ## Bar row payload (no spinner): two leading spaces, then the label.
  ## Position 0 is the slot that gets overwritten with the spinner
  ## glyph during streaming.
  "\x1b[36m\x1b[1m  " & label & "\x1b[0m"

proc spinnerFooterBytes*(frame, label, ticker: string, elapsed: int): string =
  ## Three-row spinner footer. Cursor in: col 0 of the bar row.
  ## Cursor out: same. The row above (ticker overlay target) is
  ## cleared every frame so reasoning→no-reasoning is a faithful
  ## restore as long as that row was blank to begin with (it always
  ## is — the leading `\n` callModel writes guarantees it).
  result = "\r\x1b[1A\x1b[2K"
  if ticker.len > 0:
    result.add "\x1b[2m"
    result.add ticker
    result.add "\x1b[0m"
  result.add "\n\x1b[2K"
  result.add spinnerBarBytes(frame, label, elapsed)
  result.add "\n\x1b[2K" & DimPromptColor & "❯ \x1b[0m"
  result.add "\r\x1b[1A"

const SpinnerCleanupBytes* =
  "\r\x1b[1A\x1b[2K\n\x1b[2K\n\x1b[2K\r\x1b[1A"

proc paintBarBytes*(label: string): string =
  ## Clears the bar row and writes the static-form bar payload. Cursor
  ## ends at the end of the payload on the bar row.
  "\r\x1b[2K" & liveBarBytes(label)

proc barFooterBytes*(label, promptColor: string): string =
  ## Bar at the current row + prompt at the row below, cursor parked
  ## at col 0 of the bar row. Replaces the old `liveFooterBytes` —
  ## prompt color is now a parameter (dim while typing impossible,
  ## bright cyan when readline is active).
  paintBarBytes(label) &
    "\n\x1b[2K" & promptColor & "❯ \x1b[0m\r\x1b[1A"

const ClearBarPromptBytes* = "\r\x1b[2K\n\x1b[2K\r\x1b[1A"
  ## Erase the bar + prompt rows, cursor at col 0 of the bar row.
  ## Used to make room above before a content write that will push
  ## bar+prompt one row down.

proc barFooterBelowBytes*(label, promptColor: string): string =
  ## Paint bar one row below the cursor + prompt two rows below,
  ## walking the cursor back up to the bullet row at column 2 (right
  ## after `● `). Used during mid-line streaming where the cursor
  ## sits at the bullet row, content is accumulating in `pendingLine`
  ## (in memory, no terminal write yet), and the bar still needs to
  ## be visible.
  ##
  ## Avoids CSI s/u (SCO save/restore cursor) — those are silently
  ## ignored on enough terminals (we shipped a regression where each
  ## refresh stacked another bar in scroll because the cursor never
  ## returned). `\x1b[2A` walks up 2 rows; `\x1b[3G` sets the column
  ## to 3 (1-based, == col 2 0-based, the position right after the
  ## bullet).
  "\n\x1b[2K" & liveBarBytes(label) &
    "\n\x1b[2K" & promptColor & "❯ \x1b[0m" &
    "\x1b[2A\x1b[3G"

const ClearBarBelowBytes* =
  "\n\x1b[2K\n\x1b[2K\x1b[2A\x1b[3G"
  ## Erase the bar + prompt rows below the cursor (without
  ## disturbing the cursor's row content), then walk back up to the
  ## bullet row at column 2. Same caveat as `barFooterBelowBytes`:
  ## avoids CSI s/u so it works on terminals that ignore those.

proc receiptBarBytes*(label: string): string =
  ## In-place dim repaint of the bar row's payload. No leading clear
  ## — caller has already cleared (or just walked back). No trailing
  ## newline — caller advances. The byte sequence the user-submit
  ## transition writes onto the previous turn's bar row to convert it
  ## into the **token receipt**.
  if label.len == 0: return ""
  "\x1b[2m  " & label & "\x1b[0m"

proc submitTransitionBytes*(line: string, hadPending, hadGap: bool,
                            receiptLabel: string): string =
  ## Full byte sequence for the moment the user submits a prompt.
  ##
  ## Walks back from the cursor (which sits one row below the user's
  ## input) to the row that should host the receipt:
  ##
  ## - `hadGap = true` (typing-ready state from `endTurn`): there's a
  ##   blank row above the bar between the last LLM line and the bar.
  ##   Walk up `splitLines(line).len + 2` so the cursor lands on the
  ##   *gap* row. The receipt is painted there, *replacing the blank*
  ##   — leaving the receipt flush against the LLM content with no
  ##   permanent gap in scroll history.
  ## - `hadGap = false` (first turn — welcome painted bar without
  ##   gap, no LLM content to gap from): walk up
  ##   `splitLines(line).len + 1` to land on the bar row. No receipt
  ##   to paint anyway (`hadPending` is false on first turn).
  ##
  ## Then:
  ##   1. Clear from cursor to end of screen — wipes (gap), bar,
  ##      prompt, readline echo, anything below.
  ##   2. If `hadPending`, paint the dim receipt at this row.
  ##   3. Two newlines: advance + blank separator between receipt
  ##      and user echo.
  ##   4. Echo user input line by line (`❯ ` for first, `  ` for
  ##      continuations).
  ##
  ## Cursor out: col 0 of the row directly after the last echo line.
  ## The next `callModel`'s leading `\n` sets up the scratch /
  ## ticker-overlay row.
  let lines = line.splitLines
  let n = lines.len
  let walkBack = if hadGap: n + 2 else: n + 1
  result = "\x1b[" & $walkBack & "A"
  result.add "\r\x1b[J"
  if hadPending:
    result.add receiptBarBytes(receiptLabel)
  result.add "\n\n"
  for idx, l in lines:
    let prefix = if idx == 0: "❯ " else: "  "
    result.add "\x1b[37m"
    result.add prefix
    result.add l
    result.add "\x1b[0m\n"

# ---------- Bar+prompt runtime helpers ----------
#
# The bar and prompt are *always visible*. These helpers hide them
# just long enough for a content write that would otherwise advance
# into them, and repaint them immediately below. Each helper also
# updates `currentBarLabel` so subsequent repaints (after a tool
# write, after an iteration end, etc.) use the same content.

proc paintBarPrompt*(label, promptColor: string) =
  ## Write bar + prompt at the cursor's current row, parking cursor
  ## at col 0 of the bar row. Caches `label` so a later
  ## `repaintBarPrompt` knows what to draw. Clears `currentBarHasGap`
  ## — during streaming the bar slides flush with content; only
  ## `endTurn` paints a gap.
  currentBarLabel = label
  currentBarHasGap = false
  stdout.write barFooterBytes(label, promptColor)
  stdout.flushFile

proc paintBarBelow*(label, promptColor: string) =
  ## Paint bar + prompt one and two rows below the cursor, restoring
  ## the cursor to its original (likely mid-line) position. Used
  ## during streaming to keep the bar visible while content is being
  ## accumulated in memory and the cursor stays put.
  currentBarLabel = label
  currentBarHasGap = false
  stdout.write barFooterBelowBytes(label, promptColor)
  stdout.flushFile

proc repaintBarPrompt*(promptColor = DimPromptColor) =
  ## Re-emit the bar+prompt at the cursor's current row using the
  ## cached `currentBarLabel`. Used by `withCleared` to put the bar
  ## back after a content write.
  if currentBarLabel.len == 0: return
  stdout.write barFooterBytes(currentBarLabel, promptColor)
  stdout.flushFile

proc clearBarPrompt*() =
  ## Erase the bar + prompt rows in place. Cursor parks at col 0 of
  ## the bar row so the caller can write content there (which then
  ## pushes the next `repaintBarPrompt` one row down).
  stdout.write ClearBarPromptBytes
  stdout.flushFile

template withCleared*(body: untyped) =
  ## Hide bar+prompt for the duration of `body`, repaint them below
  ## the cursor afterwards. Body writes content (banners, tool
  ## output, etc.) that advances the cursor by some number of rows;
  ## the bar+prompt slide along with the cursor.
  clearBarPrompt()
  body
  repaintBarPrompt()

proc spinnerLoop(unused: string) {.thread.} =
  ## Three-line spinner footer rooted at the cursor row:
  ##   row N-1   reasoning ticker (overlay, dim) — shown only while
  ##             reasoning streams; the row above the bar is the
  ##             leading-`\n` scratch row callModel writes, so the
  ##             overlay always lands on a blank, and clearing the
  ##             row is a faithful restore.
  ##   row N     spinner frame + token-slot bar (cyan + bright)
  ##   row N+1   dim `❯ ` placeholder, the visible caret while typing
  ##             isn't possible.
  ## See `spinnerFooterBytes` for the byte sequence each frame writes.
  const frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  let start = epochTime()
  var i = 0
  while not spinnerStop.load(moRelaxed):
    let elapsed = epochTime() - start
    let label = getSpinLabel()
    let ticker = getSpinTicker()
    try:
      let frame = frames[i mod frames.len]
      stdout.write spinnerFooterBytes(frame, label, ticker, elapsed.int)
      stdout.flushFile
    except CatchableError: discard
    sleep 80
    inc i
  try:
    stdout.write SpinnerCleanupBytes
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

proc closeCachedStreamConn() =
  if cachedStreamConn != nil:
    try: cachedStreamConn.close() except CatchableError: discard
    cachedStreamConn = nil
    cachedStreamHostKey = ""

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
  let u = try: parseUri(url) except CatchableError as e:
    result.errMsg = "bad url: " & e.msg
    return
  if u.scheme != "https":
    result.errMsg = "only https supported, got: " & u.scheme
    return
  let host = u.hostname
  let port =
    if u.port.len > 0: Port(parseInt(u.port))
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
    if interrupted:
      closeCachedStreamConn()
      result.errMsg = "interrupted by user"
      return
    inc attempt
    if cachedStreamConn != nil and cachedStreamHostKey == hostKey:
      conn = cachedStreamConn
    else:
      closeCachedStreamConn()
      try:
        conn = connectTls(host, port, timeoutMs = 1_200_000,
                          caFile = bundledCaFile())
      except CatchableError as e:
        result.errMsg = "TLS connect failed: " & e.msg
        return
      cachedStreamConn = conn
      cachedStreamHostKey = hostKey
    try:
      conn.sendRequest("POST", pathQuery, host,
                       headers = [("Authorization", "Bearer " & key),
                                  ("Content-Type", "application/json"),
                                  ("Accept", "text/event-stream")],
                       body = bodyStr)
      resp = conn.readResponseHead()
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
  # Bar+prompt remain visible the entire time content is streaming.
  # Two states track where they sit relative to the cursor:
  #   `liveBarAtCursor`  bar is at the cursor's row + prompt at row+1.
  #                      Holds after a `\n` paints the bar at the new
  #                      cursor row. Content writes that overlay the
  #                      cursor row first need to clear it.
  #   `liveBarBelow`     bar is at cursor row+1 + prompt at cursor+2.
  #                      Holds during mid-line streaming (cursor sits
  #                      on a content row that's accumulating in
  #                      `pendingLine`, no terminal advance yet). Painted
  #                      via `barFooterBelowBytes` (CSI s/u save/restore)
  #                      so it doesn't disturb the cursor row.
  # Mutually exclusive; both false means the bar isn't painted yet
  # (pre-bullet) or has been cleared (mid-flush).
  var liveBarAtCursor = false
  var liveBarBelow = false
  var liveLineEmitted = false
  let streamT0 = epochTime()
  proc currentLabel(slurpedNow: int): string =
    let elapsed = (epochTime() - streamT0).int
    liveLabel(baseLabel, slurpedNow) & "  " & $elapsed & "s"
  proc handleLine(l: string) =
    # Pre-write: if bar is at the cursor's row, clear it before
    # content writes overlay it. If the bar is below cursor, content
    # writes cleanly on the cursor row and `\n` advances onto the
    # old-bar row; the subsequent `paintBarPrompt`'s leading clear
    # handles that case.
    if liveBarAtCursor:
      clearBarPrompt()
      liveBarAtCursor = false
    if handleMdLine(mdState, l, stdout):
      liveLineEmitted = true
  proc emitContent(c: string, slurpedNow: int) =
    for ch in c:
      if ch == '\n':
        handleLine(pendingLine)
        pendingLine = ""
        if liveLineEmitted:
          # Cursor advanced one row past the just-written content.
          # That row was the previous bar/below position and now
          # holds stale chrome; `paintBarPrompt`'s leading
          # `\r\x1b[2K` clears it before painting the new bar.
          paintBarPrompt(currentLabel(slurpedNow), DimPromptColor)
          liveBarAtCursor = true
          liveBarBelow = false
      else:
        pendingLine.add ch
    # End-of-chunk refresh: keep the bar's slurped/elapsed values
    # current AND keep the bar visible across long mid-line streams.
    # Whichever state holds, paint with the matching emitter.
    if contentStarted:
      if liveBarAtCursor:
        paintBarPrompt(currentLabel(slurpedNow), DimPromptColor)
      elif liveBarBelow:
        paintBarBelow(currentLabel(slurpedNow), DimPromptColor)
  proc finishContent(slurpedNow: int) =
    if pendingLine.len > 0:
      handleLine(pendingLine)
      pendingLine = ""
      if liveLineEmitted:
        paintBarPrompt(currentLabel(slurpedNow), DimPromptColor)
        liveBarAtCursor = true
        liveBarBelow = false
    # If markdown has buffered content (open code fence, table rows
    # without a closing non-table line), flushing it writes more
    # rows above the bar — clear bar+prompt first so the writes
    # don't conflict, then repaint at the new bottom.
    if mdState.codeBuf.len > 0 or mdState.tableBuf.len > 0:
      if liveBarAtCursor:
        clearBarPrompt()
        liveBarAtCursor = false
      elif liveBarBelow:
        stdout.write ClearBarBelowBytes
        stdout.flushFile
        liveBarBelow = false
      discard finishMd(mdState, stdout)
      paintBarPrompt(currentLabel(slurpedNow), DimPromptColor)
      liveBarAtCursor = true
    # else: bar+prompt already in place, leave them alone — avoids
    # the brief clear→repaint flash we used to ship.
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
    if interrupted:
      closeCachedStreamConn()
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
              # Then paint bar+prompt one row below so the bar stays
              # visible while `pendingLine` accumulates in memory before
              # the first `\n` arrives.
              setSpinTicker("")
              stopSpinner()
              stdout.styledWrite(fgWhite, styleBright, "● ", resetStyle)
              contentStarted = true
              mdState.firstEmit = true
              paintBarBelow(currentLabel(slurped), DimPromptColor)
              liveBarBelow = true
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
    elif line.startsWith("event:") or line.strip.len == 0 or
         line.startsWith(": "):  # SSE comment
      discard
    else:
      nonSSE.add line

  if contentStarted:
    finishContent(slurped)
    # Collapse trailing blank rows the model emitted so the bar lands
    # flush below the last content line. The bar may currently sit
    # `trailingNl - 1` rows below where it should; clear it, walk up
    # the extras, repaint.
    var trailingNl = 0
    for i in countdown(accContent.len - 1, 0):
      if accContent[i] == '\n': inc trailingNl
      else: break
    if trailingNl > 1:
      if liveBarAtCursor:
        clearBarPrompt()
        liveBarAtCursor = false
      elif liveBarBelow:
        stdout.write ClearBarBelowBytes
        stdout.flushFile
        liveBarBelow = false
      for _ in 0 ..< trailingNl - 1:
        stdout.write "\x1b[1A\x1b[2K"
      paintBarPrompt(currentLabel(slurped), DimPromptColor)
    contentStreamedLive = true

  if interrupted:
    result.errMsg = "interrupted by user"
    return
  if streamErr.len > 0:
    result.errMsg = "stream read: " & streamErr &
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

proc beginTurn*() =
  ## Hide the terminal caret for the duration of the turn — the dim
  ## `❯ ` glyph (still painted, just not blinking) is the only
  ## visible marker while typing isn't possible.
  stdout.write "\x1b[?25l"
  stdout.flushFile

proc endTurn*() =
  ## Transition to typing-ready state: clear the bar at its current
  ## row, advance one row to leave a blank "gap" between the last
  ## content row and the bar, repaint bar+prompt with the bright
  ## cyan prompt color. Show the terminal caret. The gap is
  ## one-shot — `emitUserSubmit` overwrites it with the receipt at
  ## next submit, so it never persists in scroll history.
  if currentBarLabel.len > 0:
    let label = currentBarLabel
    clearBarPrompt()
    stdout.write "\n"
    stdout.write barFooterBytes(label, BrightPromptColor)
    currentBarLabel = label
    currentBarHasGap = true
  stdout.write "\x1b[?25h"
  stdout.flushFile

proc emitUserSubmit*(line: string) =
  ## Run the user-submit transition described in `submitTransitionBytes`
  ## using the current `pendingHint` and `currentBarHasGap` state. The
  ## receipt overwrites the gap (or the bar's row if no gap), echoes
  ## the user's input as scroll-history content, and parks the cursor
  ## ready for the next `callModel`'s leading `\n`.
  let receiptLabel =
    if pendingHint.active:
      tokenLineLabel(pendingHint.usage, pendingHint.window, pendingHint.elapsed)
    else: ""
  let hadGap = currentBarHasGap
  stdout.write submitTransitionBytes(line, pendingHint.active, hadGap,
                                     receiptLabel)
  stdout.flushFile
  pendingHint.active = false
  currentBarLabel = ""
  currentBarHasGap = false

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
  # Blank scratch row above the upcoming spinner / bullet. Serves two
  # purposes: (1) visual separation between the user's echoed prompt
  # (or prior tool output) and the spinner, and (2) a known-blank
  # overlay target for the reasoning ticker — the spinner thread
  # writes the ticker into this row while reasoning streams and clears
  # it back to blank when reasoning ends, so the original (blank) state
  # is faithfully restored. Done once per call; retries reuse the same
  # row.
  stdout.write "\n"
  setSpinLabel(liveLabel(baseLabel, 0))
  # Cursor is hidden for the duration of the entire turn by `runTurns`
  # so the dim `❯ ` placeholder is the only visible caret. callModel
  # itself doesn't toggle visibility — touching DECTCEM here would
  # cause a flicker between callModel iterations within a turn.
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
    # Repaint the bar with accurate values now that `usage` is parsed
    # — the live values during streaming were rough estimates
    # (`slurped/4`). `pendingHint` carries the same numbers forward
    # so the next user-submit's receipt repaints this row dim with
    # matching content.
    let label = tokenLineLabel(usage, window, elapsed.int)
    paintBarPrompt(label, DimPromptColor)
    pendingHint = (active: true, usage: usage, window: window, elapsed: elapsed.int)
    if window > 0 and usage.promptTokens.float > 0.7 * window.float and
       usage.promptTokens.float <= CompactThresholdFrac * window.float:
      withCleared:
        stdout.styledWriteLine(styleDim,
          &"  · context at {humanTokens(usage.promptTokens)}/{humanTokens(window)} — auto-compaction will fire near {humanTokens(int(CompactThresholdFrac * window.float))}; :compact or :summarize to act now",
          resetStyle)
  else:
    withCleared:
      hint &"  · {elapsed.int}s", resetStyle, "\n"
  stdout.flushFile
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
  outcome.assistantMsg

proc verifyProfile*(p: Profile): (bool, string) =
  let body = $(%*{
    "model": p.modelPrefix & p.model,
    "messages": [%*{"role": "user", "content": "ping"}],
    "max_tokens": 1,
    "stream": false
  })
  try:
    let client = newHttpClient(timeout = 20_000, userAgent = "3code",
                               sslContext = bundledSslContext())
    defer: client.close()
    client.headers["Authorization"] = "Bearer " & p.key
    client.headers["Content-Type"] = "application/json"
    let resp = client.request(p.url & "/chat/completions",
                              httpMethod = HttpPost, body = body)
    if resp.code.int != 200:
      let snip = resp.body[0 ..< min(200, resp.body.len)]
      return (false, $resp.code.int & ": " & snip)
    let j = try: parseJson(resp.body)
            except CatchableError: return (false, "bad json in response")
    if "error" in j: return (false, $j["error"])
    (true, "")
  except CatchableError as e:
    (false, e.msg)

proc fetchModels*(url, key: string): seq[string] =
  ## GET /models on the provider — that endpoint name is OpenAI's; what it
  ## returns is the list of model ids this provider exposes. Returns @[]
  ## on any failure (transport, non-200, malformed JSON).
  try:
    let client = newHttpClient(timeout = 20_000, userAgent = "3code",
                               sslContext = bundledSslContext())
    defer: client.close()
    client.headers["Authorization"] = "Bearer " & key
    let resp = client.get(url & "/models")
    if resp.code.int != 200: return
    let j = parseJson(resp.body)
    let arr = if j.kind == JArray: j
              elif "data" in j and j["data"].kind == JArray: j["data"]
              else: return
    for item in arr:
      if item.kind == JString: result.add item.getStr
      elif item.kind == JObject and "id" in item: result.add item["id"].getStr
  except CatchableError:
    discard

proc installInterruptHook*() =
  setControlCHook(proc() {.noconv.} = interrupted = true)
