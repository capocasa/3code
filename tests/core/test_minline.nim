discard """
  # Windows: arrow-key encoding differs (_getch 0xE0 prefix vs POSIX ESC [),
  # so subtests asserting cursor movement fail. See docs/windows-testing.md.
  disabled: "win"
"""
import std/[deques, unittest, strutils, sequtils, unicode]
import threecode/fatprompt
import threecode/minline
import threecode/signals
import minline_testutils
import ttty
import ttty/grid

## Multiline editor tests.
##
## Two kinds of assertions:
##
## * **Pure helper checks** — ``visualCols``, ``cursorVisual``,
##   ``totalRows``, ``renderBuffer`` against hand-computed expectations.
## * **Driver checks** — feed a synthetic keystroke stream into
##   ``readLineWith``, capture the editor's output through an inline
##   terminal grid, then assert on cell content / cursor position / final
##   ``echoRows`` / returned text.
##
## Layout invariants (mirror the spec in CLAUDE.md, multiline-aware):
##
## * The buffer is one logical string with embedded ``'\n'`` markers.
## * Each logical line is prefixed with the prompt (line 0) or
##   continuation prompt (lines 1+).
## * Auto line wrap at terminal width is rendered as additional visual
##   rows with **no** prefix — wraps are not logical lines.
## * Arrow keys navigate by *visual* row (so a long wrapped line still
##   feels like multiple rows from the user's perspective).
## * Home/End act on the current logical line.
## * Word-left / word-right cross newlines.
## * Plain Enter submits; Shift/Alt+Enter inserts a real ``'\n'``.

# ---------------- Pure helper tests ----------------

suite "minline pure helpers":
  test "visualCols counts runes":
    check visualCols("") == 0
    check visualCols("abc") == 3
    check visualCols("❯ ") == 2

  test "cursorVisual: empty buffer, prompt-only":
    let (r, c) = cursorVisual("", 0, 2, 2, 80)
    check r == 0
    check c == 2

  test "cursorVisual: simple ASCII at end":
    let (r, c) = cursorVisual("hello", 5, 2, 2, 80)
    check r == 0
    check c == 7  # 2 (prompt) + 5

  test "cursorVisual: across logical newline":
    let (r, c) = cursorVisual("a\nbc", 4, 2, 2, 80)
    check r == 1
    check c == 4  # contW(2) + "bc"(2)

  test "cursorVisual: visual wrap when col reaches width":
    # width = 5, prompt = 2, contW = 2 -> 3 data cells per row.
    let (r0, c0) = cursorVisual("abc", 3, 2, 2, 5)
    check r0 == 0
    check c0 == 5  # cursor parked one past last cell of row 0
    let (r1, c1) = cursorVisual("abcd", 4, 2, 2, 5)
    check r1 == 1
    check c1 == 3  # 'd' on row 1 after cont(2), cursor at contW+1 = 3

  test "totalRows: empty is 1":
    check totalRows("", 2, 2, 80) == 1

  test "totalRows: counts logical newlines":
    check totalRows("a\nb", 2, 2, 80) == 2
    check totalRows("a\nb\nc", 2, 2, 80) == 3

  test "totalRows: wraps long line at width":
    # width 5, prompt 2, contW 2 -> 3 data cells per row.
    check totalRows("abc", 2, 2, 5) == 1   # exactly fills row 0
    check totalRows("abcd", 2, 2, 5) == 2  # 'd' wraps to row 1
    check totalRows("abcdefgh", 2, 2, 5) == 3  # 'abc','def','gh'
    check totalRows("abcdefghi", 2, 2, 5) == 3 # 'abc','def','ghi'

  test "visualCols: CJK counts as 2 cells":
    check visualCols("\u4E2D") == 2   # '中' East Asian Wide

  test "visualCols: emoji counts as 2 cells":
    check visualCols(Rune(0x1F600).toUTF8) == 2   # '😀'

  test "visualCols: combining mark is zero-width":
    check visualCols("a\u0301") == 1   # 'a' + combining acute

  test "totalRows: wide rune wraps at right margin":
    # width 4, prompt 1, contW 1 -> 3 data cells per row. A 2-cell CJK
    # rune fills cells 1-2; a second one (cells 3-4) doesn't fit, wraps.
    check totalRows("\u4E2D\u4E2D", 1, 1, 4) == 2

  test "cursorVisual: wide rune occupies two cells":
    # prompt 0, one CJK rune: cursor advances 2 cells.
    let (r, c) = cursorVisual("\u4E2D", 3, 0, 0, 80)
    check r == 0
    check c == 2

  test "renderBuffer: prompt + text, joined by \\r\\n on wrap":
    let bytes = renderBuffer("abcd", "P ", "  ", 5)
    # 'P abc' on row 0, continuation + 'd' on row 1 (after \r\n).
    check bytes == "P abc\r\n  d"

  test "renderBuffer: continuation prompt for logical lines":
    let bytes = renderBuffer("ab\ncd", "P ", "..", 80)
    check bytes == "P ab\r\n..cd"

  test "renderBuffer: wraps at whitespace, not mid-word":
    # width 7, prompt 2, contW 2 -> 5 data cells per row. "alpha beta"
    # would char-wrap as "alpha"/" beta"; word-wrap keeps "beta" whole.
    let bytes = renderBuffer("alpha beta", "P ", "  ", 7)
    check bytes == "P alpha\r\n  beta"

  test "totalRows: word-wrap keeps words intact":
    # width 7, prompt 2 -> 5 data cells. "aa bb cc" -> "aa bb"/" cc" (2 rows)
    # rather than "aa bb"/" cc" mid-word; "aaa bbb" -> "aaa"/" bbb" (2 rows).
    check totalRows("aa bb cc", 2, 2, 7) == 2
    check totalRows("aaa bbb", 2, 2, 7) == 2

  test "cursorVisual: lands after the word that wrapped":
    # width 7, prompt 2 -> 5 data cells. "alpha beta" wraps after "alpha";
    # cursor at end (position 10) is on row 1, after contW(2) + "beta"(4) = 6.
    let (r, c) = cursorVisual("alpha beta", 10, 2, 2, 7)
    check r == 1
    check c == 6

  test "renderBuffer: over-long word still char-wraps":
    # width 5, prompt 2 -> 3 data cells. "abcdef" has no space; must
    # char-wrap as "abc"/"def" rather than overflow.
    let bytes = renderBuffer("abcdef", "P ", "  ", 5)
    check bytes == "P abc\r\n  def"

  test "totalRows: word-wrap break counts for whitespace edge cases":
    # These inputs previously disagreed between the editor geometry
    # (lineSpans) and the transcript display wrap (rendering.wrapPlain):
    # trailing spaces, overflow spaces, and multi-space runs were counted
    # differently. Pin the geometry row counts that the display must match.
    check totalRows("hello world", 0, 0, 5) == 2      # overflow space is the break
    check totalRows("hello world foo bar baz", 0, 0, 5) == 5
    check totalRows("a b c d e f g h", 0, 0, 5) == 3
    check totalRows("multiple   spaces   here", 0, 0, 5) == 5   # multi-space run
    check totalRows("trailing space ", 0, 0, 5) == 4  # trailing space after wrap
    check totalRows(" leading space", 0, 0, 5) == 4   # leading space at row 0
    check totalRows("x y z  w", 0, 0, 5) == 2         # double space before last word
    check totalRows("a        b", 0, 0, 5) == 2       # long space run

  test "totalRows: char-wrap fallback for words longer than width":
    # No break opportunity: the whole buffer is one over-long word that
    # char-wraps every `width` cells.
    check totalRows("supercalifragilisticexpialidocious word", 0, 0, 5) == 8
    check totalRows("verylongwordwithnobreaks", 0, 0, 5) == 5
    check totalRows("supercalifragilisticexpialidocious word", 0, 0, 2) == 19

  test "renderBuffer: overflow space is the break, not kept on next row":
    # width 5, prompt 0: "hello" fills the row, the space overflows and is
    # itself the break, so "world" starts clean on row 1 (no leading space).
    let bytes = renderBuffer("hello world", "", "", 5)
    check bytes == "hello\r\nworld"

  test "renderBuffer: multi-space run collapses at the break":
    # width 5: "a" then 8 spaces then "b". The spaces overflow and form one
    # break run; "b" lands on row 1 with no leading spaces.
    let bytes = renderBuffer("a        b", "", "", 5)
    check bytes == "a\r\nb"

  test "editor prompt marker uses same default style as typed text":
    let d = newDriver()
    d.terminal.write renderBuffer("x", EditorPromptBytes, "  ", 80)
    let prompt = d.grid.cellAt(0, 0)
    let typed = d.grid.cellAt(0, 2)
    check prompt.text == "❯"
    check typed.text == "x"
    check prompt.fgColor == typed.fgColor
    check uint16(prompt.attrs) == uint16(typed.attrs)

# ---------------- Driver: basic typing & submit ----------------

suite "minline editor: basic typing":
  test "type 'hello' + Enter returns 'hello'":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "hello"
    d.push Enter
    let got = d.run(ed, prompt = "> ")
    check got == "hello"
    check ed.echoRows == 1

  test "first row contains prompt + typed text":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "hello"
    d.push Enter
    discard d.run(ed, prompt = "> ")
    check rowText(d.grid, 0).startsWith("> hello")

  test "buffer is empty after backspace clears every char":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "abc"
    d.push Backspace
    d.push Backspace
    d.push Backspace
    d.push Enter
    check d.run(ed, prompt = "> ") == ""

# ---------------- Driver: cursor navigation ----------------

suite "minline editor: cursor navigation":
  test "isEscapeTailByte classifies escape continuations":
    # CSI and SS3 introducers are valid tails.
    check minline.isEscapeTailByte(91)   # '['
    check minline.isEscapeTailByte(79)   # 'O'
    # Alt+Enter (ESC CR).
    check minline.isEscapeTailByte(13)
    # Digit and '~' continuations (xterm/kitty function keys).
    check minline.isEscapeTailByte(48)   # '0'
    check minline.isEscapeTailByte(57)   # '9'
    check minline.isEscapeTailByte(126)  # '~'
    # Printable letters are NEVER valid tails. This is the key property:
    # ESC immediately followed by the user's next typed character must be
    # treated as a bare Escape so the character is not swallowed.
    check not minline.isEscapeTailByte('a'.ord)
    check not minline.isEscapeTailByte('z'.ord)
    check not minline.isEscapeTailByte('A'.ord)
    check not minline.isEscapeTailByte('w'.ord)
    check not minline.isEscapeTailByte(' '.ord)

  test "bare Escape cancels like Ctrl+C":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "draft"
    d.push Esc
    expect InputCancelled:
      discard d.run(ed, prompt = "> ")

  test "Ctrl+D exits only from an empty prompt":
    block nonEmpty:
      var ed = initEditor()
      let d = newDriver()
      d.pushString "draft"
      d.push CtrlD
      d.push Enter
      check d.run(ed, prompt = "> ") == "draft"
    block empty:
      var ed = initEditor()
      let d = newDriver()
      d.push CtrlD
      expect EOFError:
        discard d.run(ed, prompt = "> ")

  test "left arrow before middle character, then insert":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "abcd"
    # Move cursor between b and c.
    d.push Left; d.push Left
    d.pushString "X"
    d.push Enter
    check d.run(ed, prompt = "> ") == "abXcd"

  test "Home jumps to start of current logical line":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "first"
    d.push AltEnter   # newline
    d.pushString "second"
    d.push Home
    d.pushString "X"
    d.push Enter
    check d.run(ed, prompt = "> ") == "first\nXsecond"

  test "End jumps to end of current logical line, not buffer end":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "ab"
    d.push AltEnter
    d.pushString "cd"
    d.push Up         # to line 1
    d.push Home
    d.push End        # end of line 1 == position 2 (just 'ab')
    d.pushString "Z"
    d.push Enter
    check d.run(ed, prompt = "> ") == "abZ\ncd"

  test "Ctrl+Right and Ctrl+Left jump words across newlines":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "foo bar"
    d.push AltEnter
    d.pushString "baz qux"
    # Cursor at end. Ctrl+Left x4 should land at start of "foo".
    d.push CtrlLeft  # before 'qux'
    d.push CtrlLeft  # before 'baz'
    d.push CtrlLeft  # before 'bar'
    d.push CtrlLeft  # before 'foo'
    d.pushString "<"
    d.push Enter
    check d.run(ed, prompt = "> ") == "<foo bar\nbaz qux"

# ---------------- Driver: multiline newlines ----------------

suite "minline editor: newline insertion (multiline)":
  test "Alt+Enter inserts a real newline, Enter submits":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "first"
    d.push AltEnter
    d.pushString "second"
    d.push Enter
    check d.run(ed, prompt = "> ") == "first\nsecond"
    check ed.echoRows == 2

  test "Kitty Shift+Enter sequence inserts a newline":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "a"
    d.push Kitty: Shift + Enter
    d.pushString "b"
    d.push Enter
    check d.run(ed, prompt = "> ") == "a\nb"

  test "XMod Shift+Enter sequence inserts a newline":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "x"
    d.push XMod: Shift + Enter
    d.pushString "y"
    d.push Enter
    check d.run(ed, prompt = "> ") == "x\ny"
    check rowText(d.grid, 0) == "> x"
    check rowText(d.grid, 1).startsWith("  y")

  test "late escape tails are not printed into the terminal grid":
    var ed = initEditor()
    let d = newDriver()
    d.pendingInput = proc(): bool = false
    d.pushString "x"
    d.push XMod: Shift + Enter
    expect InputCancelled:
      discard d.run(ed, prompt = "> ")
    check rowText(d.grid, 0) == "> x"
    for r in 0..<d.grid.rows.len:
      check "[" notin rowText(d.grid, r)

  test "trailing backslash stays literal — no continuation":
    # The old behaviour appended `\` to the line and re-prompted for a
    # continuation. Now `\` is just text and the line submits.
    var ed = initEditor()
    let d = newDriver()
    d.pushString "abc\\"
    d.push Enter
    check d.run(ed, prompt = "> ") == "abc\\"

  test "deferred submit keeps multiline editor open and suffix is editable":
    var ed = initEditor()
    var submits: seq[string]
    ed.deferSubmit = true
    ed.onSubmit = proc(e: var LineEditor) =
      submits.add e.line.text
      e.line.position = e.line.text.len
      e.renderSuffix = " (queued)\n"
      e.renderSuffixCursor = true
    ed.onMutate = proc(e: var LineEditor) =
      e.renderSuffix = ""
      e.renderSuffixCursor = false

    let d = newDriver()
    d.pushString "line1"
    d.push AltEnter
    d.pushString "line2"
    d.push Enter
    d.pushString " edited"
    d.push Enter
    d.push CtrlC

    expect InputCancelled:
      discard d.run(ed, prompt = "> ")
    check submits == @["line1\nline2", "line1\nline2 edited"]
    check ed.line.text == "line1\nline2 edited"
    check rowText(d.grid, 1).contains("line2 edited (queued)")
    check rowText(d.grid, 2).strip.len == 0
    check len(ed.history.entries) == 2
    check ed.history.entries[0] == "line1\nline2"
    check ed.history.entries[1] == "line1\nline2 edited"

  test "typing after a queued submit edits the text instead of wiping it":
    # Models the runtime's turn-active submit: Enter queues the text, hides
    # the native caret (pendingCaret), and shows the hourglass suffix. The
    # next keystroke must cancel the queue and keep editing the same text
    # with the cursor where it was, not wipe the line.
    var ed = initEditor()
    var cancelled = 0
    ed.deferSubmit = true
    ed.onSubmit = proc(e: var LineEditor) =
      e.line.position = e.line.text.len
      e.pendingCaret = true
      e.renderSuffix = " ⏣"
    ed.onCancelDeferredSubmit = proc(e: var LineEditor) =
      inc cancelled

    let d = newDriver()
    d.pushString "hello"
    d.push Enter      # queue; pendingCaret on, suffix shown, caret hidden
    d.pushString " world"  # cancels the queue, edits in place
    d.push CtrlC
    expect InputCancelled:
      discard d.run(ed, prompt = "> ")
    check cancelled == 1
    check ed.line.text == "hello world"
    check ed.line.position == 11
    check rowText(d.grid, 0).contains("hello world")
    check not rowText(d.grid, 0).contains("⏣")

  test "backspace after a queued submit edits the text, cursor stays":
    var ed = initEditor()
    var cancelled = 0
    ed.deferSubmit = true
    ed.onSubmit = proc(e: var LineEditor) =
      e.line.position = e.line.text.len
      e.pendingCaret = true
      e.renderSuffix = " ⏣"
    ed.onCancelDeferredSubmit = proc(e: var LineEditor) =
      inc cancelled

    let d = newDriver()
    d.pushString "hello"
    d.push Enter      # queue; caret parked at end
    d.push Backspace  # cancels queue, deletes trailing 'o'
    d.pushString "o!"
    d.push CtrlC
    expect InputCancelled:
      discard d.run(ed, prompt = "> ")
    check cancelled == 1
    check ed.line.text == "hello!"
    check ed.line.position == 6

  test "first keystroke after a queued submit repaints once, not twice":
    # Regression: the cancel block used to call fullRedraw, then the
    # keystroke handler (printChar -> insertText) called fullRedraw again.
    # Two clear-and-repaints per keystroke flash on terminals without
    # DEC 2026 synchronized output. The fix defers the cancel's repaint to
    # the handler so only one clear (`\x1b[J`) fires for the keystroke.
    var ed = initEditor()
    ed.deferSubmit = true
    ed.onSubmit = proc(e: var LineEditor) =
      e.line.position = e.line.text.len
      e.pendingCaret = true
      e.renderSuffix = " \u2363"
    ed.onCancelDeferredSubmit = proc(e: var LineEditor) = discard

    let d = newDriver()
    d.pushString "hi"
    d.push Enter       # queue; pendingCaret on
    d.pushString " "   # first keystroke after queue: cancels + inserts
    d.push CtrlC
    var clearsAfterCancel = 0
    var suffixPainted = false
    let write: WriteProc = proc(s: string) =
      if "\u2363" in s: suffixPainted = true
      # Count clears in frames that no longer show the suffix glyph: those
      # are repaints after the queue was cancelled, i.e. the typed keystroke.
      # The Enter that painted the suffix is excluded (it contains the glyph).
      if suffixPainted and "\u2363" notin s and "\x1b[J" in s:
        inc clearsAfterCancel
      d.terminal.write s
    let getCh: GetChProc = proc(): int = d.terminal.read()
    let widthProc: WidthProc = proc(): int = d.width
    let hasPendingInput: HasPendingInputProc = proc(): bool =
      d.terminal.hasPendingInput()
    expect InputCancelled:
      discard ed.readLineWith("> ", getCh, write, getWidth = widthProc,
                              hasPendingInput = hasPendingInput)
    check clearsAfterCancel == 1

  test "backspace at start of second logical line joins lines":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "ab"
    d.push AltEnter
    d.pushString "cd"
    d.push Home     # cursor at start of "cd"
    d.push Backspace     # remove the newline
    d.push Enter
    check d.run(ed, prompt = "> ") == "abcd"

  test "Up arrow moves to previous visual row, preserving column":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "abcd"
    d.push AltEnter
    d.pushString "efgh"
    # Cursor at end of "efgh" (col 6 with prompt "> ").
    d.push Up
    # Now should be at end of "abcd" (col 6) — same column.
    d.pushString "X"
    d.push Enter
    check d.run(ed, prompt = "> ") == "abcdX\nefgh"

  test "Down arrow moves to next visual row":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "abcd"
    d.push AltEnter
    d.pushString "efgh"
    d.push Home
    d.push Up        # row 0, col 0 (would go to history) — actually
                      # falls through to historyPrevious at top row;
                      # since history is empty, no change.
    d.push Down      # back to row 1 col 0
    d.pushString "Y"
    d.push Enter
    check d.run(ed, prompt = "> ") == "abcd\nYefgh"

# ---------------- Driver: visual wrap ----------------

suite "minline editor: terminal-width wrap":
  test "long line wraps to additional rows":
    var ed = initEditor()
    let d = newDriver(width = 10)
    # Prompt "> " (width 2) leaves 8 cells on row 0.
    # Type 12 chars: first 8 on row 0, next 4 on row 1.
    d.pushString "abcdefghijkl"
    d.push Enter
    discard d.run(ed, prompt = "> ")
    check ed.echoRows == 2
    check rowText(d.grid, 0) == "> abcdefgh"
    check rowText(d.grid, 1).startsWith("  ijkl")

  test "edit on wrapped row updates layout in place":
    var ed = initEditor()
    let d = newDriver(width = 10)
    # width 10, prompt "> " (2) -> 8 cells fit on row 0.
    # 10 chars span row 0 ("abcdefgh") + row 1 ("ij").
    d.pushString "abcdefghij"
    d.push Left               # cursor between i and j, on row 1
    d.pushString "X"           # text becomes abcdefghiXj
    d.push Enter
    discard d.run(ed, prompt = "> ")
    check rowText(d.grid, 0) == "> abcdefgh"
    check rowText(d.grid, 1).startsWith("  iXj")

  test "Up arrow on wrapped row moves to previous visual row, same logical line":
    var ed = initEditor()
    let d = newDriver(width = 10)
    d.pushString "abcdefghijkl"  # row 0: "abcdefgh", row 1: "ijkl"
    d.push Up                   # cursor on row 0
    d.pushString "?"
    d.push Enter
    # Cursor was at end (after 'l') -> visual col 6 on row 1
    # (contW=2 + "ijkl" -> cols 2..6). Up to row 0 col 6 -> after 'd'
    # (prompt 0..1, 'a'=2, 'b'=3, 'c'=4, 'd'=5, col 6 is after 'd').
    let result = d.run(ed, prompt = "> ")
    check result == "abcd?efghijkl"

# ---------------- Driver: terminal resize ----------------

suite "minline editor: terminal resize":
  test "buffer survives a width change mid-edit":
    var ed = initEditor()
    let d = newDriver(width = 20)
    d.pushString "abcdefghijklmnop"
    # All fits on one row at width 20.
    d.push Left
    d.push Left  # cursor between n and o
    # Resize: shrink the terminal.
    d.width = 8
    # Insert a char — triggers re-render at new width.
    d.pushString "X"
    d.push Enter
    check d.run(ed, prompt = "> ") == "abcdefghijklmnXop"

  test "echoRows reflects post-resize layout":
    var ed = initEditor()
    let d = newDriver(width = 80)
    d.pushString "abcdefghijklmnop"
    d.width = 8
    d.pushString " "  # trigger re-render
    d.push Enter
    discard d.run(ed, prompt = "> ")
    # After resize: prompt "> " (2) + 17 chars. Row 0 holds 6 chars,
    # row 1 holds 8, row 2 holds 3.
    check ed.echoRows >= 2

# ---------------- Driver: rendered prompt + content ----------------

suite "minline editor: render correctness":
  test "second logical line is prefixed with continuation prompt '  '":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "ab"
    d.push AltEnter
    d.pushString "cd"
    d.push Enter
    discard d.run(ed, prompt = "> ")
    check rowText(d.grid, 0).startsWith("> ab")
    check rowText(d.grid, 1).startsWith("  cd")

  test "Ctrl+U clears the buffer in place":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "abcdef"
    d.push CtrlU
    d.pushString "xy"
    d.push Enter
    check d.run(ed, prompt = "> ") == "xy"

  test "Ctrl+W deletes the previous word":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "foo bar baz"
    d.push CtrlW
    d.push Enter
    check d.run(ed, prompt = "> ") == "foo bar "

# ---------------- Driver: bracketed paste ----------------

suite "minline editor: bracketed paste":
  test "paste with embedded newline lands as a newline in the buffer":
    var ed = initEditor()
    let d = newDriver()
    # ESC [ 200 ~  PASTE  ESC [ 201 ~
    d.push @[27, 91, 50, 48, 48, 126]
    d.pushString "line1\nline2"
    d.push @[27, 91, 50, 48, 49, 126]
    d.push Enter
    check d.run(ed, prompt = "> ") == "line1\nline2"
    check ed.echoRows == 2

  test "hidechars: bracketed paste captures key, screen shows only `*`s":
    # Regression for the Ghostty-on-macOS auth-failure report. Pasting an
    # api key in hidden mode must:
    #   1. Land the full key in `ed.line.text` (no early submit on
    #      embedded CR/LF, no silent drops of high UTF-8 bytes from a
    #      stray NBSP/BOM in the clipboard).
    #   2. Render only `*` masks on screen, never the cleartext key.
    var ed = initEditor()
    let d = newDriver()
    # ESC [ 200 ~  "sk-abc<NBSP>123\n"  ESC [ 201 ~  Enter
    d.push @[27, 91, 50, 48, 48, 126]
    d.pushString "sk-abc"
    d.push @[0xC2, 0xA0]  # UTF-8 NBSP, must be silently dropped
    d.pushString "123\n"  # trailing newline inside paste, must NOT submit
    d.push @[27, 91, 50, 48, 49, 126]
    d.push Enter
    let got = d.run(ed, prompt = "> ", hidechars = true)
    check got == "sk-abc123"
    # Screen must not contain the key plaintext; just `*`s after the prompt.
    let row0 = rowText(d.grid, 0)
    check "sk-abc" notin row0
    check "123" notin row0
    check row0.startsWith("> *********")  # 9 stars: sk-abc + 123

  test "hidechars: per-byte typed key still works (no bracketed paste)":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "secret42"
    d.push Enter
    check d.run(ed, prompt = "> ", hidechars = true) == "secret42"
    check rowText(d.grid, 0).startsWith("> ********")

  test "hidechars: paste with trailing newline dropped, Enter submits":
    # When bracketed paste is NOT active and a paste contains a trailing
    # newline (common when copying from browsers/password managers), the
    # per-byte handler must drop the embedded newline instead of submitting
    # the key early. The paste burst is detected because further input
    # (the real Enter) is still pending in stdin.
    var ed = initEditor()
    let d = newDriver()
    d.pushString "sk-ant-key\n"  # paste with trailing newline
    d.push Enter                  # real Enter press
    let got = d.run(ed, prompt = "> ", hidechars = true)
    check got == "sk-ant-key"
    check rowText(d.grid, 0).startsWith("> *********")  # 9 stars

  test "hidechars: typed key with Enter submits normally":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "sk-ant-key"
    d.push Enter
    check d.run(ed, prompt = "> ", hidechars = true) == "sk-ant-key"
    check rowText(d.grid, 0).startsWith("> *********")  # 9 stars

# ---------------- SIGWINCH / EINTR ----------------

suite "minline editor: SIGWINCH EINTR":
  test "SIGWINCH before first keypress recovers":
    var ed = initEditor()
    ed.width = 20
    var keys: seq[int] = @[-1]
    keys.add toSeq("hello".mapIt(it.ord))
    keys.add Enter
    var ki = 0
    let getCh: GetChProc = proc(): int =
      let idx = ki; inc ki
      if keys[idx] == -1:
        markResizePending()
        raise newException(IOError, "Interrupted system call")
      result = keys[idx]
    let write = proc(s: string) = discard
    let result = ed.readLineWith("> ", getCh, write)
    check result == "hello"

  test "SIGWINCH mid-input rewraps and continues":
    var ed = initEditor()
    ed.width = 20
    var keys: seq[int] = toSeq("abcdefghij".mapIt(it.ord))
    keys.add -1  # SIGWINCH: shrink width
    keys.add toSeq("kl".mapIt(it.ord))
    keys.add Enter
    var ki = 0
    let getCh: GetChProc = proc(): int =
      let idx = ki; inc ki
      if keys[idx] == -1:
        markResizePending()
        ed.width = 10
        raise newException(IOError, "Interrupted system call")
      result = keys[idx]
    var grid: seq[string]
    let write = proc(s: string) =
      for line in s.split("\r\n"):
        grid.add(line)
    let result = ed.readLineWith("> ", getCh, write)
    check result == "abcdefghijkl"
    check ed.echoRows >= 2

  test "rapid consecutive SIGWINCH recovers":
    var ed = initEditor()
    ed.width = 80
    var keys: seq[int] = @[-1, -1]
    keys.add toSeq("x".mapIt(it.ord))
    keys.add Enter
    var ki = 0
    let getCh: GetChProc = proc(): int =
      let idx = ki; inc ki
      if keys[idx] == -1:
        markResizePending()
        raise newException(IOError, "Interrupted system call")
      result = keys[idx]
    let write = proc(s: string) = discard
    let result = ed.readLineWith("> ", getCh, write)
    check result == "x"

  test "non-SIGWINCH IOError re-raises":
    var ed = initEditor()
    ed.width = 80
    let getCh: GetChProc = proc(): int =
      raise newException(IOError, "real I/O error")
    let write = proc(s: string) = discard
    expect IOError:
      discard ed.readLineWith("> ", getCh, write)
suite "minline editor: unicode input":
  proc feedBytes(bytes: openArray[int]; width = 80): string =
    var ed = initEditor()
    ed.width = width
    var keys: seq[int] = @bytes
    keys.add Enter
    var ki = 0
    let getCh: GetChProc = proc(): int =
      let idx = ki; inc ki
      result = keys[idx]
    let write = proc(s: string) = discard
    ed.readLineWith("> ", getCh, write)

  test "typed multibyte (2-byte) survives":
    # "\xC3\xA9" = 'é'
    check feedBytes([0xC3, 0xA9]) == "\xc3\xa9"

  test "typed CJK (3-byte) survives":
    # "\xE4\xB8\xAD" = '中'
    check feedBytes([0xE4, 0xB8, 0xAD]) == "\xe4\xb8\xad"

  test "typed emoji (4-byte) survives":
    # "\xF0\x9F\x98\x80" = '😀'
    check feedBytes([0xF0, 0x9F, 0x98, 0x80]) == "\xf0\x9f\x98\x80"

  test "mixed ASCII and multibyte":
    # "a\xC3\xA9z"
    let bytes = toSeq("a".items).mapIt(it.ord) & @[0xC3, 0xA9] &
      toSeq("z".items).mapIt(it.ord)
    check feedBytes(bytes) == "a\xc3\xa9z"

  test "malformed lead byte with no continuation is dropped":
    # 0xC3 is a 2-byte lead; a following ASCII byte (not a continuation)
    # makes the sequence invalid. The lead is discarded and the ASCII byte
    # is typed normally.
    check feedBytes([0xC3, 0x41]) == "A"

# ---------------- termPeeked draining ----------------

suite "minline editor: termPeeked drain":
  test "getchr drains termPeeked before reading stdin":
    termPeeked = 'Z'.ord
    let c = getchr()
    check c == 'Z'.ord.cint
    check termPeeked == -1

  test "readLineWith getCh drains termPeeked first":
    termPeeked = 'X'.ord
    var ed = initEditor()
    let d = newDriver()
    d.push Enter
    let got = d.run(ed, prompt = "> ")
    check got == "X"
    check termPeeked == -1

  test "peeked non-tail byte survives Esc cancel":
    termPeeked = -1
    var ed = initEditor()
    let d = newDriver()
    # pendingInput peeks at next byte and, if not an escape tail,
    # stashes it in termPeeked (mirroring terminalHasPendingInput).
    d.pendingInput = proc(): bool =
      if d.terminal.input.hasPendingInput:
        let b = d.terminal.input.read()
        if isEscapeTailByte(b):
          termPeeked = b
          return true
        termPeeked = b
        return false
      return false
    d.push Esc
    d.pushString "x"
    expect InputCancelled:
      discard d.run(ed, prompt = "> ")
    # After cancel, termPeeked holds 'x'. A fresh readLineWith must
    # drain it so the character is not lost.
    check termPeeked == 'x'.ord
    d.push Enter
    let got = d.run(ed, prompt = "> ")
    check got == "x"
    check termPeeked == -1

  test "peeked tail byte feeds escape sequence":
    termPeeked = -1
    var ed = initEditor()
    let d = newDriver()
    d.pendingInput = proc(): bool =
      if d.terminal.input.hasPendingInput:
        let b = d.terminal.input.read()
        if isEscapeTailByte(b):
          termPeeked = b
          return true
        termPeeked = b
        return false
      return false
    d.pushString "abc"
    d.push Left   # Esc [ D
    d.pushString "X"
    d.push Enter
    let got = d.run(ed, prompt = "> ")
    # Cursor moved left before 'X', so X is inserted between 'b' and 'c'.
    check got == "abXc"
    check termPeeked == -1
