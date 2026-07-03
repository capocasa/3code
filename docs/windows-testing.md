# Windows testing: status and path forward

Windows is a **primary** target, on equal footing with Linux and macOS. This
document records why some tests are currently disabled on Windows and the
options for closing that gap. It is a working TODO, not a permanent state.

## Current status

22 of 33 tests run on Windows; 30 of 33 on macOS. The 11 Windows-disabled tests are:

- `tests/tty/test_tty_functional.nim`
- `tests/tty/test_empty_enter_freeze.nim`
- `tests/tty/test_interrupt_prestream_freeze.nim`

  These three drive `3code` as a subprocess through a pseudo-terminal via
  `tests/tty_expect.nim` (POSIX-only; needs a ConPTY port — see below).

- `tests/api/test_api.nim` — autosend probe tests spawn a child nim compiler
  with threading; flaky on Windows runners.
- `tests/core/test_cli_args.nim` — spawns the `3code` binary with path/env
  assumptions (session list, skills dir) that differ on Windows.
- `tests/core/test_history.nim` — uses the ttty simulated terminal; escape-
  sequence key decoding differs on Windows (`_getch` 0xE0/0x00 vs POSIX ESC [).
- `tests/stream/test_streamexec.nim` — `runStreamingBash` needs the bundled
  MSYS2 bash (`%LOCALAPPDATA%\3code\msys64`), absent on CI runners (exit 127).
- `tests/core/test_minline.nim` — arrow-key encoding differs (`_getch` 0xE0
  prefix vs POSIX `ESC [`), so cursor-movement subtests fail.
- `tests/core/test_session.nim` — draft/session-path tests assume
  `XDG_DATA_HOME` isolation, but Windows `userDataRoot()` reads `APPDATA`.
- `tests/core/test_update.nim` — config-isolation tests assume `HOME/.config`
  (XDG), but Windows reads `APPDATA` via `getConfigDir()`.
- `tests/core/test_util_extra.nim` — `collapseHome` assertions use forward-
  slash POSIX paths; Windows backslash paths fail the comparison.

On macOS the same three tty tests are also skipped: the harness compiles
(post util.h/clearEnv fix) but hangs deterministically because the `expect*`
procs poll on wall-clock deadlines that starve under the OSX runner's
scheduler. The fix is the frame-event sync rewrite in `plan-flakiness.md`;
until then they carry `disabled: "osx"`.

Each skipped test carries a `disabled:` spec pointing back here. When you
see that spec, this document is the "why" and the "how to fix".

## Why they are disabled

The three tests drive `3code` as a **real subprocess through a pseudo-terminal**
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
terminal): `test_minline` (72 tests) and `test_history` use it and run on
Windows today. The disabled tests are the end-to-end / concurrency layer only.

## Options to re-enable

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
