# Test Upgrade Plan

Goal: make terminal behavior tests match real user behavior, while removing
synthetic integration-style tests that are expensive to read and easy to fix
for the wrong reason.

## Principles

- Keep pure unit tests for pure contracts: parsing, config, usage, shell
  tokenization, loop tracking, markdown helpers, and serialization.
- Keep small byte/geometry tests only for explicit byte emitters that are hard
  to diagnose from a full terminal failure.
- Replace synthetic integration tests with real full-binary PTY tests.
- Do not add tests that manually recreate production lifecycle with global UI
  state unless the target is a pure reducer or byte emitter.
- Full-binary tests are the authority for user-visible behavior.

## Test Buckets

### Pure Unit

Examples:

- `toolCallToAction`
- config parsing and profile resolution
- usage parsing
- shell mutation/read detection
- compaction and loop tracker decisions
- session round trips

Rule: keep these. They are deterministic, cheap, and readable.

### Byte Geometry

Examples:

- `barFooterBytes`
- `spinnerFooterBytes`
- `submitTransitionBytes`
- wrapping and clear-to-EOS behavior

Rule: keep only tests that pin a reusable terminal byte contract or a known
historical bug. Delete duplicates that differ only by row arithmetic.

### Synthetic Integration

Examples:

- tests that set `inputEditor`, `inputState`, `inputThreadRunning`,
  `screenState`, or related globals and then feed partial terminal bytes
- tests that assert lifecycle behavior without launching the binary
- tests where the setup cannot happen through the real app

Rule: migrate or delete. These were meant to be integration tests but drifted
into integration-shaped unit tests.

### Functional PTY

Examples:

- launch real binary
- use provider stub
- feed normal user keystrokes
- assert terminal screen/output/files

Rule: keep this set small and high-value. These tests cover the behavior users
actually see.

## Expect Minilang

Create a test helper, likely `tests/tty_expect.nim`, around a real PTY and
`ttty/grid`.

Core API:

```nim
type
  TtySession = ref object
    masterFd: cint
    pid: Pid
    grid: Grid
    raw: string
    clean: string

proc start3code*(fixture: TtyFixture; args = "-x -i"): TtySession
proc send*(t: TtySession; text: string)
proc expect*(t: TtySession; text: string; timeoutMs = 3000)
proc expectNo*(t: TtySession; text: string; settleMs = 300)
proc expectRow*(t: TtySession; text: string; timeoutMs = 3000)
proc expectScreen*(t: TtySession; lines: openArray[string])
proc expectExit*(t: TtySession; code = 0; timeoutMs = 3000)
proc close*(t: TtySession)
```

Expectations drive timing. Tests should wait for observed output before
sending the next input, instead of sleeping for fixed durations.

The expect layer must also expose read access to the current screen, not only
boolean waits:

```nim
proc screenText*(t: TtySession): string
proc rows*(t: TtySession): seq[string]
proc rowContaining*(t: TtySession; text: string): int
proc tokenBarRows*(t: TtySession): seq[int]
proc cellStyle*(t: TtySession; row, col: int): ExpectStyle
```

This is required for token-bar checks. The test should be able to wait for one
piece of output, then read nearby rows and verify that the token bar is still
present, still styled correctly, and still showing the expected details.

Target shape:

```nim
let tty = start3code(fixture)
tty.send "this is a test\n"
tty.expect "yes it is"
tty.send "and another\n"
tty.expect "❯ and another"
tty.expectNo "… The"
tty.send ":q\n"
tty.expectExit 0
```

## Formatting Expectations

Add a small test-only formatting markup for expected 16-color/style checks.
It should not become a production parser.

Target shape:

```nim
tty.expectStyled """
<cyan bold>○2%  ↑2.0k  ↻1.2k  ↓64  0s</>
<bright-cyan bold>❯ </>
"""
```

Supported tags:

- foreground: `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`,
  `white`
- bright foreground: `bright-black`, `bright-red`, `bright-green`,
  `bright-yellow`, `bright-blue`, `bright-magenta`, `bright-cyan`,
  `bright-white`
- background via `bg:<color>`
- attrs: `bold`, `dim`, `italic`, `underline`
- reset: `</>`

Use styled expectations sparingly:

- prompt color when idle vs turn-running
- token bar color/bold
- receipt non-bold
- errors in magenta
- subtle output in grey/256-color when needed

Most functional tests should assert content, not styling.

## Screen History / Snapshot Mode

Screen history should be standard, not an optional debug feature. Every PTY
read should update a compact history of the visible screen. Tests can then
assert a series of snapshots instead of only asking whether text eventually
appeared.

```nim
type
  ScreenFrame = object
    atMs: int
    rows: seq[string]
    changedRows: seq[int]

proc enableScreenTrace*(t: TtySession)
proc frames*(t: TtySession): seq[ScreenFrame]
proc dumpFramesAround*(t: TtySession; text: string): string
proc expectSnapshot*(t: TtySession; lines: openArray[string]; timeoutMs = 3000)
proc expectSnapshots*(t: TtySession; snapshots: openArray[openArray[string]])
```

Purpose:

- catch token bar updates that briefly go wrong and then recover
- debug rows that are erased or overwritten during tool execution
- make failing full-binary tests explain what changed over time
- test behavior as visible terminal states rather than as raw byte trivia

Keep the trace compact:

- store only visible row text, not the full raw byte stream per frame
- collapse identical consecutive frames
- cap history per test unless explicitly disabled

Token bar helper expectations should use this trace:

```nim
tty.expectTokenBar(parts = ["○2%", "↑2.0k", "↻1.2k", "↓64", "0s"])
tty.expectTokenBarStable(settleMs = 300)
```

`expectTokenBarStable` should ensure no trace frame during the settle window
shows a malformed token bar, a missing prompt row, or old token-bar text
stacked in scrollback.

Snapshot expectations should support partial rows and wildcards so tests stay
readable:

```nim
tty.expectSnapshots @[
  @[
    "❯ this is a test",
    "*yes it is*",
    "*○*↑*↓*0s*",
    "❯ "
  ],
  @[
    "*yes it is*",
    "*$ sleep 0.5*",
    "*○*↑*↓*1s*",
    "❯ and another*"
  ],
  @[
    "*yes it is*",
    "*❯ and another*",
    "*The final answer*"
  ]
]
```

The runner should print the nearest recorded frames on failure. That makes a
broken token bar or stale prompt visible immediately instead of forcing the
next model to reason through escape sequences.

## Validate `ttty`

Add dedicated `ttty` validation tests in the `ttty` repository, not in this
application repo, proving the subset of terminal emulation we rely on:

- cursor movement: up/down/right/left and absolute column/row
- CR/LF behavior
- erase line and erase to end-of-screen
- SGR reset
- 16 foreground colors
- 16 background colors
- bold/dim/italic/underline attrs
- UTF-8 glyph placement for `❯`, `○`, `↑`, `↓`, `↻`
- DEC synchronized update wrappers are harmless

Document known limits in comments near those tests:

- no claim of complete terminal emulation
- resize/reflow behavior is only tested for the sequences we emit
- Unicode width is only as good as the glyphs we use

## Functional Scenarios To Keep

### Basic Prompt

- configured stub provider
- send prompt
- assistant reply appears
- token bar appears
- clean exit leaves no visible remnants

### Buffered Input During Tool

- send first prompt
- assistant emits content and tool call
- while tool is running, send another prompt
- prior assistant content remains visible
- queued prompt is echoed correctly
- no partial overwrite like `… The`
- second model turn runs

### Tool Coverage

- one dialog with harmless calls:
  `bash`, `read`, `write`, `patch`, `apply_patch`, `update_plan`,
  `web_search`, `web_fetch`
- verify visible output and file side effects
- final answer appears

### Initial Wizard

- no config
- enter stub provider through normal input
- choose `stub-model`
- config is saved
- first prompt passed on argv executes after wizard

### Token Bar

- stub response includes prompt/completion/cached usage
- expect context glyph, up, cached, down, and elapsed time
- assert critical styling through the formatting markup

### Smoke

- short configured stub conversation
- one real harmless tool call
- final reply

## Migration Order

1. Keep current full-binary `test_tty_functional.nim` as the seed.
2. Add `tests/tty_expect.nim` and a fixture helper.
3. Move timed-input tests to expectation-driven tests.
4. Add `ttty` validation tests and formatting markup.
5. Rewrite buffered-input regression as the authoritative functional test.
6. Rewrite wizard/token/tool/smoke scenarios with the minilang.
7. Delete synthetic integration tests in small batches.
8. Run `nimble test` after every deletion batch.
9. Add or update a test overview that lists what each remaining suite proves.

## Deletion Criteria

Delete or rewrite a test if:

- it manually sets UI lifecycle globals
- it asserts row numbers from an impossible setup
- it duplicates behavior now covered by full-binary tests
- it encourages fixing escape bytes locally instead of fixing behavior
- it needs extensive setup explanation and has no clear user-visible contract

Keep a weird terminal test only when its comment names the exact bug or byte
contract it protects.
