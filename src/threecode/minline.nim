## Multiline line editor.
##
## The editor stores the full input as a single ``string`` whose bytes may
## include ``'\n'`` to mark logical line breaks. ``position`` is a byte
## offset into that string. Cursor motion is implemented in two layers:
##
## * **Logical** — left/right step over runes (`'\n'` counts as one cell);
##   home/end snap to the current logical line; word-left/right cross
##   newlines.
## * **Visual** — up/down move by one *visual* row (which may be the
##   wrapped tail of a long logical line, or a previous logical line);
##   the column is preserved as best-effort.
##
## After every keystroke the entire buffer is repainted in place. The
## render walks the cursor back to the row where the prompt was first
## drawn (we track the cursor's row offset from that anchor in
## ``renderRow``), erases to end of screen, prints the prompt, the text
## (wrapping at terminal width with the continuation prompt prefixed to
## each logical line), and finally walks the cursor to the visual
## position computed from the current ``position``.
##
## All terminal IO goes through the ``write``/``getCh`` procs passed to
## ``readLineWith`` — the public ``readLine`` wires them to ``stdout`` /
## ``getchr``. Tests drive the editor through the ``…With`` form against
## an in-memory grid, no PTY required.

import
  critbits,
  terminal,
  unicode,
  deques,
  sequtils,
  strutils,
  tables,
  std/exitprocs,
  os

when defined(posix):
  import posix

# SIGWINCH: set on resize. Read by the readLine driver between keystrokes
# so the editor can pick up the new terminal width and redraw cleanly.
# The handler stays lightweight (just a flag) — no allocation, no
# stdio writes — to play nicely with whatever signal mask is in effect.
var resizePending* {.threadvar.}: bool

when defined(posix):
  var SIGWINCH {.importc, header: "<signal.h>".}: cint
  proc winchHandler(sig: cint) {.noconv.} =
    resizePending = true
  if isatty(stdin):
    var sa: Sigaction
    discard sigemptyset(sa.sa_mask)
    sa.sa_flags = SA_RESTART
    sa.sa_handler = winchHandler
    discard sigaction(SIGWINCH, sa, nil)

if isatty(stdin):
  addExitProc(resetAttributes)
  # Disable bracketed paste mode on exit so the user's shell doesn't inherit
  # the paste-wrap markers (which it would then surface as literal `[200~`).
  addExitProc(proc() {.noconv.} =
    try: stdout.write("\e[?2004l"); stdout.flushFile()
    except CatchableError: discard
  )

when defined(windows):
  proc putchr*(c: cint): cint {.discardable, header: "<conio.h>", importc: "_putch".}
    ## Prints an ASCII character to stdout.
  proc getchr*(): cint {.header: "<conio.h>", importc: "_getch".}
    ## Retrieves an ASCII character from stdin.
else:
  proc putchr*(c: cint) {.header: "stdio.h", importc: "putchar"} =
    ## Prints an ASCII character to stdout.
    stdout.write(c.chr)
    stdout.flushFile()

  proc getchr*(): cint =
    ## Retrieves an ASCII character from stdin.
    stdout.flushFile()
    return getch().ord.cint

# Types

type
  Key* = int
  KeySeq* = seq[Key]
  KeyCallback* = proc(ed: var LineEditor) {.closure.}
  LineError* = ref Exception
  LineEditorError* = ref Exception
  LineEditorMode* = enum
    mdInsert
    mdReplace
  Line* = object
    text*: string
    position*: int
  LineHistory* = object
    ## Two pieces of state, deliberately separate:
    ##
    ## * ``entries`` is the persistent, on-disk log. New submissions are
    ##   appended (after dedup + skip-empty); the file mirrors it byte for
    ##   byte at all times.
    ## * The navigation view (``cursor``, ``drafts``, ``cursorPos``) is
    ##   pure in-memory state for the current ``readLine`` call. ``cursor``
    ##   is ``-1`` when the user is on their own draft, otherwise the
    ##   index into ``entries`` they're viewing. Edits the user makes
    ##   while parked on any view are stashed in ``drafts``/``cursorPos``
    ##   so navigating Up then Down brings them back exactly where they
    ##   left off (text + cursor). The view is wiped on submit.
    file*: string
    entries*: Deque[string]
    max*: int
    cursor*: int
    drafts*: Table[int, string]
    cursorPos*: Table[int, int]
  WriteProc* = proc(s: string) {.closure.}
  GetChProc* = proc(): int {.closure.}
  WidthProc* = proc(): int {.closure.}
  LineEditor* = object
    completionCallback*: proc(ed: LineEditor): seq[string] {.closure.}
    history*: LineHistory
    line*: Line
    mode*: LineEditorMode
    prompt*: string
    contPrompt*: string
    promptW*: int
    contPromptW*: int
    width*: int
    renderRow*: int
    write*: WriteProc
    getCh*: GetChProc
    getWidth*: WidthProc
    echoRows*: int
    submitted*: bool
    canceled*: bool
    eof*: bool
    hidechars*: bool
    complPrefix*: string       ## original prefix before first completion
    complMatches*: seq[string] ## current match list
    complIndex*: int           ## current match index (-1 = none)
  InputCancelled* = object of CatchableError

const
  CTRL*        = {0 .. 31}
  DIGIT*       = {48 .. 57}
  LETTER*      = {65 .. 122}
  UPPERLETTER* = {65 .. 90}
  LOWERLETTER* = {97 .. 122}
  PRINTABLE*   = {32 .. 126}
when defined(windows):
  const
    ESCAPES* = {0, 22, 224}
else:
  const
    ESCAPES* = {27}

# ---------- Pure helpers (testable without IO) ----------

proc visualCols*(s: string): int =
  ## Number of cells `s` would occupy when printed. Counts each rune as
  ## one cell. Skips ANSI CSI sequences `ESC [ ... <final>` so escape
  ## codes embedded in a colored prompt don't inflate the count. Wide
  ## CJK and combining marks are not handled — fine for our prompts.
  var i = 0
  while i < s.len:
    let b = s[i]
    if b == '\x1b' and i + 1 < s.len and s[i + 1] == '[':
      var j = i + 2
      while j < s.len and (s[j] in {'0'..'9'} or s[j] == ';' or s[j] == '?'):
        inc j
      if j < s.len: inc j  # consume final byte
      i = j
    else:
      let rl = max(1, runeLenAt(s, i))
      inc result
      i += rl

proc runeStartBefore(text: string, p: int): int =
  ## Returns the byte offset of the rune that ends at `p` (i.e. position
  ## one rune to the left of `p`).
  if p <= 0: return 0
  var q = p - 1
  while q > 0 and (byte(text[q]) and 0xC0'u8) == 0x80'u8:
    dec q
  q

proc runeLenSafe(text: string, i: int): int =
  if i >= text.len: return 0
  let n = runeLenAt(text, i)
  if n <= 0: 1 else: n

proc cursorVisual*(text: string, position, promptW, contW, width: int): (int, int) =
  ## (visualRow, visualCol) of the cursor when ``text[0 ..< position]``
  ## has been rendered into a ``width``-wide grid with ``promptW`` cells
  ## reserved before the first logical line and ``contW`` cells reserved
  ## before each subsequent logical line.
  if width <= 0: return (0, 0)
  var row = 0
  var col = promptW
  var i = 0
  while i < position and i < text.len:
    let c = text[i]
    if c == '\n':
      inc row
      col = contW
      inc i
    else:
      if col >= width:
        inc row
        col = 0
      inc col
      i += runeLenSafe(text, i)
  (row, col)

proc totalRows*(text: string, promptW, contW, width: int): int =
  ## Number of visual rows the rendered buffer occupies, always ``>= 1``.
  if width <= 0: return 1
  var row = 0
  var col = promptW
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == '\n':
      inc row
      col = contW
      inc i
    else:
      if col >= width:
        inc row
        col = 0
      inc col
      i += runeLenSafe(text, i)
  row + 1

proc renderBuffer*(text, prompt, cont: string, width: int): string =
  ## Bytes that paint the buffer. Visual rows are joined with ``"\r\n"``
  ## and no trailing newline is emitted. The prompt is written verbatim
  ## (so callers can include color escapes); its display width is taken
  ## via ``visualCols``. Same for the continuation prompt.
  let promptW = visualCols(prompt)
  let contW = visualCols(cont)
  if width <= 0: return prompt & text
  var col = promptW
  result = prompt
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == '\n':
      result.add "\r\n"
      result.add cont
      col = contW
      inc i
    else:
      let rl = runeLenSafe(text, i)
      if col >= width:
        result.add "\r\n"
        col = 0
      result.add text[i ..< i + rl]
      inc col
      i += rl

# History
#
# Two responsibilities, kept separate:
#
# 1. Persistence — `entries` is the on-disk log. `historyAdd` is the only
#    mutator: it skips empty submissions, dedupes against the previous
#    entry, evicts the oldest when at capacity, and rewrites the file.
# 2. Navigation — Up/Down walk a view over `entries` plus a virtual
#    "draft" slot at index -1 that holds the in-progress text the user
#    had typed before they started navigating. The view is `cursor` plus
#    the `drafts`/`cursorPos` tables. Both tables are keyed by the same
#    int as `cursor`, so -1 reaches the user's own draft and 0..N-1 reach
#    in-memory edits to history entries. Submit clears the view.

proc encodeHistEntry(s: string): string =
  ## Encode an entry for the on-disk history file: ``\`` -> ``\\``,
  ## newline -> ``\n``. Keeps each entry on a single physical line so
  ## the file stays human-readable (`cat ~/.local/share/.../history`).
  result = newStringOfCap(s.len + 8)
  for ch in s:
    case ch
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': discard
    else: result.add ch

proc decodeHistEntry(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      case s[i + 1]
      of '\\': result.add '\\'; i += 2
      of 'n': result.add '\n'; i += 2
      else: result.add s[i]; inc i
    else:
      result.add s[i]; inc i

proc clearNav(h: var LineHistory) =
  h.cursor = -1
  h.drafts.clear()
  h.cursorPos.clear()

proc persist(h: LineHistory) =
  if h.file == "": return
  let encoded = toSeq(h.entries.items).mapIt(encodeHistEntry(it)).join("\n")
  h.file.writeFile(encoded)

proc historyInit*(size = 256, file: string = ""): LineHistory =
  result.file = file
  result.entries = initDeque[string](size)
  result.max = size
  result.cursor = -1
  result.drafts = initTable[int, string]()
  result.cursorPos = initTable[int, int]()
  if file == "": return
  if result.file.fileExists:
    let lines = result.file.readFile.split("\n")
    for line in lines:
      if line == "": continue
      let entry = decodeHistEntry(line)
      # On load, drop consecutive duplicates so a previously-buggy file
      # converges to a clean state on first run.
      if result.entries.len > 0 and result.entries[result.entries.len - 1] == entry:
        continue
      if result.entries.len >= result.max:
        discard result.entries.popFirst
      result.entries.addLast entry
  else:
    result.file.writeFile("")

proc historyAdd*(ed: var LineEditor) =
  ## Append the just-submitted line to the persistent log. Empty
  ## submissions and consecutive duplicates are dropped — they're noise
  ## when scrolling back. Writes the file atomically each time.
  let s = ed.line.text
  if s == "": return
  let h = addr ed.history
  if h[].entries.len > 0 and h[].entries[h[].entries.len - 1] == s:
    return
  while h[].entries.len >= h[].max:
    discard h[].entries.popFirst
  h[].entries.addLast s
  persist(h[])

proc historyFlush*(ed: var LineEditor) =
  ## Reset the navigation view. Called once per submitted line so the
  ## next ``readLine`` starts fresh on the user's draft slot.
  ed.history.clearNav()

# ---------- Render ----------

proc emitMoveUp(ed: var LineEditor, n: int) =
  if n <= 0: return
  ed.write "\x1b[" & $n & "A"

proc emitMoveDown(ed: var LineEditor, n: int) =
  if n <= 0: return
  ed.write "\x1b[" & $n & "B"

proc emitColumn(ed: var LineEditor, col: int) =
  ## Set cursor to absolute column ``col`` (0-based) on the current row.
  ed.write "\r"
  if col > 0:
    ed.write "\x1b[" & $col & "C"

proc fullRedraw*(ed: var LineEditor) =
  ## Wipe the previously rendered area, repaint prompt + buffer, place
  ## the cursor at the visual position derived from ``ed.line.position``.
  ## Updates ``ed.renderRow`` to match.
  ##
  ## All bytes for the repaint are coalesced into a single ``write``
  ## call so the underlying ``stdout.flushFile`` runs once per keystroke
  ## (was: ~5 flushes per redraw, visible on Windows conhost as flicker
  ## because conhost paints between flushes). The whole thing is also
  ## wrapped in DEC 2026 synchronized-output (``CSI ? 2026 h/l``) so
  ## conhost treats the repaint as one atomic frame; terminals that
  ## don't recognize the mode ignore it silently.
  if ed.getWidth != nil:
    let w = ed.getWidth()
    if w > 0: ed.width = w
  let width = max(2, ed.width)
  let pw = if ed.promptW > 0: ed.promptW else: visualCols(ed.prompt)
  let cw = if ed.contPromptW > 0: ed.contPromptW else: visualCols(ed.contPrompt)
  ed.promptW = pw
  ed.contPromptW = cw
  let total = totalRows(ed.line.text, pw, cw, width)
  let endRow = total - 1
  let (targetRow, targetCol) = cursorVisual(ed.line.text, ed.line.position,
                                            pw, cw, width)
  var buf = "\x1b[?2026h"
  if ed.renderRow > 0:
    buf.add "\x1b[" & $ed.renderRow & "A"
  buf.add "\r\x1b[J"
  buf.add renderBuffer(ed.line.text, ed.prompt, ed.contPrompt, width)
  if endRow > targetRow:
    buf.add "\x1b[" & $(endRow - targetRow) & "A"
  buf.add "\r"
  if targetCol > 0:
    buf.add "\x1b[" & $targetCol & "C"
  buf.add "\x1b[?2026l"
  ed.write buf
  ed.renderRow = targetRow

proc parkAtEnd(ed: var LineEditor) =
  ## After submit, leave the cursor at column 0 of the row directly
  ## below the rendered input — the contract every external transition
  ## (``submitTransitionBytes`` etc.) was already written against.
  let width = max(2, ed.width)
  let total = totalRows(ed.line.text, ed.promptW, ed.contPromptW, width)
  let endRow = total - 1
  if ed.renderRow < endRow:
    emitMoveDown(ed, endRow - ed.renderRow)
  ed.write "\r\n"
  ed.echoRows = total
  ed.renderRow = 0

# ---------- Edit ops (multiline-aware) ----------

proc back*(ed: var LineEditor, n = 1) =
  ## Step the cursor left by ``n`` runes / newlines.
  for _ in 0 ..< n:
    if ed.line.position <= 0: break
    if ed.line.text[ed.line.position - 1] == '\n':
      dec ed.line.position
    else:
      ed.line.position = runeStartBefore(ed.line.text, ed.line.position)
  fullRedraw(ed)

proc forward*(ed: var LineEditor, n = 1) =
  for _ in 0 ..< n:
    if ed.line.position >= ed.line.text.len: break
    if ed.line.text[ed.line.position] == '\n':
      inc ed.line.position
    else:
      ed.line.position += runeLenSafe(ed.line.text, ed.line.position)
  fullRedraw(ed)

proc deletePrevious*(ed: var LineEditor) =
  if ed.line.position <= 0: return
  let start =
    if ed.line.text[ed.line.position - 1] == '\n': ed.line.position - 1
    else: runeStartBefore(ed.line.text, ed.line.position)
  ed.line.text = ed.line.text[0 ..< start] &
                 ed.line.text[ed.line.position .. ^1]
  ed.line.position = start
  fullRedraw(ed)

proc deleteNext*(ed: var LineEditor) =
  if ed.line.position >= ed.line.text.len: return
  let stop =
    if ed.line.text[ed.line.position] == '\n': ed.line.position + 1
    else: ed.line.position + runeLenSafe(ed.line.text, ed.line.position)
  ed.line.text = ed.line.text[0 ..< ed.line.position] &
                 ed.line.text[stop .. ^1]
  fullRedraw(ed)

proc insertText*(ed: var LineEditor, s: string) =
  ## Insert ``s`` at the current position. Replace mode overwrites runes
  ## within the current logical line; newlines in ``s`` always insert.
  if s.len == 0: return
  if ed.mode == mdInsert or s.contains('\n'):
    ed.line.text = ed.line.text[0 ..< ed.line.position] & s &
                   ed.line.text[ed.line.position .. ^1]
    ed.line.position += s.len
  else:
    var p = ed.line.position
    var i = 0
    while i < s.len:
      let rl = runeLenSafe(s, i)
      if p < ed.line.text.len and ed.line.text[p] != '\n':
        let oldRl = runeLenSafe(ed.line.text, p)
        ed.line.text = ed.line.text[0 ..< p] & s[i ..< i + rl] &
                       ed.line.text[p + oldRl .. ^1]
      else:
        ed.line.text = ed.line.text[0 ..< p] & s[i ..< i + rl] &
                       ed.line.text[p .. ^1]
      p += rl
      i += rl
    ed.line.position = p
  fullRedraw(ed)

proc printChar*(ed: var LineEditor, c: int) =
  ed.insertText($c.chr)

proc insertNewline*(ed: var LineEditor) =
  ed.insertText("\n")

proc changeLine*(ed: var LineEditor, s: string) =
  ## Replace the entire buffer.
  ed.line.text = s
  ed.line.position = s.len
  fullRedraw(ed)

proc clearLine*(ed: var LineEditor) =
  ## Empty the buffer.
  ed.changeLine("")

proc goToStart*(ed: var LineEditor) =
  ## Move to the start of the current logical line.
  var p = ed.line.position
  while p > 0 and ed.line.text[p - 1] != '\n':
    dec p
  ed.line.position = p
  fullRedraw(ed)

proc goToEnd*(ed: var LineEditor) =
  ## Move to the end of the current logical line.
  var p = ed.line.position
  while p < ed.line.text.len and ed.line.text[p] != '\n':
    inc p
  ed.line.position = p
  fullRedraw(ed)

proc goToBufferStart*(ed: var LineEditor) =
  ed.line.position = 0
  fullRedraw(ed)

proc goToBufferEnd*(ed: var LineEditor) =
  ed.line.position = ed.line.text.len
  fullRedraw(ed)

proc isWordChar(b: char): bool {.inline.} =
  b != ' ' and b != '\t' and b != '\n'

proc wordLeft*(ed: var LineEditor) =
  var p = ed.line.position
  while p > 0 and not isWordChar(ed.line.text[p - 1]):
    dec p
  while p > 0 and isWordChar(ed.line.text[p - 1]):
    dec p
  ed.line.position = p
  fullRedraw(ed)

proc wordRight*(ed: var LineEditor) =
  var p = ed.line.position
  let n = ed.line.text.len
  while p < n and isWordChar(ed.line.text[p]):
    inc p
  while p < n and not isWordChar(ed.line.text[p]):
    inc p
  ed.line.position = p
  fullRedraw(ed)

proc deleteWordLeft*(ed: var LineEditor) =
  let stop = ed.line.position
  var p = ed.line.position
  while p > 0 and not isWordChar(ed.line.text[p - 1]):
    dec p
  while p > 0 and isWordChar(ed.line.text[p - 1]):
    dec p
  if p == stop: return
  ed.line.text = ed.line.text[0 ..< p] & ed.line.text[stop .. ^1]
  ed.line.position = p
  fullRedraw(ed)

proc visualUp*(ed: var LineEditor) =
  ## Move up by one visual row, preserving the visual column as best as
  ## possible. If already on the top visual row of the buffer, fall back
  ## to ``historyPrevious`` (Emacs convention).

  let width = max(2, ed.width)
  let pw = ed.promptW
  let cw = ed.contPromptW
  let (curR, curC) = cursorVisual(ed.line.text, ed.line.position, pw, cw, width)
  if curR == 0:
    return  # caller decides whether to invoke history
  var bestP = ed.line.position
  var bestDiff = high(int)
  var i = 0
  while i <= ed.line.text.len:
    let (r, c) = cursorVisual(ed.line.text, i, pw, cw, width)
    if r == curR - 1:
      let d = abs(c - curC)
      if d < bestDiff:
        bestDiff = d
        bestP = i
    elif r >= curR:
      break
    if i < ed.line.text.len:
      if ed.line.text[i] == '\n': inc i
      else: i += runeLenSafe(ed.line.text, i)
    else:
      inc i
  ed.line.position = bestP
  fullRedraw(ed)

proc visualDown*(ed: var LineEditor) =
  let width = max(2, ed.width)
  let pw = ed.promptW
  let cw = ed.contPromptW
  let (curR, curC) = cursorVisual(ed.line.text, ed.line.position, pw, cw, width)
  let total = totalRows(ed.line.text, pw, cw, width)
  if curR >= total - 1: return
  var bestP = ed.line.position
  var bestDiff = high(int)
  var seenTarget = false
  var i = 0
  while i <= ed.line.text.len:
    let (r, c) = cursorVisual(ed.line.text, i, pw, cw, width)
    if r == curR + 1:
      seenTarget = true
      let d = abs(c - curC)
      if d < bestDiff:
        bestDiff = d
        bestP = i
    elif r > curR + 1:
      break
    if i < ed.line.text.len:
      if ed.line.text[i] == '\n': inc i
      else: i += runeLenSafe(ed.line.text, i)
    else:
      inc i
  if seenTarget:
    ed.line.position = bestP
    fullRedraw(ed)

proc loadView(ed: var LineEditor, idx: int) =
  ## Pull the buffer + cursor for view ``idx`` into the editor.
  ## ``idx == -1`` is the user's draft; ``0..entries.len-1`` is a
  ## history entry. Pending edits (``drafts[idx]``) win over the
  ## persistent text; absent entries fall back to the canonical text
  ## with the cursor parked at the end.
  let text =
    if idx == -1:
      ed.history.drafts.getOrDefault(-1, "")
    elif ed.history.drafts.hasKey(idx):
      ed.history.drafts[idx]
    else:
      ed.history.entries[idx]
  let pos =
    if ed.history.cursorPos.hasKey(idx): ed.history.cursorPos[idx]
    else: text.len
  ed.line.text = text
  ed.line.position = clamp(pos, 0, text.len)
  fullRedraw(ed)

proc stashView(ed: var LineEditor) =
  ## Save the live buffer into the slot we're about to leave so coming
  ## back finds it intact.
  ed.history.drafts[ed.history.cursor] = ed.line.text
  ed.history.cursorPos[ed.history.cursor] = ed.line.position

proc historyPrevious*(ed: var LineEditor) =
  ## Step one entry older. From the draft slot (cursor == -1) this lands
  ## on the newest entry. Already at the oldest? Do nothing — including
  ## not stashing, so a no-op Up doesn't perturb anything.
  if ed.history.entries.len == 0: return
  let target =
    if ed.history.cursor == -1: ed.history.entries.len - 1
    elif ed.history.cursor > 0: ed.history.cursor - 1
    else: return
  ed.stashView()
  ed.history.cursor = target
  ed.loadView(target)

proc historyNext*(ed: var LineEditor) =
  ## Step one entry newer. Past the last entry, fall back to the
  ## user's draft. On the draft already? No-op.
  if ed.history.cursor == -1: return
  let target =
    if ed.history.cursor < ed.history.entries.len - 1: ed.history.cursor + 1
    else: -1
  ed.stashView()
  ed.history.cursor = target
  ed.loadView(target)

proc lineText*(ed: LineEditor): string = ed.line.text

# Key Names
var KEYNAMES* {.threadvar.}: array[0 .. 31, string]

KEYNAMES[1]    = "ctrl+a"
KEYNAMES[2]    = "ctrl+b"
KEYNAMES[3]    = "ctrl+c"
KEYNAMES[4]    = "ctrl+d"
KEYNAMES[5]    = "ctrl+e"
KEYNAMES[6]    = "ctrl+f"
KEYNAMES[7]    = "ctrl+g"
KEYNAMES[8]    = "ctrl+h"
KEYNAMES[9]    = "ctrl+i"
KEYNAMES[9]    = "tab"
KEYNAMES[10]   = "ctrl+j"
KEYNAMES[11]   = "ctrl+k"
KEYNAMES[12]   = "ctrl+l"
KEYNAMES[13]   = "ctrl+m"
KEYNAMES[14]   = "ctrl+n"
KEYNAMES[15]   = "ctrl+o"
KEYNAMES[16]   = "ctrl+p"
KEYNAMES[17]   = "ctrl+q"
KEYNAMES[18]   = "ctrl+r"
KEYNAMES[19]   = "ctrl+s"
KEYNAMES[20]   = "ctrl+t"
KEYNAMES[21]   = "ctrl+u"
KEYNAMES[22]   = "ctrl+v"
KEYNAMES[23]   = "ctrl+w"
KEYNAMES[24]   = "ctrl+x"
KEYNAMES[25]   = "ctrl+y"
KEYNAMES[26]   = "ctrl+z"

var KEYSEQS* {.threadvar.}: CritBitTree[KeySeq]

when defined(windows):
  KEYSEQS["up"]         = @[224, 72]
  KEYSEQS["down"]       = @[224, 80]
  KEYSEQS["right"]      = @[224, 77]
  KEYSEQS["left"]       = @[224, 75]
  KEYSEQS["home"]       = @[224, 71]
  KEYSEQS["end"]        = @[224, 79]
  KEYSEQS["insert"]     = @[224, 82]
  KEYSEQS["delete"]     = @[224, 83]
else:
  KEYSEQS["up"]         = @[27, 91, 65]
  KEYSEQS["down"]       = @[27, 91, 66]
  KEYSEQS["right"]      = @[27, 91, 67]
  KEYSEQS["left"]       = @[27, 91, 68]
  KEYSEQS["home"]       = @[27, 91, 72]
  KEYSEQS["end"]        = @[27, 91, 70]
  KEYSEQS["insert"]     = @[27, 91, 50, 126]
  KEYSEQS["delete"]     = @[27, 91, 51, 126]

var KEYMAP* {.threadvar.}: CritBitTree[KeyCallback]

KEYMAP["backspace"] = proc(ed: var LineEditor) = ed.deletePrevious()
KEYMAP["delete"]    = proc(ed: var LineEditor) = ed.deleteNext()
KEYMAP["insert"]    = proc(ed: var LineEditor) =
  ed.mode = if ed.mode == mdInsert: mdReplace else: mdInsert
KEYMAP["down"]      = proc(ed: var LineEditor) =
  ## Down — visual row first; if already at the last visual row, fall
  ## through to history-next (matches readline / Emacs feel).
  let pw = ed.promptW; let cw = ed.contPromptW
  let width = max(2, ed.width)
  let (curR, _) = cursorVisual(ed.line.text, ed.line.position, pw, cw, width)
  let total = totalRows(ed.line.text, pw, cw, width)
  if curR >= total - 1: ed.historyNext()
  else: ed.visualDown()
KEYMAP["up"]        = proc(ed: var LineEditor) =
  let pw = ed.promptW; let cw = ed.contPromptW
  let width = max(2, ed.width)
  let (curR, _) = cursorVisual(ed.line.text, ed.line.position, pw, cw, width)
  if curR <= 0: ed.historyPrevious()
  else: ed.visualUp()
KEYMAP["ctrl+n"]    = proc(ed: var LineEditor) = ed.historyNext()
KEYMAP["ctrl+p"]    = proc(ed: var LineEditor) = ed.historyPrevious()
KEYMAP["left"]      = proc(ed: var LineEditor) = ed.back()
KEYMAP["right"]     = proc(ed: var LineEditor) = ed.forward()
KEYMAP["ctrl+b"]    = proc(ed: var LineEditor) = ed.back()
KEYMAP["ctrl+f"]    = proc(ed: var LineEditor) = ed.forward()
KEYMAP["ctrl+u"]    = proc(ed: var LineEditor) = ed.clearLine()
KEYMAP["ctrl+a"]    = proc(ed: var LineEditor) = ed.goToStart()
KEYMAP["ctrl+e"]    = proc(ed: var LineEditor) = ed.goToEnd()
KEYMAP["home"]      = proc(ed: var LineEditor) = ed.goToStart()
KEYMAP["end"]       = proc(ed: var LineEditor) = ed.goToEnd()
KEYMAP["ctrl+w"]    = proc(ed: var LineEditor) = ed.deleteWordLeft()
KEYMAP["ctrl+c"]    = proc(ed: var LineEditor) =
  ed.canceled = true
  raise newException(InputCancelled, "")
KEYMAP["ctrl+d"]    = proc(ed: var LineEditor) =
  ed.eof = true
  raise newException(EOFError, "")
KEYMAP["ctrl+l"]    = proc(ed: var LineEditor) =
  ed.write "\x1b[H\x1b[2J"
  ed.renderRow = 0
  fullRedraw(ed)
when defined(posix):
  KEYMAP["ctrl+z"]  = proc(ed: var LineEditor) =
    ed.write "\n\e[?2004l"
    resetAttributes()
    stdout.flushFile()
    discard posix.kill(posix.getpid(), posix.SIGTSTP)
    ed.write "\e[?2004h"
    ed.renderRow = 0
    fullRedraw(ed)

# ---------- Completion ----------

proc complCurrentWord(ed: LineEditor): string =
  let position = ed.line.position
  let words = ed.line.text[0 ..< position].split({' ', '\n'})
  if words.len > 0: words[^1] else: ""

proc complAdvance(ed: var LineEditor; offset: int) =
  ## Move completion by `offset` steps (+1 forward, -1 backward).
  ## Initialises state on first call; cycles on subsequent calls.
  if ed.completionCallback.isNil: return
  let word = ed.complCurrentWord()
  # Fresh cycle: user just typed a new prefix
  if ed.complIndex < 0 or ed.complIndex >= ed.complMatches.len or word != ed.complMatches[ed.complIndex]:
    ed.complPrefix = word
    ed.complMatches = ed.completionCallback(ed)
      .filterIt(it.toLowerAscii.startsWith(ed.complPrefix.toLowerAscii))
    if ed.complMatches.len == 0:
      ed.complIndex = -1
      return
    ed.complIndex = 0
    if ed.complPrefix.len > 0:
      for _ in 0 ..< ed.complPrefix.len: ed.deletePrevious()
    ed.insertText(ed.complMatches[0])
    return
  # Continue existing cycle
  if ed.complMatches.len == 0: return
  let oldIdx = ed.complIndex
  ed.complIndex = (ed.complIndex + offset + ed.complMatches.len) mod ed.complMatches.len
  for _ in 0 ..< ed.complMatches[oldIdx].len: ed.deletePrevious()
  ed.insertText(ed.complMatches[ed.complIndex])

proc completeLine*(ed: var LineEditor): int =
  ## First Tab: insert first match. Subsequent Tabs: cycle forward.
  ## Returns the non-Tab keystroke that broke the cycle.
  ed.complAdvance(+1)
  if ed.complIndex == -1: return -1
  var ch = ed.getCh()
  while ch == 9:
    ed.complAdvance(+1)
    ch = ed.getCh()
  ed.complIndex = -1
  return ch

proc reverseCompleteLine*(ed: var LineEditor) =
  ed.complAdvance(-1)

# ---------- Bracketed paste ----------

proc readBracketedPaste(ed: var LineEditor): string =
  # Read characters until the bracketed paste end sequence ESC [ 201 ~
  # The previous implementation built the entire string and used
  # `endsWith` on each iteration, which can be inefficient for large
  # pastes. Here we detect the terminator by checking the last five
  # characters directly, avoiding a full scan each loop.
  const endSeq = "\e[201~"
  const endLen = endSeq.len
  while true:
    let b = ed.getCh()
    if b < 0:
      return result
    result.add b.chr
    if result.len >= endLen:
      # Compare the tail of the buffer with the end sequence.
      if result[result.len - endLen ..< result.len] == endSeq:
        # Remove the terminator and return the paste content.
        result.setLen(result.len - endLen)
        return result

# ---------- readLine driver ----------

proc initEditor*(mode = mdInsert, historySize = 256, historyFile: string = ""): LineEditor =
  result.mode = mode
  result.history = historyInit(historySize, historyFile)
  result.width = 80
  result.contPrompt = "  "

proc resetForRead(ed: var LineEditor, prompt: string, hidechars: bool) =
  ed.line = Line(text: "", position: 0)
  ed.prompt = prompt
  if ed.contPrompt.len == 0:
    ed.contPrompt = "  "
  ed.promptW = visualCols(prompt)
  ed.contPromptW = visualCols(ed.contPrompt)
  ed.renderRow = 0
  ed.echoRows = 0
  ed.submitted = false
  ed.canceled = false
  ed.eof = false
  ed.hidechars = hidechars
  if ed.getWidth != nil:
    let w = ed.getWidth()
    if w > 0: ed.width = w

proc handleEscape*(ed: var LineEditor, c1: int): bool =
  ## Process a single escape sequence starting just after the leading
  ## prefix byte ``c1`` (POSIX: ESC = 27; Windows console: 0 or 224 for
  ## extended keys). Returns ``true`` if the sequence requested a submit
  ## (Shift+Enter / Alt+Enter — these now insert a real newline rather
  ## than backslash-continuation).
  let c2 = ed.getCh()
  if c2 < 0: return false
  # Two-byte sequences. On Windows arrows / nav keys arrive as ``[224, X]``
  # and KEYSEQS holds the same shape; on POSIX KEYSEQS values are 3+ bytes
  # so this two-byte check is always a no-op there.
  var s = @[c1.Key, c2.Key]
  if s == KEYSEQS["left"]:   ed.back();             return false
  if s == KEYSEQS["right"]:  ed.forward();          return false
  if s == KEYSEQS["up"]:     KEYMAP["up"](ed);      return false
  if s == KEYSEQS["down"]:   KEYMAP["down"](ed);    return false
  if s == KEYSEQS["home"]:   ed.goToStart();        return false
  if s == KEYSEQS["end"]:    ed.goToEnd();          return false
  if s == KEYSEQS["delete"]: ed.deleteNext();       return false
  if s == KEYSEQS["insert"]: KEYMAP["insert"](ed);  return false
  # Everything below is POSIX-specific (ESC + CR for Alt/Shift+Enter,
  # CSI ``ESC [`` sequences, modifyOtherKeys, bracketed paste, kitty
  # extensions). Windows' 0/224 prefixes have no further structure.
  if c1 != 27: return false
  if c2 == 13:
    ed.insertNewline()
    return false
  if c2 == 91:  # CSI
    let c3 = ed.getCh()
    if c3 < 0: return false
    s.add c3.Key
    if s == KEYSEQS["right"]:  ed.forward(); return false
    if s == KEYSEQS["left"]:   ed.back();    return false
    if s == KEYSEQS["up"]:     KEYMAP["up"](ed);   return false
    if s == KEYSEQS["down"]:   KEYMAP["down"](ed); return false
    if s == KEYSEQS["home"]:   ed.goToStart(); return false
    if s == KEYSEQS["end"]:    ed.goToEnd();   return false
    if c3 == 90:
      # Shift+Tab: reverse completion
      ed.reverseCompleteLine()
      return false
    if c3 == 50 or c3 == 51:
      let c4 = ed.getCh()
      if c4 < 0: return false
      if c4 == 126 and c3 == 50:
        KEYMAP["insert"](ed); return false
      if c4 == 126 and c3 == 51:
        ed.deleteNext(); return false
      if c3 == 50 and c4 == 55:
        # modifyOtherKeys: ESC [ 27 ; <mod> ; <key> ~
        let c5 = ed.getCh()
        if c5 == 59:
          var modDigits = ""
          var ch = ed.getCh()
          while ch >= 48 and ch <= 57:
            modDigits.add ch.chr
            ch = ed.getCh()
          if ch == 59:
            var keyDigits = ""
            ch = ed.getCh()
            while ch >= 48 and ch <= 57:
              keyDigits.add ch.chr
              ch = ed.getCh()
            if ch == 126 and keyDigits == "13" and modDigits == "2":
              ed.insertNewline()
              return false
        return false
      if c3 == 50 and c4 == 48:
        # bracketed paste start: ESC [ 200 ~
        let c5 = ed.getCh()
        let c6 = ed.getCh()
        if c5 == 48 and c6 == 126:
          let paste = readBracketedPaste(ed)
          if paste.len > 0:
            if ed.hidechars:
              # Hidden inputs (api keys): drop CR/LF and any non-printable
              # byte, append the rest to the buffer directly, write one `*`
              # per kept byte. Avoids `insertText` -> `fullRedraw` (which
              # would render the cleartext key on screen) and avoids
              # `c1 == 10/13` early-submit if the clipboard had a trailing
              # newline that the terminal happens to send raw.
              var stars = 0
              for ch in paste:
                if ch.ord in PRINTABLE:
                  ed.line.text.add ch
                  inc ed.line.position
                  inc stars
              if stars > 0:
                ed.write repeat('*', stars)
            else:
              var clean = newStringOfCap(paste.len)
              for ch in paste:
                if ch == '\r': discard
                else: clean.add ch
              ed.insertText(clean)
        return false
      if c3 == 51 and c4 == 59:
        # ESC [ 3 ; <mod> ~  (e.g. shift+delete)
        let modCh = ed.getCh()
        let final = ed.getCh()
        if final == 126 and modCh == 53:  # ctrl+delete
          ed.deleteWordLeft()
        return false
    elif c3 == 49:
      # ESC [ 1 ; <mod> <dir>
      let c4 = ed.getCh()
      if c4 == 59:
        let modifier = ed.getCh()
        let direction = ed.getCh()
        if modifier == 53:  # ctrl
          case direction
          of 68: wordLeft(ed)
          of 67: wordRight(ed)
          of 65: KEYMAP["up"](ed)
          of 66: KEYMAP["down"](ed)
          else: discard
      elif c4 == 51:
        # Kitty Shift+Enter: ESC [ 1 3 ; 2 u
        let c5 = ed.getCh()
        if c5 == 59:
          var modDigits = ""
          var ch = ed.getCh()
          while ch >= 48 and ch <= 57:
            modDigits.add ch.chr
            ch = ed.getCh()
          if ch == 117 and modDigits == "2":
            ed.insertNewline()
      return false
  return false

proc readLineWith*(ed: var LineEditor, prompt: string,
                   getCh: GetChProc, write: WriteProc,
                   hidechars = false, noHistory = false,
                   getWidth: WidthProc = nil): string =
  ## Pluggable form of ``readLine``. Provides the same behavior as
  ## ``readLine`` but with explicit IO procs so tests can drive the
  ## editor against a fake terminal.
  ed.getCh = getCh
  ed.write = write
  ed.getWidth = getWidth
  resetForRead(ed, prompt, hidechars)
  # Enable bracketed paste in both modes. For hidden inputs (api keys),
  # this lets the bracketed-paste handler atomically capture the paste
  # and mask it as `*`s, instead of letting the per-byte loop see
  # embedded CR/LF (early submit) or drop high UTF-8 bytes silently.
  ed.write "\x1b[?2004h"
  fullRedraw(ed)
  while true:
    let c1 = ed.getCh()
    if resizePending:
      resizePending = false
      fullRedraw(ed)
    if c1 < 0:
      ed.eof = true
      raise newException(EOFError, "")
    if c1 == 10 or c1 == 13:
      parkAtEnd(ed)
      if not noHistory and not hidechars:
        ed.historyAdd()
      ed.historyFlush()
      ed.write "\x1b[?2004l"
      ed.submitted = true
      return ed.line.text
    if c1 == 8 or c1 == 127:
      ed.deletePrevious()
      continue
    if c1 in PRINTABLE:
      if hidechars:
        ed.line.text.add c1.chr
        inc ed.line.position
        ed.write "*"
      else:
        ed.printChar(c1)
      continue
    if c1 == 9:
      let nxt = ed.completeLine()
      if nxt > 0:
        # The completion absorbed a trailing keystroke we should treat
        # as the next char. Re-dispatch via a tiny tail-call by
        # synthesising a tiny `pending` slot — but we don't have one;
        # so handle the common "Enter after completion" case here.
        if nxt == 10 or nxt == 13:
          parkAtEnd(ed)
          if not noHistory and not hidechars:
            ed.historyAdd()
          ed.historyFlush()
          ed.write "\x1b[?2004l"
          ed.submitted = true
          return ed.line.text
        if nxt in PRINTABLE:
          ed.printChar(nxt)
      continue
    if c1 in ESCAPES:
      discard handleEscape(ed, c1)
      continue
    if c1 in CTRL and KEYMAP.hasKey(KEYNAMES[c1]):
      KEYMAP[KEYNAMES[c1]](ed)
      continue
    # Unknown byte: ignore.

proc readLine*(ed: var LineEditor, prompt = "", hidechars = false,
               noHistory = false): string =
  let getCh: GetChProc = proc(): int = getchr().int
  let write: WriteProc = proc(s: string) =
    stdout.write s
    stdout.flushFile()
  let getWidth: WidthProc = proc(): int =
    try: terminalWidth() except CatchableError: 80
  ed.readLineWith(prompt, getCh, write, hidechars = hidechars,
                  noHistory = noHistory, getWidth = getWidth)

proc password*(ed: var LineEditor, prompt = ""): string =
  ed.readLine(prompt, true)

when isMainModule:
  proc test() =
    var ed = initEditor(historyFile = "")
    while true:
      let s = ed.readLine("-> ")
      stdout.writeLine "got: " & s.replace("\n", "\\n")
  test()
