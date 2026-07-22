# Windows testing: status and path forward

Windows is a **primary** target, on equal footing with Linux and macOS. This
document records why some tests are currently disabled on Windows and the
options for closing that gap. It is a working TODO, not a permanent state.

## Current status

39 of 40 test files run on Windows. The tty suite (18 files) is now enabled
via a ConPTY port of `tests/tty_expect.nim` (see below). One stream test
remains disabled with a precise, irreducible blocker:

- `tests/stream/test_netthread_blocks.nim` — asserts the
  interrupt-returns-cleanly-from-a-stuck-socket contract. That relies on
  `shutdownCachedStreamFd()` (src/threecode/api.nim), which is a no-op on
  Windows because it wraps `posix.shutdown` to wake a blocking `recv`. The
  Windows interrupt path needs an equivalent fd-wakeup (closesocket or a
  self-pipe) before this test can pass.

The tty suite (18 files) drives `3code` as a subprocess through the Windows
Pseudo Console API (ConPTY). The POSIX PTY lifecycle in `tty_expect.nim` is
forked on `when defined(windows):` — `openpty`→`CreatePseudoConsole`,
`fork`+`login_tty`+`execv`→`InitializeProcThreadAttributeList`+
`UpdateProcThreadAttribute(PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE)`+
`CreateProcessW`, `waitpid`→`GetExitCodeProcess`, `kill`→`TerminateProcess`,
`TIOCSWINSZ`+`SIGWINCH`→`ResizePseudoConsole`. Every blocking call on the
Windows path is bounded (`WaitForSingleObject` with a timeout, never
INFINITE), mirroring the OSX hardening discipline. The `TtySession` record
and the public `expect*`/`send`/`resize`/`close` API are identical across
both platforms, so the 18 test bodies needed no changes.

**Caveat (initial enablement):** the child-side test synchronization hooks
(`emitTestFrameEvent`, `waitForTestContinue`, `testTickerControlLoop` in
`src/`) are currently `when defined(posix):`-gated, so on Windows the
harness's frame-event waits and ticker-advance calls timeout (bounded — no
hang) and tests settle via `drain()`/`waitForOutput` wall-clock polling
instead. Some timing-sensitive assertions may need small tolerance
adjustments surfaced by CI; the IPC pipes are wired end-to-end so enabling
the child side later needs no harness change.

The following were previously disabled and are now **enabled and adapted**
(not skipped) to run meaningfully on Windows:

- `tests/core/test_session.nim`, `test_update.nim`, `test_util_extra.nim`,
  `test_cli_args.nim` — `userDataRoot()`/`userConfigRoot()` now honor
  `XDG_DATA_HOME`/`XDG_CONFIG_HOME` on Windows (mirroring the macOS fix,
  b7ea0f0), so the test env isolation that sets those vars actually redirects
  on Windows instead of leaking into real `APPDATA`. The `collapseHome`
  assertion is now separator-agnostic.
- `tests/core/test_minline.nim`, `test_history.nim` — the simulated-terminal
  `Driver` (tests/minline_testutils.nim) now feeds platform-correct nav-key
  bytes via a compile-time split mirroring `minline.KEYSEQS`/`ESCAPES`
  (Windows `_getch` `[224, X]` vs POSIX `ESC [ X`). The editor behavior under
  test is identical cross-platform; only the input encoding differs.
- `tests/api/test_api.nim` — probe subprocess outPath now carries the `.exe`
  suffix on Windows.
- `tests/stream/test_streamexec.nim` — injects the runner's git-bash via
  `cachedBash` when the bundled MSYS2 is absent, so the streaming-plumbing
  tests (line callback, stderr merge, exit codes, NUL suppression) run
  against a real bash. Production `resolveBash()` is unchanged.
- `tests/config/test_provider_wizard.nim` — two of the nine subtests
  ("add wizard lists models sorted alphabetically", "edit wizard lists
  models sorted alphabetically") capture wizard stdout by reassigning the
  `stdout` global var. On Windows MinGW, `stdout` is a macro
  (`(&__iob_func()[1])`), so the generated C assignment `stdout = f`
  fails to compile with `error: lvalue required as left operand of
  assignment`. The other seven subtests in the file don't use stdout
  capture and run unchanged on Windows. The two capture subtests are
  gated with `when not defined(windows):`; re-enabling them cross-
  platform would require plumbing a hook through `display.nim` so
  `hintLn` writes to a caller-supplied `File`.

Each still-skipped test carries a `disabled:` spec pointing back here. When
you see that spec, this document is the "why" and the "how to fix".

## Why the tty tests are disabled

The tty tests drive `3code` as a **real subprocess through a pseudo-terminal**
via the `tests/tty_expect.nim` harness. That harness is POSIX-only:

- `openpty` / `login_tty` (from `<pty.h>` / `<utmp.h>`) allocate the PTY pair.
- `fork` + `execv` start the child with the slave end as its controlling tty.
- `waitpid`, `kill` (SIGTERM/SIGKILL/SIGWINCH), `fcntl`, `pipe` manage the
  child lifecycle and the IPC pipes.

None of those exist on Windows. It is not a `/dev/pts` path issue: `openpty`
hands back an already-open slave fd, it never reads a `/dev/pts/N` path. The
blocker is the entire `fork` + PTY + signals API family.

These tests exist precisely because the bugs they target - input-thread
freezes, interrupt-during-stream races, queued-prompt/turn interactions - live
in the concurrency between the input reader, the controller, and the renderer
reacting to real I/O timing. A simulated terminal cannot reproduce them.

Note: the line editor and rendering layer that *doesn't* depend on timing is
already tested cross-platform via `ttty.newTerminal` (an in-process virtual
terminal): `test_minline` and `test_history` use it and run on Windows now.
The disabled tests are the end-to-end / concurrency layer only.

## Options to re-enable the tty suite

### Option A: Port `tty_expect.nim` to ConPTY (recommended)

Windows 10 1809+ ships the **Pseudo Console API** (ConPTY), which is the
modern, supported equivalent of `openpty`:

- `CreatePseudoConsole(cols, rows, hInput, hOutput, 0, &hPC)` replaces
  `openpty` + `login_tty`.
- `InitializeProcThreadAttributeList` + `UpdateProcThreadAttribute` with
  `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` attaches the ConPTY to the child,
  replacing `fork` + `login_tty(slaveFd)` + `execv`.
- The master side reads/writes the input/output pipes; `ResizePseudoConsole`
  replaces the `TIOCSWINSZ` `ioctl` + `SIGWINCH` path.
- Child exit is observed via `GetExitCodeProcess` / waiting on the process
  handle, replacing `waitpid`. Termination is `TerminateProcess`, replacing
  `kill(SIGTERM/SIGKILL)`.

This is a real port of one file (`tty_expect.nim`), behind `when defined(...)`.
The `TtySession` record and the public `expect*` API stay identical, so the
test bodies need no changes. The IPC pipe wiring (`THREECODE_TEST_FRAME_FD`
etc.) is already pipe-based and works on both platforms.

Caveat: the tests are timing-sensitive (they assert on streaming behavior with
real delays). ConPTY's scheduling differs slightly from a Linux PTY, so some
timing-dependent assertions may need small tolerance adjustments - but that is
a debugging exercise, not an architectural barrier.

GitHub Actions `windows-latest` runners support ConPTY. This is the path that
makes Windows a true peer.

### Option B: Run the PTY tests on Windows via WSL only

Run the existing POSIX harness inside Windows Subsystem for Linux. This
requires no code changes but does not actually exercise the Windows binary - it
tests the Linux build on a Windows host. Useful as a developer convenience,
not as a Windows-target CI signal. Not recommended as the primary strategy.

### Option C: Add a ConPTY-backed simulated-subprocess layer

A hybrid: instead of a real `3code` subprocess, build a Windows path that
drives the rendering and controller logic in-process against a ConPTY-shaped
virtual terminal. This would catch rendering regressions but would miss the
process-boundary bugs (signal handling, exit polling, the fork/exec contract)
that the real-subprocess tests are specifically built for. Lower value than
Option A for comparable effort.
