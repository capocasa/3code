## HTTP client, SSE streaming, spinner, and thinking ticker.
##
## `callModel` is the single outbound call: it sends the messages array as an
## OpenAI-compatible chat completions request, reads the Server-Sent Events
## stream chunk by chunk, and returns a completed assistant `JsonNode` plus
## a `Usage` record.
##
## The spinner runs on a background thread so the braille animation stays
## smooth while the main thread blocks on I/O. The thinking ticker - a dim
## one-liner above the spinner showing the model's `reasoning_content` deltas
## - is cleared when the model transitions from reasoning to output.
##
## XML tool call recovery handles a gpt-oss quirk: some nvidia-hosted variants
## leak the model's native `<tool_call>` chat template into `delta.content`
## instead of the OpenAI `tool_calls` field. When `xmlToolCalls` is set for a
## combo, `callModel` promotes those tags to synthetic tool_calls so the rest
## of the pipeline sees a uniform shape.

import std/[algorithm, atomics, hashes, httpclient, json, locks, nativesockets, net, os, sequtils, strformat, strutils, tables, terminal, times, unicode, uri]
when defined(posix):
  import std/posix except SocketHandle
  import posix/termios
import streamhttp
import types, util, prompts, compact, display, minline, screen

type
  VerifyProfileHook* = proc(p: Profile): (bool, string) {.closure.}
  FetchModelsHook* = proc(url, key: string): (seq[string], string) {.closure.}

var
  verifyProfileHook*: VerifyProfileHook
  fetchModelsHook*: FetchModelsHook

const providerStub {.booldefine.} = false
when providerStub:
  var stubResponseIdx = 0
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

var screenState* = initScreenState()
  ## Explicit state for the normal scrollback transcript's volatile footer.
  ## Rendering still happens in this module, but prompt/bar/ticker data now
  ## has one home instead of separate process-level globals.

template pendingHint*(): untyped = screenState.footer.pendingHint
  ## Carries the latest iteration's accurate usage forward. Two roles:
  ##   1. After each `callModel` iteration, used to repaint the **token
  ##      bar** with accurate values (replacing the live rough ones).
  ##   2. On user submit (next turn), the saved values become the
  ##      **token receipt** — the dim repaint of the previous bar's
  ##      row, leaving the receipt in scroll history while a fresh
  ##      bar (at zeros) takes its place at the new bottom.
  ## See `## Token UI` in `CLAUDE.md` for the full lifecycle.

template currentBarLabel*(): untyped = screenState.footer.barLabel
  ## What's currently shown in the live bar. Updated by every paint
  ## (live during streaming, accurate after `callModel` parses usage,
  ## zero on first turn). Used by `screenWriteTranscript` to repaint the bar
  ## with the same label after a content write hides it.

template currentBarHasGap*(): untyped = screenState.footer.hasGap
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
var quietStop: Atomic[bool]
var quietThread: Thread[string]
var quietRunning = false
var lastProviderActivity: Atomic[int]
var renderLock*: Lock
initLock(renderLock)
var inputState*: InputState
var inputThread: Thread[void]
var inputThreadRunning* = false
var inputEditor*: ptr minline.LineEditor
var inputProfile*: ptr Profile
var inputSession*: ptr Session
var inputMessages*: ptr JsonNode
var turnHandleCommand*: proc(cmd: string): bool

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

proc emitScreenEvent*(ev: ScreenEvent) =
  ## Single state transition entry point for the volatile footer model.
  ## Terminal bytes are still rendered by the helpers below, but all
  ## production state changes flow through this event reducer.
  screenState.apply ev

type LiveMarkdownStream* = object
  ## Incremental renderer for assistant content during provider streaming.
  ## It buffers input until markdown line/block boundaries, renders through
  ## the same MarkdownState used by replay, and keeps the token footer sliding
  ## below whatever rendered bytes are emitted.
  baseLabel: string
  started: bool
  md: MarkdownState
  pendingLine: string
  utf8Pending: string
  streamT0: float
  liveBarAtCursor: bool
  liveBarBelow: bool
  liveLineEmitted: bool
  liveCol: int

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
    if s.len == 0:
      emitScreenEvent clearTickerEvent()
    else:
      emitScreenEvent setTickerEvent(s)

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
#   row K+1   prompt ❯ — dim while typing isn't possible, bright
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
  DimPromptColor* = GreyFg
    ## Prompt color while typing isn't possible (model streaming,
    ## tool exec, etc.). Mid-grey 244 — readable on both bg.
  BrightPromptColor* = CyanFg & BoldOn
    ## Prompt color when readline is active (typing-ready).
  TurnPromptColor* = OffWhiteFg & BoldOn
    ## Prompt color while a turn is running but buffered typing is active.
  SyncBegin* = "\x1b[?2026h"
    ## DEC 2026 begin synchronized update — conhost (Win11 modern) and
    ## Windows Terminal commit all bytes between BEGIN and END as one
    ## atomic frame. Terminals that don't recognize the mode ignore it
    ## silently. Wrapping per-frame paints (bar, spinner ticker)
    ## eliminates the mid-frame partial-paint flicker conhost shows.
  SyncEnd* = "\x1b[?2026l"
    ## End synchronized update.

proc screenRenderSync*(s: string) =
  ## Single-flush write of ``s`` wrapped in DEC 2026 synchronized
  ## output, so conhost paints it as one atomic frame.
  stdout.write SyncBegin & s & SyncEnd
  stdout.flushFile

proc syncWrite*(s: string) =
  ## Compatibility wrapper for older tests/callers; prefer
  ## `screenRenderSync` at new rendering boundaries.
  screenRenderSync(s)

proc screenRenderFooterFrame*(s: string) {.gcsafe.} =
  ## Like ``screenRenderSync`` for turn-time footer animations, but if the
  ## background input editor is active, repaint the footer from the bar
  ## anchor and then restore the editor's prompt/input row in the same
  ## synchronized frame. Otherwise spinner/bar ticks park the physical
  ## cursor on the token bar and the next typed character echoes there.
  {.cast(gcsafe).}:
    acquire renderLock
    try:
      if inputThreadRunning and inputState.turnActive and inputEditor != nil:
        let edPtr = inputEditor
        stdout.write SyncBegin
        let up = edPtr[].renderRow + 1
        stdout.write "\r"
        if up > 0:
          stdout.write "\x1b[" & $up & "A"
        stdout.write s
        stdout.write "\x1b[" & $up & "B"
        stdout.write edPtr[].redrawBytes()
        if edPtr[].postRedraw != nil:
          edPtr[].postRedraw(edPtr[])
        stdout.write SyncEnd
        stdout.flushFile
      else:
        stdout.write SyncBegin & s & SyncEnd
        stdout.flushFile
    finally:
      release renderLock

proc syncTurnFooterWrite*(s: string) {.gcsafe.} =
  ## Compatibility wrapper for older tests/callers; prefer
  ## `screenRenderFooterFrame` at new rendering boundaries.
  screenRenderFooterFrame(s)

proc spinnerBarBytes*(frame, label: string, elapsed: int): string =
  ## Bar row payload during the spinner phase: braille glyph at col 0,
  ## one space at col 1, then the label. 2-char prefix total — the same
  ## width as `liveBarBytes`'s "  " so the spinner can be replaced by
  ## a space without shifting the label.
  CyanFg & BoldOn & frame & Reset & CyanFg & BoldOn & " " &
    label & " " & $elapsed & "s" & Reset

proc liveBarBytes*(label: string): string =
  ## Bar row payload (no spinner): two leading spaces, then the label.
  ## Position 0 is the slot that gets overwritten with the spinner
  ## glyph during streaming.
  CyanFg & BoldOn & "  " & label & Reset

proc labelCells(label: string): int =
  ## Visible cells the (plain-text, no-SGR) bar/spinner label occupies.
  ## Labels come from `liveLabel` / `tokenLineLabel` — both build the
  ## string from glyphs and digits joined by spaces, no escape codes.
  ## One cell per rune; wide CJK glyphs are not used in our labels.
  var i = 0
  while i < label.len:
    let rl = max(1, runeLenAt(label, i))
    inc result
    i += rl

proc barWrapRows(visibleCells, termW: int): int =
  ## Visual rows a bar payload of `visibleCells` cells occupies on a
  ## terminal `termW` wide. `termW = 0` means "unknown" — caller is
  ## the legacy single-row path and gets `1`. Otherwise round up,
  ## never less than 1.
  if termW <= 0 or visibleCells <= 0: return 1
  result = (visibleCells + termW - 1) div termW
  if result < 1: result = 1

proc spinnerFooterBytes*(frame, label, ticker: string, elapsed: int,
                         termW = 0): string =
  ## Three-row spinner footer. Cursor in: col 0 of the bar row.
  ## Cursor out: same. The row above (ticker overlay target) is
  ## cleared every frame so reasoning→no-reasoning is a faithful
  ## restore as long as that row was blank to begin with (it always
  ## is — the leading `\n` callModel writes guarantees it).
  # Re-assert hide-cursor every frame. Some terminals (older conhost,
  # a few VTE variants) transiently re-show the caret on cursor
  # movement or on sync-update end, so a single `?25l` from beginTurn
  # isn't enough — at 80ms cadence the re-shown caret is visible as a
  # flicker glued to the braille glyph. Cheap, idempotent.
  #
  # Bar payload visible width = "<frame> <label> <elapsed>s" = label
  # cells + 4 (frame + 2 spaces + "s") + digits of `elapsed`. When
  # `termW > 0` and the payload exceeds it, the bar wraps to `barRows`
  # visual rows; the trailing back-walk must compensate so the cursor
  # parks on the bar's *first* wrap row, not its last. `termW = 0`
  # falls back to the legacy single-row walk.
  # Emit explicit CR before every `\n` instead of relying on OPOST/ONLCR
  # to translate LF to CRLF. The previous SIGWINCH fix preserves OPOST
  # through the editor's `getchr`, but the dim prompt still drifts right
  # after a shrink-then-content sequence — some path (terminal reflow
  # of an in-flight raw-mode capture elsewhere, a tool subprocess
  # leaving termios with OPOST off, etc.) can still flip it off
  # mid-session. Belt-and-braces: with explicit `\r`, the spinner /
  # bar / prompt rows snap to col 0 regardless of OPOST state.
  let barCells = labelCells(label) + 4 + ($elapsed).len
  let barRows = barWrapRows(barCells, termW)
  result = "\x1b[?25l\r\x1b[1A\x1b[2K"
  if ticker.len > 0:
    result.add GreyFg
    result.add ticker
    result.add Reset
  result.add "\r\n\x1b[2K"
  result.add spinnerBarBytes(frame, label, elapsed)
  result.add "\r\n\x1b[2K" & DimPromptColor & "❯ " & Reset
  result.add "\r\x1b[" & $barRows & "A"

proc spinnerCleanupBytes*(tickerRows = 1): string =
  ## Erase spinner ticker + bar + prompt, cursor at col 0 of the bar
  ## row. Clears to end-of-screen from the ticker row so wrapped
  ## spinner labels/tickers left by terminal reflow are removed too.
  let rows = max(1, tickerRows)
  "\r\x1b[" & $rows & "A\x1b[J\n"

const SpinnerCleanupBytes* = "\r\x1b[1A\x1b[J\n"

proc paintBarBytes*(label: string): string =
  ## Clears the bar row and writes the static-form bar payload. Cursor
  ## ends at the end of the payload on the bar row.
  "\r\x1b[2K" & liveBarBytes(label)

proc barFooterBytes*(label, promptColor: string, termW = 0): string =
  ## Bar at the current row + prompt at the row below, cursor parked
  ## at col 0 of the bar row. Replaces the old `liveFooterBytes` —
  ## prompt color is now a parameter (dim while typing impossible,
  ## bright cyan when readline is active).
  ##
  ## `termW` is the current terminal column count (0 = unknown). When
  ## the bar payload (`"  " & label`) is wider than `termW`, the bar
  ## wraps to multiple visual rows. The trailing back-walk must climb
  ## *all* of them so the cursor parks on the bar's first wrap row —
  ## the only position from which `ClearBarPromptBytes` can erase the
  ## whole bar+prompt block cleanly. Passing `0` keeps the old
  ## single-row back-walk for callers that haven't been width-aware.
  # Explicit `\r` before `\n` so the prompt row reaches col 0 even when
  # OPOST/ONLCR is off — see `spinnerFooterBytes` for the rationale.
  let barRows = barWrapRows(2 + labelCells(label), termW)
  paintBarBytes(label) &
    "\r\n\x1b[2K" & promptColor & "❯ " & Reset &
    "\r\x1b[" & $barRows & "A"

const ClearBarPromptBytes* = "\r\x1b[J"
  ## Erase the bar + prompt area, cursor at col 0 of the bar row.
  ## This intentionally clears to end-of-screen rather than exactly
  ## two rows: after terminal width shrink, an already-painted token
  ## bar may have reflowed into multiple visual rows. The footer owns
  ## everything below its anchor, so clearing from the anchor is the
  ## stable recovery operation before content pushes the footer down.

proc barFooterBelowAtColBytes*(label, promptColor: string, col: int,
                               termW = 0): string =
  ## Paint bar one row below the cursor + prompt two rows below,
  ## walking the cursor back up to the content row at `col`. Used
  ## during mid-line streaming where the cursor sits on an in-progress
  ## content row and the bar still needs to be visible underneath it.
  ##
  ## Avoids CSI s/u (SCO save/restore cursor) — those are silently
  ## ignored on enough terminals (we shipped a regression where each
  ## refresh stacked another bar in scroll because the cursor never
  ## returned). The trailing `\x1b[<n>A\x1b[<col>G` walks back up to the
  ## content row (`n` = bar wrap rows + 1 for the prompt row) and sets
  ## the cursor column (1-based).
  ## With a wrapped bar (post-shrink) `n` is larger than the
  ## single-row default of 2.
  # Explicit `\r` before each `\n` so the bar and prompt rows reach
  # col 0 even when OPOST/ONLCR is off — see `spinnerFooterBytes`.
  let barRows = barWrapRows(2 + labelCells(label), termW)
  "\r\n\x1b[2K" & liveBarBytes(label) &
    "\r\n\x1b[2K" & promptColor & "❯ " & Reset &
    "\x1b[" & $(barRows + 1) & "A\x1b[" & $(max(0, col) + 1) & "G"

proc barFooterBelowBytes*(label, promptColor: string, termW = 0): string =
  ## Compatibility wrapper for the canonical pre-text state: cursor
  ## returns to column 2, right after `● `.
  barFooterBelowAtColBytes(label, promptColor, 2, termW)

proc clearBarBelowAtColBytes*(col: int): string =
  ## Erase the bar + prompt rows below the current cursor row and
  ## restore the cursor to `col` on that original row.
  "\n\r\x1b[J\x1b[1A\x1b[" & $(max(0, col) + 1) & "G"

const ClearBarBelowBytes* = "\n\r\x1b[J\x1b[1A\x1b[3G"
  ## Erase the bar + prompt rows below the cursor (without
  ## disturbing the cursor's row content), then walk back up to the
  ## bullet row at column 2. Clears to end-of-screen because a resize
  ## can reflow the already-painted bar/prompt into more than two
  ## visual rows.

proc receiptBarBytes*(label: string): string =
  ## In-place dim repaint of the bar row's payload. No leading clear
  ## — caller has already cleared (or just walked back). No trailing
  ## newline — caller advances. The byte sequence the user-submit
  ## transition writes onto the previous turn's bar row to convert it
  ## into the **token receipt**.
  if label.len == 0: return ""
  CyanFg & "  " & label & Reset

proc submitTransitionBytes*(line: string, hadPending, hadGap: bool,
                            receiptLabel: string, hasBar = true,
                            echoRows = -1): string =
  ## Full byte sequence for the moment the user submits a prompt.
  ##
  ## Walks back from the cursor (which sits one row below the user's
  ## input) to the row that should host the receipt:
  ##
  ## - `hasBar = false` (prompt-only startup state — no token bar
  ##   painted yet, no prior turn): walk up `splitLines(line).len` so
  ##   the cursor lands on the row that held the static prompt. No
  ##   receipt to paint (`hadPending` is false in this state).
  ## - `hadGap = true` (typing-ready state from `endTurn`): there's a
  ##   blank row above the bar between the last LLM line and the bar.
  ##   Walk up `splitLines(line).len + 2` so the cursor lands on the
  ##   *gap* row. The receipt is painted there, *replacing the blank*
  ##   — leaving the receipt flush against the LLM content with no
  ##   permanent gap in scroll history.
  ## - `hadGap = false` + `hasBar = true` (first turn — welcome
  ##   painted bar without gap, no LLM content to gap from): walk up
  ##   `splitLines(line).len + 1` to land on the bar row. No receipt
  ##   to paint anyway (`hadPending` is false on first turn).
  ##
  ## Then:
  ##   1. Clear from cursor to end of screen — wipes (gap), bar,
  ##      prompt, readline echo, anything below.
  ##   2. If `hadPending`, paint the dim receipt at this row.
  ##   3. Two newlines: advance + blank separator between receipt
  ##      and user echo.
  ##   4. Echo user input line by line (❯ for first, continuation indent for
  ##      continuations).
  ##
  ## Cursor out: col 0 of the row directly after the last echo line.
  ## The next `callModel`'s leading `\n` sets up the scratch /
  ## ticker-overlay row.
  let lines = line.splitLines
  let n = if echoRows > 0: echoRows else: lines.len
  let walkBack =
    if not hasBar: n
    elif hadGap: n + 2
    else: n + 1
  result = "\x1b[" & $walkBack & "A"
  result.add "\r\x1b[J"
  if hadPending:
    result.add receiptBarBytes(receiptLabel)
    result.add "\n\n"
  elif hasBar:
    result.add "\n\n"
  # hasBar=false: cursor is on the cleared prompt row after walkback;
  # the gap row from paintInitialPrompt already provides the separator.
  # No extra newline — echo goes directly on the cleared row.
  let termW = try: terminalWidth() except CatchableError: 0
  for idx, l in lines:
    let prefix = if idx == 0: "❯ " else: "  "
    result.add prefix
    if termW <= 0:
      result.add l
    else:
      var col = 2  # prefix width — "❯ " and "  " both render as 2 cells
      var i = 0
      while i < l.len:
        let rl = max(1, runeLenAt(l, i))
        if col >= termW:
          result.add "\n  "
          col = 2
        result.add l[i ..< i + rl]
        inc col
        i += rl
    result.add "\n"

# ---------- Bar+prompt runtime helpers ----------
#
# The bar and prompt are *always visible*. These helpers hide them
# just long enough for a content write that would otherwise advance
# into them, and repaint them immediately below. Each helper also
# updates `currentBarLabel` so subsequent repaints (after a tool
# write, after an iteration end, etc.) use the same content.

proc currentTermW(): int =
  ## Best-effort terminal column count for the width-aware bar emitters.
  ## Returns 0 when stdout is not a tty (test harnesses, redirected
  ## runs) so the emitters fall back to the single-row default rather
  ## than guessing a width that doesn't match what the consumer sees.
  try: terminalWidth() except CatchableError: 0

proc paintBarPrompt*(label, promptColor: string) =
  ## Write bar + prompt at the cursor's current row, parking cursor
  ## at col 0 of the bar row. Caches `label` so a later
  ## `repaintBarPrompt` knows what to draw. Clears `currentBarHasGap`
  ## — during streaming the bar slides flush with content; only
  ## `endTurn` paints a gap.
  debugOut "paintBarPrompt label=" & label[0..min(30, label.len-1)]
  emitScreenEvent setBarEvent(label)
  screenRenderSync barFooterBytes(label, promptColor, currentTermW())

proc paintBarBelow*(label, promptColor: string) =
  ## Paint bar + prompt one and two rows below the cursor, restoring
  ## the cursor to its original (likely mid-line) position. Used
  ## during streaming to keep the bar visible while content is being
  ## accumulated in memory and the cursor stays put.
  emitScreenEvent setBarEvent(label)
  screenRenderSync barFooterBelowBytes(label, promptColor, currentTermW())

proc paintBarBelowAtCol(label, promptColor: string, col: int) =
  emitScreenEvent setBarEvent(label)
  screenRenderSync barFooterBelowAtColBytes(label, promptColor, col, currentTermW())

proc clearBarBelowAtCol(col: int) =
  screenRenderSync clearBarBelowAtColBytes(col)

proc repaintBarPrompt*(promptColor = DimPromptColor) =
  ## Re-emit the bar+prompt at the cursor's current row using the
  ## cached `currentBarLabel`. Used by `screenWriteTranscript` to put the bar
  ## back after a content write.
  if currentBarLabel.len == 0: return
  screenRenderSync barFooterBytes(currentBarLabel, promptColor, currentTermW())

proc clearBarPrompt*() =
  ## Erase the bar + prompt rows in place. Cursor parks at col 0 of
  ## the bar row so the caller can write content there (which then
  ## pushes the next `repaintBarPrompt` one row down).
  screenRenderSync ClearBarPromptBytes

proc paintPromptOnly*(promptColor: string)

proc enterPromptInput*(promptColor: string) =
  ## Prepare the physical cursor for either immediate input or buffered
  ## input during a running turn. In bar mode, repaint the shared
  ## bar+prompt footer and park on the prompt row. In prompt-only mode,
  ## clear the prompt row in place. The line editor writes its own prompt
  ## glyph after this, so the prepainted glyph is only a stable visual
  ## placeholder.
  if currentBarLabel.len > 0:
    clearBarPrompt()
    stdout.write barFooterBytes(currentBarLabel, promptColor, currentTermW())
    stdout.write "\x1b[1B"
  else:
    stdout.write "\r\x1b[2K" & promptColor & "❯ " & Reset & "\r"
  stdout.flushFile

proc resetPromptInputAfterEmpty*(echoRows: int; promptColor: string) =
  ## Empty submission should leave the prompt/footer at the same visual
  ## floor instead of drifting downward. `echoRows` is the editor's visual
  ## input height, including wraps.
  let n = max(1, echoRows)
  if currentBarLabel.len == 0:
    stdout.write "\x1b[" & $n & "A\r\x1b[J"
    paintPromptOnly(promptColor)
  else:
    stdout.write "\x1b[" & $(n + 1) & "A\r\x1b[J"
    repaintBarPrompt(promptColor)

proc enterToolViewport*(termH: int) =
  ## Enter the bounded live tool-output viewport while preserving the
  ## footer rows at the bottom of the normal terminal buffer.
  emitScreenEvent setModeEvent(smToolStreaming)
  stdout.write &"\x1b[1;{termH - 2}r"
  stdout.write &"\x1b[{termH - 2};1H"
  stdout.flushFile()

proc leaveToolViewport*(termH: int) =
  ## Leave the bounded live tool-output viewport and return to normal
  ## transcript rendering with the cursor on the bar row.
  stdout.write "\x1b[r"
  stdout.write &"\x1b[{termH - 1};1H"
  stdout.flushFile()
  emitScreenEvent setModeEvent(smNormal)

proc endTurnBytes*(label, promptColor: string, repaintPrompt: bool,
                   termW = 0): string =
  ## Byte sequence for leaving model/tool mode. Normal completion repaints
  ## the typing-ready footer; exceptional user interrupts only clear the
  ## owned footer area so the caller's feedback lands as plain output.
  if label.len > 0:
    result.add ClearBarPromptBytes
    if repaintPrompt:
      result.add "\n"
      result.add barFooterBytes(label, promptColor, termW)
  result.add "\x1b[?25h"

template screenWriteTranscript*(body: untyped) =
  ## Commit transcript output while preserving the volatile footer.
  ## The footer is cleared, body writes normal scrollback content, then
  ## the footer is repainted below the new cursor position. If the
  ## buffered prompt is active, restore that live editor in the same
  ## render-locked critical section so appended transcript rows do not
  ## erase in-progress multiline input.
  debugOut &"screenWriteTranscript enter barLabel={currentBarLabel.len}"
  acquire renderLock
  try:
    if inputThreadRunning and inputState.turnActive and inputEditor != nil:
      let up = inputEditor[].renderRow + 1
      stdout.write "\r"
      if up > 0:
        stdout.write "\x1b[" & $up & "A"
    clearBarPrompt()
    body
    debugOut "screenWriteTranscript exit"
    repaintBarPrompt()
    if inputThreadRunning and inputState.turnActive and inputEditor != nil:
      stdout.write "\x1b[1B"
      stdout.write inputEditor[].redrawBytes()
      stdout.flushFile
  finally:
    release renderLock

template withCleared*(body: untyped) =
  ## Compatibility alias while older tests and callers move to the
  ## screen-controller vocabulary.
  screenWriteTranscript:
    body

proc spinnerLoop(unused: string) {.thread.} =
  ## Three-line spinner footer rooted at the cursor row:
  ##   row N-1   reasoning ticker (overlay, dim) — shown only while
  ##             reasoning streams; the row above the bar is the
  ##             leading-`\n` scratch row callModel writes, so the
  ##             overlay always lands on a blank, and clearing the
  ##             row is a faithful restore.
  ##   row N     spinner frame + token-slot bar (cyan + bright)
  ##   row N+1   dim ❯ placeholder, the visible caret while typing
  ##             isn't possible.
  ## See `spinnerFooterBytes` for the byte sequence each frame writes.
  const frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  let start = epochTime()
  var i = 0
  var lastTicker = ""
  while not spinnerStop.load(moRelaxed):
    let elapsed = epochTime() - start
    let label = getSpinLabel()
    let ticker = getSpinTicker()
    lastTicker = ticker
    try:
      let frame = frames[i mod frames.len]
      screenRenderFooterFrame spinnerFooterBytes(frame, label, ticker, elapsed.int,
                                             currentTermW())
    except CatchableError: discard
    sleep 80
    inc i
  try:
    let termW = try: terminalWidth() except CatchableError: 80
    let tickerRows =
      if lastTicker.len == 0: 1
      else: max(1, (visibleWidth(lastTicker) + max(1, termW) - 1) div max(1, termW))
    screenRenderSync spinnerCleanupBytes(tickerRows)
  except CatchableError: discard

proc liveLabel*(base: string, slurped: int): string =
  ## Spinner label whose token slots match the per-call summary's shape:
  ## icon hugs value, slots joined by two spaces. ↑/↻ read as `0` until
  ## the final usage event closes the response; the spinner thread
  ## renders this in fgCyan + styleBright.
  var parts: seq[string]
  if base.len > 0: parts.add base
  let up = tokenSlot("↑", 0)
  if up.len > 0: parts.add up
  let cached = tokenSlot("↻", 0)
  if cached.len > 0: parts.add cached
  let down = tokenSlot("↓", slurped div 4)
  if down.len > 0: parts.add down
  parts.join("  ")

proc paintInitialBar*(p: Profile) =
  ## Welcome-time paint: one blank gap row, then bar+prompt at zero
  ## values *with* a `○ 0%` context indicator (the empty-circle glyph
  ## is the same one a populated bar carries — at startup we just
  ## haven't sent a request yet, so promptTokens is 0). Bright cyan
  ## prompt — typing-ready. Sets `currentBarHasGap = true` to match
  ## `endTurn`'s shape between turns.
  stdout.write "\n"
  let window = contextWindowFor(p.model)
  let baseLabel = contextLabel(0, window)
  paintBarPrompt(liveLabel(baseLabel, 0), BrightPromptColor)
  emitScreenEvent setBarEvent(currentBarLabel, hasGap = true)

proc paintPromptOnly*(promptColor: string) =
  ## Paint just the prompt ❯ at the cursor's current row, no token
  ## bar above. Used in the pre-first-turn startup state where we have
  ## no real token values yet — the bar stays hidden until the first
  ## model response brings them. Cursor parks at col 0 of the prompt
  ## row.
  ##
  ## Leaves `currentBarLabel = ""` and `currentBarHasGap = false` —
  ## the signals `readInput`, `emitUserSubmit`, and the slash-command
  ## repaint use to detect prompt-only mode.
  stdout.write "\x1b[2K" & promptColor & "❯ " & Reset & "\r"
  stdout.flushFile
  emitScreenEvent clearBarEvent()

proc paintInitialPrompt*(p: Profile) =
  ## Welcome-time paint when starting fresh (no prior session, no
  ## prior usage to show): one blank gap row, then just the bright
  ## cyan prompt — the token bar stays hidden until the first model
  ## response. Mirrors the shape `endTurn` would leave between turns,
  ## minus the bar.
  stdout.write "\n"
  paintPromptOnly(BrightPromptColor)


var spinnerRunning = false  # only mutated by main thread

# --- Bar tick: repaints the token bar with an incrementing elapsed counter
#     during tool execution. No spinner icon, just the bar label + time.

var barTickStop: Atomic[bool]
var barTickThread: Thread[void]
var barTickRunning = false
var barTickStart: float
var barTickBase: string
var barTickLock: Lock
barTickLock.initLock()

proc barTickLoop() {.thread.} =
  while not barTickStop.load(moRelaxed):
    var base: string
    {.cast(gcsafe).}:
      acquire barTickLock
      base = barTickBase
      release barTickLock
    let elapsed = (epochTime() - barTickStart).int
    let label = base & "  " & $elapsed & "s"
    # Re-assert hide-cursor each tick — same rationale as
    # `spinnerFooterBytes`: some terminals transiently re-show the
    # caret on cursor movement, and beginTurn's one-shot `?25l`
    # isn't enough to keep it hidden over a long-running tool.
    let tw = currentTermW()
    let th = try: terminalHeight() except CatchableError: 24
    let pos = "\x1b[" & $(th - 1) & ";1H"
    screenRenderFooterFrame "\x1b[?25l" & pos &
      barFooterBytes(label, DimPromptColor, tw)
    sleep 500

proc startBarTick*(base: string) =
  debugOut "startBarTick"
  if barTickRunning: return
  {.cast(gcsafe).}:
    acquire barTickLock
    barTickBase = base
    release barTickLock
  barTickStart = epochTime()
  barTickStop.store(false, moRelaxed)
  createThread(barTickThread, barTickLoop)
  barTickRunning = true

proc stopBarTick*(): int =
  ## Stops the bar tick and returns elapsed seconds.
  debugOut "stopBarTick"
  if not barTickRunning: return 0
  let elapsed = (epochTime() - barTickStart).int
  barTickStop.store(true, moRelaxed)
  joinThread(barTickThread)
  barTickRunning = false
  return elapsed

proc startSpinner*(label: string) =
  debugOut "startSpinner"
  if spinnerRunning: return
  if label.len > 0: setSpinLabel(label)
  spinnerStop.store(false, moRelaxed)
  createThread(spinnerThread, spinnerLoop, "")
  spinnerRunning = true

proc stopSpinner*() =
  debugOut "stopSpinner"
  if not spinnerRunning: return
  spinnerStop.store(true, moRelaxed)
  joinThread(spinnerThread)
  spinnerRunning = false

proc nowMs(): int =
  int(epochTime() * 1000.0)

proc markProviderActivity*() =
  lastProviderActivity.store(nowMs(), moRelaxed)

proc quietWatchLoop(baseLabel: string) {.thread.} =
  var shown = false
  while not quietStop.load(moRelaxed):
    let idleMs = nowMs() - lastProviderActivity.load(moRelaxed)
    if idleMs >= 15_000:
      setSpinLabel("network quiet; still waiting")
      shown = true
    elif shown:
      setSpinLabel(baseLabel)
      shown = false
    sleep 500

proc startQuietWatch(baseLabel: string) =
  if quietRunning: return
  markProviderActivity()
  quietStop.store(false, moRelaxed)
  createThread(quietThread, quietWatchLoop, baseLabel)
  quietRunning = true

proc stopQuietWatch() =
  if not quietRunning: return
  quietStop.store(true, moRelaxed)
  joinThread(quietThread)
  quietRunning = false

proc initLiveMarkdownStream*(baseLabel: string): LiveMarkdownStream =
  LiveMarkdownStream(baseLabel: baseLabel, md: initMarkdownState(),
    streamT0: epochTime(), liveCol: 2)

proc currentLabel(s: LiveMarkdownStream, slurpedNow: int): string =
  let elapsed = (epochTime() - s.streamT0).int
  liveLabel(s.baseLabel, slurpedNow) & "  " & $elapsed & "s"

proc utf8LenAt(s: string, i: int): int =
  let b = s[i].uint8
  if (b and 0x80'u8) == 0'u8: 1
  elif (b and 0xE0'u8) == 0xC0'u8: 2
  elif (b and 0xF0'u8) == 0xE0'u8: 3
  elif (b and 0xF8'u8) == 0xF0'u8: 4
  else: 1

proc captureMd(s: var LiveMarkdownStream, line: string,
               finish = false): string =
  let path = getTempDir() / "3code_live_md_" & $getCurrentProcessId()
  let f = open(path, fmWrite)
  defer:
    try: removeFile(path) except OSError: discard
  if finish:
    discard finishMd(s.md, f)
  else:
    discard handleMdLine(s.md, line, f)
  f.flushFile
  close(f)
  result = readFile(path)

proc startContent(s: var LiveMarkdownStream, slurpedNow: int) =
  if s.started: return
  setSpinTicker("")
  stopSpinner()
  stdout.styledWrite(styleBright, "● ", resetStyle)
  s.started = true
  paintBarBelow(s.currentLabel(slurpedNow), DimPromptColor)
  s.liveBarBelow = true

proc advanceLiveCol(s: var LiveMarkdownStream, text: string) =
  let termW = max(1, try: terminalWidth() except CatchableError: 80)
  s.liveCol += visibleWidth(text)
  while s.liveCol >= termW:
    s.liveCol -= termW

proc writeLiveSegment(s: var LiveMarkdownStream, text: string) =
  if text.len == 0: return
  if s.liveBarAtCursor:
    clearBarPrompt()
    s.liveBarAtCursor = false
  elif s.liveBarBelow:
    clearBarBelowAtCol(s.liveCol)
    s.liveBarBelow = false
  stdout.write text
  s.advanceLiveCol(text)
  s.liveLineEmitted = true

proc writeRendered(s: var LiveMarkdownStream, bytes: string,
                   slurpedNow: int) =
  if bytes.len == 0: return
  s.startContent(slurpedNow)
  var i = 0
  while i < bytes.len:
    if bytes[i] == '\n':
      if s.liveBarBelow:
        clearBarBelowAtCol(s.liveCol)
        s.liveBarBelow = false
      stdout.write "\n"
      s.liveCol = 0
      if s.liveLineEmitted:
        paintBarPrompt(s.currentLabel(slurpedNow), DimPromptColor)
        s.liveBarAtCursor = true
      inc i
    else:
      let start = i
      while i < bytes.len and bytes[i] != '\n':
        inc i
      s.writeLiveSegment(bytes[start ..< i])
  if s.started:
    if s.liveBarAtCursor:
      paintBarPrompt(s.currentLabel(slurpedNow), DimPromptColor)
    else:
      paintBarBelowAtCol(s.currentLabel(slurpedNow), DimPromptColor, s.liveCol)
      s.liveBarBelow = true

proc feedContent*(s: var LiveMarkdownStream, chunk: string, slurpedNow: int) =
  if chunk.len == 0: return
  var data = s.utf8Pending & chunk
  s.utf8Pending = ""
  var i = 0
  while i < data.len:
    if data[i] == '\n':
      let rendered = s.captureMd(s.pendingLine)
      s.pendingLine = ""
      s.writeRendered(rendered, slurpedNow)
      inc i
    else:
      let charLen = utf8LenAt(data, i)
      if i + charLen > data.len:
        s.utf8Pending = data[i .. ^1]
        break
      s.pendingLine.add data[i ..< i + charLen]
      i += charLen
  stdout.flushFile()

proc finishContent*(s: var LiveMarkdownStream, slurpedNow: int) =
  if s.utf8Pending.len > 0:
    s.pendingLine.add s.utf8Pending
    s.utf8Pending = ""
  if s.pendingLine.len > 0:
    let rendered = s.captureMd(s.pendingLine)
    s.pendingLine = ""
    s.writeRendered(rendered, slurpedNow)
  let tail = s.captureMd("", finish = true)
  s.writeRendered(tail, slurpedNow)
  if s.started and s.liveBarBelow:
    paintBarPrompt(s.currentLabel(slurpedNow), DimPromptColor)
    s.liveBarAtCursor = true
    s.liveBarBelow = false

when providerStub:
  proc stubUsage(content: string): Usage =
    result.promptTokens = 100
    result.completionTokens = max(1, content.len div 4)
    result.totalTokens = result.promptTokens + result.completionTokens

  proc streamStubContent(content, baseLabel: string, slurped: var int) =
    ## Provider-stub streaming path. It intentionally exercises the
    ## same footer geometry as live SSE, including chunked newlines, so
    ## terminal regressions show up in local/manual stub runs.
    if content.strip.len == 0: return
    var live = initLiveMarkdownStream(baseLabel)
    var i = 0
    while i < content.len:
      let charLen = utf8LenAt(content, i)
      let chunk = content[i ..< min(i + charLen, content.len)]
      slurped += chunk.len
      live.feedContent(chunk, slurped)
      sleep 15
      i += charLen
    live.finishContent(slurped)
    contentStreamedLive = true

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
  ## return so the streamHttp loop observes `interrupted` and bails.
  ## Safe to call from a SIGINT hook or from the stdin watcher thread.
  when defined(posix):
    let fd = cachedStreamFd
    if fd != osInvalidSocket:
      discard posix.shutdown(posix.SocketHandle(fd), SHUT_RDWR.cint)

# ---- Stream-time stdin cancel watcher ----
#
# During streamHttp's read loop, a tiny POSIX-only watcher thread polls
# stdin in non-canonical/no-isig/no-echo mode and shuts down the cached
# socket on the first ctrl-c (`\x03`) or ESC (`\x1b`) byte. The SIGINT
# hook covers ctrl-c too, but only when the terminal is in cooked mode
# at the moment the keystroke arrives — keeping a dedicated watcher
# means cancel works the same way whether the kernel turns ctrl-c into
# SIGINT or we read the raw byte ourselves, and ESC works at all (no
# signal path exists for it).
when defined(posix):
  var
    cancelWatcherStop: Atomic[bool]
    cancelWatcherThread: Thread[void]
    cancelWatcherActive: bool
    cancelOrigTermios: Termios
    cancelOrigTermiosValid: bool

  proc restoreCancelTermios*() {.noconv, gcsafe.} =
    if cancelOrigTermiosValid:
      discard tcSetAttr(0.cint, TCSANOW, addr cancelOrigTermios)
      cancelOrigTermiosValid = false

  proc cancelWatcherLoop() {.thread, nimcall.} =
    while not cancelWatcherStop.load(moRelaxed):
      var pfd: TPollfd
      pfd.fd = 0.cint  # STDIN_FILENO
      pfd.events = POLLIN
      let r = poll(addr pfd, 1.Tnfds, 100.cint)
      if r > 0 and (pfd.revents and POLLIN) != 0:
        var buf: array[64, char]
        let n = posix.read(0.cint, addr buf[0], buf.len)
        if n > 0:
          for i in 0 ..< n.int:
            let b = buf[i].uint8
            if b == 0x03 or b == 0x1b:
              {.cast(gcsafe).}:
                interrupted = true
                shutdownCachedStreamFd()
                restoreCancelTermios()
              return
            else: discard
        # else: spurious wakeup or EOF on stdin; loop and re-check stop.

  proc drainCancelInput() =
    ## Drop keystrokes pressed while the dim prompt is visible. Input is
    ## locked during provider work; carrying buffered Enter bytes into the
    ## next prompt turns an accidental keypress into a blank submission.
    if isatty(0.cint) == 0: return
    while true:
      var pfd: TPollfd
      pfd.fd = 0.cint
      pfd.events = POLLIN
      let r = poll(addr pfd, 1.Tnfds, 0.cint)
      if r <= 0 or (pfd.revents and POLLIN) == 0:
        break
      var buf: array[64, char]
      let n = posix.read(0.cint, addr buf[0], buf.len)
      if n <= 0:
        break

  proc startCancelWatcher() =
    if cancelWatcherActive: return
    if isatty(0.cint) == 0: return
    var t: Termios
    if tcGetAttr(0.cint, addr t) != 0: return
    cancelOrigTermios = t
    cancelOrigTermiosValid = true
    # Disable canonical line buffering, signal generation (so ctrl-c
    # arrives as `\x03` instead of SIGINT), and local echo. VMIN/VTIME
    # don't really matter — we only ever read after `poll` says there's
    # data — but pin them so a non-poll caller doesn't accidentally
    # block.
    t.c_lflag = t.c_lflag and not Cflag(ICANON or ECHO or ISIG)
    t.c_cc[VMIN] = 0.char
    t.c_cc[VTIME] = 0.char
    if tcSetAttr(0.cint, TCSANOW, addr t) != 0:
      cancelOrigTermiosValid = false
      return
    cancelWatcherStop.store(false, moRelaxed)
    createThread(cancelWatcherThread, cancelWatcherLoop)
    cancelWatcherActive = true

  proc stopCancelWatcher() =
    if not cancelWatcherActive: return
    cancelWatcherStop.store(true, moRelaxed)
    joinThread(cancelWatcherThread)
    cancelWatcherActive = false
    drainCancelInput()
    if cancelOrigTermiosValid:
      restoreCancelTermios()
else:
  proc startCancelWatcher() = discard
  proc stopCancelWatcher() = discard
  proc restoreCancelTermios*() {.noconv.} = discard

type StreamOutcome = object
  statusCode: int
  retryAfter: string
  errMsg: string          # non-empty on transport-level failure
  errBody: string         # non-SSE response body (error responses)
  assistantMsg: JsonNode  # reconstructed from SSE when status=200
  usage: Usage

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
      cachedStreamFd = conn.getFd
    try:
      conn.sendRequest("POST", pathQuery, host,
                       headers = [("Authorization", "Bearer " & key),
                                  ("Content-Type", "application/json"),
                                  ("Accept", "text/event-stream")],
                       body = bodyStr)
      markProviderActivity()
      resp = conn.readResponseHead()
      markProviderActivity()
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
  var live = initLiveMarkdownStream(baseLabel)
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
    markProviderActivity()
    if interrupted:
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
            setSpinLabel(liveLabel(baseLabel, slurped))
            if showThinking and not contentStarted:
              refreshTicker()
          let c = delta{"content"}.getStr("")
          if c.len > 0:
            accContent &= c
            slurped += c.len
            let visible =
              if suppressXml: feed(xmlFilter, c)
              else: c
            if visible.len > 0:
              live.feedContent(visible, slurped)
              contentStarted = live.started
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

  if suppressXml:
    let tail = flushTail(xmlFilter)
    if tail.len > 0:
      live.feedContent(tail, slurped)
      contentStarted = live.started

  if contentStarted:
    live.finishContent(slurped)
    # Collapse trailing blank rows the model emitted so the bar lands
    # flush below the last content line. The bar may currently sit
    # `trailingNl - 1` rows below where it should; clear it, walk up
    # the extras, repaint.
    var trailingNl = 0
    for i in countdown(accContent.len - 1, 0):
      if accContent[i] == '\n': inc trailingNl
      else: break
    if trailingNl > 1:
      if live.liveBarAtCursor:
        clearBarPrompt()
        live.liveBarAtCursor = false
      elif live.liveBarBelow:
        stdout.write ClearBarBelowBytes
        stdout.flushFile
        live.liveBarBelow = false
      for _ in 0 ..< trailingNl - 1:
        stdout.write "\x1b[1A\x1b[2K"
      paintBarPrompt(live.currentLabel(slurped), DimPromptColor)
    contentStreamedLive = true
    # Normalize cursor to bar row col 0. The streaming loop may have left
    # the cursor in the content area (liveBarBelow case); move it down to
    # the bar row before inserting the ticker row and restarting the spinner.
    if live.liveBarBelow:
      screenRenderSync "\x1b[1B"        # bar is 1 row below cursor
    # Now cursor is at bar row col 0.
    # Insert a blank row above the bar (ticker row for the spinner)
    # and restart the spinner so the elapsed time keeps ticking during
    # post-streaming processing (tool-call parsing, usage calculation).
    screenRenderSync "\x1b[L\x1b[1B"
    setSpinLabel(liveLabel(baseLabel, slurped))
    startSpinner("")

  if interrupted:
    if result.assistantMsg == nil:
      result.assistantMsg = buildStreamAssistantMsg(accContent, accReasoning,
        accTools, result.usage, interrupted)
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
      accTools, result.usage, interrupted)
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

template hint(args: varargs[untyped]) =
  stdout.styledWrite(fgCyan, styleBright, args, resetStyle)

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

proc inputThreadProc() {.thread.} =
  ## Runs readline while the model or a tool owns the turn. Completed text is
  ## queued for the outer REPL to send as soon as the current turn settles;
  ## partial text is handed back as the next prompt's prefill.
  {.cast(gcsafe).}:
    if inputEditor == nil:
      return
    template withRender(body: untyped) =
      acquire renderLock
      try:
        body
      finally:
        release renderLock

    let edPtr = inputEditor
    when defined(posix):
      let fd = getFileHandle(stdin)
      let getCh: minline.GetChProc = proc(): int =
        var pfd: Tpollfd
        pfd.fd = STDIN_FILENO
        pfd.events = POLLIN
        while inputState.turnActive:
          let r = poll(addr pfd, 1.Tnfds, 200.cint)
          if r < 0:
            if errno == EINTR:
              continue
            return -1
          if r > 0 and (pfd.revents and POLLIN) != 0:
            var ch: char
            if posix.read(fd.cint, addr ch, 1) == 1:
              return ch.ord.int
            return -1
        -1
    else:
      let getCh: minline.GetChProc = proc(): int =
        if inputState.turnActive: getchr().int else: -1

    let writeProc: minline.WriteProc = proc(s: string) =
      withRender:
        stdout.write s
        stdout.flushFile

    edPtr[].onMutate = proc(ed: var minline.LineEditor) =
      if inputState.autoSend:
        inputState.autoSend = false
        inputState.queuedText = ""
        inputState.queuedEchoRows = 0
        ed.renderSuffix = ""
    edPtr[].onSubmit = proc(ed: var minline.LineEditor) =
      inputState.queuedText = ed.line.text
      inputState.queuedEchoRows = minline.totalRows(ed.line.text, ed.promptW,
                                                    ed.contPromptW,
                                                    max(2, ed.width))
      inputState.autoSend = ed.line.text.len > 0
      ed.line.position = ed.line.text.len
      ed.renderSuffix =
        if inputState.autoSend: OffWhiteFg & "⏳" & Reset
        else: ""
    edPtr[].postRedraw = proc(ed: var minline.LineEditor) =
      discard

    withRender:
      enterPromptInput(TurnPromptColor)

    when defined(posix):
      var oldMode: Termios
      var haveOldMode = false
      if isatty(fd) != 0 and fd.tcGetAttr(addr oldMode) == 0:
        haveOldMode = true
        var rawMode = oldMode
        rawMode.c_iflag = rawMode.c_iflag and not Cflag(BRKINT or ICRNL or
          INPCK or ISTRIP or IXON)
        rawMode.c_cflag = (rawMode.c_cflag and not Cflag(CSIZE or PARENB)) or CS8
        rawMode.c_lflag = rawMode.c_lflag and not Cflag(ECHO or ICANON or
          IEXTEN or ISIG)
        rawMode.c_cc[VMIN] = 1.char
        rawMode.c_cc[VTIME] = 0.char
        discard fd.tcSetAttr(TCSANOW, addr rawMode)

    edPtr[].deferSubmit = true
    edPtr[].submitIcon = OffWhiteFg & "⏳" & Reset
    while inputState.turnActive:
      try:
        let text = minline.readLineWith(edPtr[], "❯ ", getCh, writeProc)
        if text.len == 0:
          continue
        if text[0] == ':':
          withRender:
            clearBarPrompt()
          if turnHandleCommand != nil:
            discard turnHandleCommand(text)
          withRender:
            enterPromptInput(TurnPromptColor)
            stdout.write edPtr[].redrawBytes()
            if edPtr[].postRedraw != nil:
              edPtr[].postRedraw(edPtr[])
            stdout.flushFile()
          if text.strip in [":q", ":quit", ":exit"]:
            inputState.cmdWasQuit = true
            interrupted = true
            break
        else:
          withRender:
            inputState.queuedText = text
            inputState.queuedEchoRows = edPtr[].echoRows
            inputState.autoSend = true
            emitScreenEvent setPromptModeEvent(pmBufferedInput)
      except minline.InputCancelled:
        interrupted = true
        break
      except EOFError:
        if edPtr[].line.text.len == 0:
          inputState.cmdWasQuit = true
          interrupted = true
        break
      except CatchableError:
        break

    when defined(posix):
      if haveOldMode:
        discard fd.tcSetAttr(TCSADRAIN, addr oldMode)
    inputState.residualText = edPtr[].line.text
    if inputState.autoSend and inputState.queuedText == inputState.residualText:
      inputState.residualText = ""
    edPtr[].onMutate = nil
    edPtr[].onSubmit = nil
    edPtr[].postRedraw = nil
    edPtr[].deferSubmit = false
    edPtr[].renderSuffix = ""
    edPtr[].getCh = nil
    edPtr[].write = nil
    edPtr[].getWidth = nil
    edPtr[].hasPendingInput = nil

proc beginTurn*() =
  ## Hide the terminal caret for the duration of the turn — the dim
  ## ❯ glyph (still painted, just not blinking) is the only
  ## visible marker while typing isn't possible.
  stdout.write "\x1b[?25l"
  stdout.flushFile
  emitScreenEvent setPromptModeEvent(pmTurnRunning)
  if inputEditor != nil and not inputThreadRunning:
    inputState = InputState(turnActive: true)
    createThread(inputThread, inputThreadProc)
    inputThreadRunning = true

proc endTurn*(repaintPrompt = true) =
  ## Transition to typing-ready state: clear the bar at its current
  ## row, advance one row to leave a blank "gap" between the last
  ## content row and the bar, repaint bar+prompt with the bright
  ## cyan prompt color. Show the terminal caret. The gap is
  ## one-shot — `emitUserSubmit` overwrites it with the receipt at
  ## next submit, so it never persists in scroll history.
  # Defensive: nothing should be animating between turns. If a tool
  # path leaked the bar-tick thread (e.g. an uncaught exception
  # past the per-tool stopBarTick), the thread would otherwise keep
  # painting the bottom row with a ticking seconds counter forever.
  # Idempotent — these are no-ops when the threads aren't running.
  discard stopBarTick()
  stopSpinner()
  let hadInputThread = inputThreadRunning
  if inputThreadRunning:
    inputState.turnActive = false
    joinThread(inputThread)
    inputThreadRunning = false
  if hadInputThread and inputEditor != nil:
    let up =
      if currentBarLabel.len > 0: inputEditor[].renderRow + 1
      else: inputEditor[].renderRow
    stdout.write "\r"
    if up > 0:
      stdout.write "\x1b[" & $up & "A"
  if currentBarLabel.len > 0:
    let label = currentBarLabel
    stdout.write endTurnBytes(label, BrightPromptColor, repaintPrompt,
                              currentTermW())
    if repaintPrompt:
      emitScreenEvent setBarEvent(label, hasGap = true)
    else:
      emitScreenEvent clearBarEvent()
  else:
    stdout.write endTurnBytes("", BrightPromptColor, repaintPrompt)
  if repaintPrompt:
    emitScreenEvent setPromptModeEvent(pmIdle)
  stdout.flushFile

proc emitUserSubmit*(line: string, echoRows = -1) =
  ## Run the user-submit transition described in `submitTransitionBytes`
  ## using the current `pendingHint`, `currentBarHasGap`, and
  ## `currentBarLabel` state. The receipt overwrites the gap (or the
  ## bar's row if no gap), echoes the user's input as scroll-history
  ## content, and parks the cursor ready for the next `callModel`'s
  ## leading `\n`. When `currentBarLabel` is empty (prompt-only
  ## startup state), the walk-back skips the (non-existent) bar row.
  ##
  ## ``echoRows`` should be the visual row count occupied by the
  ## rendered input (the editor exposes this via ``LineEditor.echoRows``)
  ## so wrap-affected logical lines are walked back over correctly. When
  ## negative, the legacy ``splitLines(line).len`` is used (still
  ## correct as long as no logical line wraps).
  let receiptLabel =
    if pendingHint.active:
      tokenLineLabel(pendingHint.usage, pendingHint.window, pendingHint.elapsed)
    else: ""
  let hadGap = currentBarHasGap
  let hasBar = currentBarLabel.len > 0
  stdout.write submitTransitionBytes(line, pendingHint.active, hadGap,
                                     receiptLabel, hasBar, echoRows)
  stdout.flushFile
  emitScreenEvent clearPendingHintEvent()
  emitScreenEvent clearBarEvent()

proc callModel*(p: Profile, messages: JsonNode, usage: var Usage, lastPromptTokens: int): JsonNode =
  when providerStub:
    block:
      let stubT0 = epochTime()
      let stubWindow = contextWindowFor(p.model)
      let stubBaseLabel = contextLabel(lastPromptTokens, stubWindow)
      stdout.write "\n"
      setSpinLabel(liveLabel(stubBaseLabel, 0))
      startSpinner("")
      startQuietWatch(liveLabel(stubBaseLabel, 0))
      let cancelWatcherStarted = not inputThreadRunning
      if cancelWatcherStarted:
        startCancelWatcher()
      defer:
        stopQuietWatch()
        if cancelWatcherStarted:
          stopCancelWatcher()
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
            if interrupted:
              stopSpinner()
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
            stopSpinner()
            raise newException(ApiError,
              errMsg & (if stubErrBody(lastFailure, node).len > 0:
                ": " & stubErrBody(lastFailure, node) else: ""))
          let retryAfter = try: parseInt(stubRetryAfter(node)) except CatchableError: 0
          let backoff =
            if retryAfter > 0: retryAfter
            elif category == "rate": min(1 shl rateRetryLevel, 90)
            else: min(1 shl serverRetryLevel, 16)
          stopSpinner()
          stderr.writeLine &"3code: {errMsg}; retry {attempt + 1}/{StubMaxAttempts} in {backoff}s"
          var waitMs = backoff * 1000
          while waitMs > 0:
            if interrupted:
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
          setSpinLabel(&"retry {attempt + 1}/{StubMaxAttempts}")
          startSpinner("")
        else:
          result = node
          break
      if result.kind == JObject and "role" notin result:
        result["role"] = %"assistant"
      debugOut &"callModel stub idx={stubResponseIdx-1} failure={stubFailureName(lastFailure)}"
      var slurped = 0
      let preStreamDelay = stubDelayMs(result, "preStreamDelayMs", 0)
      if preStreamDelay > 0:
        var remaining = preStreamDelay
        while remaining > 0:
          if interrupted:
            stopSpinner()
            raise newException(ApiError, "interrupted by user")
          let step = min(100, remaining)
          sleep(step)
          remaining -= step
      streamStubContent(result{"content"}.getStr(""), stubBaseLabel, slurped)
      stopSpinner()
      usage = stubUsage(result{"content"}.getStr(""))
      let stubElapsed = (epochTime() - stubT0).int
      let stubLabel = tokenLineLabel(usage, stubWindow, stubElapsed)
      paintBarPrompt(stubLabel, DimPromptColor)
      emitScreenEvent setPendingHintEvent(usage, stubWindow, stubElapsed)
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
  # so the dim ❯ placeholder is the only visible caret. callModel
  # itself doesn't toggle visibility — touching DECTCEM here would
  # cause a flicker between callModel iterations within a turn.
  startSpinner("")
  startQuietWatch(liveLabel(baseLabel, 0))
  let cancelWatcherStarted = not inputThreadRunning
  if cancelWatcherStarted:
    startCancelWatcher()
  defer:
    stopQuietWatch()
    if cancelWatcherStarted:
      stopCancelWatcher()
  const MaxAttempts = 8
  var outcome: StreamOutcome
  var attempt = 0
  while true:
    inc attempt
    var slurped = 0
    outcome = streamHttp(p.url & "/chat/completions", p.key, bodyStr,
                        baseLabel, slurped, xmlToolCallsFallback(p))
    if outcome.errMsg == "interrupted by user":
      stopSpinner()
      if outcome.assistantMsg == nil:
        raise newException(ApiError, "interrupted by user")
      break
    let code = outcome.statusCode
    let category = retryCategory(outcome.errMsg, outcome.assistantMsg, code)
    let retryable = category != ""
    var errMsg = outcome.errMsg
    if errMsg == "" and retryable: errMsg = "api " & $code
    if not retryable:
      stopSpinner()
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
    if contentStreamedLive:
      # Remove the ticker row inserted by the post-streaming spinner restart.
      screenRenderSync "\r\x1b[1A\x1b[M"
    paintBarPrompt(label, DimPromptColor)
    emitScreenEvent setPendingHintEvent(usage, window, elapsed.int)
    if window > 0 and usage.promptTokens.float > 0.7 * window.float and
       usage.promptTokens.float <= CompactThresholdFrac * window.float:
      screenWriteTranscript:
        subtleWriteLn(stdout,
          &"  · context at {humanTokens(usage.promptTokens)}/{humanTokens(window)} — auto-compaction will fire near {humanTokens(int(CompactThresholdFrac * window.float))}; :compact or :summarize to act now")
  else:
    screenWriteTranscript:
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
  debugOut &"callModel end streamedLive={contentStreamedLive} usage={usage.totalTokens}"
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
    interrupted = true
    # Wake any blocking `recv` on the in-flight stream socket so the
    # caller can observe `interrupted` and bail. Without this, ctrl-c
    # before the first SSE chunk just sets a flag while `recv` keeps
    # blocking until data arrives.
    shutdownCachedStreamFd())
