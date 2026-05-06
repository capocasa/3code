import std/[unittest, os, posix, times]
import threecode/[types, display]

## Golden-file tests: pin the exact byte output of the render helpers so
## any change to spacing, ANSI sequences, glyphs, dim/bright choices, or
## newline placement trips a failing test. Intentional changes regenerate
## the fixtures with `THREECODE_GOLDEN_UPDATE=1 nimble test`; the
## resulting `.gold` diff is the visible diff for review.
##
## Why this complements `test_render.nim`: that file checks parity (live
## vs replay) and that *certain* bytes are present. This file freezes the
## *whole* byte stream. The two together catch both classes of regression.
##
## Adding a scenario:
##   1. Write the test below, capture bytes via `capture` or pass a `File`.
##   2. Run `THREECODE_GOLDEN_UPDATE=1 nimble test` once to seed the file.
##   3. Inspect `tests/golden/<name>.gold` (raw ANSI; `cat` it in a
##      colour-capable terminal to eyeball the look).
##   4. Commit the gold file alongside the test.

const GoldenDir = currentSourcePath().parentDir / "golden"

proc goldPath(name: string): string =
  GoldenDir / name & ".gold"

proc goldCheck(name, actual: string) =
  ## Compare `actual` against `tests/golden/<name>.gold`. With
  ## `THREECODE_GOLDEN_UPDATE=1` set, write the file instead and pass.
  ## Missing fixture is treated as "regenerate"-only — won't silently
  ## pass, but won't blow up the suite either; the next run with the
  ## env var creates it.
  let path = goldPath(name)
  if getEnv("THREECODE_GOLDEN_UPDATE").len > 0:
    createDir(GoldenDir)
    writeFile(path, actual)
    echo "  [golden] wrote ", path, " (", actual.len, " bytes)"
    return
  if not fileExists(path):
    fail()
    echo "  missing fixture: ", path,
         "  (rerun with THREECODE_GOLDEN_UPDATE=1 to create)"
    return
  let expected = readFile(path)
  if actual != expected:
    let actPath = path & ".actual"
    writeFile(actPath, actual)
    fail()
    echo "  golden mismatch: ", path
    echo "  actual written to: ", actPath
    echo "  diff with: diff -u ", path, " ", actPath
    echo "  to accept: THREECODE_GOLDEN_UPDATE=1 nimble test"

proc captureStdout(body: proc()): string =
  ## Redirect stdout to a tempfile for the duration of `body`, return
  ## the captured bytes. POSIX-only; tests are POSIX-only today (CI
  ## matrix is linux + macos for the moment).
  let path = getTempDir() / "3code_gold_" & $getCurrentProcessId() & "_" &
             $epochTime().int64
  flushFile(stdout)
  let saved = dup(1)
  doAssert saved >= 0
  let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
  doAssert fd >= 0
  doAssert dup2(fd, 1) >= 0
  discard close(fd)
  try:
    body()
    flushFile(stdout)
  finally:
    doAssert dup2(saved, 1) >= 0
    discard close(saved)
  result = readFile(path)
  try: removeFile(path) except OSError: discard

proc captureFile(body: proc(f: File)): string =
  let path = getTempDir() / "3code_gold_f_" & $getCurrentProcessId() & "_" &
             $epochTime().int64
  let f = open(path, fmWrite)
  defer:
    try: removeFile(path) except OSError: discard
  body(f)
  flushFile(f)
  close(f)
  result = readFile(path)

# Force a stable terminal width so wrapAnsi behaviour is deterministic.
# 80 cols is the default fallback and what most fixtures should target.
# Tests that need a specific width set TERMINAL_COLS / COLUMNS via env
# wrappers in nimble.cfg if we ever need them.

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

suite "golden: render helpers":
  test "renderAssistantContent — full markdown sample":
    let bytes = captureFile(proc(f: File) =
      renderAssistantContent(Sample, f))
    goldCheck("assistant_content_sample", bytes)

  test "renderAssistantContent — short plain reply":
    let bytes = captureFile(proc(f: File) =
      renderAssistantContent("Hello there!", f))
    goldCheck("assistant_content_short", bytes)

  test "renderAssistantContent — multiline plain":
    let bytes = captureFile(proc(f: File) =
      renderAssistantContent("first line\nsecond line\nthird line", f))
    goldCheck("assistant_content_multiline", bytes)

  test "renderAssistantContent — empty content is a no-op":
    let bytes = captureFile(proc(f: File) =
      renderAssistantContent("", f))
    check bytes.len == 0
    goldCheck("assistant_content_empty", bytes)

  test "renderTokenLine — typical turn":
    let usage = Usage(promptTokens: 12345, cachedTokens: 8000,
                      completionTokens: 487, totalTokens: 12832)
    let bytes = captureStdout(proc() =
      renderTokenLine(usage, window = 128_000, elapsedS = 7))
    goldCheck("token_line_typical", bytes)

  test "renderTokenLine — no cache, replay mode (no elapsed)":
    let usage = Usage(promptTokens: 2300, cachedTokens: 0,
                      completionTokens: 31, totalTokens: 2331)
    let bytes = captureStdout(proc() =
      renderTokenLine(usage, window = 128_000))
    goldCheck("token_line_no_cache_replay", bytes)

  test "renderTokenLine — zero usage is a no-op":
    let bytes = captureStdout(proc() =
      renderTokenLine(Usage(), window = 128_000, elapsedS = 0))
    check bytes.len == 0
    goldCheck("token_line_empty", bytes)

  test "renderToolBanner — success with elapsed":
    let bytes = captureStdout(proc() =
      renderToolBanner("bash   echo hello", akBash, code = 0, elapsedS = 2))
    goldCheck("tool_banner_ok", bytes)

  test "renderToolBanner — error, no elapsed (replay)":
    let bytes = captureStdout(proc() =
      renderToolBanner("bash   exit 1", akBash, code = 1))
    goldCheck("tool_banner_err_replay", bytes)

  test "renderToolPending — dim leading bullet":
    let bytes = captureStdout(proc() =
      renderToolPending("read   src/foo.nim", akRead))
    goldCheck("tool_pending", bytes)
