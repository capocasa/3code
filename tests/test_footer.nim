import std/[unicode, unittest, strutils, parseutils]
import threecode/[api, display, types]

## Self-eval for the streaming footer layout.
##
## CLAUDE.md "Token UI" section is the spec. Pinned invariants:
##
## - **bar always visible** (cyan + bright). 2-char prefix: column 0
##   is the spinner braille glyph during streaming, a space otherwise;
##   column 1 is always a space. Label starts at column 2.
## - **prompt `❯ ` always visible**. Dim while typing isn't possible,
##   bright cyan when readline is active. Sits one row below the bar.
## - **thinking ticker** is a transient overlay one row above the bar,
##   only painted while reasoning streams; restores to blank when
##   reasoning ends.
## - **token receipt** is *not* a separate row of content — it's the
##   in-place dim repaint of the previous bar's row at user-submit
##   time. The `submitTransitionBytes` sequence walks back to that
##   row, repaints it dim, and echoes the user's input below.
##
## Eyeballing terminal output costs more than writing a test. The
## grid renderer below feeds raw byte streams through an inline ANSI
## VT, then assertions read cell content / cursor / DECTCEM state.
## When a layout bug surfaces, the loop is: write the failing assertion
## here first, *then* fix the byte emitters in `api.nim` /
## `display.nim`. Don't iterate by guessing at byte sequences.

# ---------------- ANSI VT grid renderer ----------------

type
  Grid* = ref object
    rows*: seq[seq[Rune]]
    row*, col*: int
    savedRow*, savedCol*: int
    hasSaved*: bool
    cursorHidden*: bool

proc newGrid*(): Grid =
  Grid(rows: @[newSeq[Rune]()], row: 0, col: 0,
       savedRow: 0, savedCol: 0, hasSaved: false,
       cursorHidden: false)

proc ensureRow(g: Grid, r: int) =
  while g.rows.len <= r:
    g.rows.add newSeq[Rune]()

proc padTo(row: var seq[Rune], col: int) =
  while row.len < col:
    row.add Rune(' ')

proc putRune(g: Grid, r: Rune) =
  ensureRow(g, g.row)
  padTo(g.rows[g.row], g.col)
  if g.rows[g.row].len == g.col:
    g.rows[g.row].add r
  else:
    g.rows[g.row][g.col] = r
  inc g.col

proc eraseLine(g: Grid, mode: int) =
  ensureRow(g, g.row)
  case mode
  of 0:
    if g.rows[g.row].len > g.col:
      g.rows[g.row].setLen(g.col)
  of 1:
    for k in 0 ..< min(g.col, g.rows[g.row].len):
      g.rows[g.row][k] = Rune(' ')
  of 2:
    g.rows[g.row].setLen(0)
  else: discard

proc eraseDisplay(g: Grid, mode: int) =
  ensureRow(g, g.row)
  case mode
  of 0:
    # cursor → end of screen
    if g.rows[g.row].len > g.col:
      g.rows[g.row].setLen(g.col)
    g.rows.setLen(g.row + 1)
  of 1:
    # start of screen → cursor
    for r in 0 ..< g.row:
      g.rows[r].setLen(0)
    for k in 0 ..< min(g.col, g.rows[g.row].len):
      g.rows[g.row][k] = Rune(' ')
  of 2:
    for r in 0 ..< g.rows.len:
      g.rows[r].setLen(0)
  else: discard

proc parseN(s: string): int =
  if s.len == 0: 1
  else:
    var n = 0
    discard parseInt(s, n, 0)
    if n == 0: 1 else: n

proc feed*(g: Grid, bytes: string) =
  var i = 0
  while i < bytes.len:
    let b = bytes[i]
    case b
    of '\r':
      g.col = 0
      inc i
    of '\n':
      inc g.row
      g.col = 0
      ensureRow(g, g.row)
      inc i
    of '\x1b':
      if i + 1 < bytes.len and bytes[i + 1] == '[':
        var j = i + 2
        var private = false
        if j < bytes.len and bytes[j] == '?':
          private = true; inc j
        var params = ""
        while j < bytes.len and (bytes[j] in {'0'..'9'} or bytes[j] == ';'):
          params.add bytes[j]
          inc j
        if j >= bytes.len:
          i = j; continue
        let final = bytes[j]
        if private:
          if params == "25":
            if final == 'l': g.cursorHidden = true
            elif final == 'h': g.cursorHidden = false
        else:
          case final
          of 'A':
            g.row = max(0, g.row - parseN(params))
          of 'B':
            g.row += parseN(params); ensureRow(g, g.row)
          of 'C':
            g.col += parseN(params)
          of 'D':
            g.col = max(0, g.col - parseN(params))
          of 'G':
            # CSI Pn G — cursor horizontal absolute, 1-based.
            g.col = max(0, parseN(params) - 1)
          of 'K':
            var mode = 0
            if params.len > 0:
              discard parseInt(params, mode, 0)
            eraseLine(g, mode)
          of 'J':
            var mode = 0
            if params.len > 0:
              discard parseInt(params, mode, 0)
            eraseDisplay(g, mode)
          of 'm':
            discard
          of 's':
            # CSI s — save cursor (SCO).
            g.savedRow = g.row
            g.savedCol = g.col
            g.hasSaved = true
          of 'u':
            # CSI u — restore cursor (SCO).
            if g.hasSaved:
              g.row = g.savedRow
              g.col = g.savedCol
              ensureRow(g, g.row)
          of 'H', 'f':
            let semi = params.find(';')
            let r = if semi < 0: parseN(params) - 1
                    else: parseN(params[0 ..< semi]) - 1
            let c = if semi < 0: 0 else: parseN(params[semi + 1 .. ^1]) - 1
            g.row = max(0, r); g.col = max(0, c)
            ensureRow(g, g.row)
          else: discard
        i = j + 1
      else:
        inc i
    else:
      let rl = runeLenAt(bytes, i)
      let r = runeAt(bytes, i)
      putRune(g, r)
      i += rl

proc rowText*(g: Grid, r: int): string =
  if r < 0 or r >= g.rows.len: return ""
  result = ""
  for ru in g.rows[r]:
    result.add $ru

# ---------------- Bar payload geometry ----------------

suite "bar payload geometry":
  test "liveBarBytes: 2-space prefix, label starts at col 2":
    let g = newGrid()
    g.feed liveBarBytes("○ 0%  ↑0  ↻0  ↓0  0s")
    let row = rowText(g, 0)
    # Position 0 and 1 are blank, label starts at col 2.
    check row[0] == ' '
    check row[1] == ' '
    # The context glyph and label content follow immediately.
    check row.len >= 3
    check row[2 .. ^1].startsWith("○")

  test "spinnerBarBytes: spinner glyph at col 0, space at col 1":
    let g = newGrid()
    g.feed spinnerBarBytes("⠋", "○ 0%  ↑0  ↻0  ↓0", 1)
    let row = rowText(g, 0)
    # Column 0 is the braille glyph (spinner overwrites the leading
    # space); column 1 stays a space; label content from col 2.
    check row.startsWith("⠋")
    # After the multi-byte rune, runes 1 should be a space.
    let r0len = "⠋".len
    check row[r0len] == ' '
    # Label content right after.
    check "○ 0%" in row

  test "spinner and live bar share label column":
    # The same label rendered with/without the spinner must land at
    # the same column — the spinner replaces ONLY position 0, never
    # shifts the label. Compare by *column* (rune-indexed) not by
    # byte offset — the braille rune is multi-byte UTF-8 so a
    # `find` on the row text disagrees with the column.
    let g1 = newGrid()
    g1.feed liveBarBytes("LBL")
    let g2 = newGrid()
    g2.feed spinnerBarBytes("⠋", "LBL", 0)
    check g1.rows[0][2] == Rune('L')
    check g2.rows[0][2] == Rune('L')

# ---------------- bar+prompt footer ----------------

suite "bar+prompt footer":
  test "barFooterBytes: bar at row 0, prompt at row 1, no blank between":
    let g = newGrid()
    g.feed barFooterBytes("LBL  1s", DimPromptColor)
    check "LBL" in rowText(g, 0)
    check "❯" in rowText(g, 1)
    check g.row == 0
    check g.col == 0

  test "barFooterBytes parks cursor at bar row col 0":
    let g = newGrid()
    g.feed "preamble\n"
    g.feed barFooterBytes("LBL", DimPromptColor)
    # Bar at row 1 (after preamble row 0), prompt at row 2.
    check rowText(g, 0).startsWith("preamble")
    check "LBL" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    check g.row == 1
    check g.col == 0

  test "ClearBarPromptBytes erases bar+prompt rows in place":
    let g = newGrid()
    g.feed barFooterBytes("LBL", DimPromptColor)
    g.feed ClearBarPromptBytes
    check rowText(g, 0).strip == ""
    check rowText(g, 1).strip == ""
    check g.row == 0
    check g.col == 0

  test "live footer slides down with each emitted content line":
    let g = newGrid()
    # Bullet on bar row.
    g.feed "● "
    g.feed "Hello\n"
    # First repaint: bar at row 1, prompt at row 2.
    g.feed barFooterBytes("lbl  1s", DimPromptColor)
    # Next line: clear, write, repaint.
    g.feed ClearBarPromptBytes
    g.feed "  World\n"
    g.feed barFooterBytes("lbl  2s", DimPromptColor)
    # Final: content above, bar+prompt at the new bottom (no blank
    # between bar and prompt).
    check rowText(g, 0).startsWith("● Hello")
    check rowText(g, 1).startsWith("  World")
    check "lbl" in rowText(g, 2)
    check "❯" in rowText(g, 3)
    # No blank separator between bar (row 2) and prompt (row 3).
    check rowText(g, 2).strip != ""
    check rowText(g, 3).strip != ""

  test "prompt color toggles between dim and bright cyan":
    # Same label, different prompt color — the bar payload is the
    # same; only the prompt SGR differs. Bytes assertion only (the
    # grid renderer doesn't track SGR).
    check DimPromptColor != BrightPromptColor
    check DimPromptColor in barFooterBytes("LBL", DimPromptColor)
    check BrightPromptColor in barFooterBytes("LBL", BrightPromptColor)
    check DimPromptColor notin barFooterBytes("LBL", BrightPromptColor)

# ---------------- mid-line bar visibility ----------------
#
# The user-visible "bar disappears during streaming" symptom comes
# from the streaming loop only repainting on `\n`. When the model
# emits a long partial line (no `\n` yet), the bar would stay missing
# for the entire wait. `barFooterBelowBytes` (CSI s/u save/restore)
# paints the bar one row below the cursor without disturbing the
# content row, so the bar stays visible through pendingLine
# accumulation.

suite "mid-line bar visibility":
  test "barFooterBelowBytes paints bar+prompt below, walks cursor to col 2":
    let g = newGrid()
    # Canonical mid-line state: cursor is at the bullet row col 2
    # (right after `● ` writes). Content accumulates in memory but
    # no terminal write has advanced past col 2 yet.
    g.feed "● "
    g.feed barFooterBelowBytes("LBL  1s", DimPromptColor)
    # Bar at row 1, prompt at row 2.
    check rowText(g, 0).startsWith("● ")
    check "LBL" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    # Cursor walked back to bullet row col 2 (right after `● `) —
    # uses `\x1b[2A\x1b[3G` instead of CSI s/u (SCO save/restore is
    # silently ignored on some terminals; we hit a regression where
    # each refresh stacked another bar in scroll).
    check g.row == 0
    check g.col == 2

  test "ClearBarBelowBytes wipes bar+prompt below, walks cursor to col 2":
    let g = newGrid()
    g.feed "● "
    g.feed barFooterBelowBytes("LBL", DimPromptColor)
    g.feed ClearBarBelowBytes
    check rowText(g, 0).startsWith("● ")
    check rowText(g, 1).strip == ""
    check rowText(g, 2).strip == ""
    check g.row == 0
    check g.col == 2

  test "repeated paintBarBelow does NOT stack bars in scroll":
    # Regression: CSI s/u was ignored on some terminals, so each
    # refresh advanced cursor 2 rows without restore — 30 chunks
    # stacked 30 bars in scroll history before the first `\n`. The
    # walk-up-relative emitter must keep cursor on row 0 col 2.
    let g = newGrid()
    g.feed "● "
    for i in 0 .. 30:
      g.feed barFooterBelowBytes("↓" & $i, DimPromptColor)
    # After 31 paints, only one bar+prompt visible (rows 1 + 2).
    check rowText(g, 0).startsWith("● ")
    check "↓30" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    # No bar payload anywhere from row 3 onward.
    for r in 3 ..< g.rows.len:
      check "↓" notin rowText(g, r)
    check g.row == 0
    check g.col == 2

  test "first chunk no \\n: bar visible from bullet onwards":
    let g = newGrid()
    # Bullet → paintBarBelow → mid-line content. No `\n` yet; bar
    # must already be visible. Bullet at row 0, bar at row 1, prompt
    # at row 2.
    g.feed "● "
    g.feed barFooterBelowBytes("↑0  ↻0  ↓5  1s", DimPromptColor)
    # Cursor at row 0 col 2. Content writes there.
    g.feed "Hello"
    check rowText(g, 0).startsWith("● Hello")
    check "↓5" in rowText(g, 1)
    check "❯" in rowText(g, 2)

  test "transition mid-line → \\n: bar replaces below-bar at-cursor":
    let g = newGrid()
    g.feed "● "
    g.feed barFooterBelowBytes("LBL  1s", DimPromptColor)
    g.feed "Hello"
    # After mid-line content, bar still below.
    check "LBL" in rowText(g, 1)
    # Now `\n` arrives. Content writes "\n" → cursor advances onto
    # row 1 (where bar was). paintBarPrompt's leading clear erases
    # old bar and writes new one in place.
    g.feed "\n"
    g.feed barFooterBytes("LBL  2s", DimPromptColor)
    # Row 0 still has "● Hello"; row 1 now NEW bar; row 2 prompt.
    check rowText(g, 0).startsWith("● Hello")
    check "LBL" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    # No double bar — old bar at row 1 was overwritten cleanly.
    check rowText(g, 1).count("LBL") == 1

# ---------------- spinner footer ----------------

suite "spinner footer":
  test "ticker overlay row blank when no reasoning":
    let g = newGrid()
    g.feed "\n"  # callModel's leading \n — scratch row above bar
    g.feed spinnerFooterBytes("⠋", "lbl", "", 1)
    check rowText(g, 0).strip == ""
    check "⠋" in rowText(g, 1)
    check "1s" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    check g.row == 1
    check g.col == 0

  test "ticker overlay populated when reasoning":
    let g = newGrid()
    g.feed "\n"
    g.feed spinnerFooterBytes("⠋", "lbl", "  … pondering", 2)
    check "pondering" in rowText(g, 0)
    check "⠋" in rowText(g, 1)
    check "❯" in rowText(g, 2)

  test "reasoning → no-reasoning restores blank above bar":
    let g = newGrid()
    g.feed "\n"
    g.feed spinnerFooterBytes("⠋", "lbl", "  … reasoning", 1)
    check "reasoning" in rowText(g, 0)
    g.feed spinnerFooterBytes("⠙", "lbl", "", 2)
    check rowText(g, 0).strip == ""
    check "⠙" in rowText(g, 1)

  test "spinner cleanup wipes all three footer rows":
    let g = newGrid()
    g.feed "\n"
    g.feed spinnerFooterBytes("⠋", "lbl", "  … reasoning", 1)
    g.feed SpinnerCleanupBytes
    check rowText(g, 0).strip == ""
    check rowText(g, 1).strip == ""
    check rowText(g, 2).strip == ""
    check g.row == 1
    check g.col == 0

# ---------------- token receipt (in-place repaint) ----------------
#
# The receipt is NOT a separate content row. It's the in-place dim
# repaint of the previous bar's row at user-submit time. After
# `submitTransitionBytes` runs:
#
#   row K     dim receipt (was the cyan+bright bar)
#   row K+1   blank (separator)
#   row K+2   user echo (`❯ <input>`)
#   ...       further lines if multi-line input
#
# The bar+prompt that were on rows K, K+1 are gone — `clear-to-EOS`
# erased them; the dim receipt replaces the bar's row, the prompt is
# wiped. The next callModel will paint a fresh bar+prompt below.

suite "token receipt placement":
  let usage = Usage(
    promptTokens: 3800, completionTokens: 45,
    totalTokens: 3845, cachedTokens: 0,
  )

  test "tokenLineLabel: empty when no totals":
    check tokenLineLabel(Usage(), 200_000) == ""
    check tokenLineLabel(usage, 200_000) != ""

  test "receiptBarBytes: dim payload, no leading clear, no \\n":
    let bytes = receiptBarBytes("○ 2%  ↑3.8k  ↻0  ↓45  1s")
    check bytes.startsWith("\x1b[2m  ")
    check bytes.endsWith("\x1b[0m")
    check '\n' notin bytes

  test "receiptBarBytes: empty label → empty bytes":
    check receiptBarBytes("") == ""

  test "submitTransitionBytes: 1-line input, no pending — receipt skipped":
    # Stage: bar at row 0, prompt at row 1, user types "hello", Enter
    # lands cursor at row 2.
    let g = newGrid()
    g.feed barFooterBytes("↑0  ↻0  ↓0  0s", BrightPromptColor)
    # Cursor at row 0 col 0 (bar row). Walk to prompt row, draw
    # readline, type "hello", press Enter.
    g.feed "\n\r\x1b[2K"  # readInput's cursor advance + clear
    g.feed "❯ hello\n"     # minline draw + Enter
    # Now feed submitTransitionBytes for non-pending case.
    g.feed submitTransitionBytes("hello", hadPending = false, "")
    # Row 0 must NOT be a receipt (no pending). Row 1 blank. Row 2
    # echo.
    check "↑3.8k" notin rowText(g, 0)
    check rowText(g, 0).strip == ""
    check rowText(g, 1).strip == ""
    check rowText(g, 2).startsWith("❯ hello")

  test "submitTransitionBytes: 1-line input + pending receipt":
    let g = newGrid()
    g.feed barFooterBytes(tokenLineLabel(usage, 200_000, 1), BrightPromptColor)
    g.feed "\n\r\x1b[2K"
    g.feed "❯ next\n"
    let label = tokenLineLabel(usage, 200_000, 1)
    g.feed submitTransitionBytes("next", hadPending = true, label)
    # Row 0 = receipt (carries `↑3.8k`).
    check "3.8k" in rowText(g, 0)
    # Row 1 = blank separator.
    check rowText(g, 1).strip == ""
    # Row 2 = user echo.
    check rowText(g, 2).startsWith("❯ next")
    # Receipt is dim — verify SGR in the raw bytes.
    check "\x1b[2m" in submitTransitionBytes("next", true, label)

  test "submitTransitionBytes: multi-line input walks back N+1 rows":
    let g = newGrid()
    g.feed barFooterBytes("LBL", BrightPromptColor)
    # User types "foo" on prompt row, continuation, "bar" on next row.
    g.feed "\n\r\x1b[2K"
    g.feed "❯ foo\n"      # row 1
    g.feed "  bar\n"      # row 2 — continuation
    # Cursor at row 3 col 0. Feed transition for 2-line input.
    let label = tokenLineLabel(usage, 200_000, 1)
    g.feed submitTransitionBytes("foo\nbar", hadPending = true, label)
    # Walk-back is splitLines.len + 1 = 3 → land on row 0 (bar row).
    # Receipt repaints row 0; rows 1+ wiped by \x1b[J.
    check "3.8k" in rowText(g, 0)
    check rowText(g, 1).strip == ""
    check rowText(g, 2).startsWith("❯ foo")
    check rowText(g, 3).startsWith("  bar")

  test "submitTransitionBytes: cursor lands after echo, ready for callModel \\n":
    let g = newGrid()
    g.feed barFooterBytes("LBL", BrightPromptColor)
    g.feed "\n\r\x1b[2K"
    g.feed "❯ hi\n"
    let label = tokenLineLabel(usage, 200_000, 1)
    g.feed submitTransitionBytes("hi", true, label)
    # Receipt at 0, blank at 1, echo at 2, cursor parked at 3 col 0.
    check g.row == 3
    check g.col == 0

# ---------------- runTurns lifecycle ----------------
#
# The key state-flag invariant: `pendingHint.active` is set after
# `callModel` parses usage; it survives `endTurn` (typing-ready
# repaint) and is consumed by the next `emitUserSubmit`.

suite "runTurns boundaries":
  let usage = Usage(
    promptTokens: 3800, completionTokens: 45,
    totalTokens: 3845, cachedTokens: 0,
  )

  template withPendingHint(body: untyped) =
    let saved = pendingHint
    pendingHint = (active: true, usage: usage,
                   window: 200_000, elapsed: 1)
    body
    pendingHint = saved

  test "beginTurn does NOT consume pendingHint":
    # beginTurn just hides the cursor — receipt rendering moved to
    # `emitUserSubmit` at user-submit time.
    withPendingHint:
      beginTurn()
      check pendingHint.active

  test "endTurn does NOT consume pendingHint":
    # Receipt survives endTurn so the *next* emitUserSubmit can paint
    # it. If this fails, someone moved the receipt logic into endTurn.
    withPendingHint:
      let savedLabel = currentBarLabel
      currentBarLabel = "LBL"
      endTurn()
      check pendingHint.active
      check pendingHint.usage.totalTokens == 3845
      currentBarLabel = savedLabel

  test "emitUserSubmit consumes pendingHint":
    withPendingHint:
      currentBarLabel = "LBL"
      emitUserSubmit("hello")
      check not pendingHint.active

  test "emitUserSubmit clears currentBarLabel":
    # The new bar is painted by the next callModel iteration — we
    # don't carry the old label across the submit transition.
    withPendingHint:
      currentBarLabel = "LBL"
      emitUserSubmit("hello")
      check currentBarLabel == ""

# ---------------- Full turn lifecycle ----------------
#
# Replay the byte stream a real turn produces and pin which row
# carries what at every checkpoint.

# styledWrite(fgWhite, styleDim, "<text>\n", resetStyle) emits this.
proc styledLineBytes(text: string): string =
  "\x1b[37m\x1b[2m" & text & "\n\x1b[0m\x1b[0m"

suite "full turn lifecycle":
  let usage = Usage(
    promptTokens: 3800, completionTokens: 45,
    totalTokens: 3845, cachedTokens: 0,
  )

  test "single turn: bar visible during streaming, finalised at end":
    let g = newGrid()
    # ---- welcome paints initial bar+prompt at zeros ----
    g.feed "  ╭─╮\n   ─┤  3code v0.0\n  ╰─╯\n"
    g.feed barFooterBytes("↑0  ↻0  ↓0", BrightPromptColor)
    # Bar at row 3, prompt at row 4, cursor at row 3 col 0.
    check "↑0" in rowText(g, 3)
    check "❯" in rowText(g, 4)
    # ---- readInput: walk down to prompt row, clear, type, Enter ----
    g.feed "\n\r\x1b[2K"          # readInput's advance + clear
    g.feed "❯ test prompt\n"      # minline echo + Enter
    # Cursor at row 5 col 0.
    # ---- emitUserSubmit (first turn — pending NOT active) ----
    g.feed submitTransitionBytes("test prompt", hadPending = false, "")
    # Walk back 2 rows to bar row 3, \x1b[J wipes from row 3 down.
    # Row 3 stays blank (no receipt — first turn). Row 4 blank,
    # row 5 user echo.
    check rowText(g, 3).strip == ""
    check rowText(g, 4).strip == ""
    check rowText(g, 5).startsWith("❯ test prompt")
    check g.row == 6 and g.col == 0
    # ---- runTurns → beginTurn (hide cursor) ----
    g.feed "\x1b[?25l"
    check g.cursorHidden
    # ---- callModel: leading \n + spinner ----
    g.feed "\n"
    g.feed spinnerFooterBytes("⠋", "↑0  ↻0  ↓0", "", 0)
    # Bar at row 7 (cursor advance), prompt at row 8, scratch at row 6.
    check "⠋" in rowText(g, 7)
    check "❯" in rowText(g, 8)
    # ---- content arrives ----
    g.feed SpinnerCleanupBytes
    g.feed "\x1b[37m\x1b[1m● \x1b[0m"
    g.feed styledLineBytes("Hello")
    g.feed barFooterBytes("↑0  ↻0  ↓5  1s", DimPromptColor)
    # Bar visible during streaming.
    let barRow = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "↓5" in rowText(g, r): found = r; break
      found
    check barRow >= 0
    check "❯" in rowText(g, barRow + 1)
    # Second content line.
    g.feed ClearBarPromptBytes
    g.feed styledLineBytes("  World")
    g.feed barFooterBytes("↑0  ↻0  ↓11  2s", DimPromptColor)
    let barRow2 = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "↓11" in rowText(g, r): found = r; break
      found
    check barRow2 == barRow + 1
    check "❯" in rowText(g, barRow2 + 1)
    # ---- streamHttp finishContent + final paintBarPrompt ----
    g.feed ClearBarPromptBytes
    g.feed barFooterBytes("↑0  ↻0  ↓11  2s", DimPromptColor)
    # ---- callModel post-stream: repaint with accurate values ----
    g.feed barFooterBytes(tokenLineLabel(usage, 200_000, 2), DimPromptColor)
    let finalBarRow = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "3.8k" in rowText(g, r) and "↓45" in rowText(g, r):
          found = r; break
      found
    check finalBarRow == barRow2
    # No blank between bar and prompt.
    check "❯" in rowText(g, finalBarRow + 1)
    # ---- endTurn: bright cyan prompt + show cursor ----
    g.feed barFooterBytes(tokenLineLabel(usage, 200_000, 2), BrightPromptColor)
    g.feed "\x1b[?25h"
    check not g.cursorHidden

  test "turn 2: receipt morphs turn 1's bar in place":
    # Stage turn 1 final: bar with iter-1 values, prompt below.
    let g = newGrid()
    g.feed "● Hello\n"
    let iter1Label = tokenLineLabel(usage, 200_000, 1)
    g.feed barFooterBytes(iter1Label, BrightPromptColor)
    let bar1Row = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "3.8k" in rowText(g, r): found = r; break
      found
    check bar1Row >= 0
    # ---- readInput (turn 2): walk to prompt row, type, Enter ----
    g.feed "\n\r\x1b[2K"
    g.feed "❯ elaborate\n"
    # ---- emitUserSubmit (turn 2 — pending IS active) ----
    g.feed submitTransitionBytes("elaborate", hadPending = true, iter1Label)
    # Receipt repaints bar1Row dim with the same label content.
    check "3.8k" in rowText(g, bar1Row)
    # Row right below = blank separator.
    check rowText(g, bar1Row + 1).strip == ""
    # Row two below = user echo.
    check rowText(g, bar1Row + 2).startsWith("❯ elaborate")
    # Receipt is dim (in raw bytes).
    check "\x1b[2m" in submitTransitionBytes("elaborate", true, iter1Label)

  test "tool exec under withCleared: bar+prompt slide down":
    # Bar at row 0, prompt at row 1. Tool exec writes content above
    # via clearBarPrompt + body + repaintBarPrompt-like sequence.
    let g = newGrid()
    g.feed barFooterBytes("LBL", DimPromptColor)
    # withCleared body: clear → write → repaint.
    g.feed ClearBarPromptBytes
    g.feed "  bash   ls\n"
    g.feed "  total 16\n"
    g.feed barFooterBytes("LBL", DimPromptColor)
    # Tool output rows 0-1, bar slid down to row 2, prompt row 3.
    check "bash" in rowText(g, 0)
    check "total 16" in rowText(g, 1)
    check "LBL" in rowText(g, 2)
    check "❯" in rowText(g, 3)
    # No blank between bar and prompt.
    check rowText(g, 2).strip != ""
    check rowText(g, 3).strip != ""

  test "iter 2 stream end: bar at new bottom with no blank above prompt":
    let g = newGrid()
    # Iter 1 stream end.
    g.feed "● iter 1 content\n"
    g.feed barFooterBytes("↑0  ↻0  ↓18  1s", DimPromptColor)
    # Tool exec under withCleared.
    g.feed ClearBarPromptBytes
    g.feed "  bash   ls\n"
    g.feed "  total 16\n"
    g.feed barFooterBytes("↑0  ↻0  ↓18  1s", DimPromptColor)
    # Iter 2: callModel \n + spinner + content + finalise.
    g.feed "\n"
    g.feed spinnerFooterBytes("⠋", "ctx 5%  ↑0  ↻0  ↓0", "", 0)
    g.feed SpinnerCleanupBytes
    g.feed "\x1b[37m\x1b[1m● \x1b[0m"
    g.feed styledLineBytes("iter 2 content")
    g.feed barFooterBytes("ctx 5%  ↑0  ↻0  ↓14  1s", DimPromptColor)
    g.feed ClearBarPromptBytes
    g.feed barFooterBytes("ctx 5%  ↑0  ↻0  ↓14  1s", DimPromptColor)
    # Final state: iter 2 bar visible with prompt directly below.
    let bar2Row = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "↓14" in rowText(g, r): found = r; break
      found
    check bar2Row >= 0
    check "❯" in rowText(g, bar2Row + 1)

  test "DECTCEM hide on beginTurn, show on endTurn":
    let g = newGrid()
    check not g.cursorHidden
    g.feed "\x1b[?25l"
    check g.cursorHidden
    g.feed "\x1b[?25h"
    check not g.cursorHidden

  test "multi-line content in one chunk: bar painted after every \\n":
    # Per-line repaint pattern: bar visible at every checkpoint.
    let g = newGrid()
    g.feed "\x1b[37m\x1b[1m● \x1b[0m"
    g.feed styledLineBytes("Line 1")
    g.feed barFooterBytes("lbl  1s", DimPromptColor)
    check "Line 1" in rowText(g, 0)
    check "lbl" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    g.feed ClearBarPromptBytes
    g.feed styledLineBytes("  Line 2")
    g.feed barFooterBytes("lbl  2s", DimPromptColor)
    check "Line 2" in rowText(g, 1)
    check "lbl" in rowText(g, 2)
    check "❯" in rowText(g, 3)
    g.feed ClearBarPromptBytes
    g.feed styledLineBytes("  Line 3")
    g.feed barFooterBytes("lbl  3s", DimPromptColor)
    check "Line 3" in rowText(g, 2)
    check "lbl" in rowText(g, 3)
    check "❯" in rowText(g, 4)
