## This module provides a simple, limited but fully-functional line editing library written in pure Nim.
##
## To use this library, you must first initialize a **LineEditor** object using the **initEditor** method,
## and then use the **readLine** method to capture standard input instead of **stdout.readLine**:
##
## .. code-block:: nim
##    var ed = initEditor(historyFile = "history.txt")
##    while true:
##      let str = ed.readLine("-> ")
##      echo "You typed: ", str
##
## Optionally, you can also configure custom key bindings for keys and key sequences:
##
## .. code-block:: nim
##    KEYMAP["ctrl+k"] = proc(ed: var LineEditor) =
##      ed.clearLine()
##
## Additionally, you can also configure a **completionCallback** proc to trigger auto-completion by pressing TAB:
##
## .. code-block:: nim
##    ed.completionCallback = proc(ed: LineEditor): seq[string] =
##      return @["copy", "list", "delete", "move", "remove"]
##
## **Note** When compared to the readline or linenoise libraries, this module has the following limitations:
##
## * It is only possible to edit one line of text at a time. When using the **readLine** method, it will not be possible to physically go to the next line (this simplifies things a bit...).
## * No UTF8 support, only ASCII characters are supported.
## * No support for colorized output.
## * Only limited support for Emacs keybindings, no support for Vi mode and Vi keybindings.

import
  critbits,
  terminal,
  deques,
  sequtils,
  strutils,
  std/exitprocs,
  os

when defined(posix):
  import posix

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
  Key* = int ## The ASCII code of a keyboard key.
  KeySeq* = seq[Key] ## A sequence of one or more Keys.
  KeyCallback* = proc(ed: var LineEditor) {.closure.} ## A proc that can be bound to a key or a key sequence to access line editing functionalities.
  LineError* = ref Exception ## A generic minline error.
  LineEditorError* = ref Exception ## An error occured in the LineEditor.
  LineEditorMode* = enum ## The *mode* a LineEditor operates in (insert or replace).
    mdInsert
    mdReplace 
  Line* = object ## An object representing a line of text.
    text: string 
    position: int 
  LineHistory* = object ## An object representing the history of all commands typed in a LineEditor.
    file: string 
    tainted: bool 
    position: int 
    queue: Deque[string] 
    max: int 
  LineEditor* = object ## An object representing a line editor, used to process text typed in the terminal.
    completionCallback*: proc(ed: LineEditor): seq[string] {.closure.}
    history: LineHistory
    line: Line
    mode: LineEditorMode
    hint: string
    prompt: string
  InputCancelled* = object of CatchableError ## Raised by the default ctrl+c handler to abort the current input line without quitting.

# Internal Methods

proc empty(line: Line): bool =
  return line.text.len <= 0

proc full(line: Line): bool =
  return line.position >= line.text.len

proc first(line: Line): int =
  if line.empty:
    raise LineError(msg: "Line is empty!")
  return 0

proc last(line: Line): int =
  if line.empty:
    raise LineError(msg: "Line is empty!")
  return line.text.len-1

proc fromStart(line: Line): string =
  if line.empty:
    return ""
  return line.text[line.first..line.position-1]

proc toEnd(line: Line): string =
  if line.empty:
    return ""
  return line.text[line.position..line.last]

proc back*(ed: var LineEditor, n=1) =
  ## Move the cursor back by **n** characters on the current line (unless the beginning of the line is reached).
  if ed.line.position <= 0:
    return
  stdout.cursorBackward(n)
  ed.line.position = ed.line.position - n

proc forward*(ed: var LineEditor, n=1) =
  ## Move the cursor forward by **n** characters on the current line (unless the beginning of the line is reached).
  if ed.line.full:
    return
  stdout.cursorForward(n)
  ed.line.position += n

proc wordLeft*(ed: var LineEditor) =
  ## Move the cursor to the start of the current word (or the previous word
  ## if already at a word boundary). Whitespace is the word separator.
  var pos = ed.line.position
  while pos > 0 and ed.line.text[pos-1] == ' ':
    dec pos
  while pos > 0 and ed.line.text[pos-1] != ' ':
    dec pos
  let delta = ed.line.position - pos
  if delta > 0:
    stdout.cursorBackward(delta)
    ed.line.position = pos

proc wordRight*(ed: var LineEditor) =
  ## Move the cursor forward to the start of the next word.
  var pos = ed.line.position
  let n = ed.line.text.len
  while pos < n and ed.line.text[pos] != ' ':
    inc pos
  while pos < n and ed.line.text[pos] == ' ':
    inc pos
  let delta = pos - ed.line.position
  if delta > 0:
    stdout.cursorForward(delta)
    ed.line.position = pos

proc `[]`( q: Deque[string], pos: int): string =
  var c = 0
  for e in q.items:
    if c == pos:
      result = e
      break
    c.inc

proc `[]=`( q: var Deque[string], pos: int, s: string) =
  var c = 0
  for e in q.mitems:
    if c == pos:
      e = s
      break
    c.inc

proc add(h: var LineHistory, s: string, force=false) =
  if s == "" and not force:
    return
  if h.queue.len >= h.max:
    discard h.queue.popFirst
  if h.tainted:
    h.queue[h.queue.len-1] = s
  else:
    h.queue.addLast s

proc previous(h: var LineHistory): string =
  if h.queue.len == 0 or h.position <= 0:
    return ""
  h.position.dec
  result = h.queue[h.position]

proc next(h: var LineHistory): string =
  if h.queue.len == 0 or h.position >= h.queue.len-1:
    return ""
  h.position.inc
  result = h.queue[h.position]

# Public API

proc deletePrevious*(ed: var LineEditor) =
  ## Move the cursor to the left by one character (unless at the beginning of the line) and delete the existing character, if any.
  if ed.line.position <= 0:
    return
  if not ed.line.empty:
    if ed.line.full:
      stdout.cursorBackward
      putchr(32)
      stdout.cursorBackward
      ed.line.position.dec
      ed.line.text = ed.line.text[0..ed.line.last-1]
    else:
      let rest = ed.line.toEnd & " "
      ed.back
      for i in rest:
        putchr i.ord.cint
      ed.line.text = ed.line.fromStart & ed.line.text[ed.line.position+1..ed.line.last]
      stdout.cursorBackward(rest.len)
  
proc deleteNext*(ed: var LineEditor) =
  ## Move the cursor to the right by one character (unless at the end of the line) and delete the existing character, if any.
  if not ed.line.empty:
    if not ed.line.full:
      let rest = ed.line.toEnd[1..^1] & " "
      for c in rest:
        putchr c.ord.cint
      stdout.cursorBackward(rest.len)
      ed.line.text = ed.line.fromStart & ed.line.toEnd[1..^1]

proc printChar*(ed: var LineEditor, c: int) =  
  ## Prints the character **c** to the current line. If in the middle of the line, the following characters are shifted right or replaced depending on the editor mode.
  if ed.line.full:
    putchr(c.cint)
    ed.line.text &= c.chr
    ed.line.position += 1
  else:
    if ed.mode == mdInsert:
      putchr(c.cint)
      let rest = ed.line.toEnd
      ed.line.text.insert($c.chr, ed.line.position)
      ed.line.position += 1
      for j in rest:
        putchr(j.ord.cint)
        ed.line.position += 1
      ed.back(rest.len)
    else: 
      putchr(c.cint)
      ed.line.text[ed.line.position] = c.chr
      ed.line.position += 1

proc changeLine*(ed: var LineEditor, s: string) =
  ## Replaces the contents of the current line with the string **s**.
  let text = ed.line.text
  let diff = text.len - s.len
  let position = ed.line.position
  if position > 0:
    stdout.cursorBackward(position)
  for c in s:
    putchr(c.ord.cint)
  ed.line.position = s.len
  ed.line.text = s
  if diff > 0:
    for i in 0.countup(diff-1):
      putchr(32)
    stdout.cursorBackward(diff)

proc addToLineAtPosition(ed: var LineEditor, s: string) =
  for c in s:
    ed.printChar(c.ord.cint)

proc clearLine*(ed: var LineEditor) =
  ## Clears the contents of the current line and reset the cursor position to the beginning of the line.
  stdout.cursorBackward(ed.line.position+1)
  for i in ed.line.text:
    putchr(32)
  putchr(32)
  putchr(32)
  stdout.cursorBackward(ed.line.text.len+1)
  ed.line.position = 0
  ed.line.text = ""

proc goToStart*(ed: var LineEditor) =
  ## Move the cursor to the beginning of the line.
  if ed.line.position <= 0:
    return
  try:
    stdout.cursorBackward(ed.line.position)
    ed.line.position = 0
  except:
    discard

proc goToEnd*(ed: var LineEditor) =
  ## Move the cursor to the end of the line.
  if ed.line.full:
    return
  let diff = ed.line.text.len - ed.line.position
  stdout.cursorForward(diff)
  ed.line.position = ed.line.text.len

proc historyInit*(size = 256, file: string = ""): LineHistory =
  ## Creates a new **LineHistory** object with the specified **size** and **file**.
  result.file = file
  result.queue = initDeque[string](size)
  result.position = 0
  result.tainted = false
  result.max = size
  if file == "":
    return
  if result.file.fileExists:
    let lines = result.file.readFile.split("\n")
    for line in lines:
      if line != "":
        result.add line
    result.position = lines.len
  else:
    result.file.writeFile("")

proc historyAdd*(ed: var LineEditor, force = false) =
  ## Adds the current editor line to the history. If **force** is set to **true**, the line will be added even if it's blank.
  ed.history.add ed.line.text, force
  if ed.history.file == "":
    return
  ed.history.file.writeFile(toSeq(ed.history.queue.items).join("\n"))

proc historyPrevious*(ed: var LineEditor) =
  ## Replaces the contents of the current line with the previous line stored in the history (if any).
  ## The current line will be added to the history and the hisory will be marked as *tainted*.
  let s = ed.history.previous
  if s == "":
    return
  let pos = ed.history.position
  var current: int
  if ed.history.tainted:
    current = ed.history.queue.len-2
  else:
    current = ed.history.queue.len-1
  if pos == current and ed.history.queue[current] != ed.line.text:
    ed.historyAdd(force = true)
    ed.history.tainted = true
  if s != "":
    ed.changeLine(s)
  
proc historyNext*(ed: var LineEditor) =
  ## Replaces the contents of the current line with the following line stored in the history (if any).
  let s = ed.history.next
  if s == "":
    return
  ed.changeLine(s)

proc historyFlush*(ed: var LineEditor) =
  ## If there is at least one entry in the history, it sets the position of the cursor to the last element and sets the **tainted** flag to **false**.
  if ed.history.queue.len > 0:
    ed.history.position = ed.history.queue.len
    ed.history.tainted = false

proc completeLine*(ed: var LineEditor): int =
  ## If a **completionCallback** proc has been specified for the current editor, attempts to auto-complete the current line by running **completionProc**
  ## to return a list of possible values. It is possible to cycle through the matches by pressing the same key that triggered this proc.
  ##
  ## The matches provided will be filtered based on the contents of the line when this proc was first triggered. If a match starts with the contents of the line, it
  ## will be displayed.
  ##
  ## The following is a real-world example of a **completionCallback** used to complete the last word on the line with valid file paths.
  ##
  ## .. code-block:: nim
  ##   import sequtils, strutils, ospath
  ##
  ##   ed.completionCallback = proc(ed: LineEditor): seq[string] =
  ##     var words = ed.lineText.split(" ")
  ##     var word: string
  ##     if words.len == 0:
  ##       word = ed.lineText
  ##     else:
  ##       word = words[words.len-1]
  ##     var f = word[1..^1]
  ##     if f == "":
  ##       f = getCurrentDir().replace("\\", "/")  
  ##       return toSeq(walkDir(f, true))
  ##         .mapIt("\"$1" % it.path.replace("\\", "/"))
  ##     elif f.dirExists:
  ##       f = f.replace("\\", "/")
  ##       if f[f.len-1] != '/':
  ##         f = f & "/"
  ##       return toSeq(walkDir(f, true))
  ##         .mapIt("\"$1$2" % [f, it.path.replace("\\", "/")])
  ##     else:
  ##       var dir: string
  ##       if f.contains("/") or dir.contains("\\"):
  ##         dir = f.parentDir
  ##         let file = f.extractFileName
  ##         return toSeq(walkDir(dir, true))
  ##           .filterIt(it.path.toLowerAscii.startsWith(file.toLowerAscii))
  ##           .mapIt("\"$1/$2" % [dir, it.path.replace("\\", "/")])
  ##       else:
  ##         dir = getCurrentDir()
  ##         return toSeq(walkDir(dir, true))
  ##           .filterIt(it.path.toLowerAscii.startsWith(f.toLowerAscii))
  ##           .mapIt("\"$1" % [it.path.replace("\\", "/")])
  ##
  if ed.completionCallback.isNil:
    return
  let compl = ed.completionCallback(ed)
  let position = ed.line.position
  let words = ed.line.fromStart.split(" ")
  var word: string
  if words.len > 0:
    word = words[words.len-1]
  else:
    word = ed.line.fromStart
  var matches = compl.filterIt(it.toLowerAscii.startsWith(word.toLowerAscii))
  if ed.line.fromStart.len > 0 and matches.len > 0:
    for i in 0..word.len-1:
      ed.deletePrevious
  var n = 0
  if matches.len > 0:
    ed.addToLineAtPosition(matches[0])
  else:
    return -1
  var ch = getchr()
  while ch == 9:
    n.inc
    if n < matches.len:
      let diff = ed.line.position - position
      for i in 0.countup(diff-1 + word.len):
        ed.deletePrevious
      ed.addToLineAtPosition(matches[n])
      ch = getchr()
    else:
      n = -1
  return ch

proc lineText*(ed: LineEditor): string =
  ## Returns the contents of the current line.
  return ed.line.text
  
proc initEditor*(mode = mdInsert, historySize = 256, historyFile: string = ""): LineEditor =
  ## Creates a **LineEditor** object.
  result.mode = mode
  result.history = historyInit(historySize, historyFile)

# Character sets
const
  CTRL*        = {0 .. 31}    ## Control characters.
  DIGIT*       = {48 .. 57}   ## Digits.
  LETTER*      = {65 .. 122}  ## Letters.
  UPPERLETTER* = {65 .. 90}   ## Uppercase letters.
  LOWERLETTER* = {97 .. 122}  ## Lowercase letters.
  PRINTABLE*   = {32 .. 126}  ## Printable characters.
when defined(windows):
  const
    ESCAPES* = {0, 22, 224}   ## Escape characters.
else:
  const
    ESCAPES* = {27}           ## Escape characters.

# Key Names
var KEYNAMES* {.threadvar.}: array[0..31, string] ## The following strings can be used in keymaps instead of the correspinding ASCII codes:
##
## .. code-block:: nim
##    KEYNAMES[1]    =    "ctrl+a"
##    KEYNAMES[2]    =    "ctrl+b"
##    KEYNAMES[3]    =    "ctrl+c"
##    KEYNAMES[4]    =    "ctrl+d"
##    KEYNAMES[5]    =    "ctrl+e"
##    KEYNAMES[6]    =    "ctrl+f"
##    KEYNAMES[7]    =    "ctrl+g"
##    KEYNAMES[8]    =    "ctrl+h"
##    KEYNAMES[9]    =    "ctrl+i"
##    KEYNAMES[9]    =    "tab"
##    KEYNAMES[10]   =    "ctrl+j"
##    KEYNAMES[11]   =    "ctrl+k"
##    KEYNAMES[12]   =    "ctrl+l"
##    KEYNAMES[13]   =    "ctrl+m"
##    KEYNAMES[14]   =    "ctrl+n"
##    KEYNAMES[15]   =    "ctrl+o"
##    KEYNAMES[16]   =    "ctrl+p"
##    KEYNAMES[17]   =    "ctrl+q"
##    KEYNAMES[18]   =    "ctrl+r"
##    KEYNAMES[19]   =    "ctrl+s"
##    KEYNAMES[20]   =    "ctrl+t"
##    KEYNAMES[21]   =    "ctrl+u"
##    KEYNAMES[22]   =    "ctrl+v"
##    KEYNAMES[23]   =    "ctrl+w"
##    KEYNAMES[24]   =    "ctrl+x"
##    KEYNAMES[25]   =    "ctrl+y"
##    KEYNAMES[26]   =    "ctrl+z"

KEYNAMES[1]    =    "ctrl+a"
KEYNAMES[2]    =    "ctrl+b"
KEYNAMES[3]    =    "ctrl+c"
KEYNAMES[4]    =    "ctrl+d"
KEYNAMES[5]    =    "ctrl+e"
KEYNAMES[6]    =    "ctrl+f"
KEYNAMES[7]    =    "ctrl+g"
KEYNAMES[8]    =    "ctrl+h"
KEYNAMES[9]    =    "ctrl+i"
KEYNAMES[9]    =    "tab"
KEYNAMES[10]   =    "ctrl+j"
KEYNAMES[11]   =    "ctrl+k"
KEYNAMES[12]   =    "ctrl+l"
KEYNAMES[13]   =    "ctrl+m"
KEYNAMES[14]   =    "ctrl+n"
KEYNAMES[15]   =    "ctrl+o"
KEYNAMES[16]   =    "ctrl+p"
KEYNAMES[17]   =    "ctrl+q"
KEYNAMES[18]   =    "ctrl+r"
KEYNAMES[19]   =    "ctrl+s"
KEYNAMES[20]   =    "ctrl+t"
KEYNAMES[21]   =    "ctrl+u"
KEYNAMES[22]   =    "ctrl+v"
KEYNAMES[23]   =    "ctrl+w"
KEYNAMES[24]   =    "ctrl+x"
KEYNAMES[25]   =    "ctrl+y"
KEYNAMES[26]   =    "ctrl+z"

# Key Sequences
var KEYSEQS* {.threadvar.}: CritBitTree[KeySeq] ## The following key sequences are defined and are used internally by **LineEditor**:
##
## .. code-block:: nim
##    KEYSEQS["up"]         = @[27, 91, 65]      # Windows: @[224, 72]
##    KEYSEQS["down"]       = @[27, 91, 66]      # Windows: @[224, 80]
##    KEYSEQS["right"]      = @[27, 91, 67]      # Windows: @[224, 77]
##    KEYSEQS["left"]       = @[27, 91, 68]      # Windows: @[224, 75]
##    KEYSEQS["home"]       = @[27, 91, 72]      # Windows: @[224, 71]
##    KEYSEQS["end"]        = @[27, 91, 70]      # Windows: @[224, 79]
##    KEYSEQS["insert"]     = @[27, 91, 50, 126] # Windows: @[224, 82]
##    KEYSEQS["delete"]     = @[27, 91, 51, 126] # Windows: @[224, 83]

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

# Key Mappings
var KEYMAP* {.threadvar.}: CritBitTree[KeyCallBack] ## The following key mappings are configured by default:
##
## * backspace: **deletePrevious**
## * delete: **deleteNext**
## * insert: *toggle editor mode*
## * down: **historyNext**
## * up: **historyPrevious**
## * ctrl+n: **historyNext**
## * ctrl+p: **historyPrevious**
## * left: **back**
## * right: **forward**
## * ctrl+b: **back**
## * ctrl+f: **forward**
## * ctrl+c: *quits the program*
## * ctrl+d: *quits the program*
## * ctrl+u: **clearLine**
## * ctrl+a: **goToStart**
## * ctrl+e: **goToEnd**
## * home: **goToStart**
## * end: **goToEnd**

KEYMAP["backspace"] = proc(ed: var LineEditor) =
  ed.deletePrevious()
KEYMAP["delete"] = proc(ed: var LineEditor) =
  ed.deleteNext()
KEYMAP["insert"] = proc(ed: var LineEditor) =
  if ed.mode == mdInsert:
    ed.mode = mdReplace
  else:
    ed.mode = mdInsert
KEYMAP["down"] = proc(ed: var LineEditor) =
  ed.historyNext()
KEYMAP["up"] = proc(ed: var LineEditor) =
  ed.historyPrevious()
KEYMAP["ctrl+n"] = proc(ed: var LineEditor) =
  ed.historyNext()
KEYMAP["ctrl+p"] = proc(ed: var LineEditor) =
  ed.historyPrevious()
KEYMAP["left"] = proc(ed: var LineEditor) =
  ed.back()
KEYMAP["right"] = proc(ed: var LineEditor) =
  ed.forward()
KEYMAP["ctrl+b"] = proc(ed: var LineEditor) =
  ed.back()
KEYMAP["ctrl+f"] = proc(ed: var LineEditor) =
  ed.forward()
KEYMAP["ctrl+c"] = proc(ed: var LineEditor) =
  stdout.write("\n"); stdout.flushFile()
  raise newException(InputCancelled, "")
KEYMAP["ctrl+d"] = proc(ed: var LineEditor) =
  stdout.write("\n"); stdout.flushFile()
  raise newException(EOFError, "")
KEYMAP["ctrl+u"] = proc(ed: var LineEditor) =
  ed.clearLine()
KEYMAP["ctrl+a"] = proc(ed: var LineEditor) =
  ed.goToStart()
KEYMAP["ctrl+e"] = proc(ed: var LineEditor) =
  ed.goToEnd()
KEYMAP["home"] = proc(ed: var LineEditor) =
  ed.goToStart()
KEYMAP["end"] = proc(ed: var LineEditor) =
  ed.goToEnd()
KEYMAP["ctrl+l"] = proc(ed: var LineEditor) =
  # Clear screen, redraw prompt + current line, restore cursor position.
  stdout.eraseScreen()
  stdout.setCursorPos(0, 0)
  stdout.write(ed.prompt)
  stdout.write(ed.line.text)
  let trail = ed.line.text.len - ed.line.position
  if trail > 0: stdout.cursorBackward(trail)
  stdout.flushFile()
when defined(posix):
  KEYMAP["ctrl+z"] = proc(ed: var LineEditor) =
    # Suspend ourselves the same way the terminal driver would have. Tear
    # down the modes we set (bracketed paste, SGR) so the user's shell isn't
    # left with surprises, then re-establish them on SIGCONT and redraw.
    stdout.write("\n\e[?2004l")
    resetAttributes()
    stdout.flushFile()
    discard posix.kill(posix.getpid(), posix.SIGTSTP)
    stdout.write("\e[?2004h")
    stdout.write(ed.prompt)
    stdout.write(ed.line.text)
    let trail = ed.line.text.len - ed.line.position
    if trail > 0: stdout.cursorBackward(trail)
    stdout.flushFile()

var keyMapProc {.threadvar.}: proc(ed: var LineEditor)

proc clearHint(ed: var LineEditor) =
  # Erase any ghost-hint characters previously rendered to the right of the
  # cursor. Caller ensures the cursor sits at the start of the hint area
  # (which is guaranteed by only rendering when position == text.len).
  if ed.hint.len == 0:
    return
  for _ in 0 ..< ed.hint.len:
    putchr(32)
  stdout.cursorBackward(ed.hint.len)
  stdout.flushFile()
  ed.hint = ""

proc readBracketedPaste(): tuple[text: string, hasNewline: bool] =
  # Consume bytes from stdin until we see the bracketed-paste end marker
  # `\e[201~`. Strip the marker and return the raw paste plus a flag for
  # whether it contained a line break.
  while true:
    let b = getchr()
    result.text.add b.chr
    if result.text.endsWith("\e[201~"):
      result.text.setLen(result.text.len - "\e[201~".len)
      for c in result.text:
        if c == '\n' or c == '\r':
          result.hasNewline = true
          return
      return

proc renderHint(ed: var LineEditor) =
  # Show the tail of the first matching completion as dim text after the
  # cursor, as a visual cue that tab will complete it. Only fires at end of
  # line on a non-empty input.
  if ed.completionCallback.isNil: return
  if ed.line.text.len == 0: return
  if ed.line.position != ed.line.text.len: return
  let compl = ed.completionCallback(ed)
  if compl.len == 0: return
  let words = ed.line.text.split(' ')
  let word = if words.len > 0: words[^1] else: ""
  let wordLower = word.toLowerAscii
  var hint = ""
  for m in compl:
    if m.len > word.len and m.toLowerAscii.startsWith(wordLower):
      hint = m[word.len .. ^1]
      break
  if hint.len == 0: return
  stdout.write("\e[2m")
  stdout.write(hint)
  stdout.write("\e[22m")
  stdout.cursorBackward(hint.len)
  stdout.flushFile()
  ed.hint = hint

proc readLine*(ed: var LineEditor, prompt="", hidechars = false, noHistory = false): string  =
  ## High-level proc to be used instead of **stdin.readLine** to read a line from standard input using the specified **LineEditor** object.
  ##
  ## Note that:
  ## * **prompt** is a string (that *cannot* contain escape codes, so it cannot be colored) that will be prepended at the start of the line and
  ##   not included in the contents of the line itself.
  ## * If **hidechars** is set to **true**, asterisks will be printed to stdout instead of the characters entered by the user.
  # TODO: vim mode — add a normal-mode / insert-mode switch here with
  # hjkl/w/b/e motions, dw/cw, etc. Will likely need an `ed.vimMode` field
  # and a per-keystroke dispatch that differs by mode.
  if not hidechars:
    stdout.write("\e[?2004h")  # enable bracketed paste
  stdout.write(prompt)
  stdout.flushFile()
  ed.line = Line(text: "", position: 0)
  ed.prompt = prompt
  var c = -1 # Used to manage completions
  var esc = false
  while true:
    var c1: int
    if c > 0:
      c1 = c
      c = -1
    else:
      c1 = getchr()
    ed.clearHint()
    if esc:
      esc = false
      continue
    elif c1 in {10, 13}:
      stdout.write("\n")
      if not noHistory and not hidechars: ed.historyAdd()
      ed.historyFlush()
      if not hidechars: stdout.write("\e[?2004l")
      return ed.line.text
    elif c1 in {8, 127}:
      KEYMAP["backspace"](ed)
    elif c1 in PRINTABLE:
      if hidechars:
        putchr('*'.ord.cint)
        ed.line.text &= c1.chr
        ed.line.position.inc
      else:
        ed.printChar(c1)
    elif c1 == 9: # TAB
      c = ed.completeLine()
    elif c1 in ESCAPES:
      var s = newSeq[Key](0)
      s.add(c1)
      let c2 = getchr()
      s.add(c2)
      if s == KEYSEQS["left"]:
        KEYMAP["left"](ed)
      elif s == KEYSEQS["right"]:
        KEYMAP["right"](ed)
      elif s == KEYSEQS["up"]:
        KEYMAP["up"](ed)
      elif s == KEYSEQS["down"]:
        KEYMAP["down"](ed)
      elif s == KEYSEQS["home"]:
        KEYMAP["home"](ed)
      elif s == KEYSEQS["end"]:
        KEYMAP["end"](ed)
      elif s == KEYSEQS["delete"]:
        KEYMAP["delete"](ed)
      elif s == KEYSEQS["insert"]:
        KEYMAP["insert"](ed)
      elif c2 == 91:
        let c3 = getchr()
        s.add(c3)
        if s == KEYSEQS["right"]:
          KEYMAP["right"](ed)
        elif s == KEYSEQS["left"]:
          KEYMAP["left"](ed)
        elif s == KEYSEQS["up"]:
          KEYMAP["up"](ed)
        elif s == KEYSEQS["down"]:
          KEYMAP["down"](ed)
        elif s == KEYSEQS["home"]:
          KEYMAP["home"](ed)
        elif s == KEYSEQS["end"]:
          KEYMAP["end"](ed)
        elif c3 in {50, 51}:
          let c4 = getchr()
          s.add(c4)
          if c4 == 126 and c3 == 50:
            KEYMAP["insert"](ed)
          elif c4 == 126 and c3 == 51:
            KEYMAP["delete"](ed)
          elif c3 == 50 and c4 == 48:
            # \e[200~ = bracketed paste start; \e[201~ = stray paste end.
            let c5 = getchr()
            let c6 = getchr()
            if c5 == 48 and c6 == 126:
              let paste = readBracketedPaste()
              if paste.hasNewline:
                ed.clearHint()
                ed.line.text = ed.line.fromStart & paste.text & (if ed.line.position < ed.line.text.len: ed.line.toEnd else: "")
                stdout.write("\n")
                if not noHistory and not hidechars: ed.historyAdd()
                ed.historyFlush()
                if not hidechars: stdout.write("\e[?2004l")
                return ed.line.text
              else:
                for ch in paste.text:
                  if ch.ord in PRINTABLE:
                    if hidechars:
                      putchr('*'.ord.cint)
                      ed.line.text &= ch
                      ed.line.position.inc
                    else:
                      ed.printChar(ch.ord)
        elif c3 == 49:
          # Modified arrows: ESC [ 1 ; <mod> <dir>, e.g. ctrl+left = ESC [ 1 ; 5 D
          let c4 = getchr()
          if c4 == 59:
            let modifier = getchr()
            let direction = getchr()
            if modifier == 53:  # ctrl
              case direction
              of 68: wordLeft(ed)   # 'D'
              of 67: wordRight(ed)  # 'C'
              of 65: KEYMAP["up"](ed)    # 'A' — fall back to history up
              of 66: KEYMAP["down"](ed)  # 'B' — fall back to history down
              else: discard
    elif c1 in CTRL and KEYMAP.hasKey(KEYNAMES[c1]):
      keyMapProc = KEYMAP[KEYNAMES[c1]]
      keyMapProc(ed)
    else:
      # Assuming unhandled two-values escape sequence; do nothing.
      if esc:
        esc = false
        continue
      else:
        esc = true
        continue
    if not hidechars:
      ed.renderHint()

proc password*(ed: var LineEditor, prompt=""): string =
  ## Convenience method to use instead of **readLine** to hide the characters inputed by the user.
  return ed.readLine(prompt, true)
 
when isMainModule:
  #proc testChar() =
  #  while true:
  #    let a = getchr()
  #    echo "\n->", a
  #    if a == 3:
  #      quit(0)
  #
  #testChar()
  proc testLineEditor() =
    var ed = initEditor(historyFile = "")
    while true:
      echo "---", ed.readLine("-> "), "---"

  testLineEditor()
