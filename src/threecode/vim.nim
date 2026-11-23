## Vi editing mode for the line editor, ported from readline's
## ``vi_mode.c`` — the module behind bash's ``set -o vi``. Conceptual
## port, not literal: the C implementation drives a single-line byte
## buffer through readline keymaps; here vi commands operate on the
## multi-line rune editor in ``minline`` through its public editing
## surface (insert/delete/kill/undo procs), reusing its rendering,
## kill ring and undo stack instead of vi-private state.
##
## Supported in command (normal) mode:
##   motions  h l 0 ^ $ w b e W B E f{c} F{c} t{c} T{c} ; , % Space
##   editing  x X r{c} ~ D C s S cc dd yy d{motion} c{motion}
##            y{motion} p P u
##   insert   i a I A R (replace mode)
##   search   / ? (history isearch)
##   count    1-9 prefixes apply to motions and most edits
##
## Mode switching mirrors bash: lines start in insert mode; ESC (or the
## user-rebound ``vi-mode`` key) enters command mode. The `[shortcuts]`
## key is ``vi-mode``. When the vi-mode key is ESC, ESC is removed from
## readline's cancel/clear bindings so it is free to switch modes.
##
## The ``editing`` setting selects ``readline`` (default), ``vim`` or
## ``both``. ``both`` keeps every readline binding and layers vi command
## mode on top; ctrl keys keep their readline meaning in both modes,
## exactly as in bash's vi mode.

import strutils, tables, unicode, deques

import threecode/minline

type
  EditingMode* = enum
    emReadline ## classic readline (emacs) bindings only — the default
    emVim      ## vi bindings; ctrl keys keep their readline meaning
    emBoth     ## readline bindings plus ESC-entered vi command mode

var editingMode* = emReadline

var viEnabled = false
  ## Plain (shared) globals, not threadvars: vi state is assigned once at
  ## startup and each readLineWith session starts in insert mode, so a
  ## wizard read and the input thread can interleave without corrupting
  ## each other's mode.
var viNormal = false
var viCount = 1
var viPendingOp = ' '     ## 'd' / 'c' / 'y' waiting for a motion
var viPendingFind = ' '   ## f/F/t/T waiting for the target char
var viPendingR = false    ## r waiting for the replacement char
var viLastFind = ' '      ## last f/F/t/T/,/; motion, for ; and ,
var viLastFindChar = Rune(0)
var viYankWasLine = false
var viModeChar = Rune(0)  ## printable char bound to enter command mode;
                          ## Rune(0) means ESC (or vi editing is off)

# ---------- buffer helpers (rune-safe, logical-line scoped) ----------

proc prevRuneStart(text: string; pos: int): int =
  var p = pos - 1
  while p > 0 and (text[p].ord and 0xC0) == 0x80: dec p
  p

proc nextRuneEnd(text: string; pos: int): int =
  var p = pos + 1
  while p < text.len and (text[p].ord and 0xC0) == 0x80: inc p
  p

proc runeAt(text: string; pos: int): Rune =
  var p = pos
  var r: Rune
  fastRuneAt(text, p, r, true)
  r

proc lineBounds(ed: LineEditor): tuple[start, stop: int] =
  ## Byte range of the logical line holding the cursor: `stop` is
  ## exclusive and points at the terminating '\n' or buffer end.
  result.start = ed.line.position
  while result.start > 0 and ed.line.text[result.start - 1] != '\n':
    dec result.start
  result.stop = ed.line.position
  while result.stop < ed.line.text.len and ed.line.text[result.stop] != '\n':
    inc result.stop

proc classOf(r: Rune): int =
  ## Vi word classes: 0 whitespace (blank, tab, '\n'), 1 word (alnum/_),
  ## 2 everything else.
  if r == Rune(10) or r == Rune(32) or r == Rune(9): 0
  elif unicode.isAlpha(r) or r.int >= 48 and r.int <= 57 or r == Rune(0x5F): 1
  else: 2

proc charAt(ed: LineEditor; pos: int): Rune =
  runeAt(ed.line.text, pos)

proc viBell(ed: var LineEditor) =
  ed.write "\a"

proc viMove(ed: var LineEditor; target: int) =
  ## Set the cursor to a rune boundary with the cheap movement repaint.
  if target == ed.line.position: return
  ed.selAnchor = -1
  let oldPos = ed.line.position
  let hadSel = ed.hasSelection()
  ed.line.position = target
  if not moveOnlyRedraw(ed, oldPos, hadSel):
    fullRedraw(ed)

proc viRedraw(ed: var LineEditor) =
  ed.selAnchor = -1
  fullRedraw(ed)

# ---------- one-step motions (return -1 when blocked) ----------

proc motionLeft(ed: var LineEditor): int =
  let (start, _) = ed.lineBounds()
  if ed.line.position <= start: return -1
  prevRuneStart(ed.line.text, ed.line.position)

proc motionRight(ed: var LineEditor): int =
  let (_, stop) = ed.lineBounds()
  let nxt = nextRuneEnd(ed.line.text, ed.line.position)
  if nxt >= stop: return -1
  nxt

proc motionLineStart(ed: var LineEditor): int =
  ed.lineBounds().start

proc motionFirstNonBlank(ed: var LineEditor): int =
  let (start, stop) = ed.lineBounds()
  result = start
  while result < stop and classOf(ed.charAt(result)) == 0:
    result = nextRuneEnd(ed.line.text, result)

proc motionLineEnd(ed: var LineEditor): int =
  ed.lineBounds().stop

proc motionWordFwd(ed: var LineEditor; big: bool): int =
  ## `w` / `W`: start of the next word. Newlines separate words. `W`
  ## treats any run of non-blanks (words and punctuation alike) as one
  ## big word.
  let (_, stop) = ed.lineBounds()
  var p = ed.line.position
  if p >= stop: return -1
  let cur = classOf(ed.charAt(p))
  if cur > 0:
    while p < stop:
      let c = classOf(ed.charAt(p))
      if (big and c == 0) or (not big and c != cur): break
      p = nextRuneEnd(ed.line.text, p)
  # skip whitespace (including the newline itself)
  while p < stop and classOf(ed.charAt(p)) == 0:
    p = nextRuneEnd(ed.line.text, p)
  if p >= stop: return -1
  p

proc motionWordBack(ed: var LineEditor; big: bool): int =
  ## `b` / `W` backward: first char of the previous word.
  let (start, _) = ed.lineBounds()
  var p = prevRuneStart(ed.line.text, ed.line.position)
  if p < start: return -1
  while p >= start and classOf(ed.charAt(p)) == 0:
    p = prevRuneStart(ed.line.text, p)
  if p < start: return -1
  let cur = classOf(ed.charAt(p))
  while p > start:
    let prev = prevRuneStart(ed.line.text, p)
    let pc = classOf(ed.charAt(prev))
    if pc == 0 or (not big and pc != cur): break
    p = prev
  p

proc motionWordEnd(ed: var LineEditor; big: bool): int =
  ## `e` / `E`: last char of the current or next word.
  let (_, stop) = ed.lineBounds()
  var q = ed.line.position
  if q < stop: q = nextRuneEnd(ed.line.text, q)
  while q < stop and classOf(ed.charAt(q)) == 0:
    q = nextRuneEnd(ed.line.text, q)
  if q >= stop: return -1
  var endP = q
  while true:
    let nxt2 = nextRuneEnd(ed.line.text, endP)
    if nxt2 >= stop: break
    let nc = classOf(ed.charAt(nxt2))
    if nc == 0 or (not big and nc != classOf(ed.charAt(q))): break
    endP = nxt2
  endP

proc findFwd(ed: var LineEditor; target: Rune; till: bool): int =
  let (_, stop) = ed.lineBounds()
  var p = nextRuneEnd(ed.line.text, ed.line.position)
  while p < stop:
    if ed.charAt(p) == target:
      return if till: prevRuneStart(ed.line.text, p) else: p
    p = nextRuneEnd(ed.line.text, p)
  -1

proc findBack(ed: var LineEditor; target: Rune; till: bool): int =
  let (start, _) = ed.lineBounds()
  var p = prevRuneStart(ed.line.text, ed.line.position)
  while p >= start:
    if ed.charAt(p) == target:
      return if till: nextRuneEnd(ed.line.text, p) else: p
    p = prevRuneStart(ed.line.text, p)
  -1

proc findRepeat(ed: var LineEditor; backward: bool): int =
  ## ; repeats the last f/F/t/T in its own direction, , in the opposite.
  case viLastFind
  of 'f': return if backward: findBack(ed, viLastFindChar, false) else: findFwd(ed, viLastFindChar, false)
  of 'F': return if backward: findFwd(ed, viLastFindChar, false) else: findBack(ed, viLastFindChar, false)
  of 't': return if backward: findBack(ed, viLastFindChar, true) else: findFwd(ed, viLastFindChar, true)
  of 'T': return if backward: findFwd(ed, viLastFindChar, true) else: findBack(ed, viLastFindChar, true)
  else: -1

proc motionPercent(ed: var LineEditor): int =
  ## % : jump to the bracket matching the one under the cursor.
  const opens = {'(', '[', '{'}
  const closes = {')', ']', '}'}
  let (start, stop) = ed.lineBounds()
  var p = ed.line.position
  if p >= stop: return -1
  let c = ed.line.text[p]
  var depth: int
  var step: int
  if c in opens:
    depth = 1
    step = 1
  elif c in closes:
    depth = -1
    step = -1
  else:
    return -1
  p = if step > 0: nextRuneEnd(ed.line.text, p) else: prevRuneStart(ed.line.text, p)
  while p >= start and p < stop:
    let b = ed.line.text[p]
    if b == c:
      inc depth, step
    elif (step > 0 and b in closes) or (step < 0 and b in opens):
      dec depth, step
    if depth == 0: return p
    p = if step > 0: nextRuneEnd(ed.line.text, p) else: prevRuneStart(ed.line.text, p)
  -1

proc runMotion(ed: var LineEditor; kind: char; arg: Rune): int =
  case kind
  of 'h': motionLeft(ed)
  of 'l': motionRight(ed)
  of '0': motionLineStart(ed)
  of '^': motionFirstNonBlank(ed)
  of '$': motionLineEnd(ed)
  of 'w': motionWordFwd(ed, false)
  of 'W': motionWordFwd(ed, true)
  of 'b': motionWordBack(ed, false)
  of 'B': motionWordBack(ed, true)
  of 'e': motionWordEnd(ed, false)
  of 'E': motionWordEnd(ed, true)
  of 'f': findFwd(ed, arg, false)
  of 'F': findBack(ed, arg, false)
  of 't': findFwd(ed, arg, true)
  of 'T': findBack(ed, arg, true)
  of ';': findRepeat(ed, false)
  of ',': findRepeat(ed, true)
  of '%': motionPercent(ed)
  else: -1

# ---------- text mutation ----------

proc viDeleteRange(ed: var LineEditor; a, b: int) =
  ## Delete the byte range [a, b) into the kill ring, vi-style: the
  ## cursor lands on the char after the deletion, or one further back
  ## at end of line. Whole-logical-line deletions leave the cursor at
  ## the line start.
  if a >= b: return
  let (start, stop) = ed.lineBounds()
  pushUndo(ed, typing = false)
  let wasAt = ed.line.position
  let text = ed.line.text
  killSave(ed, text[a ..< b], false, wasAt, a)
  ed.line.text = text[0 ..< a] & text[b .. ^1]
  var pos = a
  if a == start and b == stop and a > 0:
    # deleted the entire logical line: step back over its newline
    pos = prevRuneStart(ed.line.text, a)
  elif wasAt >= b and pos > 0 and
       (pos >= ed.line.text.len or ed.line.text[pos] == '\n'):
    # the cursor sat at end of line: land on the new last char
    pos = prevRuneStart(ed.line.text, pos)
  ed.line.position = pos
  callHook(ed.onMutate, ed)
  fullRedraw(ed)

proc viYankRange(ed: var LineEditor; a, b: int) =
  if a >= b: return
  killSave(ed, ed.line.text[a ..< b], false, -1, -1)
  viMove(ed, a)

proc rangeForMotion(ed: var LineEditor; kind: char, arg: Rune): tuple[a, b: int] =
  ## Byte range an operator covers when applied to motion `kind`.
  ## Line motions (0 ^ $ and cc/dd/yy) cover the whole logical line;
  ## 'e'/'E' extend one rune so the word's last char is included.
  let (start, stop) = ed.lineBounds()
  block:
    let target = runMotion(ed, kind, arg)
    if target < 0: return (-1, -1)
    var a = min(ed.line.position, target)
    var b = max(ed.line.position, target)
    if kind in {'e', 'E'} and b < stop and a < b:
      # e lands ON the word's last char; the operator must cover it
      b = nextRuneEnd(ed.line.text, b)
    return (a, b)

# ---------- insert-mode entry points ----------

proc enterInsert(ed: var LineEditor) =
  viNormal = false
  viCount = 1
  viPendingOp = ' '
  viPendingFind = ' '
  viPendingR = false
  ed.mode = mdInsert
  viRedraw(ed)

proc enterNormal(ed: var LineEditor) =
  ## ESC from insert mode: land the cursor on the last inserted char,
  ## the way readline's rl_vi_movement_mode backs point up.
  viNormal = true
  viCount = 1
  viPendingOp = ' '
  viPendingFind = ' '
  viPendingR = false
  ed.mode = mdInsert
  ed.selAnchor = -1
  if ed.line.position > 0:
    let (_, stop) = ed.lineBounds()
    if ed.line.position >= stop or ed.line.position == ed.line.text.len or
        ed.line.text[ed.line.position] == '\n':
      ed.line.position = prevRuneStart(ed.line.text, ed.line.position)
  fullRedraw(ed)

# ---------- command-mode key dispatch ----------

proc viInsertMode(ed: var LineEditor; where: char) =
  ## i a I A: enter insert mode, moving the cursor first as needed.
  case where
  of 'a':
    let (_, stop) = ed.lineBounds()
    if ed.line.position < stop:
      ed.line.position = nextRuneEnd(ed.line.text, ed.line.position)
  of 'I': ed.line.position = motionLineStart(ed)
  of 'A': ed.line.position = motionLineEnd(ed)
  else: discard
  enterInsert(ed)

proc viDeleteChar(ed: var LineEditor; back: bool) =
  ## x / X.
  let (start, stop) = ed.lineBounds()
  if back:
    let a = prevRuneStart(ed.line.text, ed.line.position)
    if a < start: return
    viDeleteRange(ed, a, ed.line.position)
  else:
    let b = nextRuneEnd(ed.line.text, ed.line.position)
    if b > stop: return
    viDeleteRange(ed, ed.line.position, b)

proc viReplaceChar(ed: var LineEditor; r: Rune; count: int) =
  ## r : overwrite `count` chars with `r`, cursor left on the last one.
  let (_, stop) = ed.lineBounds()
  var p = ed.line.position
  var text = ed.line.text
  pushUndo(ed, typing = false)
  var n = count
  while n > 0 and p < stop:
    let nxt = nextRuneEnd(text, p)
    text = text[0 ..< p] & $r & text[nxt .. ^1]
    dec n
    p += runeLen($r)
  ed.line.text = text
  ed.line.position = p
  if p > ed.line.position:
    ed.line.position = prevRuneStart(ed.line.text, p)
  callHook(ed.onMutate, ed)
  fullRedraw(ed)

proc viTilde(ed: var LineEditor; count: int) =
  ## ~ : toggle case under the cursor, advancing.
  let (_, stop) = ed.lineBounds()
  var p = ed.line.position
  var text = ed.line.text
  pushUndo(ed, typing = false)
  var n = count
  while n > 0 and p < stop:
    let r = runeAt(text, p)
    let nxt = nextRuneEnd(text, p)
    let swapped = if unicode.isUpper(r): toLower(r)
                  elif unicode.isLower(r): toUpper(r)
                  else: r
    text = text[0 ..< p] & $swapped & text[nxt .. ^1]
    dec n
    p += runeLen($swapped)
  ed.line.text = text
  ed.line.position = if p >= stop: stop else: p
  callHook(ed.onMutate, ed)
  fullRedraw(ed)

proc viPaste(ed: var LineEditor; after: bool) =
  ## p / P: insert the kill-ring head after / before the cursor. A line
  ## yank (dd / yy / Y) pastes as a new logical line below / above,
  ## vi-style.
  if ed.killRing.len == 0: return
  if viYankWasLine:
    viYankWasLine = false
    let text = ed.killRing[0]
    if ed.line.text.len == 0:
      pushUndo(ed, typing = false)
      ed.line.text = text
      ed.line.position = 0
    else:
      var p = ed.line.position
      while p < ed.line.text.len and ed.line.text[p] != '\n': inc p
      if not after and p > 0: dec p  # P pastes above the current line
      pushUndo(ed, typing = false)
      let ins = "\n" & text
      ed.line.text = ed.line.text[0 ..< p] & ins & ed.line.text[p .. ^1]
      ed.line.position = p + 1
    callHook(ed.onMutate, ed)
    viRedraw(ed)
    return
  if after:
    let (_, stop) = ed.lineBounds()
    if ed.line.position < stop:
      ed.line.position = nextRuneEnd(ed.line.text, ed.line.position)
  ed.yank()
  # vi leaves the cursor on the last pasted char
  if ed.line.position > 0:
    ed.line.position = prevRuneStart(ed.line.text, ed.line.position)
  viRedraw(ed)

proc viChangeLine(ed: var LineEditor) =
  ## cc / S: empty the logical line and insert.
  let (start, stop) = ed.lineBounds()
  if stop > start:
    pushUndo(ed, typing = false)
    killSave(ed, ed.line.text[start ..< stop], false, ed.line.position, start)
    ed.line.text = ed.line.text[0 ..< start] & ed.line.text[stop .. ^1]
    callHook(ed.onMutate, ed)
  ed.line.position = start
  enterInsert(ed)

proc viJoin(ed: var LineEditor) =
  ## J: join the next logical line onto this one with a space.
  var p = ed.line.position
  while p < ed.line.text.len and ed.line.text[p] != '\n':
    inc p
  if p >= ed.line.text.len: return
  pushUndo(ed, typing = false)
  var glue = " "
  if p > 0 and ed.line.text[p - 1] == ' ': glue = ""
  ed.line.text = ed.line.text[0 ..< p] & glue & ed.line.text[p + 1 .. ^1]
  ed.line.position = p
  if glue == " " and ed.line.position > 0:
    dec ed.line.position
  callHook(ed.onMutate, ed)
  fullRedraw(ed)

proc viSearch(ed: var LineEditor; forward: bool) =
  viNormal = false
  viRedraw(ed)
  ed.isearchStart(forward)

proc viExecuteCommand(ed: var LineEditor; kind: char; arg: Rune): bool =
  ## One command-mode key with its count resolved. Returns false when
  ## the key is not a vi command (caller bells).
  let count = max(1, viCount)
  case kind
  # --- motions ---
  of 'h', 'l', '0', '^', '$', 'w', 'W', 'b', 'B', 'e', 'E', '%':
    var target = ed.line.position
    for _ in 1 .. count:
      let t = runMotion(ed, kind, arg)
      if t < 0: break
      target = t
      # motions read the cursor; step it so counts compound
      ed.line.position = target
    viMove(ed, target)
    return true
  of ';', ',':
    let t = findRepeat(ed, kind == ',')
    if t < 0: viBell(ed) else: viMove(ed, t)
    return true
  of 'f', 'F', 't', 'T':
    viPendingFind = kind
    return true
  of ' ':
    let t = motionRight(ed)
    if t < 0: viBell(ed) else: viMove(ed, t)
    return true
  # --- operators applied to a motion (counted) ---
  of 'd', 'c', 'y':
    # `kind` is the operator; the motion arrived as `arg` through the
    # pending-operator path
    if arg == Rune(0): return true
    for _ in 1 .. count:
      let (a, b) = rangeForMotion(ed, char(arg), Rune(0))
      if a < 0:
        viBell(ed)
        break
      case kind
      of 'd': viDeleteRange(ed, a, b)
      of 'c':
        viDeleteRange(ed, a, b)
        enterInsert(ed)
        break
      else: viYankRange(ed, a, b)
    return true
  # --- single-key edits ---
  of 'x':
    for _ in 1 .. count: viDeleteChar(ed, false)
    return true
  of 'X':
    for _ in 1 .. count: viDeleteChar(ed, true)
    return true
  of 'D':
    let (_, stop) = ed.lineBounds()
    viDeleteRange(ed, ed.line.position, stop)
    return true
  of 'C':
    let (_, stop) = ed.lineBounds()
    viDeleteRange(ed, ed.line.position, stop)
    enterInsert(ed)
    return true
  of 's':
    for _ in 1 .. count: viDeleteChar(ed, false)
    enterInsert(ed)
    return true
  of 'S':
    viChangeLine(ed)
    return true
  of 'r':
    viPendingR = true
    return true
  of '~':
    viTilde(ed, count)
    return true
  of 'Y':
    let (a, b) = ed.lineBounds()
    viYankWasLine = true
    viYankRange(ed, a, b)
    return true
  of 'p':
    for _ in 1 .. count: viPaste(ed, true)
    return true
  of 'P':
    for _ in 1 .. count: viPaste(ed, false)
    return true
  of 'u':
    ed.undo()
    return true
  of 'J':
    for _ in 1 .. count: viJoin(ed)
    return true
  of 'i':
    viInsertMode(ed, 'i')
    return true
  of 'a':
    viInsertMode(ed, 'a')
    return true
  of 'I':
    viInsertMode(ed, 'I')
    return true
  of 'A':
    viInsertMode(ed, 'A')
    return true
  of 'R':
    viNormal = false
    viCount = 1
    viPendingOp = ' '
    viPendingFind = ' '
    viPendingR = false
    ed.mode = mdReplace
    viRedraw(ed)
    return true
  of '/':
    viSearch(ed, false)
    return true
  of '?':
    viSearch(ed, true)
    return true
  else:
    return false

proc viKey(ed: var LineEditor; c1: int): bool =
  ## The self-insert hook. Consumes every printable byte while vi
  ## command mode is active; in insert mode consumes only the printable
  ## vi-mode key (when it is not ESC).
  if not viEnabled: return false
  if c1 < 0:
    # session sentinel from resetForRead: every line starts in insert
    # mode, the way readline's vi-mode does
    viNormal = false
    viCount = 1
    viPendingOp = ' '
    viPendingFind = ' '
    viPendingR = false
    viYankWasLine = false
    ed.mode = mdInsert
    return false
  let r = Rune(c1)
  if not viNormal:
    # insert mode: only the alternate vi-mode char is ours
    if viModeChar != Rune(0) and r == viModeChar:
      enterNormal(ed)
      return true
    return false
  # command mode
  if viPendingR:
    viPendingR = false
    viReplaceChar(ed, r, max(1, viCount))
    return true
  if viPendingFind != ' ':
    let kind = viPendingFind
    viPendingFind = ' '
    viLastFind = kind
    viLastFindChar = r
    let t = runMotion(ed, kind, r)
    if t < 0: viBell(ed) else: viMove(ed, t)
    return true
  if viPendingOp != ' ':
    let op = viPendingOp
    viPendingOp = ' '
    if r == Rune(op):
      viYankWasLine = op in {'y', 'd'}
      # doubled operator: whole logical line
      case op
      of 'd': viDeleteRange(ed, ed.lineBounds().start, ed.lineBounds().stop)
      of 'c': viChangeLine(ed)
      else:
        let (a, b) = ed.lineBounds()
        viYankRange(ed, a, b)
      return true
    return viExecuteCommand(ed, op, r)  # operator + motion
  if int(r) >= 49 and int(r) <= 57:
    viCount = if viCount == 1: int(r) - 48
              else: viCount * 10 + (int(r) - 48)
    return true
  if int(r) == 48 and viCount == 1:
    viMove(ed, motionLineStart(ed))
    return true
  if char(r) in {'d', 'c', 'y'}:
    viPendingOp = char(r)
    return true
  if viExecuteCommand(ed, char(r), Rune(0)):
    if viNormal and viPendingOp == ' ' and viPendingFind == ' ' and not viPendingR:
      viCount = 1
    return true
  viCount = 1
  viBell(ed)
  return true

proc viNormalModeCmd(ed: var LineEditor) =
  ## The bound `vi-mode` key (default ESC): enter command mode.
  if not viEnabled: return
  if not viNormal:
    enterNormal(ed)

proc installCommandProcs() =
  # initKeyTables populates CommandProcs only when empty; make sure the
  # shared table exists before adding the vi-mode command so a call
  # before any editor thread started never suppresses the full populate.
  minline.initKeyTables()
  minline.CommandProcs["vi-mode"] = viNormalModeCmd

proc configureEditing*(userShortcuts: Table[string, string]) =
  ## Wire up the configured editing mode. Call once at startup with the
  ## parsed `[shortcuts]` table, before input threads start: it rewrites
  ## ``minline.configuredShortcuts`` to the effective binding set and
  ## installs the printable-char interception hook every editor thread
  ## consults.
  installCommandProcs()
  viEnabled = editingMode != emReadline
  if not viEnabled:
    minline.selfInsertHook = nil
    minline.configuredShortcuts = userShortcuts
    return
  # The vi-mode key: [shortcuts] vi-mode, default ESC.
  var viKeyEsc = true
  viModeChar = Rune(0)
  let spec = userShortcuts.getOrDefault("vi-mode", "ESC").strip
  if spec.len > 0:
    for token in strutils.splitWhitespace(spec.toLowerAscii):
      let t = token.replace("+", "")
      if t == "esc" or t == "escape":
        viKeyEsc = true
        viModeChar = Rune(0)
      elif t.len == 1 and char(t[0]).isAlphaAscii or
           (t.len == 1 and t[0] in {'!', ',', ';', ':', ' '}):
        viKeyEsc = false
        viModeChar = Rune(t[0])
      break   # single key only; later tokens are ignored
  # Start from the full effective binding set: applyShortcuts merges
  # configuredShortcuts back over DefaultShortcuts, so stripping ESC
  # from the user layer alone would leave the default ESC cancel/clear
  # alive and the key would still cancel instead of switching modes.
  var effective = minline.DefaultShortcuts
  for cmd, s in userShortcuts:
    effective[cmd] = s
  if spec.len > 0:
    # Honour the user's own key spec (already validated through
    # parseShortcutSpec at config load).
    effective["vi-mode"] = spec
  elif viKeyEsc:
    effective["vi-mode"] = "ESC"
  if viKeyEsc:
    # ESC switches modes, so readline must not also claim it: strip the
    # ESC token from cancel/clear (readline's ESC-to-clear/cancel). With
    # any other vi-mode key ESC keeps its readline meaning.
    for cmd in ["cancel", "clear"]:
      if effective.hasKey(cmd):
        var kept: seq[string] = @[]
        for tok in strutils.splitWhitespace(effective[cmd]):
          let low = tok.toLowerAscii.replace("+", "")
          if low != "esc" and low != "escape": kept.add tok
        effective[cmd] = kept.join(" ")
  minline.configuredShortcuts = effective
  minline.selfInsertHook = viKey
