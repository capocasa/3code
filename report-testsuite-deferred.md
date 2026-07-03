# Test suite: deferred findings and fix paths

This is the consolidated record of everything learned about the test suite
during the testament-migration session, organized so future work can pick up
without rediscovering. Focused execution plans live in `plan-flakiness.md`
(tty timing) and `plan-ci-green.md` (immediate CI failures).

## Architecture (how the test suite is wired now)

After the migration:
- `nimble test` runs `testament --print --megatest:off all` (no bash wrapper).
- Megatest is OFF: our tests are unittest-style and print to stdout, which
  megatest miscompares as literal expected output.
- testament parallelizes across `tests/` category subdirs (tty, stream, api,
  config, shell, core) — one OS process per category.
- Test data lives in `testdata/` (not `tests/`) so `testament all` doesn't
  trip on non-test subdirs (its whitelist assertion).
- `config.nims` adds `--path:src` and `--path:tests` so tests in subdirs can
  import the helper modules at `tests/` root (tty_expect, stub_helpers,
  minline_testutils).
- Platform-incompatible tests self-disable via `discard """ disabled: "win" """`
  specs (testament skips compilation entirely for disabled tests).

## The tty_expect harness (the concurrency test layer)

`tty_expect.nim` drives `3code` as a real subprocess through a pseudo-terminal:
`openpty` → `fork` → `login_tty` → `execv`, with IPC via pipes
(`THREECODE_TEST_FRAME_FD` etc.). It is POSIX-only:
- Linux: `openpty`/`login_tty` in `<pty.h>`.
- macOS: same symbols in `<util.h>` (fixed this session; needs `-lutil`
  verification on the link step).
- Windows: no equivalent; needs a ConPTY port (`CreatePseudoConsole` +
  `UpdateProcThreadAttribute`). See docs/windows-testing.md.

The three tty tests (test_tty_functional, test_empty_enter_freeze,
test_interrupt_prestream_freeze) catch concurrency bugs (input-thread freezes,
interrupt races, queued-prompt/turn interactions) that a simulated terminal
cannot reproduce. They are the highest-value, most-fragile tests.

## Deferred issue 1: tty timing flakiness (the big one)

**Status:** focused plan in `plan-flakiness.md`. Summary below.

Different subtests fail on different runs; none individually broken. Fails
under parallel load, passes in isolation. Root cause: `expect*` procs poll on
**wall-clock deadlines** (`sleep 5` loops), ignoring the deterministic
frame-event channel (`THREECODE_TEST_FRAME_FD` / `emitTestFrameEvent` in
`testdata/stub/provider.nim`) that the harness already wires up and acks in
`pollOnce`. Under load the polling cadence starves and a back-to-back
assertion times out before the child produces the bytes.

**macOS note:** on the OSX CI runner this manifests as a deterministic hang
(a subtest never returns), not just a flake, so the three tty tests carry
`disabled: "osx"` until the frame-event sync rewrite lands. They still run
on Linux, where they pass (intermittently under heavy parallel load).

**Fix direction:** make `expect*` block on the frame-event pipe before
checking screen state (child becomes the clock), wall-clock timeout kept only
as a hung-child detector. Harness-only change; no src/ production code, no
test-body changes, no assertion loosening.

## Resolved issue 2: streamexec NUL-byte suppression (Linux)

**Root cause (was misdiagnosed as a production race):** the test ran
`printf 'before\n\x00binary\x00garbage\nafter\n'` via `/bin/sh`. On
Debian/Ubuntu CI `/bin/sh` is **dash**, whose `printf` builtin does not
understand hex escapes (`\x00`); POSIX mandates octal (`\nnn`). dash emitted
the four literal characters `\x00`, so `feedOutputChunk` never saw a real
NUL and `suppress` never engaged. The CI repr's double-backslash
(`\\x00`) was the tell — a genuine NUL renders as a single `\x00`. On the
developer's machine `/bin/sh` is bash, whose printf supports `\x00`, so it
never reproduced.

**Fix:** the test now uses octal `\000`, which both bash and dash interpret
as a real NUL. The production suppress logic in `streamexec.nim` was correct
all along. The Windows streamexec failure was unrelated (exit 127: the
bundled MSYS2 bash is absent on CI runners) and is now skipped via
`disabled: "win"`.

## Resolved issue 3: OSX path isolation (test_session, test_display, test_cli_args)

**Root cause:** `userDataRoot()` honored `XDG_DATA_HOME` on Linux but ignored
it on macOS, where it returned `getConfigDir() / "3code"` (which reads
`XDG_CONFIG_HOME`, falling back to the real `~/Library/Application Support`).
Tests set `XDG_DATA_HOME` expecting it to redirect the data root; on macOS it
didn't, so real runner sessions leaked in (`paths.len was 28`) and
`draftPathFor` resolved against the real config dir.

**Fix:** `userDataRoot()` now honors `XDG_DATA_HOME` on all POSIX platforms
(macOS default unchanged when unset). This is a consistency fix in
`src/threecode/util.nim`, not a test workaround — the code was already spec-
compliant on Linux and the divergence was the bug. The tty_expect harness's
`clearenv()` C import was also replaced (it is a glibc/BSD extension absent
from macOS `<stdlib.h>`, which blocked compilation of every tty test on OSX)
with a portable Nim `clearEnv` using `envPairs`/`delEnv`.

## Deferred issue 4: Windows test skips (restore old coverage)

CI shows 8 tests fail on Windows: the 4 originally identified
(test_api, test_cli_args, test_history, test_streamexec) plus test_minline,
test_session, test_update, and test_util_extra. All 8 now carry
`disabled: "win"` specs:
- test_streamexec: missing bundled MSYS2 bash (exit 127), not the NUL logic.
- test_minline: `_getch` arrow-key encoding (0xE0 prefix vs POSIX ESC [).
- test_session/test_update: assume XDG/HOME config isolation; Windows uses
  APPDATA via getConfigDir().
- test_util_extra: collapseHome forward-slash path assertions.

The Windows step also now runs testament directly (not via `nimble test`)
because git-bash did not propagate nimble's non-zero exit, silently reporting
green on failing test runs.

## What NOT to do (applies to all deferred work)

- No increased timeouts (masks races, slows the suite).
- No retries on flaky assertions (hides real regressions).
- No disabling tests except with a documented platform reason in
  docs/windows-testing.md.
- No loosening assertions to make red go green — the tests exist precisely to
  catch the regressions cheaper models ship.