# Cybernetic Plan: re-enable Windows-disabled tests (adapt, don't skip)

## Context

Windows is a primary target on equal footing with Linux and macOS. Today 27
test files carry `disabled: "win"`. The OSX work (this branch, commit
eec8d80) took the "adapt to the OS, just as meaningful" path: it removed
`disabled: "osx"` from 17 of 18 tty files and hardened the harness's blocking
calls rather than loosening assertions. The goal here is the same for Windows
— remove every `disabled: "win"` that can be made genuinely meaningful on
Windows, and leave a precise, documented fallback only for what truly cannot.

The 27 `disabled: "win"` files split into three classes with distinct root
causes (confirmed by reading source this session):

### Class A — OS-assumption in the test, not the harness (9 files)

The tests assume POSIX env isolation that the production code does not honor
on Windows. Three concrete root causes, all in `src/threecode/util.nim`:

1. **`userDataRoot()` ignores `XDG_DATA_HOME` on Windows** (util.nim:298).
   The POSIX branch reads `getEnv("XDG_DATA_HOME")` (line 300); the Windows
   branch (line 298) was bare `getConfigDir() / "3code"`. Tests that set
   `XDG_DATA_HOME` to a temp dir for isolation leaked into real `APPDATA`.
2. **`userConfigRoot()` ignored `XDG_CONFIG_HOME` on Windows** (util.nim:285).
   Both branches used `getConfigDir()`. On Linux `getConfigDir()` honors
   `XDG_CONFIG_HOME`; on Windows Nim's `getConfigDir()` returns `APPDATA` and
   ignores it. So `test_update.nim`'s `putEnv("XDG_CONFIG_HOME", ...)` was
   silently ignored on Windows.
3. **`collapseHome()` uses `/` separators** (util.nim:807). On Windows
   `getHomeDir() / "x"` yields backslashes, and `collapseHome` strips `/`
   only, so `~/src/test.nim` assertions failed. The proc itself is correct
   (separator agnostic via prefix match), the test expectations were not.

Fix: honor the XDG overrides on Windows too (mirrors the macOS XDG fix from
b7ea0f0, same rationale). This is a source fix that *enables* correct test
isolation, not a test workaround.

### Class B — simulated-terminal tests feeding platform-wrong key bytes (2 files)

`test_minline.nim` and `test_history.nim` drive the editor through
`tests/minline_testutils.nim`'s `Driver`, which pushes bytes into an in-process
`ttty` terminal (NOT a real PTY, NOT `_getch`). The editor's decode tables are
platform-conditional (`src/threecode/minline.nim`): POSIX `ESCAPES={27}`,
Windows `{0,22,224}`; `KEYSEQS` POSIX `@[27,91,68]` vs Windows `@[224,75]`.

The test path never touches `_getch`: `Driver.run` overrides `getCh` to read
from `d.terminal.read()`. The tests correctly test editor *behavior* (cursor
movement, history nav), identical cross-platform; only the *byte encoding the
test feeds* must match the platform's `KEYSEQS`. Fix: compile-time split in
the Driver mirroring minline's own tables.

### Class C — API/shell subprocess tests (3 files)

- `tests/api/test_api.nim` — pure shaping/fallback suites + autosend/probe
  tests that `execCmdEx("nim c ...")`. Probe outPath needed `.exe` on Windows.
- `tests/stream/test_streamexec.nim` — `runStreamingBash` shells out; on
  Windows only the bundled MSYS2 bash resolves (absent on CI). Inject git-bash
  via `cachedBash` in the test (production `resolveBash` unchanged).
- `tests/stream/test_netthread_blocks.nim` — `shutdownCachedStreamFd()` is a
  no-op on Windows (wraps `posix.shutdown` to wake blocking recv). The
  interrupt contract this test asserts is unimplemented cross-platform. Kept
  disabled with a PRECISE reason.

### Class D — real-subprocess PTY tests (18 files, the tty suite)

All 18 `tests/tty/test_*.nim` drive the real `3code` binary through a PTY via
`tests/tty_expect.nim`, which is POSIX-only (`openpty`/`fork`/`execv`/
`waitpid`/`kill`/`TIOCSWINSZ`). The windows-testing.md Option A path: port
`tty_expect.nim` to ConPTY behind `when defined(windows):`, keeping the
`TtySession` record and `expect*` API identical so test bodies need no changes.
The IPC pipes (`THREECODE_TEST_FRAME_FD` etc.) are already pipe-based and
cross-platform. This is the largest single piece (1192-line harness port).

## Current state

Steps 1-4 DONE and committed (branch `timing`). 8 of 9 non-tty
`disabled: "win"` files enabled via source/test adaptation
(test_session, test_update, test_util_extra, test_cli_args, test_minline,
test_history, test_api, test_streamexec). 1 remains precisely disabled:
test_netthread_blocks (the interrupt-wakes-blocking-recv path is POSIX-only;
shutdownCachedStreamFd is a no-op on Windows — a real source gap, documented).

Step 4 (ConPTY port of tty_expect.nim): the prior iteration's "PROVEN
WORKING" claim was WRONG — the diagnostic tests had no `check` assertions,
so a dead child produced a false PASS. This iteration built a hard-asserting
diagnostic (`tests/tty/test_conpty_diag.nim`) and a standalone smoke
(`tools/conpty_smoke.nim`) and drove ~30 CI round-trips to find THREE real
harness bugs, all now fixed and confirmed on the GHA windows runner
(Windows Server 2025, 10.0.26100):

1. lpValue for PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE (tty_expect.nim): the
   attribute was set with `cast[pointer](unsafeAddr hpc)` (generic pointer-
   to-value semantic). For THIS attribute UpdateProcThreadAttribute treats
   lpValue as the HPCON value itself (special case, per the MS sample).
   The wrong form produced a DEAD pseudoconsole attach: every child (even
   cmd.exe) died 0xC0000142 (STATUS_DLL_INIT_FAILED). Fix:
   `cast[pointer](hpc.Handle)`. Proven: a standalone smoke spawning cmd.exe
   `/c echo` with byValue saw 16 bytes exit 0; byAddr saw 0xC0000142.
2. readPtyChunk(0) never read (tty_expect.nim): `pollOnce` calls
   `readPtyChunk(0)` after PeekNamedPipe confirms bytes, but the loop
   `while epochTime() < deadline` with deadline=now was immediately false,
   so confirmed-available bytes were never read (raw stayed empty).
   Fix: run the body at least once (do-while).
3. ensureBash gated behind providerStub (src/threecode.nim): the stub binary
   hit `ensureBash()` which hard-fails ExitUsage (code 2) when bundled
   MSYS2 bash is absent (CI has none). Same gate as `initSandbox`.

Also: bInheritHandles=FALSE for the ConPTY child (matches MS sample; IPC
pipes are POSIX-gated in src/ so the Windows child doesn't use them), and
lpApplicationName=NULL (cmdline carries the program path).

OTHER CONFIRMED-NOT-THE-CAUSE (saves future round-trips): env block contents
(constructed vs NULL inherit — both fail identically), pipe inheritance flags,
console attach state (FreeConsole/AllocConsole), shell (bash/cmd/pwsh all
fail), DLL staging (smoke `./3code.exe -v` runs fine), alloc0 of the
attribute-list buffer, NAMED pipes + ConnectNamedPipe (node-pty pattern) —
ConnectNamedPipe blocks indefinitely even with the lpValue fix; the conhost
spawned by CreatePseudoConsole on Server 2025 does NOT connect to externally-
created named pipes. Anonymous pipes are the correct choice here.

REMAINING BLOCKER (precise, needs a Windows box): after the 3 fixes the child
process RUNS and EXITS CLEANLY (no 0xC0000142), but the ConPTY conhost only
relays its OWN init bytes (`\x1b[?9001h\x1b[?1004h` — bracketed-paste +
focus-reporting mode enables the conhost emits) to the output pipe. The
child's OWN stdout is never relayed — the harness captures only those 16
bytes even with a 10s drain after child exit. Confirmed for both `3code_stub
-v` (should echo version + exit) and `3code_stub -x -i` (should paint the
❯ prompt). Plain CreateProcessW (no ConPTY) relays stdout fine (the P probe
captured 10 bytes). So the ConPTY output channel is half-working: conhost→
pipe works, child-stdout→conhost→pipe does not. This is a Windows Server
2025 / conhost ConPTY quirk; node-pty ships its own conpty.dll + OpenConsole.exe
to avoid exactly this class of issue. Likely next steps for a Windows-local
investigator: try the InheritCursor flag, try CREATE_NEW_CONSOLE combined
with EXTENDED_STARTUPINFO_PRESENT, or ship a conpty.dll/OpenConsole pair.

`test_broken_stdout_exit.nim` was re-disabled with a precise reason: it
drives the binary via execCmdEx + bash + python3 (NOT the ConPTY harness)
and asserts POSIX broken-pipe semantics; python3 isn't guaranteed on the
Windows runner.

wip commits on branch timing (664ffce..08bf07f) contain the iteration.
windows.yml currently runs `testament cat tty` with DLL staging; revert to
`testament all` once the 0xC0000142 blocker is resolved. POSIX branch
verified green on linux throughout (8/8 test_quit_signals).

## Steps

- [x] 1. **Class A source fix: honor XDG on Windows.** DONE (006e20a).
- [x] 2. **Class B: platform-correct key bytes in the Driver.** DONE (97842b1).
      Implemented as a compile-time `when defined(windows)` split mirroring
      minline's KEYSEQS, not a runtime lookup (CritBitTree's `[]` doesn't
      resolve in the test module scope; the split keeps encoding obvious).
- [x] 3. **Class C: api + stream tests.** DONE (521f654, 15b0dab). test_api:
      platform-aware probe `.exe`. test_streamexec: git-bash injection via
      cachedBash (production resolveBash unchanged). test_netthread kept
      disabled with a precise reason (shutdownCachedStreamFd is a no-op on
      Windows).

- [x] 4. **Class D: ConPTY port of tty_expect.nim.** DONE (commits 91130c4,
      acff7d9). Full ConPTY lifecycle behind `when defined(windows):`, all
      blocking calls bounded, TtySession + expect*/send/resize/close
      identical, all 18 `disabled: "win"` removed. POSIX green on linux;
      Windows type-checks clean under --os:windows. Runtime correctness
      pending CI (`windows.yml`) — the child-side sync hooks are POSIX-gated
      in src/ so frame-event/ticker waits timeout (bounded) and tests settle
      via drain(); may surface timing assertions to iterate on.

- [ ] 5. **docs + workflow.** Update `docs/windows-testing.md` to reflect the
      new state (XDG honored, Driver KEYSEQS, ConPTY port). If the ConPTY port
      needs the windows.yml run to use categories-sequential like osx.yml did,
      adjust it. Final: `grep -rn 'disabled: "win"' tests/` returns only files
      with a concrete, documented, irreducible blocker.

## Notes

- Verification gate is CI (windows.yml) for Windows-correctness, same model as
  the OSX work used osx.yml. Linux correctness verified locally each step.
- The XDG-on-Windows source change mirrors the macOS XDG change (b7ea0f0) in
  both shape and rationale — it's the established pattern in this codebase.
- Commit per step. Short one-line messages. Do NOT push or merge to main
  (release-level action per ~/p/3CODE.md).
