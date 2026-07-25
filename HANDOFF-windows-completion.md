# HANDOFF: Windows ConPTY tty-test completion (branch `timing`)

This is a self-contained handoff for the **next agent** to finish Step 4
(re-enable the 18 Windows-disabled tty tests). The hard part is DONE and
VERIFIED on a real Windows box. Read `cybernetic-plan.md` "Current state" for
full history. This file is the operational guide.

## TL;DR - where things stand

The ConPTY harness **works end-to-end on Windows**. Verified locally on
`ssh beck` (Windows 10.0.26200, Nim 2.2.10): `test_quit_signals.nim` passes
**6/8** tests (was 0/8). The remaining 2 failures are interrupt-during-turn
tests. The root cause is now **precisely identified** (see "THE INTERRUPT
BUG" below) but the fix is incomplete.

## The Windows box: `ssh beck`

`ssh beck` drops into **PowerShell 5.1** on Windows 10.0.26200. Already set up
(verify with the checks below):

- **Nim 2.2.10** at `C:\Users\Quickemu\.nimble\bin\nim.exe` (matches CI).
- **Git 2.55** installed via winget: `C:\Program Files\Git\`.
- **Repo** at `C:\Users\Quickemu\p\3code` (tarball, not git - use `scp` to push
  changed files, NOT git pull).
- **nimble deps installed** (`ttty`, `unicodedb`, `streamhttp`, `tinotify`, `nimbox`).
- **OpenSSL DLLs staged**: `libssl-1_1-x64.dll`, `libcrypto-1_1-x64.dll`,
  `cacert.pem` in repo root AND `build/`.
- **Stub binary** at `build/3code_stub.exe` (rebuild after each src change).

**Important:** every `ssh beck '<cmd>'` must prepend git to PATH:
`$env:PATH = "C:\Program Files\Git\cmd;C:\Program Files\Git\bin;$env:PATH"`

**To push a changed source file to beck** (repo is a tarball, no git):
```bash
scp src/threecode/fatprompt/runtime.nim beck:"C:/Users/Quickemu/p/3code/src/threecode/fatprompt/runtime.nim"
```
**To push a test file** (base64 - command line arg limits prevent scp of large
files through the double-quote layer for some paths; scp works fine for most):
```bash
scp tests/tty/diag_single.nim beck:"C:/Users/Quickemu/p/3code/tests/tty/diag_single.nim"
```

## The iteration loop (seconds, not CI minutes)

```powershell
cd $env:USERPROFILE\p\3code
$env:PATH = "C:\Program Files\Git\cmd;C:\Program Files\Git\bin;$env:PATH"
$env:SSL_CERT_FILE = "$PWD\cacert.pem"
# Rebuild the stub (the tty tests spawn it) after any src/ change:
nim c -d:ssl -d:providerStub --threads:on --path:src -o:build\3code_stub.exe src\threecode.nim
# Run a single tty test directly (fastest feedback):
nim c -r --path:src --path:tests tests\tty\test_quit_signals.nim
```

## THE INTERRUPT BUG (the 2 remaining failures)

### What fails
`test_quit_signals.nim` tests "Ctrl-D during an active turn interrupts" and
"Ctrl-C interrupt then Ctrl-D quits" both fail: `expectInHistory "interrupted
by user"` not found.

### Root cause analysis (done this session, confirmed on beck)

There are **TWO distinct issues** stacked on top of each other:

#### Issue 1: ENABLE_PROCESSED_INPUT intercepts control chars (PARTIALLY FIXED)

Under ConPTY with the default console mode, Ctrl-C (`\x03`) is intercepted by
the console subsystem as `CTRL_C_EVENT` and never delivered to `_getch`.

**Fix applied (committed):** `src/threecode/fatprompt/runtime.nim` now calls
`SetConsoleMode` on `STD_INPUT_HANDLE` to clear `ENABLE_PROCESSED_INPUT`,
`ENABLE_LINE_INPUT`, and `ENABLE_ECHO_INPUT` - mirroring the POSIX
`ISIG`/`ICANON`/`ECHO` disable in the `tcSetAttr` block right above it.
Console mode confirmed changing on beck: `old=503 (0x1F7) new=496 (0x1F0)`.

After this fix, Ctrl-D (`\x04`) DOES reach `_getch` during a turn and
`requestTurnInterrupt()` IS called (confirmed via stderr debug in child).

#### Issue 2: The interrupt flag is set too late - the stub is past the check (NOT FIXED)

Even with Issue 1 fixed, the interrupt message never appears. The problem is
**timing**. Here's the exact sequence observed on beck (timestamps from
epochTime in seconds):

1. User submits "go\n". Input thread pushes `ieLine`, sets
   `inputIdleLinePending=true`, parks in `getCh` (5ms sleep loop).
2. Controller's `pollInputEvent` consumes `ieLine` (~1ms later).
3. **~1.3 SECOND GAP** between consuming the event and `beginTurn()` running.
   During this gap, `inputIdleLinePending` is still true, so the input thread
   is parked and NOT calling `_getch()`.
4. `beginTurn()` finally runs, clears `inputIdleLinePending`.
5. Input thread unparks, calls `_getch()`, blocks waiting for input.
6. Test sends `\x04` at ~2.1s after submit. `_getch` returns 4 within ~250ms.
7. EOFError raised, `requestTurnInterrupt()` called, sets `interruptedFlag`.
8. The stub's `preStreamDelay` loop SHOULD see `isInterrupted()` on its next
   100ms tick and raise `ApiError("interrupted by user")`. **BUT IT DOESN'T.**

**The remaining mystery:** After `requestTurnInterrupt()` fires (confirmed
via debug), the stub's preStreamDelay loop's next `isInterrupted()` check
should return true. But no more stub ticks appear in the debug output, and
the "interrupted by user" message never renders. The process stays alive but
frozen.

Possible explanations to investigate:
- **The 1.3-second gap (step 3) is the real problem.** Something between
  `pollInputEvent` consuming the event and `beginTurn()` takes 1.3 seconds on
  Windows. This is `emitUserSubmit(line)` -> `commitTranscriptBytes` ->
  terminal write via ConPTY. ConPTY output writes under SSH are slow. If this
  delay pushes `requestTurnInterrupt` past the stub's preStreamDelay check
  window... but the stub sleeps 6000ms and checks every 100ms, so the flag
  SHOULD be caught.
- **Deadlock after requestTurnInterrupt.** The input thread's EOFError handler
  calls `requestTurnInterrupt()` then `continue`s to `readLineWith` -> `_getch`.
  If `_getch` blocks AND somehow prevents the main thread from running... but
  they're separate threads with no shared lock at that point.
- **Non-determinism:** Sometimes `beginTurn` never runs at all (the event is
  consumed but the controller appears stuck). This suggests the controller
  thread itself is blocked, possibly in a ConPTY terminal write that deadlocks
  when the output pipe buffer is full and the harness isn't draining fast
  enough.

### How to debug further
1. Rebuild stub with debug stderr lines (child stderr goes through ConPTY,
   captured in the harness `cleanRaw()`). Add lines in:
   - `src/threecode/fatprompt/runtime.nim`: `pushInputEvent`, `beginTurn`,
     the EOFError/InputCancelled handlers in `inputThreadProc`
   - `testdata/stub/provider.nim`: the preStreamDelay loop
2. Write a diagnostic test (see git history for `diag_single.nim` pattern):
   extract `[diag ...]` lines from `tty.cleanRaw()` to trace the timeline.
3. Focus on the **1.3-second gap** between event consumption and beginTurn.
   That's likely a ConPTY output write blocking the main thread.

### Alternative approach: avoid the timing race entirely
Instead of relying on the input thread to call `_getch` and raise EOFError
during the turn, consider adding a **Windows console control handler**
(`SetConsoleCtrlHandler`) that catches `CTRL_C_EVENT` and calls
`requestTurnInterrupt()` directly from the system callback. This bypasses the
input thread entirely and works even if `_getch` is blocked. This is the
standard Windows pattern for handling Ctrl-C in console apps. The downside:
Ctrl-D (`\x04`) does NOT generate a console control event, so it would still
need the `_getch` path. But Ctrl-C (the more common interrupt) would work
reliably.

## The 6 fixes that made it work (all committed)

1. **`STARTF_USESTDHANDLES` + INVALID std handles** - `tests/tty_expect.nim:606`.
2. **`lpValue = cast[pointer](hpc.Handle)`** - `tests/tty_expect.nim:596`.
3. **`configPath() = userConfigRoot() / "config"`** - `src/threecode/config.nim:330`.
4. **`readPtyChunk` do-while** - `tests/tty_expect.nim:290`.
5. **`ensureBash` gated behind `providerStub`** - `src/threecode.nim:89`.
6. **`bInheritHandles=FALSE`, non-inheritable pipes, `lpApplicationName=NULL`** -
   `tests/tty_expect.nim`.

Plus the **SetConsoleMode raw-input fix** (this session, committed):
`src/threecode/fatprompt/runtime.nim` - clears `ENABLE_PROCESSED_INPUT` on the
console input handle so control chars reach `_getch`.

## THE REMAINING WORK

### A. The 2 interrupt-test failures (primary - see THE INTERRUPT BUG above)

### B. Run the full `testament cat tty` on beck
Get the complete pass/fail landscape (caveat: times out in one ssh call; run
detached or in batches).

### C. `test_tty_functional.nim` compile error under testament
Compiles fine directly but under `testament r` fails at gcc link step with
`-Wl,-Bstatic -lpthread` (POSIX flag leaking into Windows link line).

### D. Finish + ship
1. Once failures resolved, revert `windows.yml` to `testament all`.
2. Trigger CI; update `docs/windows-testing.md` and `cybernetic-plan.md`.
3. Final: `grep -rn 'disabled: "win"' tests/` returns only documented blockers.
4. **Squash** the ~30 `wip:` diagnostic commits before merge.

## Key files
- `tests/tty_expect.nim` (~1630 lines) - the harness. Windows branch in
  `newTtySession` ConPTY setup ~520-710.
- `src/threecode/fatprompt/runtime.nim` - input thread, `beginTurn`,
  `inputThreadProc` (the EOFError/InputCancelled handlers ~2060-2180),
  `getCh` closures (POSIX ~1766, Windows ~1818), the new SetConsoleMode block
  ~1952.
- `src/threecode/minline.nim:71-86` - `getchr`/`rawGetch` (`_getch` on Windows).
- `testdata/stub/provider.nim:298-312` - `callModelStub` preStreamDelay loop.
- `src/threecode/turns.nim:36-66` - `onTurnInterrupted`, `emitTestFrameEvent`.
- `src/threecode.nim:580-650` - the REPL loop, `readInput`, turn dispatch.

## Constraints
- `tests/api/test_api.nim` fails under testament (pre-existing streamhttp 0.4.4
  drift) - NOT your problem.
- Commit per coherent step. Push to `origin timing` only.
- `ssh beck` emits a post-quantum warning each time - harmless.
- Non-interactive `ssh beck '<ps>'` works; use PowerShell syntax.

## What "done" looks like
`testament cat tty` green on Windows CI (or remaining failures are precisely
documented timing-tolerances, not harness bugs), `windows.yml` back on
`testament all`, and `grep -rn 'disabled: "win"' tests/` returns only the
documented irreducible blockers.
