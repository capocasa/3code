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

**Fix direction:** make `expect*` block on the frame-event pipe before
checking screen state (child becomes the clock), wall-clock timeout kept only
as a hung-child detector. Harness-only change; no src/ production code, no
test-body changes, no assertion loosening.

## Deferred issue 2: streamexec NUL-byte suppression (Linux + Windows)

**The test:** `test_streamexec.nim` "suppresses streaming callback after NUL
byte". Runs `printf 'before\n\x00binary\x00garbage\nafter\n'`, expects the
callback to stop receiving lines after the first NUL.

**The failure (CI only, does not reproduce locally):** `lines was
@["before", "\x00binary\x00garbage", "after"]` — "after" leaked through,
meaning `suppress` was false when it was emitted.

**The mechanism (src/threecode/streamexec.nim):** `readAvailableOutput` (line
94) holds one `suppress` var across all chunks in a single call.
`feedOutputChunk` (line 61) sets `suppress = true` on `'\x00'`. Called once
from `runStreamingBash` (line 347). In theory suppress persists.

**Open question:** why did suppress reset? Most likely a chunk-boundary path
that re-emits without checking suppress — audit `emitPartialLine` (line 73),
the partial-flush branch (line 121, fires on `PartialLineFlushMs` idle), and
the post-exit drain loop (line 126). One of these may emit when suppress is
already true. The CI runner's slower scheduling makes the idle-flush timer
fire where a fast machine never hits it.

**This is the one real bug** in the deferred set — the others are test
isolation or known skips. Fixing it likely closes both the Linux and Windows
streamexec failure.

## Deferred issue 3: OSX path isolation (test_session, test_display, test_cli_args)

Pre-existing (main was red on OSX before this work). The tests' `setup` blocks
set `XDG_DATA_HOME` to a tmpdir, but `draftPathFor`/`getConfigDir`/
`listSessionPathsForCwd` resolve against the real `~/.config/3code` or
`~/.local/share/3code` on the runner (28 real sessions leak in). Likely the
helpers read `XDG_CONFIG_HOME` (unset in setup) or fall back to the real home.

**Fix direction:** set BOTH `XDG_DATA_HOME` and `XDG_CONFIG_HOME` in the
affected setup blocks; for test_cli_args, pass the isolated env through to the
spawned `3code` binary (it currently inherits the runner's real env).

## Deferred issue 4: Windows test skips (restore old coverage)

The deleted `tools/test.sh` skipped 8 tests on Windows; CI shows only 4
actually fail there (test_api, test_cli_args, test_history, test_streamexec).
The other 4 (test_minline, test_session, test_update, test_util_extra) pass.
Add `disabled: "win"` specs to the 4 that fail. test_streamexec may resolve
via issue 2's fix; re-check before skipping it.

## What NOT to do (applies to all deferred work)

- No increased timeouts (masks races, slows the suite).
- No retries on flaky assertions (hides real regressions).
- No disabling tests except with a documented platform reason in
  docs/windows-testing.md.
- No loosening assertions to make red go green — the tests exist precisely to
  catch the regressions cheaper models ship.