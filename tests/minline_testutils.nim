import std/deques
import threecode/minline
import ttty/grid

type
  Driver* = ref object
    keystrokes*: seq[int]
    pos*: int
    output*: string
    grid*: Grid
    width*: int

proc newDriver*(width = 80): Driver =
  Driver(keystrokes: @[], pos: 0, output: "", grid: newGrid(), width: width)

proc push*(d: Driver, ks: openArray[int]) =
  for k in ks:
    d.keystrokes.add k

proc pushString*(d: Driver, s: string) =
  for ch in s:
    d.keystrokes.add ch.int

const
  KCtrlC*  = @[3]
  KEnter*  = @[13]
  KLeft*   = @[27, 91, 68]
  KRight*  = @[27, 91, 67]
  KUp*     = @[27, 91, 65]
  KDown*   = @[27, 91, 66]
  KHome*   = @[27, 91, 72]
  KEnd*    = @[27, 91, 70]
  KDel*    = @[27, 91, 51, 126]
  KBack*   = @[127]
  KCtrlU*  = @[21]
  KCtrlW*  = @[23]
  KCtrlA*  = @[1]
  KCtrlE*  = @[5]
  KCtrlLeft*  = @[27, 91, 49, 59, 53, 68]
  KCtrlRight* = @[27, 91, 49, 59, 53, 67]
  # Alt+Enter: ESC followed by CR.
  KAltEnter* = @[27, 13]
  # Kitty Shift+Enter: ESC [ 1 3 ; 2 u.
  KKittyShiftEnter* = @[27, 91, 49, 51, 59, 50, 117]
  # modifyOtherKeys Shift+Enter: ESC [ 27 ; 2 ; 13 ~.
  KModkSE* = @[27, 91, 50, 55, 59, 50, 59, 49, 51, 126]

proc run*(d: Driver, ed: var LineEditor, prompt = "> ",
          hidechars = false): string =
  let getCh: GetChProc = proc(): int =
    if d.pos >= d.keystrokes.len: return -1
    let k = d.keystrokes[d.pos]
    inc d.pos
    return k
  let write: WriteProc = proc(s: string) =
    d.output.add s
    d.grid.feed s
  let widthProc: WidthProc = proc(): int = d.width
  ed.readLineWith(prompt, getCh, write, hidechars = hidechars,
                  getWidth = widthProc)

proc seedHistory*(ed: var LineEditor, entries: seq[string]) =
  for e in entries:
    ed.history.entries.addLast e
  ed.history.cursor = -1
