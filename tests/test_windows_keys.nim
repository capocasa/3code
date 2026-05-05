## Windows console key dispatch tests.
##
## On Windows, arrow / nav keys arrive as a 2-byte sequence: a
## prefix byte (224 for arrows / nav, 0 for some function keys)
## followed by a key code. KEYSEQS["up"] etc. on Windows hold those
## 2-byte shapes.
##
## We can't trigger the windows ``if c1 in ESCAPES`` branch in
## ``readLineWith`` from Linux (the const set is platform-baked),
## so this suite drives ``handleEscape`` directly with a Windows
## prefix and a temporarily Windows-shaped KEYSEQS. The test
## confirms the seq dispatch works end-to-end through the editor's
## state (cursor position, history navigation, etc.).

import std/[unittest, deques, critbits]
import threecode/minline

# Inline driver: feeds the leftover bytes (everything after the
# prefix) through ``ed.getCh`` so handleEscape can read them as if
# they came from the console.
type
  ByteSource = ref object
    bytes: seq[int]
    pos: int

proc src(bs: openArray[int]): ByteSource =
  ByteSource(bytes: @bs, pos: 0)

proc wire(ed: var LineEditor, b: ByteSource) =
  ed.getCh = proc(): int =
    if b.pos >= b.bytes.len: return -1
    let k = b.bytes[b.pos]; inc b.pos; return k
  ed.write = proc(s: string) = discard
  ed.getWidth = proc(): int = 80

proc setupWindowsLikeKEYSEQS() =
  # Mirror Windows console codes for nav keys.
  KEYSEQS["up"]     = @[224, 72]
  KEYSEQS["down"]   = @[224, 80]
  KEYSEQS["left"]   = @[224, 75]
  KEYSEQS["right"]  = @[224, 77]
  KEYSEQS["home"]   = @[224, 71]
  KEYSEQS["end"]    = @[224, 79]
  KEYSEQS["delete"] = @[224, 83]
  KEYSEQS["insert"] = @[224, 82]

proc seedHistory(ed: var LineEditor, entries: seq[string]) =
  for e in entries: ed.history.entries.addLast e
  ed.history.cursor = -1

proc resetEditorBuffer(ed: var LineEditor, text: string) =
  ed.line.text = text
  ed.line.position = text.len
  ed.promptW = 2
  ed.contPromptW = 2
  ed.width = 80
  ed.renderRow = 0

suite "windows console key dispatch":
  setup:
    setupWindowsLikeKEYSEQS()

  test "Windows up arrow [224, 72] triggers history previous":
    var ed = initEditor()
    seedHistory(ed, @["older"])
    resetEditorBuffer(ed, "draft")
    let b = src([72])  # second byte; first byte (224) is c1 to handleEscape
    ed.wire b
    discard handleEscape(ed, 224)
    check ed.line.text == "older"

  test "Windows down arrow [224, 80] returns to draft":
    var ed = initEditor()
    seedHistory(ed, @["older"])
    resetEditorBuffer(ed, "draft")
    let b = src([72])
    ed.wire b
    discard handleEscape(ed, 224)  # up — saves draft, shows "older"
    check ed.line.text == "older"
    let b2 = src([80])
    ed.wire b2
    discard handleEscape(ed, 224)  # down — restore draft
    check ed.line.text == "draft"

  test "Windows left/right arrows move cursor":
    var ed = initEditor()
    resetEditorBuffer(ed, "abc")
    check ed.line.position == 3
    ed.wire src([75])  # left
    discard handleEscape(ed, 224)
    check ed.line.position == 2
    ed.wire src([77])  # right
    discard handleEscape(ed, 224)
    check ed.line.position == 3

  test "Windows home/end snap to logical line":
    var ed = initEditor()
    resetEditorBuffer(ed, "hello")
    ed.wire src([71])  # home
    discard handleEscape(ed, 224)
    check ed.line.position == 0
    ed.wire src([79])  # end
    discard handleEscape(ed, 224)
    check ed.line.position == 5

  test "Windows delete removes next char":
    var ed = initEditor()
    resetEditorBuffer(ed, "abcd")
    ed.line.position = 1
    ed.wire src([83])  # delete
    discard handleEscape(ed, 224)
    check ed.line.text == "acd"

  test "Windows prefix that doesn't match a known key is a no-op":
    var ed = initEditor()
    resetEditorBuffer(ed, "abc")
    ed.wire src([99])  # arbitrary unmapped second byte
    discard handleEscape(ed, 224)
    check ed.line.text == "abc"
    check ed.line.position == 3
