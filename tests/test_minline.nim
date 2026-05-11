import std/[unittest, strutils, parseutils, sequtils]
import threecode/minline
import minline_testutils
import ttty/grid

## Multiline editor tests.
##
## Two kinds of assertions:
##
## * **Pure helper checks** — ``visualCols``, ``cursorVisual``,
##   ``totalRows``, ``renderBuffer`` against hand-computed expectations.
## * **Driver checks** — feed a synthetic keystroke stream into
##   ``readLineWith``, capture the editor's output through an inline
##   ANSI grid, then assert on cell content / cursor position / final
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

# ---------------- Atomic-redraw invariant ----------------

suite "minline: atomic single-flush redraw":
  ## On Windows conhost, splitting a redraw across multiple writes /
  ## flushes (or omitting DEC 2026 synchronized output) makes conhost
  ## paint mid-frame, which manifests as flicker. The editor's
  ## ``fullRedraw`` MUST emit one buffered write per call, wrapped in
  ## ``CSI ? 2026 h`` ... ``CSI ? 2026 l``, or the flicker comes back.

  test "fullRedraw: exactly one write per call, sync-wrapped":
    var ed = initEditor()
    ed.line.text = "hello world"
    ed.line.position = 11
    ed.prompt = "❯ "
    ed.contPrompt = "  "
    ed.width = 80
    ed.renderRow = 0
    var writes: seq[string] = @[]
    ed.write = proc(s: string) = writes.add s
    ed.getWidth = proc(): int = 80
    fullRedraw(ed)
    check writes.len == 1
    check writes[0].startsWith("\x1b[?2026h")
    check writes[0].endsWith("\x1b[?2026l")
    check "❯ hello world" in writes[0]

  test "fullRedraw: multi-line buffer also fits in one sync frame":
    var ed = initEditor()
    ed.line.text = "first\nsecond"
    ed.line.position = 12
    ed.prompt = "❯ "
    ed.contPrompt = "  "
    ed.width = 80
    ed.renderRow = 0
    var writes: seq[string] = @[]
    ed.write = proc(s: string) = writes.add s
    ed.getWidth = proc(): int = 80
    fullRedraw(ed)
    check writes.len == 1
    check writes[0].startsWith("\x1b[?2026h")
    check writes[0].endsWith("\x1b[?2026l")

# ---------------- Pure helper tests ----------------

suite "minline pure helpers":
  test "visualCols counts runes, ignores CSI sequences":
    check visualCols("") == 0
    check visualCols("abc") == 3
    check visualCols("❯ ") == 2
    check visualCols("\x1b[1;36m❯ \x1b[0m") == 2
    check visualCols("\x1b[?2004h") == 0

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

  test "renderBuffer: prompt + text, joined by \\r\\n on wrap":
    let bytes = renderBuffer("abcd", "P ", "  ", 5)
    # 'P abc' on row 0, continuation + 'd' on row 1 (after \r\n).
    check bytes == "P abc\r\n  d"

  test "renderBuffer: continuation prompt for logical lines":
    let bytes = renderBuffer("ab\ncd", "P ", "..", 80)
    check bytes == "P ab\r\n..cd"

  test "renderBuffer: colored prompt styles only prompt cells":
    let bytes = renderBuffer("hello", "\x1b[1;36m❯ \x1b[0m", "  ", 80)
    let g = newGrid()
    g.feed bytes
    check rowText(g, 0) == "❯ hello"
    check g.cellFg(0, 0) == colCyan
    check hasAttr(g.cellAttr(0, 0), saBold)
    check g.cellFg(0, 1) == colCyan
    check hasAttr(g.cellAttr(0, 1), saBold)
    check g.cellFg(0, 2) == colDefault
    check not hasAttr(g.cellAttr(0, 2), saBold)

# ---------------- Driver: basic typing & submit ----------------

suite "minline editor: basic typing":
  test "type 'hello' + Enter returns 'hello'":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "hello"
    d.push KEnter
    let got = d.run(ed, prompt = "> ")
    check got == "hello"
    check ed.echoRows == 1

  test "first row contains prompt + typed text":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "hello"
    d.push KEnter
    discard d.run(ed, prompt = "> ")
    check rowText(d.grid, 0).startsWith("> hello")

  test "buffer is empty after backspace clears every char":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "abc"
    d.push KBack
    d.push KBack
    d.push KBack
    d.push KEnter
    check d.run(ed, prompt = "> ") == ""

# ---------------- Driver: cursor navigation ----------------

suite "minline editor: cursor navigation":
  test "left arrow before middle character, then insert":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "abcd"
    # Move cursor between b and c.
    d.push KLeft; d.push KLeft
    d.pushString "X"
    d.push KEnter
    check d.run(ed, prompt = "> ") == "abXcd"

  test "Home jumps to start of current logical line":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "first"
    d.push KAltEnter   # newline
    d.pushString "second"
    d.push KHome
    d.pushString "X"
    d.push KEnter
    check d.run(ed, prompt = "> ") == "first\nXsecond"

  test "End jumps to end of current logical line, not buffer end":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "ab"
    d.push KAltEnter
    d.pushString "cd"
    d.push KUp         # to line 1
    d.push KHome
    d.push KEnd        # end of line 1 == position 2 (just 'ab')
    d.pushString "Z"
    d.push KEnter
    check d.run(ed, prompt = "> ") == "abZ\ncd"

  test "Ctrl+Right and Ctrl+Left jump words across newlines":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "foo bar"
    d.push KAltEnter
    d.pushString "baz qux"
    # Cursor at end. Ctrl+Left x4 should land at start of "foo".
    d.push KCtrlLeft  # before 'qux'
    d.push KCtrlLeft  # before 'baz'
    d.push KCtrlLeft  # before 'bar'
    d.push KCtrlLeft  # before 'foo'
    d.pushString "<"
    d.push KEnter
    check d.run(ed, prompt = "> ") == "<foo bar\nbaz qux"

# ---------------- Driver: multiline newlines ----------------

suite "minline editor: newline insertion (multiline)":
  test "Alt+Enter inserts a real newline, Enter submits":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "first"
    d.push KAltEnter
    d.pushString "second"
    d.push KEnter
    check d.run(ed, prompt = "> ") == "first\nsecond"
    check ed.echoRows == 2

  test "Kitty Shift+Enter sequence inserts a newline":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "a"
    d.push KKittyShiftEnter
    d.pushString "b"
    d.push KEnter
    check d.run(ed, prompt = "> ") == "a\nb"

  test "modifyOtherKeys Shift+Enter sequence inserts a newline":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "x"
    d.push KModkSE
    d.pushString "y"
    d.push KEnter
    check d.run(ed, prompt = "> ") == "x\ny"

  test "trailing backslash stays literal — no continuation":
    # The old behaviour appended `\` to the line and re-prompted for a
    # continuation. Now `\` is just text and the line submits.
    var ed = initEditor()
    let d = newDriver()
    d.pushString "abc\\"
    d.push KEnter
    check d.run(ed, prompt = "> ") == "abc\\"

  test "backspace at start of second logical line joins lines":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "ab"
    d.push KAltEnter
    d.pushString "cd"
    d.push KHome     # cursor at start of "cd"
    d.push KBack     # remove the newline
    d.push KEnter
    check d.run(ed, prompt = "> ") == "abcd"

  test "Up arrow moves to previous visual row, preserving column":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "abcd"
    d.push KAltEnter
    d.pushString "efgh"
    # Cursor at end of "efgh" (col 6 with prompt "> ").
    d.push KUp
    # Now should be at end of "abcd" (col 6) — same column.
    d.pushString "X"
    d.push KEnter
    check d.run(ed, prompt = "> ") == "abcdX\nefgh"

  test "Down arrow moves to next visual row":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "abcd"
    d.push KAltEnter
    d.pushString "efgh"
    d.push KHome
    d.push KUp        # row 0, col 0 (would go to history) — actually
                      # falls through to historyPrevious at top row;
                      # since history is empty, no change.
    d.push KDown      # back to row 1 col 0
    d.pushString "Y"
    d.push KEnter
    check d.run(ed, prompt = "> ") == "abcd\nYefgh"

# ---------------- Driver: visual wrap ----------------

suite "minline editor: terminal-width wrap":
  test "long line wraps to additional rows":
    var ed = initEditor()
    let d = newDriver(width = 10)
    # Prompt "> " (width 2) leaves 8 cells on row 0.
    # Type 12 chars: first 8 on row 0, next 4 on row 1.
    d.pushString "abcdefghijkl"
    d.push KEnter
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
    d.push KLeft               # cursor between i and j, on row 1
    d.pushString "X"           # text becomes abcdefghiXj
    d.push KEnter
    discard d.run(ed, prompt = "> ")
    check rowText(d.grid, 0) == "> abcdefgh"
    check rowText(d.grid, 1).startsWith("  iXj")

  test "Up arrow on wrapped row moves to previous visual row, same logical line":
    var ed = initEditor()
    let d = newDriver(width = 10)
    d.pushString "abcdefghijkl"  # row 0: "abcdefgh", row 1: "ijkl"
    d.push KUp                   # cursor on row 0
    d.pushString "?"
    d.push KEnter
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
    d.push KLeft
    d.push KLeft  # cursor between n and o
    # Resize: shrink the terminal.
    d.width = 8
    # Insert a char — triggers re-render at new width.
    d.pushString "X"
    d.push KEnter
    check d.run(ed, prompt = "> ") == "abcdefghijklmnXop"

  test "echoRows reflects post-resize layout":
    var ed = initEditor()
    let d = newDriver(width = 80)
    d.pushString "abcdefghijklmnop"
    d.width = 8
    d.pushString " "  # trigger re-render
    d.push KEnter
    discard d.run(ed, prompt = "> ")
    # After resize: prompt "> " (2) + 17 chars. Row 0 holds 6 chars,
    # row 1 holds 8, row 2 holds 3.
    check ed.echoRows >= 2

# ---------------- Driver: rendered prompt + content ----------------

suite "minline editor: render correctness":
  test "colored prompt survives redraw and resets before input":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "hello"
    d.push KEnter
    discard d.run(ed, prompt = "\x1b[1;36m❯ \x1b[0m")
    check rowText(d.grid, 0) == "❯ hello"
    check d.grid.cellFg(0, 0) == colCyan
    check hasAttr(d.grid.cellAttr(0, 0), saBold)
    check d.grid.cellFg(0, 2) == colDefault
    check not hasAttr(d.grid.cellAttr(0, 2), saBold)

  test "second logical line is prefixed with continuation prompt '  '":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "ab"
    d.push KAltEnter
    d.pushString "cd"
    d.push KEnter
    discard d.run(ed, prompt = "> ")
    check rowText(d.grid, 0).startsWith("> ab")
    check rowText(d.grid, 1).startsWith("  cd")

  test "Ctrl+U clears the buffer in place":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "abcdef"
    d.push KCtrlU
    d.pushString "xy"
    d.push KEnter
    check d.run(ed, prompt = "> ") == "xy"

  test "Ctrl+W deletes the previous word":
    var ed = initEditor()
    let d = newDriver()
    d.pushString "foo bar baz"
    d.push KCtrlW
    d.push KEnter
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
    d.push KEnter
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
    d.push KEnter
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
    d.push KEnter
    check d.run(ed, prompt = "> ", hidechars = true) == "secret42"
    check rowText(d.grid, 0).startsWith("> ********")


# ---------------- SIGWINCH / EINTR ----------------

# ---------------- SIGWINCH / EINTR ----------------

template sigGetCh(keys: seq[int]; ki: var int; body: untyped): untyped =
  ## Read from `keys` where -1 = raise IOError (SIGWINCH EINTR).
  let idx = ki
  inc ki
  if keys[idx] == -1:
    resizePending = true
    raise newException(IOError, "Interrupted system call")
  body = keys[idx]

suite "minline editor: SIGWINCH EINTR":
  test "SIGWINCH before first keypress recovers":
    var ed = initEditor()
    ed.width = 20
    var keys: seq[int] = @[-1]
    keys.add toSeq("hello".mapIt(it.ord))
    keys.add KEnter
    var ki = 0
    let getCh: GetChProc = proc(): int =
      let idx = ki; inc ki
      if keys[idx] == -1:
        resizePending = true
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
    keys.add KEnter
    var ki = 0
    let getCh: GetChProc = proc(): int =
      let idx = ki; inc ki
      if keys[idx] == -1:
        resizePending = true
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
    keys.add KEnter
    var ki = 0
    let getCh: GetChProc = proc(): int =
      let idx = ki; inc ki
      if keys[idx] == -1:
        resizePending = true
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
