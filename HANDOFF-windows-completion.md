# HANDOFF: Windows ConPTY tty-test completion (branch `timing`)

This is a self-contained handoff for the **next agent** to finish Step 4
(re-enable the 18 Windows-disabled tty tests). The hard part is DONE and
VERIFIED on a real Windows box. Read `cybernetic-plan.md` "Current state" for
full history. This file is the operational guide.

## TL;DR — where things stand

The ConPTY harness **works end-to-end on Windows**. Verified locally on
`ssh beck` (Windows 10.0.26200, Nim 2.2.10): `test_quit_signals.nim` now passes
**6/8** tests (was 0/8 — every child died `0xC0000142`). The remaining 2
failures are timing-sensitive interrupt-during-turn tests, NOT harness bugs.
Several other tty tests also pass (test_no_config_bootstrap, test_empty_enter_freeze
pass fully; test_pause_no_indicator passes 1/2).

The breakthrough fix (committed `874e9ef`, pushed to `origin/timing`): the ConPTY
child must be spawned with `STARTF_USESTDHANDLES` + all three std handles set to
`INVALID_HANDLE_VALUE`, otherwise the child inherits the *parent's console*
handles (console handles bypass `bInheritHandles=FALSE`), its stdout lands on the
parent console, and the conhost only relays its own init bytes — never the child's
output.

## The Windows box: `ssh beck`

`ssh beck` drops into **PowerShell 5.1** on Windows 10.0.26200. Already set up
this session (these are done — verify with the checks below):

- **Nim 2.2.10** at `C:\Users\Quickemu\.nimble\bin\nim.exe` (matches CI).
- **Git 2.55** installed via winget (was absent): `C:\Program Files\Git\`.
- **Repo cloned** to `C:\Users\Quickemu\p\3code` via tarball (no git originally).
- **nimble deps installed** (`ttty`, `unicodedb`, `streamhttp`, `tinotify`, `nimbox`).
- **OpenSSL DLLs staged**: `libssl-1_1-x64.dll`, `libcrypto-1_1-x64.dll`,
  `cacert.pem` copied to repo root AND `build/` (from nim-lang.org/download/dlls.zip).
- **Stub binary built** at `build/3code_stub.exe` (rebuilt after each src change).

**Important:** every `ssh beck '<cmd>'` must prepend git to PATH:
`$env:PATH = "C:\Program Files\Git\cmd;C:\Program Files\Git\bin;$env:PATH"`

Re-clone if needed (no git was originally present):
```powershell
cd $env:USERPROFILE; mkdir p -ErrorAction SilentlyContinue; cd p
curl.exe -sL https://github.com/capocasa/3code/archive/refs/heads/timing.tar.gz -o 3code.tgz
tar xf 3code.tgz; mv 3code-timing 3code; cd 3code
# PATH for git (nimble deps need it):
$env:PATH = "C:\Program Files\Git\cmd;C:\Program Files\Git\bin;$env:PATH"
nimble install -y --depsOnly
# Stage DLLs + build stub (see "Iteration loop" below)
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
# Or via testament (matches CI exactly):
testament --print --megatest:off r tests/tty/test_quit_signals.nim
```

**Keep `build/3code_stub.exe` built.** `ensureStubBinary()` (tests/stub_helpers.nim)
reuses it if present + not stale; if you edit src/ it rebuilds (slow ~25s). Pre-building
avoids surprises.

## The 6 fixes that made it work (all committed, do NOT re-litigate)

1. **`STARTF_USESTDHANDLES` + INVALID std handles** — `tests/tty_expect.nim:606`.
   THE relay fix. Without it the child inherits the parent console and conhost
   never relays stdout. `dwFlags: 0x100`, `hStdInput/hStdOutput/hStdError: Handle(-1)`.
2. **`lpValue = cast[pointer](hpc.Handle)`** — `tests/tty_expect.nim:596`. The HPCON
   *value* (not `unsafeAddr hpc`). Wrong form = dead pseudoconsole = 0xC0000142.
3. **`configPath() = userConfigRoot() / "config"`** — `src/threecode/config.nim:330`.
   Was raw `getConfigDir()` which ignores `XDG_CONFIG_HOME` on Windows; the Class A
   XDG fix only updated `userConfigRoot`, not the actual config-loading path. Without
   this the stub can't find test config → provider wizard instead of `❯` prompt.
4. **`readPtyChunk` do-while** — `tests/tty_expect.nim:290`. `pollOnce` calls it with
   `waitMs=0`; the old `while epochTime() < deadline` was immediately false.
5. **`ensureBash` gated behind `providerStub`** — `src/threecode.nim:89`. Stub exited
   `ExitUsage` (2) with no bundled MSYS2 on CI/local. Same gate as `initSandbox`.
6. **`bInheritHandles=FALSE`, non-inheritable pipes, `lpApplicationName=NULL`** —
   `tests/tty_expect.nim` newTtySession. Matches the MS CreatePseudoConsole sample.

POSIX stays green throughout: `nim c -r --path:src --path:tests tests/tty/test_quit_signals.nim` = 8 OK.

## THE REMAINING WORK (your job)

### A. The 2 interrupt-test failures (primary)

`test_quit_signals.nim` tests "Ctrl-D during an active turn interrupts" and
"Ctrl-C interrupt then Ctrl-D quits" both fail: `expectInHistory "interrupted by user"`
not found. The test types "go\n", drains 400ms (turn should be active in the 4s
`slowResponses` pre-stream delay), sends `\x04` (Ctrl-D), expects the magenta
"interrupted by user" line.

Observed on beck: the frames stop at `❯ go` (~199ms) — the `\n` submit and spinner
aren't captured, suggesting either (a) the turn didn't visibly start within the
drain window, or (b) Ctrl-D during a turn isn't routed to the interrupt path on
Windows the way it is on POSIX. Investigate:
- Is the `\n` submit reaching the child? (the 5 passing quit tests send `\n` fine,
  so input works — but those submit `:q`, not a turn).
- Does Ctrl-D (`\x04`) during `inputTurnActive` call `requestTurnInterrupt` on
  Windows? Check `src/threecode/minline.nim` ESCAPES/KEYSEQS and the turn-interrupt
  wiring in `src/threecode/turns.nim` (`onTurnInterrupted` at line 36).
- The child-side sync hooks (`emitTestFrameEvent`/`waitForTestContinue`) are
  POSIX-gated in `src/` (`when defined(posix)`), so frame-event/ticker waits timeout
  (bounded) and the harness settles via `drain()` polling — this may shift timing
  enough that the 400ms drain misses the turn start. Try increasing the drain or
  making the interrupt wait more tolerant.

### B. Run the full `testament cat tty` on beck

Get the complete pass/fail landscape. **Caveat:** running the full category in one
`ssh beck` call times out (each test compiles ~20s + runs with bounded waits).
Run it detached and poll, or run tests in batches:
```powershell
testament --print --megatest:off cat tty *> tty_results.txt   # detached, then poll the file
```
Expected: many pass, several have 1-2 timing-sensitive sub-test failures (same
class as A). Some may need tolerance tweaks in the test or harness `expect`/`drain`.

### C. `test_tty_functional.nim` compile error under testament

Compiles fine with `nim c --os:windows --path:src --path:tests` directly, but
under `testament r` it fails at the gcc link step with `-Wl,-Bstatic -lpthread`
(a POSIX flag leaking into the Windows link line). The file HAS proper
`when defined(posix):` / `else:` gates for `hardKillAndWait`/`discardClose`
(test_tty_functional.nim:114-157). The `-lpthread` comes from somewhere in
testament's compile invocation or a transitive dep (osproc?). Reproduce:
`testament --print --megatest:off r tests/tty/test_tty_functional.nim` and inspect
the exact gcc command testament emits. Likely a testament/nimblePath config issue.

### D. Finish + ship

1. Once `testament cat tty` is green (or failures are documented timing-tolerances),
   revert `.github/workflows/windows.yml` `Run tests` step from diagnostic mode to
   `testament --print --megatest:off cat tty`, then to `testament all`.
2. Trigger CI: `gh workflow run windows.yml --ref timing` (from a machine with gh);
   poll `gh run view <id> --json status,conclusion`; logs `gh run view --log <id>`.
   **beck reproduces CI's Server-2025 behavior exactly** (verified: same 16-byte
   conhost-only symptom before the fix), so CI should match local results.
3. Update `docs/windows-testing.md` and `cybernetic-plan.md` "Current state".
4. Final check: `grep -rn 'disabled: "win"' tests/` returns only files with a
   concrete documented irreducible blocker: `test_broken_stdout_exit.nim`
   (execCmdEx+bash+python3+POSIX-pipe), `test_netthread_blocks.nim`
   (shutdownCachedFd is a no-op on Windows), and `test_tty_functional.nim`
   (disabled:"osx" only — it's a macOS-threading hang, NOT windows).
5. **Squash** the ~30 `wip:` diagnostic commits before merge (keep the named fix
   commits). Do NOT push or merge to `main` (release-level action per ~/p/3CODE.md).

## Key files

- `tests/tty_expect.nim` (~1630 lines) — the harness. Windows branch:
  `pipeBytesAvail`/`readPtyChunk`/`pollOnce` ~270-400; `newTtySession` ConPTY
  setup ~520-710 (the fixes are here); `expect` post-exit drain ~1310-1335;
  `expectInHistory` ~1386; `close` ~1490-1570.
- `tools/conpty_smoke.nim` — standalone ConPTY smoke (fastest isolated probe;
  HEAD is the named-pipe variant that blocks — revert to anonymous-pipe byValue
  from commit `e8be14c` if you want the proven probe).
- `tests/tty/test_conpty_diag.nim` — in-harness diagnostic (tests P/B/C).
- `src/threecode.nim:89` — `ensureBash` gate. `src/threecode/config.nim:330` — configPath.
- `tests/stub_helpers.nim` — `ensureStubBinary` (builds the stub).
- `.github/workflows/windows.yml` — CI (diagnostic mode now).
- `cybernetic-plan.md` — source of truth (update as you go).

## Constraints

- `tests/api/test_api.nim` fails under testament (pre-existing streamhttp 0.4.4
  drift) — NOT your problem.
- Commit per coherent step. Push to `origin timing` only.
- `ssh beck` emits a post-quantum warning each time — harmless.
- Non-interactive `ssh beck '<ps>'` works; use PowerShell syntax (`foreach` not
  `for...in`; `$env:VAR` not `$VAR`).

## What "done" looks like

`testament cat tty` green on Windows CI (or remaining failures are precisely
documented timing-tolerances, not harness bugs), `windows.yml` back on
`testament all`, and `grep -rn 'disabled: "win"' tests/` returns only the
documented irreducible blockers.
