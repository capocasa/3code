import std/[unittest, os, strutils]
import threecode/[display, util]

## Live and replay must render byte-identically. Both paths now go through
## the same `MarkdownState` handlers; this test pins the property by
## feeding the same content through `handleMdLine` two different ways:
##
## 1. Replay style: one big `splitLines` loop (mirrors what
##    `renderAssistantContent` does on resumed sessions).
## 2. Streaming style: feed the content character by character, splitting
##    on '\n' to call `handleMdLine` for each emerged line, then
##    `finishMd` on the last partial. This mirrors the SSE chunk loop in
##    `streamHttp` (with the chunk boundary set to one byte, the smallest
##    feed possible).
##
## If both produce the same bytes, varying the chunk shape can't change
## the visible output either, since the handlers are stateless w.r.t.
## chunk boundaries (state lives in `MarkdownState`). Tested with content
## that exercises every branch the streaming path takes: paragraphs,
## inline `**bold**` and `` `code` ``, ATX headers, fenced code blocks,
## and a markdown table.

const Sample = """# Heading One

A paragraph with **bold word** and `inline code` to exercise the
inline markdown handlers.

## Subheading

```nim
echo "fenced code"
let x = 42
```

| Service     | Cost            |
|-------------|-----------------|
| **A**       | free, sort of   |
| B           | $0.17 per minute |

End paragraph."""

proc renderReplay(content: string): string =
  let path = getTempDir() / "3code_test_replay_" & $getCurrentProcessId()
  let f = open(path, fmWrite)
  defer:
    try: removeFile(path) except OSError: discard
  var st = initMarkdownState()
  for line in content.splitLines:
    discard handleMdLine(st, line, f)
  discard finishMd(st, f)
  flushFile(f)
  close(f)
  result = readFile(path)

proc renderStreaming(content: string): string =
  ## Feed one character at a time; on every '\n' fire handleMdLine.
  ## Whatever's left in `pending` after the loop is the last partial
  ## line; pass it through handleMdLine before finishMd, mirroring how
  ## `finishContent` flushes `pendingLine` in api.nim.
  let path = getTempDir() / "3code_test_stream_" & $getCurrentProcessId()
  let f = open(path, fmWrite)
  defer:
    try: removeFile(path) except OSError: discard
  var st = initMarkdownState()
  var pending = ""
  for ch in content:
    if ch == '\n':
      discard handleMdLine(st, pending, f)
      pending = ""
    else:
      pending.add ch
  if pending.len > 0:
    discard handleMdLine(st, pending, f)
  discard finishMd(st, f)
  flushFile(f)
  close(f)
  result = readFile(path)

suite "markdown render parity (live vs replay)":
  test "byte-identical output regardless of chunk shape":
    let a = renderReplay(Sample)
    let b = renderStreaming(Sample)
    check a == b
    check a.len > 0

  test "structural elements present (smoke)":
    let r = renderReplay(Sample)
    # ATX header rendered as bold, hash stripped
    check "Heading One" in r
    check "Subheading" in r
    check "#" notin r.splitLines[0]  # first emitted line drops the # prefix
    # Inline `**bold**` rendered as ANSI bold, asterisks dropped
    check "bold word" in r
    check "**bold word**" notin r
    check "\x1b[1m" in r  # bold ANSI
    # Inline `` `code` `` rendered as bold
    check "inline code" in r
    check "`inline code`" notin r
    # Fenced code block: bar prefix, fence lines suppressed
    check "┃" in r
    check "```" notin r
    check "echo \"fenced code\"" in r
    # Table: box-drawing characters
    check "┌" in r
    check "├" in r
    check "└" in r
    check "│" in r

  test "bold renders as bold without yellow":
    # Regression: bold used to emit `\x1b[33m` (yellow). It now uses
    # plain bold (`\x1b[1m`) inside the dim envelope.
    let r = renderReplay("**word**")
    check "\x1b[1m" in r
    check "\x1b[33m" notin r

  test "italic with * and _ renders, identifiers and arithmetic spared":
    # Italic emits both italic AND underline ANSI so it shows on
    # terminals without an italic font face. Either marker proves
    # italic detection fired.
    let a = applyInlineMd("The quick brown fox jumps over the *lazy* dog.")
    check "\x1b[3m" in a
    check "\x1b[4m" in a
    check "*lazy*" notin a
    check "lazy" in a
    let b = applyInlineMd("Sometimes you need _both_ styles.")
    check "\x1b[3m" in b
    check "_both_" notin b
    check "both" in b
    # `snake_case` — must NOT italicize (no boundary on opening _)
    let c = applyInlineMd("call snake_case_var here")
    check "\x1b[3m" notin c
    check "snake_case_var" in c
    # `5*5*7` — must NOT italicize (no boundary on opening *)
    let d = applyInlineMd("compute 5*5*7 result")
    check "\x1b[3m" notin d
    check "5*5*7" in d
    # `**bold**` still bold, not accidentally italicized
    let e = applyInlineMd("**bold word**")
    check "\x1b[1m" in e
    check "\x1b[3m" notin e

  test "nested **_italic_** and **`code`** render through":
    # Bold wrapping italic-via-underscore. Outer bold consumes whole
    # `**...**`, leaves `_lazy_` as inner; recursion italicizes it.
    let a = applyInlineMd("**_lazy_**")
    check "\x1b[1m" in a  # bold
    check "\x1b[3m" in a  # italic (from recursion)
    check "_lazy_" notin a
    check "lazy" in a
    # Bold wrapping inline code.
    let b = applyInlineMd("**`func()`**")
    check "\x1b[1m" in b
    check "`func()`" notin b
    check "func()" in b
    # Italic wrapping code.
    let c = applyInlineMd("*`x`*")
    check "\x1b[3m" in c
    check "`x`" notin c

  test "***bold-italic*** combines bold + italic":
    let r = applyInlineMd("***apple***")
    check "\x1b[1m" in r  # bold
    check "\x1b[3m" in r  # italic
    check "***apple***" notin r
    check "*apple*" notin r  # leftover stray asterisks would mean only inner matched
    check "apple" in r

  test "italic inside table cells renders":
    let r = renderReplay("""| Plain | Italic |
|-------|--------|
| apple | *apple* |
| code  | _code_  |""")
    check "\x1b[3m" in r
    check "*apple*" notin r
    check "_code_" notin r
    check "apple" in r
    check "code" in r

  test "**bold** inside table cells is rendered, not literal":
    let r = renderReplay("""| Service     | Note |
|-------------|------|
| **A**       | one  |
| **B**       | two  |""")
    # Bold ANSI present (means cell got run through applyInlineMd)
    check "\x1b[1m" in r
    # Marker characters dropped from rendered output
    check "**A**" notin r
    check "**B**" notin r
    # Box-drawing intact
    check "│" in r
