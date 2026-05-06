import std/[unicode, unittest, strutils, parseutils, json, os]
import threecode/[api, display, types, util, compact]

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
    g.feed liveBarBytes("○ 0%          ↓0  0s")
    let row = rowText(g, 0)
    # Position 0 and 1 are blank, label starts at col 2.
    check row[0] == ' '
    check row[1] == ' '
    # The context glyph and label content follow immediately.
    check row.len >= 3
    check row[2 .. ^1].startsWith("○")

  test "spinnerBarBytes: spinner glyph at col 0, space at col 1":
    let g = newGrid()
    g.feed spinnerBarBytes("⠋", "○ 0%          ↓0", 1)
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
    g.feed barFooterBelowBytes("        ↓5  1s", DimPromptColor)
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

  test "receiptBarBytes: grey payload, no leading clear, no \\n":
    let bytes = receiptBarBytes("○ 2%  ↑3.8k      ↓45  1s")
    check bytes.startsWith(GreyFg & "  ")
    check bytes.endsWith(Reset)
    check '\n' notin bytes

  test "receiptBarBytes: empty label → empty bytes":
    check receiptBarBytes("") == ""

  test "submitTransitionBytes: no gap, no pending — receipt skipped":
    # Stage: bar at row 0 (no gap above), prompt at row 1, user types
    # "hello", Enter lands cursor at row 2.
    let g = newGrid()
    g.feed barFooterBytes("        ↓0  0s", BrightPromptColor)
    g.feed "\n\r\x1b[2K"
    g.feed "❯ hello\n"
    g.feed submitTransitionBytes("hello", hadPending = false,
                                 hadGap = false, "")
    # Walk-back nLines+1 = 2 → row 0 (bar row). \x1b[J wipes from
    # there. No receipt. \n\n + echo.
    check rowText(g, 0).strip == ""
    check rowText(g, 1).strip == ""
    check rowText(g, 2).startsWith("❯ hello")

  test "submitTransitionBytes: no gap + pending receipt":
    let g = newGrid()
    g.feed barFooterBytes(tokenLineLabel(usage, 200_000, 1), BrightPromptColor)
    g.feed "\n\r\x1b[2K"
    g.feed "❯ next\n"
    let label = tokenLineLabel(usage, 200_000, 1)
    g.feed submitTransitionBytes("next", hadPending = true,
                                 hadGap = false, label)
    # Row 0 = receipt (carries `↑3.8k`), row 1 = blank, row 2 = echo.
    check "3.8k" in rowText(g, 0)
    check rowText(g, 1).strip == ""
    check rowText(g, 2).startsWith("❯ next")
    check GreyFg in submitTransitionBytes("next", true, false, label)

  test "submitTransitionBytes: hadGap=true overwrites the gap row":
    # Stage typing-ready state: LLM line at row 0, *gap* (blank) at
    # row 1, bar at row 2, prompt at row 3. User types "next", Enter
    # lands cursor at row 4.
    let g = newGrid()
    g.feed "● Hello\n"                                     # row 0
    g.feed "\n"                                            # row 1: gap
    g.feed barFooterBytes(tokenLineLabel(usage, 200_000, 1),
                          BrightPromptColor)               # bar @ 2, prompt @ 3
    g.feed "\n\r\x1b[2K"                                   # readInput
    g.feed "❯ next\n"                                      # row 3 echo + Enter
    let label = tokenLineLabel(usage, 200_000, 1)
    g.feed submitTransitionBytes("next", hadPending = true,
                                 hadGap = true, label)
    # Walk-back nLines+2 = 3 → row 1 (the gap row). Receipt lands
    # there, *replacing the blank* — flush against "● Hello" at row 0.
    check rowText(g, 0).startsWith("● Hello")
    check "3.8k" in rowText(g, 1)               # receipt on the old gap
    check rowText(g, 2).strip == ""             # blank separator
    check rowText(g, 3).startsWith("❯ next")    # user echo
    # Crucially: no permanent gap survives into scroll history. The
    # receipt is FLUSH against the LLM content.
    check rowText(g, 0).strip != ""
    check rowText(g, 1).strip != ""

  test "submitTransitionBytes: multi-line input + hadGap walks back N+2":
    let g = newGrid()
    g.feed "● Hello\n"                # row 0
    g.feed "\n"                       # row 1: gap
    g.feed barFooterBytes("LBL", BrightPromptColor)   # bar @ 2, prompt @ 3
    g.feed "\n\r\x1b[2K"
    g.feed "❯ foo\n"                  # row 3
    g.feed "  bar\n"                  # row 4 (continuation)
    # Cursor at row 5. nLines=2, hadGap=true → walk back 4 → row 1.
    let label = tokenLineLabel(usage, 200_000, 1)
    g.feed submitTransitionBytes("foo\nbar", hadPending = true,
                                 hadGap = true, label)
    check rowText(g, 0).startsWith("● Hello")
    check "3.8k" in rowText(g, 1)               # receipt
    check rowText(g, 2).strip == ""             # blank separator
    check rowText(g, 3).startsWith("❯ foo")
    check rowText(g, 4).startsWith("  bar")

  test "submitTransitionBytes: cursor lands after echo, ready for callModel \\n":
    let g = newGrid()
    g.feed barFooterBytes("LBL", BrightPromptColor)
    g.feed "\n\r\x1b[2K"
    g.feed "❯ hi\n"
    let label = tokenLineLabel(usage, 200_000, 1)
    g.feed submitTransitionBytes("hi", hadPending = true, hadGap = false,
                                 label)
    # Receipt at 0, blank at 1, echo at 2, cursor parked at 3 col 0.
    check g.row == 3
    check g.col == 0

  test "submitTransitionBytes: hasBar=false walks back N (prompt-only)":
    # Prompt-only startup state: no bar painted, prompt at row 0,
    # user types "hello", Enter lands cursor at row 1.
    let g = newGrid()
    g.feed "\x1b[2K" & BrightPromptColor & "❯ \x1b[0m\r"
    g.feed "\r\x1b[2K"             # readInput's in-place clear
    g.feed "❯ hello\n"             # minline echo + Enter
    g.feed submitTransitionBytes("hello", hadPending = false,
                                 hadGap = false, "", hasBar = false)
    # Walk-back nLines=1 → row 0 (the prompt row). \x1b[J wipes from
    # there. No receipt (first turn). \n\n + echo at row 2.
    check rowText(g, 0).strip == ""
    check rowText(g, 1).strip == ""
    check rowText(g, 2).startsWith("❯ hello")
    check g.row == 3
    check g.col == 0

  test "submitTransitionBytes: hasBar=false multi-line walks back N":
    let g = newGrid()
    g.feed "\x1b[2K" & BrightPromptColor & "❯ \x1b[0m\r"
    g.feed "\r\x1b[2K"
    g.feed "❯ foo\n"
    g.feed "  bar\n"
    # Cursor at row 2. nLines=2, hasBar=false → walk back 2 → row 0.
    g.feed submitTransitionBytes("foo\nbar", hadPending = false,
                                 hadGap = false, "", hasBar = false)
    check rowText(g, 0).strip == ""
    check rowText(g, 1).strip == ""
    check rowText(g, 2).startsWith("❯ foo")
    check rowText(g, 3).startsWith("  bar")

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
      let savedGap = currentBarHasGap
      currentBarLabel = "LBL"
      endTurn()
      check pendingHint.active
      check pendingHint.usage.totalTokens == 3845
      currentBarLabel = savedLabel
      currentBarHasGap = savedGap

  test "endTurn sets currentBarHasGap = true":
    # endTurn transitions to typing-ready: bar+prompt repaint with
    # bright cyan prompt, AND a one-row gap is added between the
    # bar and the row above it (breathing room while user reads).
    let savedLabel = currentBarLabel
    let savedGap = currentBarHasGap
    currentBarLabel = "LBL"
    currentBarHasGap = false
    endTurn()
    check currentBarHasGap
    currentBarLabel = savedLabel
    currentBarHasGap = savedGap

  test "paintBarPrompt clears currentBarHasGap":
    # Mid-stream paints (per-\n, end-of-chunk refresh, accurate
    # repaint after callModel parses usage) — none of these have
    # a gap. Gap only appears at endTurn.
    let savedLabel = currentBarLabel
    let savedGap = currentBarHasGap
    currentBarHasGap = true
    paintBarPrompt("LBL", DimPromptColor)
    check not currentBarHasGap
    currentBarLabel = savedLabel
    currentBarHasGap = savedGap

  test "emitUserSubmit consumes pendingHint":
    withPendingHint:
      currentBarLabel = "LBL"
      emitUserSubmit("hello")
      check not pendingHint.active

  test "emitUserSubmit clears currentBarLabel and currentBarHasGap":
    # The new bar is painted by the next callModel iteration — we
    # don't carry the old label across the submit transition.
    withPendingHint:
      currentBarLabel = "LBL"
      currentBarHasGap = true
      emitUserSubmit("hello")
      check currentBarLabel == ""
      check not currentBarHasGap

  test "paintInitialBar: startup label leads with `○0%` context":
    # Bug: welcome-time paint passed an empty base to liveLabel, so
    # the bar showed `        ↓0` with no context indicator. Should
    # match the shape a populated bar carries: glyph + percent first.
    let savedLabel = currentBarLabel
    let savedGap = currentBarHasGap
    let p = Profile(model: "glm-4.7")
    paintInitialBar(p)
    check currentBarLabel.startsWith("○0%")
    check "  " in currentBarLabel
    check currentBarHasGap
    currentBarLabel = savedLabel
    currentBarHasGap = savedGap

  test "paintInitialPrompt: prompt-only, no bar, no stale state":
    # Fresh-startup paint hides the token bar and shows just the
    # bright cyan prompt. `currentBarLabel` and `currentBarHasGap`
    # are the signals readInput / emitUserSubmit / the slash-command
    # repaint use to detect prompt-only mode — must end up cleared
    # even if a previous run left them populated.
    let savedLabel = currentBarLabel
    let savedGap = currentBarHasGap
    currentBarLabel = "stale"
    currentBarHasGap = true
    let p = Profile(model: "glm-4.7")
    paintInitialPrompt(p)
    check currentBarLabel == ""
    check not currentBarHasGap
    currentBarLabel = savedLabel
    currentBarHasGap = savedGap

  test "paintPromptOnly: clears state, paints in place":
    # Used by readInput's empty-Enter handler and the slash-command
    # repaint when in prompt-only mode. Resets the bar-mode signals
    # so the next readInput knows to clear in place rather than walk
    # down to a non-existent bar row.
    let savedLabel = currentBarLabel
    let savedGap = currentBarHasGap
    currentBarLabel = "stale"
    currentBarHasGap = true
    paintPromptOnly(BrightPromptColor)
    check currentBarLabel == ""
    check not currentBarHasGap
    currentBarLabel = savedLabel
    currentBarHasGap = savedGap

# ---------------- Full turn lifecycle ----------------
#
# Replay the byte stream a real turn produces and pin which row
# carries what at every checkpoint.

# Markdown body now rides the terminal's default fg (no envelope SGR);
# stdout.write(text & "\n") is the byte form.
proc styledLineBytes(text: string): string =
  text & "\n"

suite "full turn lifecycle":
  let usage = Usage(
    promptTokens: 3800, completionTokens: 45,
    totalTokens: 3845, cachedTokens: 0,
  )

  test "single turn: bar visible during streaming, finalised at end":
    let g = newGrid()
    # ---- welcome paints initial bar+prompt at zeros ----
    g.feed "  ╭─╮\n   ─┤  3code v0.0\n  ╰─╯\n"
    g.feed barFooterBytes("        ↓0", BrightPromptColor)
    # Bar at row 3, prompt at row 4, cursor at row 3 col 0.
    check "  " in rowText(g, 3)
    check "❯" in rowText(g, 4)
    # ---- readInput: walk down to prompt row, clear, type, Enter ----
    g.feed "\n\r\x1b[2K"          # readInput's advance + clear
    g.feed "❯ test prompt\n"      # minline echo + Enter
    # Cursor at row 5 col 0.
    # ---- emitUserSubmit (first turn — pending NOT active) ----
    g.feed submitTransitionBytes("test prompt", hadPending = false,
                                 hadGap = false, "")
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
    g.feed spinnerFooterBytes("⠋", "        ↓0", "", 0)
    # Bar at row 7 (cursor advance), prompt at row 8, scratch at row 6.
    check "⠋" in rowText(g, 7)
    check "❯" in rowText(g, 8)
    # ---- content arrives ----
    g.feed SpinnerCleanupBytes
    g.feed "\x1b[36m\x1b[1m● \x1b[0m"
    g.feed styledLineBytes("Hello")
    g.feed barFooterBytes("        ↓5  1s", DimPromptColor)
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
    g.feed barFooterBytes("        ↓11  2s", DimPromptColor)
    let barRow2 = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "↓11" in rowText(g, r): found = r; break
      found
    check barRow2 == barRow + 1
    check "❯" in rowText(g, barRow2 + 1)
    # ---- streamHttp finishContent + final paintBarPrompt ----
    g.feed ClearBarPromptBytes
    g.feed barFooterBytes("        ↓11  2s", DimPromptColor)
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

  test "turn 2: receipt overwrites the gap, lands flush below LLM":
    # Stage turn 1 typing-ready state: LLM line at row 0, gap at
    # row 1, bar at row 2, prompt at row 3.
    let g = newGrid()
    g.feed "● Hello\n"                      # row 0
    g.feed "\n"                             # row 1: gap
    let iter1Label = tokenLineLabel(usage, 200_000, 1)
    g.feed barFooterBytes(iter1Label, BrightPromptColor)
    # ---- readInput (turn 2): walk to prompt row, type, Enter ----
    g.feed "\n\r\x1b[2K"
    g.feed "❯ elaborate\n"
    # ---- emitUserSubmit: hadGap=true ----
    g.feed submitTransitionBytes("elaborate", hadPending = true,
                                 hadGap = true, iter1Label)
    # Receipt lands on the GAP row (row 1), flush below LLM.
    check rowText(g, 0).startsWith("● Hello")
    check "3.8k" in rowText(g, 1)               # receipt on old gap
    check rowText(g, 2).strip == ""             # blank separator
    check rowText(g, 3).startsWith("❯ elaborate")
    # Receipt is grey.
    check GreyFg in submitTransitionBytes("elaborate", true, true,
                                          iter1Label)

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

  test "tool exec: bar+prompt visible during runAction (per-write withCleared)":
    # Production sequence: paintBarPrompt → withCleared(renderToolPending)
    # → runAction (no writes) → withCleared(\e[1A clear + renderToolBanner
    # + printToolResult). The KEY property: between the pending banner
    # and runAction, bar+prompt must be visible — runAction can take
    # seconds (a bash command), and the user sees a frozen screen if
    # bar+prompt are gone for that whole time.
    #
    # Wrapping the whole block in ONE withCleared is the bug we're
    # guarding against: clearBarPrompt fires once at start, repaintBarPrompt
    # fires once at end, so during runAction (mid-block) bar/prompt are
    # cleared and not yet repainted.
    let g = newGrid()
    # Initial: bar at row 0, prompt at row 1.
    g.feed barFooterBytes("LBL  1s", DimPromptColor)
    check "LBL" in rowText(g, 0)
    check "❯" in rowText(g, 1)
    # withCleared(renderToolPending): clear → "  bash   ls\n" → repaint.
    g.feed ClearBarPromptBytes
    g.feed "  bash   ls\n"
    g.feed barFooterBytes("LBL  1s", DimPromptColor)
    # CHECKPOINT: this is the moment runAction starts. Bar+prompt MUST
    # be visible here, with the pending banner above.
    let pendingBarRow = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "LBL" in rowText(g, r): found = r; break
      found
    check pendingBarRow >= 0
    check "❯" in rowText(g, pendingBarRow + 1)
    check "bash" in rowText(g, pendingBarRow - 1)
    # No blank between pending banner and bar.
    check rowText(g, pendingBarRow - 1).strip != ""
    check rowText(g, pendingBarRow).strip != ""
    check rowText(g, pendingBarRow + 1).strip != ""
    # Now runAction "completes" (no writes). Then result phase:
    # withCleared(\e[1A clear pending + final banner + output + repaint).
    g.feed ClearBarPromptBytes        # clearBarPrompt
    g.feed "\x1b[1A\r\x1b[2K"         # walk up to pending row, clear it
    g.feed "  bash   ls  (1s)\n"      # final banner overwrites pending
    g.feed "  total 16\n"             # tool output
    g.feed "  [exit 0]\n"             # tool output
    g.feed barFooterBytes("LBL  2s", DimPromptColor)
    # FINAL: bar+prompt at the bottom, output above, no blank between bar
    # and prompt.
    let finalBarRow = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "LBL" in rowText(g, r): found = r
      found
    check finalBarRow >= 0
    check "❯" in rowText(g, finalBarRow + 1)
    check rowText(g, finalBarRow).strip != ""
    check rowText(g, finalBarRow + 1).strip != ""
    # The pending banner row was overwritten with the timed final form.
    var foundFinal = false
    for r in 0 ..< g.rows.len:
      if "(1s)" in rowText(g, r): foundFinal = true
    check foundFinal

  test "iter 2 stream end: bar at new bottom with no blank above prompt":
    let g = newGrid()
    # Iter 1 stream end.
    g.feed "● iter 1 content\n"
    g.feed barFooterBytes("        ↓18  1s", DimPromptColor)
    # Tool exec under withCleared.
    g.feed ClearBarPromptBytes
    g.feed "  bash   ls\n"
    g.feed "  total 16\n"
    g.feed barFooterBytes("        ↓18  1s", DimPromptColor)
    # Iter 2: callModel \n + spinner + content + finalise.
    g.feed "\n"
    g.feed spinnerFooterBytes("⠋", "ctx 5%          ↓0", "", 0)
    g.feed SpinnerCleanupBytes
    g.feed "\x1b[36m\x1b[1m● \x1b[0m"
    g.feed styledLineBytes("iter 2 content")
    g.feed barFooterBytes("ctx 5%          ↓14  1s", DimPromptColor)
    g.feed ClearBarPromptBytes
    g.feed barFooterBytes("ctx 5%          ↓14  1s", DimPromptColor)
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

  test "fresh startup: prompt-only → first turn paints bar, no stale row":
    # Welcome paints banner, paintInitialPrompt drops one blank gap
    # row + the bright cyan prompt — no token bar above. User types,
    # emitUserSubmit walks back N (hasBar=false) so the prompt's row
    # is wiped, NOT some non-existent bar row. After the first turn's
    # callModel paints the bar, the layout is back to normal.
    let g = newGrid()
    g.feed "  type a prompt.\n"
    # paintInitialPrompt: blank gap + prompt, cursor at col 0 of prompt row.
    g.feed "\n"
    g.feed "\x1b[2K" & BrightPromptColor & "❯ \x1b[0m\r"
    let promptRow = g.row
    check rowText(g, promptRow).startsWith("❯")
    check rowText(g, promptRow - 1).strip == ""
    # No bar row above the prompt: the row above is just the gap.
    check "↑" notin rowText(g, promptRow - 1)
    # readInput in prompt-only mode: clear in place (no walk-down).
    g.feed "\r\x1b[2K"
    g.feed "❯ hello\n"           # minline echo
    # Cursor at promptRow + 1.
    # emitUserSubmit with hasBar=false walks back N=1 to promptRow,
    # clears, \n\n + echo. No receipt (first turn).
    g.feed submitTransitionBytes("hello", hadPending = false,
                                 hadGap = false, "", hasBar = false)
    check rowText(g, promptRow).strip == ""               # cleared
    check rowText(g, promptRow + 1).strip == ""           # blank separator
    check rowText(g, promptRow + 2).startsWith("❯ hello") # echo
    # Now callModel's leading \n + content + paintBarPrompt paints
    # the bar; from here the normal lifecycle resumes.
    g.feed "\n"                                            # scratch
    g.feed "\x1b[36m\x1b[1m● \x1b[0m"
    g.feed styledLineBytes("hi back")
    g.feed barFooterBytes("ctx 1%  ↑10      ↓7  1s", DimPromptColor)
    let barRow = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "↓7" in rowText(g, r): found = r; break
      found
    check barRow >= 0
    check "❯" in rowText(g, barRow + 1)

  test "multi-line content in one chunk: bar painted after every \\n":
    # Per-line repaint pattern: bar visible at every checkpoint.
    let g = newGrid()
    g.feed "\x1b[36m\x1b[1m● \x1b[0m"
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

# ---------------- Resume bar shape ----------------
#
# On `-r`, after replaying the tail, the live token bar at the bottom
# should carry the *last response's* usage (so the user sees what the
# previous turn cost without needing the inline receipt above), and
# that response's inline receipt is suppressed. `pendingHint` is
# primed so the next user submit converts the bar into the receipt.

suite "resume bar":
  proc replayTo(s: string, messages: JsonNode): (string, Usage) =
    let path = getTempDir() / "3code_resume_capture_" & s
    let saved = stdout
    let f = open(path, fmWrite)
    stdout = f
    var u: Usage
    try:
      u = replaySessionTail(messages, @[], 200_000, "glm")
    finally:
      stdout.flushFile
      stdout = saved
      close(f)
    let captured = readFile(path)
    try: removeFile(path) except OSError: discard
    (captured, u)

  test "replaySessionTail returns last assistant's usage":
    let messages = parseJson("""[
      {"role":"system","content":"sys"},
      {"role":"user","content":"hi"},
      {"role":"assistant","content":"first answer",
       "usage":{"promptTokens":100,"completionTokens":10,
                "totalTokens":110,"cachedTokens":0}},
      {"role":"user","content":"again"},
      {"role":"assistant","content":"second answer",
       "usage":{"promptTokens":200,"completionTokens":20,
                "totalTokens":220,"cachedTokens":50}}
    ]""")
    let (_, last) = replayTo("ret", messages)
    check last.totalTokens == 220
    check last.promptTokens == 200
    check last.completionTokens == 20
    check last.cachedTokens == 50

  test "replaySessionTail suppresses last assistant's receipt":
    # The last response's token line lives in the bottom bar (painted
    # by the resume code in `main`), not as a scrollback receipt. So
    # the last `↓20` should NOT appear in the replay output.
    let messages = parseJson("""[
      {"role":"user","content":"again"},
      {"role":"assistant","content":"second answer",
       "usage":{"promptTokens":200,"completionTokens":20,
                "totalTokens":220,"cachedTokens":50}}
    ]""")
    let (captured, _) = replayTo("suppress", messages)
    check "second answer" in captured
    check "↓20" notin captured

  test "replaySessionTail keeps non-last receipts in scrollback":
    # Only the *last* assistant in the replayed tail gets the bar
    # treatment. Earlier assistant iterations within the same user turn
    # (multi-iteration: tool call → tool result → final answer) keep
    # their inline receipts so the user sees token cost per iteration.
    let messages = parseJson("""[
      {"role":"user","content":"go"},
      {"role":"assistant","content":"answer one",
       "tool_calls":[{"id":"t1","function":{"name":"bash",
                                            "arguments":"{\"command\":\"ls\"}"}}],
       "usage":{"promptTokens":100,"completionTokens":11,
                "totalTokens":111,"cachedTokens":0}},
      {"role":"tool","tool_call_id":"t1","content":"out"},
      {"role":"assistant","content":"answer two",
       "usage":{"promptTokens":200,"completionTokens":22,
                "totalTokens":222,"cachedTokens":0}}
    ]""")
    let (captured, _) = replayTo("keep", messages)
    check "↓11" in captured
    check "↓22" notin captured

  test "post-replay bar carries last response's tokens at bottom":
    # The byte sequence main writes after replay when lastUsage > 0:
    # gap row + bar+prompt with bright cyan prompt. Pin it via the
    # grid renderer.
    let g = newGrid()
    let lastUsage = Usage(
      promptTokens: 200, completionTokens: 20,
      totalTokens: 220, cachedTokens: 50,
    )
    g.feed "● resumed abc123\n"
    g.feed "(replayed content here)\n"
    g.feed "\n"
    let label = tokenLineLabel(lastUsage, 200_000)
    g.feed barFooterBytes(label, BrightPromptColor)
    var barRow = -1
    for r in 0 ..< g.rows.len:
      if "↓20" in rowText(g, r):
        barRow = r; break
    check barRow >= 0
    check "↑150" in rowText(g, barRow)
    check "↻50" in rowText(g, barRow)
    check "❯" in rowText(g, barRow + 1)
