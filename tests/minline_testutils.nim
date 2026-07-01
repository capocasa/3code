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
  CtrlC* = KeyCtrlC
  CtrlD* = @[4]
  Esc* = KeyEsc
  Enter* = KeyEnter
  Left* = KeyLeft
  Right* = KeyRight
  Up* = KeyUp
  Down* = KeyDown
  Home* = KeyHome
  End* = KeyEnd
  Delete* = KeyDelete
  Backspace* = KeyBackspace
  CtrlU* = @[21]
  CtrlW* = @[23]
  CtrlA* = @[1]
  CtrlE* = @[5]
  CtrlLeft* = @[27, 91, 49, 59, 53, 68]
  CtrlRight* = @[27, 91, 49, 59, 53, 67]
  AltEnter* = KeyAltEnter
  KittyShiftEnter = KeyKittyShiftEnter
  XModShiftEnter = KeyModifyOtherShiftEnter

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
  let getCh: GetChProc = proc(): int =
    if termPeeked >= 0:
      result = termPeeked
      termPeeked = -1
      return result
    d.terminal.read()
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
