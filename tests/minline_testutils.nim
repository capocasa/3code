import std/deques
import threecode/minline
import ttty

type
  Driver* = ref object
    terminal*: Terminal
    grid*: Grid
    width*: int
    pendingInput*: HasPendingInputProc
  KeyEncoding* = enum
    XMod
    Kitty
  KeyMod* = enum
    Shift
    Ctrl
    Alt
  KeyChord* = object
    mods*: set[KeyMod]
    key*: seq[int]

proc newDriver*(width = 80): Driver =
  let terminal = newTerminal(width = width)
  Driver(terminal: terminal, grid: terminal.grid, width: width)

proc push*(d: Driver, ks: openArray[int]) =
  d.terminal.push ks

proc pushString*(d: Driver, s: string) =
  d.terminal.pushText s

const
  # Single-byte keys are platform-independent terminal control chars.
  CtrlC* = KeyCtrlC
  CtrlD* = @[4]
  Esc* = KeyEsc
  Enter* = KeyEnter
  Backspace* = KeyBackspace
  CtrlU* = @[21]
  CtrlW* = @[23]
  CtrlA* = @[1]
  CtrlE* = @[5]
  AltB* = @[27, 98]   # Alt+B: back one word
  AltF* = @[27, 102]  # Alt+F: forward one word
  CtrlAltH* = @[27, 8]  # Ctrl+Alt+H: delete back to word boundary
  AltEnter* = KeyAltEnter
  KittyShiftEnter = KeyKittyShiftEnter
  XModShiftEnter = KeyModifyOtherShiftEnter
  CtrlLeft* = @[27, 91, 49, 59, 53, 68]
  CtrlRight* = @[27, 91, 49, 59, 53, 67]

# Arrow / nav keys are multi-byte escape sequences whose encoding is
# platform-conditional: POSIX terminals send `ESC [ X`, the Windows console
# (`_getch`) sends `[224, X]`. The editor's `KEYSEQS`/`ESCAPES` tables
# (src/threecode/minline.nim) mirror exactly this split, so the test must
# feed the same bytes the platform build decodes. Mirrored here as a
# compile-time split so the encoding is obvious and the tables stay in
# lockstep by construction.
when defined(windows):
  const
    Left* = @[224, 75]
    Right* = @[224, 77]
    Up* = @[224, 72]
    Down* = @[224, 80]
    Home* = @[224, 71]
    End* = @[224, 79]
    Delete* = @[224, 83]
else:
  const
    Left* = KeyLeft
    Right* = KeyRight
    Up* = KeyUp
    Down* = KeyDown
    Home* = KeyHome
    End* = KeyEnd
    Delete* = KeyDelete

proc `+`*(modifier: KeyMod, key: openArray[int]): KeyChord =
  KeyChord(mods: {modifier}, key: @key)

proc `+`*(a, b: KeyMod): set[KeyMod] =
  {a, b}

proc `+`*(mods: set[KeyMod], key: openArray[int]): KeyChord =
  KeyChord(mods: mods, key: @key)

proc encode*(encoding: KeyEncoding, chord: KeyChord): seq[int] =
  if chord.mods == {Shift} and chord.key == KeyEnter:
    case encoding
    of XMod: return XModShiftEnter
    of Kitty: return KittyShiftEnter
  raise newException(ValueError, "unsupported key chord")

template push*(d: Driver, encoding: KeyEncoding, body: untyped) =
  d.push encode(encoding, body)

var testPendingInput: Input

proc testPollStdinNow(): bool =
  testPendingInput.hasPendingInput()

proc run*(d: Driver, ed: var LineEditor, prompt = "> ",
          hidechars = false): string =
  # Mirror the production readLine getCh's reply filter, with test
  # byte sources. On ESC: if the terminal input queue holds a plausible
  # reply prefix (`[` or `?`), scan the queue directly for a reply
  # (`CSI [?] nums R|c`) and drop it; anything else passes through to
  # the editor untouched. This mirrors production semantics (drop
  # unsolicited replies) without the replay machinery tests don't need.
  let getCh: GetChProc = proc(): int =
    if pushedBack.len > 0:
      return pushedBack.popFirst()
    if termPeeked >= 0:
      result = termPeeked
      termPeeked = -1
      return result
    let b = d.terminal.read()
    if b != 27: return b
    let inp = d.terminal.input
    if not inp.hasPendingInput(): return b
    let avail = inp.bytes.len - inp.pos
    if avail >= 3 and inp.bytes[inp.pos] == '['.ord and
       chr(inp.bytes[inp.pos + 1]) in {'0'..'9', '?'}:
      # Find the final byte within reply-charset reach.
      var j = 1
      var isReply = false
      while j < avail and j < 22:
        let c = inp.bytes[inp.pos + j]
        if c == 'R'.ord or c == 'c'.ord:
          isReply = j >= 2
          break
        if not (chr(c) in {'0'..'9', ';', '?'}):
          break
        inc j
      if isReply:
        var bytes = "\x1b"
        for k in 0 .. j:
          bytes.add chr(inp.bytes[inp.pos + k])
        # Validate body shape (digits/;/optional leading ?) like the
        # production filter, so modified arrows (CSI 1;5R) pass through.
        let body = bytes[2 ..< ^1]
        var shaped = true
        for i, ch in body:
          let okDigit = ch in {'0'..'9'}
          let okSep = ch == ';' and i > 0
          let okPriv = ch == '?' and i == 0
          if not (okDigit or okSep or okPriv):
            shaped = false
            break
        if shaped:
          for _ in 0 .. j: discard inp.read()
          noteReplyCaptured(bytes)
          # Reply dropped; return the next real byte.
          if pushedBack.len > 0:
            return pushedBack.popFirst()
          return d.terminal.read()
    return b
  let write: WriteProc = proc(s: string) =
    d.terminal.write s
  let widthProc: WidthProc = proc(): int = d.width
  let hasPendingInput: HasPendingInputProc = proc(): bool =
    if d.pendingInput != nil:
      d.pendingInput()
    else:
      d.terminal.hasPendingInput()
  # In test mode, pollStdinNowHook uses terminal pending-input check
  # (no real stdin poll). Bytes pushed before run() are "immediately
  # available" when the per-byte loop's newline handler checks.
  testPendingInput = d.terminal.input
  let prevPollHook = pollStdinNowHook
  pollStdinNowHook = testPollStdinNow
  defer: pollStdinNowHook = prevPollHook
  ed.readLineWith(prompt, getCh, write, hidechars = hidechars,
                  getWidth = widthProc, hasPendingInput = hasPendingInput)

proc seedHistory*(ed: var LineEditor, entries: seq[string]) =
  for e in entries:
    ed.history.entries.addLast e
  ed.history.cursor = -1
