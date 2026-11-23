## Vi editing mode tests — a conceptual port of readline's vi-mode
## (``vi_mode.c``, the machinery behind bash's ``set -o vi``) onto the
## minline driver. Each case feeds real keystrokes through the editor
## and asserts on the submitted text, mirroring the readline vi-mode
## behavior table: motions, operators, insert-mode entry points, counts
## and mode switching. Readline-mode regression guards at the bottom
## pin the ``editing = readline`` default and the ESC routing rules for
## ``both``.

import std/[unittest, tables]
import threecode/minline
import threecode/vim
import minline_testutils
import ttty/grid

proc viDriver(): Driver =
  ## Driver that reports no pending input, so a pushed ESC is always a
  ## bare Escape (never the head of an alt-chord).
  let d = newDriver()
  d.pendingInput = proc(): bool = false
  d

proc enableVi(mode = emBoth) =
  ## Arm vi editing the way the config loader does.
  vim.editingMode = mode
  vim.configureEditing(initTable[string, string]())

proc enableReadline() =
  vim.editingMode = emReadline
  vim.configureEditing(initTable[string, string]())

proc newViEd(): (Driver, LineEditor) =
  let d = viDriver()
  var ed = initEditor()
  (d, ed)

proc submit(d: Driver, ed: var LineEditor): string =
  d.push Enter
  d.run(ed, prompt = "> ")

suite "vim mode: command-mode motions":
  enableVi()
  test "ESC 0 i X inserts at start of line":
    var (d, ed) = newViEd()
    d.pushString "hello"
    d.push Esc
    d.pushString "0iX"
    check submit(d, ed) == "Xhello"
  test "ESC h i inserts before the char the cursor landed on":
    var (d, ed) = newViEd()
    d.pushString "hello"
    d.push Esc
    d.pushString "hiX"
    check submit(d, ed) == "helXlo"
  test "ESC l l i inserts two chars right":
    var (d, ed) = newViEd()
    d.pushString "hello"
    d.push Esc
    d.pushString "0lliX"
    check submit(d, ed) == "heXllo"
  test "w advances to the next word start":
    var (d, ed) = newViEd()
    d.pushString "foo bar"
    d.push Esc
    d.pushString "0wiX"
    check submit(d, ed) == "foo Xbar"
  test "b backs to the current word start":
    var (d, ed) = newViEd()
    d.pushString "foo bar"
    d.push Esc
    d.pushString "0wbiX"
    check submit(d, ed) == "Xfoo bar"
  test "e lands on the word's last char and a appends after it":
    var (d, ed) = newViEd()
    d.pushString "foo bar"
    d.push Esc
    d.pushString "0eaX"
    check submit(d, ed) == "fooX bar"
  test "$ A appends at end of line":
    var (d, ed) = newViEd()
    d.pushString("  indented")
    d.push Esc
    d.pushString "$AX"
    check submit(d, ed) == "  indentedX"
  test "^ I inserts at first non-blank":
    var (d, ed) = newViEd()
    d.pushString("  indented")
    d.push Esc
    d.pushString "^IX"
    check submit(d, ed) == "X  indented"

suite "vim mode: word classes (bash vi-mode w/b/e semantics)":
  enableVi()
  test "w stops on punctuation words as separate words":
    var (d, ed) = newViEd()
    d.pushString "cd ../x"
    d.push Esc
    d.pushString "0wwiX"
    check submit(d, ed) == "cd ../Xx"
  test "W treats punctuation as part of a big word":
    var (d, ed) = newViEd()
    d.pushString "cd ../x"
    d.push Esc
    d.pushString "0WiX"
    check submit(d, ed) == "cd X../x"

suite "vim mode: find motions":
  enableVi()
  test "f finds the next occurrence and x deletes it":
    var (d, ed) = newViEd()
    d.pushString "a1a2a3"
    d.push Esc
    d.pushString "0fax;x"
    check submit(d, ed) == "a123"
  test "F searches backward":
    var (d, ed) = newViEd()
    d.pushString "a b a"
    d.push Esc
    d.pushString "$Fax"
    check submit(d, ed) == "a b "
  test "t stops just before the target":
    var (d, ed) = newViEd()
    d.pushString "aXa"
    d.push Esc
    d.pushString "0tiaX"
    check submit(d, ed) == "aXXa"

suite "vim mode: operators":
  enableVi()
  test "D deletes to end of line":
    var (d, ed) = newViEd()
    d.pushString "hello world"
    d.push Esc
    d.pushString "0wD"
    check submit(d, ed) == "hello "
  test "dw deletes through the separating whitespace":
    var (d, ed) = newViEd()
    d.pushString "foo bar"
    d.push Esc
    d.pushString "0dw"
    check submit(d, ed) == "bar"
  test "2dw deletes two words":
    var (d, ed) = newViEd()
    d.pushString "foo bar baz"
    d.push Esc
    d.pushString "02dw"
    check submit(d, ed) == "baz"
  test "cc empties the line and inserts":
    var (d, ed) = newViEd()
    d.pushString "hello"
    d.push Esc
    d.pushString "ccworld"
    check submit(d, ed) == "world"
  test "S is cc":
    var (d, ed) = newViEd()
    d.pushString "hello"
    d.push Esc
    d.pushString "Snew"
    check submit(d, ed) == "new"
  test "yy yanks the line and p pastes it":
    var (d, ed) = newViEd()
    d.pushString "one"
    d.push Esc
    d.pushString "yyp"
    check submit(d, ed) == "one\none"
  test "dd then p restores the line":
    var (d, ed) = newViEd()
    d.pushString "one"
    d.push Esc
    d.pushString "ddp"
    check submit(d, ed) == "one"

suite "vim mode: single-key edits":
  enableVi()
  test "x deletes the char under the cursor":
    var (d, ed) = newViEd()
    d.pushString "abcd"
    d.push Esc
    d.pushString "x"
    check submit(d, ed) == "abc"
  test "0 3x deletes three chars":
    var (d, ed) = newViEd()
    d.pushString "abcdef"
    d.push Esc
    d.pushString "03x"
    check submit(d, ed) == "def"
  test "X deletes before the cursor":
    var (d, ed) = newViEd()
    d.pushString "abcd"
    d.push Esc
    d.pushString "0lX"
    check submit(d, ed) == "bcd"
  test "r replaces one char":
    var (d, ed) = newViEd()
    d.pushString "abc"
    d.push Esc
    d.pushString "rz"
    check submit(d, ed) == "abz"
  test "~ toggles case under the cursor":
    var (d, ed) = newViEd()
    d.pushString "abc"
    d.push Esc
    d.pushString "~"
    check submit(d, ed) == "abC"
  test "s substitutes the char and inserts":
    var (d, ed) = newViEd()
    d.pushString "abc"
    d.push Esc
    d.pushString "sX"
    check submit(d, ed) == "abX"
  test "C changes to end of line":
    var (d, ed) = newViEd()
    d.pushString "hello world"
    d.push Esc
    d.pushString "0wCX"
    check submit(d, ed) == "hello X"
  test "u undoes the last edit":
    var (d, ed) = newViEd()
    d.pushString "abc"
    d.push Esc
    d.pushString "xu"
    check submit(d, ed) == "abc"

suite "vim mode: insert-mode entry points":
  enableVi()
  test "a appends after the cursor char":
    var (d, ed) = newViEd()
    d.pushString "abc"
    d.push Esc
    d.pushString "aX"
    check submit(d, ed) == "abcX"
  test "I inserts at first non-blank":
    var (d, ed) = newViEd()
    d.pushString("  ind")
    d.push Esc
    d.pushString "IX"
    check submit(d, ed) == "X  ind"
  test "A appends at end of line":
    var (d, ed) = newViEd()
    d.pushString "foo"
    d.push Esc
    d.pushString "AX"
    check submit(d, ed) == "fooX"
  test "ESC leaves the line intact and Enter submits":
    var (d, ed) = newViEd()
    d.pushString "hello"
    d.push Esc
    check submit(d, ed) == "hello"
  test "R enters replace mode (typing overwrites)":
    var (d, ed) = newViEd()
    d.pushString "abc"
    d.push Esc
    d.pushString "RXY"
    check submit(d, ed) == "abXY"
  test "insert mode letters self-insert again":
    var (d, ed) = newViEd()
    d.pushString "ab"
    d.push Esc
    d.pushString "ihl"
    check submit(d, ed) == "ahlb"

suite "vim mode: counts":
  enableVi()
  test "3l moves three chars right":
    var (d, ed) = newViEd()
    d.pushString "abcdef"
    d.push Esc
    d.pushString "03liX"
    check submit(d, ed) == "abcXdef"
  test "2r replaces two chars with the same char":
    var (d, ed) = newViEd()
    d.pushString "abcde"
    d.push Esc
    d.pushString "02rz"
    check submit(d, ed) == "zzcde"
  test "counted ~ toggles several chars":
    var (d, ed) = newViEd()
    d.pushString "abcd"
    d.push Esc
    d.pushString "03~"
    check submit(d, ed) == "ABCd"

suite "vim mode: readline keys survive in both mode":
  enableVi()
  test "Ctrl+A still moves to start of line":
    var (d, ed) = newViEd()
    d.pushString "hello"
    d.push Esc
    d.push CtrlA
    d.pushString "iX"
    check submit(d, ed) == "Xhello"
  test "Ctrl+W still deletes the word left":
    var (d, ed) = newViEd()
    d.pushString "foo bar"
    d.push CtrlW
    check submit(d, ed) == "foo "

suite "vim mode: ESC routing":
  enableVi()
  test "ESC stripped from readline cancel/clear; ESC edits instead":
    var (d, ed) = newViEd()
    d.pushString "draft"
    d.push Esc
    d.pushString "x"
    check submit(d, ed) == "draf"
  test "ESC then i returns to insert mode":
    var (d, ed) = newViEd()
    d.push Esc
    d.pushString "iabc"
    check submit(d, ed) == "abc"

suite "vim mode: emVim without readline letters":
  enableVi(emVim)
  test "vi motions work":
    var (d, ed) = newViEd()
    d.pushString "hello"
    d.push Esc
    d.pushString "0iX"
    check submit(d, ed) == "Xhello"

suite "readline default is untouched":
  enableReadline()
  test "ESC keeps the clear role; the draft is discarded":
    var (d, ed) = newViEd()
    d.pushString "hello"
    d.push Esc
    expect EOFError:  # ESC cleared the draft; the read ends at EOF
      discard d.run(ed, prompt = "> ")
    check ed.line.text.len == 0
  test "letters insert literally (no vi interception)":
    var (d, ed) = newViEd()
    d.pushString "hji"
    check submit(d, ed) == "hji"
