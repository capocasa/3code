# HANDOFF: Windows ConPTY tty-test completion (branch `timing`)

This is a precise, actionable handoff for completing Step 4 (re-enable the 18
Windows-disabled tty tests) of the "re-enable Windows-disabled tests" task.
Read `cybernetic-plan.md` "Current state" for full history; this file is the
operational guide.

## You have a Windows box: `ssh beck`

`ssh beck` drops into **PowerShell 5.1** on Windows 10.0.26200 (a *newer* build
than CI's Server 2025 / 26100 — relevant: if ConPTY works there but not on CI,
the bug is runner-image-specific). Tools available on beck:

- **Nim 2.2.10** (`C:\Users\Quickemu\.nimble\bin\nim.exe`) — matches CI.
- **nimble 0.22.2**, **gcc (mingw)** via nimble's toolchain.
- **curl.exe**, internet works (GitHub API returns 200).
- **NO git, NO gh.** Clone via tarball (see setup below).
- Repo not present yet (`~/p/3code` does not exist). 40 GB free on C:.

This is the decisive advantage the prior iterations lacked: you can iterate in
seconds, not 2-min CI round-trips, and attach a debugger.

## What's DONE and verified (do NOT re-litigate)

Three real bugs were found and fixed this iteration, each **confirmed via CI**
on the GHA windows runner:

1. **`lpValue` for `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`** —
   `tests/tty_expect.nim:~610`. Must be `cast[pointer](hpc.Handle)` (the HPCON
   **value**), NOT `cast[pointer](unsafeAddr hpc)` (pointer-to-the-variable).
   `UpdateProcThreadAttribute` treats this attribute as a special case: lpValue
   IS the value. The wrong form attached a *dead* pseudoconsole → every child
   died `0xC0000142` (STATUS_DLL_INIT_FAILED), even `cmd.exe`. **Proven:** a
   standalone smoke spawning `cmd.exe /c echo` with `byValue` captured output
   exit 0; with `byAddr` got `0xC0000142`. (This was masked for a long time
   because the prior iteration's "PROVEN WORKING" diagnostics had no `check`
   assertions — dead children falsely passed.)

2. **`readPtyChunk(0)` never read** — `tests/tty_expect.nim:~290`.
   `pollOnce` calls `readPtyChunk(0)` after PeekNamedPipe confirms bytes are
   available, but the loop `while epochTime() < deadline` with `deadline=now`
   was immediately false, so confirmed-available bytes were never read (raw
   stayed empty). Fixed to a do-while (body runs at least once).

3. **`ensureBash` gated behind `providerStub`** — `src/threecode.nim:89`.
   The stub binary hit `ensureBash()`, which hard-fails `ExitUsage` (code 2)
   when bundled MSYS2 bash is absent (CI has none). Now gated
   `when defined(windows) and not defined(providerStub):` — same gate as
   `initSandbox` (line 109). The stub tty tests drive REPL rendering, not bash
   enforcement; bash enforcement is covered by the cli_args `box` suite.

Also in place: `bInheritHandles=FALSE`, `lpApplicationName=NULL` (cmdline
carries the program path), non-inheritable pipes (`bInheritHandle=0`),
env-empty→NULL `lpEnvironment`, and a post-exit drain in `expect` (conhost
lags the child).

POSIX is green throughout: `nim c -r --path:src --path:tests tests/tty/test_quit_signals.nim` = 8 OK. Windows branch type-checks clean: `nim check --os:windows --path:src --path:tests tests/tty_expect.nim`.

## THE REMAINING BLOCKER (your job)

After the 3 fixes, the child process **runs and exits cleanly** (no more
`0xC0000142`, no more exit 2). But the ConPTY conhost only relays **its own**
init bytes to the output pipe — never the child's own stdout.

Specifically, the harness captures exactly 16 bytes:
`\x1b[?9001h\x1b[?1004h` (bracketed-paste + focus-reporting mode enables —
emitted by the conhost, NOT by 3code/3code_stub source; grep confirms neither
is in `src/` nor in ttty/nimbox). The child's actual output (the `❯` prompt
for `3code_stub -x -i`, or the version string for `3code_stub -v`) never
appears, even with a 10s drain after child exit.

Key diagnostic facts (all confirmed on CI):
- Plain `CreateProcessW` (no ConPTY) relays stdout fine — the "P" probe in
  `tests/tty/test_conpty_diag.nim` captured 10 bytes, exit 0. So process
  creation + stdout capture works; only the ConPTY relay is broken.
- Conhost→pipe works (the 16 mode bytes arrive). Child-stdout→conhost→pipe does not.
- Sending input to the child (`tty.send("hi")`) does not prime the relay.

### Confirmed NOT the cause (saves you time)
Env block contents (constructed vs NULL inherit — identical), pipe inheritance
flags, console attach state (FreeConsole/AllocConsole), shell (bash/cmd/pwsh),
DLL staging (`./3code.exe -v` runs standalone), `alloc0` of the attribute-list
buffer, NAMED pipes + ConnectNamedPipe (node-pty pattern — ConnectNamedPipe
blocks indefinitely even with the lpValue fix; the Server-2025 conhost does
not connect to externally-created named pipes).

## Setup on beck (one-time)

```powershell
# No git on beck — clone via tarball.
cd $env:USERPROFILE
mkdir p; cd p
curl.exe -L https://github.com/capocasa/3code/archive/refs/heads/timing.tar.gz -o 3code.tar.gz
tar xf 3code.tar.gz        # built-in bsdtar on Win10+
mv 3code-timing 3code
cd 3code
# Install nimble deps (ttty, unicodedb, streamhttp, tinotify, nimbox).
nimble install -y --depsOnly
```

If `tar` is missing, use `Expand-Archive` after fetching a zip:
`curl.exe -L https://github.com/capocasa/3code/archive/refs/heads/timing.zip -o 3code.zip; Expand-Archive 3code.zip`.

## The fastest iteration loop on beck

The standalone smoke (`tools/conpty_smoke.nim`) is the tightest loop — it
spawns `cmd.exe /c echo` under ConPTY and prints exactly what it captures. No
testament, no full build. Currently it's set to the named-pipe variant (which
blocks); **revert it to the anonymous-pipe byValue version first** (see
`tools/conpty_smoke.nim` history; the `attempt("byValue", false)` version at
commit `e8be14c` is the proven-byValue smoke — `git show e8be14c:tools/conpty_smoke.nim`).

```powershell
cd $env:USERPROFILE\p\3code
nim c -o:conpty_smoke.exe tools\conpty_smoke.nim
.\conpty_smoke.exe
```

The smoke should print `child output: [conpty_ok]` and `child exit=0` if the
relay works. Right now it only shows the 16 conhost mode bytes. **Your goal:
make the smoke see cmd.exe's actual echo output.** Once the smoke relays child
stdout, the harness (`tests/tty_expect.nim`) will too (same read path), and
`test_conpty_diag.nim` test C (`expect "\u276f"`) will pass.

Run the harness diag next:
```powershell
nim c -r --path:src --path:tests tests\tty\test_conpty_diag.nim
```

## The most promising leads to try (in order)

1. **Does ConPTY work at all on beck's build (26200)?** Run the smoke first. If
   it relays child stdout on beck but not on CI, the bug is Server-2025-image-
   specific and you may need a conhost/OpenConsole workaround only for CI. If it
   fails on beck too, you can debug it live.

2. **`STARTF_USESTDHANDLES`?** The MS EchoCon sample does NOT set it for
   ConPTY. But some reports indicate setting `dwFlags = STARTF_USESTDHANDLES`
   with `hStdOutput`/`hStdError` pointed at... nothing, OR at the output pipe,
   forces conhost to relay. Worth a quick try in the smoke. (The plain-P probe
   in the diag DOES use STARTF_USESTDHANDLES and captures stdout — but that's
   not ConPTY.)

3. **The conhost may need the INPUT channel serviced to avoid deadlock.** The
   MS doc warns: "Servicing all of the pseudoconsole activities on the same
   thread may result in a deadlock." The harness reads output on the same
   thread that would write input. Try: spawn a thread that continuously drains
   `pttyOutRead` (ReadFile in a loop) right after CreatePseudoConsole, BEFORE
   CreateProcessW, so the conhost's output is always being consumed. (This is
   how the EchoCon sample structures it — a `PipeListener` thread.)

4. **Ship `conpty.dll` + `OpenConsole.exe`** from the Windows Terminal project
   (this is what node-pty does to avoid system-conhost quirks). node-pty's
   `LoadConptyDll` loads a bundled `conpty\conpty.dll` and calls
   `ConptyCreatePseudoConsole` instead of the kernel32
   `CreatePseudoConsole`. The conhost it spawns is the bundled `OpenConsole.exe`,
   not the system one. This is the heavy-hammer fix if leads 1-3 fail. Source:
   `microsoft/terminal` repo, `src/win/conpty.dll` build + the
   `OpenConsole.exe` artifact.

5. **`PSEUDOCONSOLE_INHERIT_CURSOR` flag** (0x1) as the 4th arg to
   `CreatePseudoConsole`. Unlikely but cheap to try.

6. **Debugger:** attach to the spawned `conhost.exe` (child of the smoke
   process) and trace why it isn't reading the child's console output. Or use
   `Process Monitor` to see the conhost's handle activity.

## Files you'll touch

- `tests/tty_expect.nim` (~1627 lines) — the harness. Windows branch:
  `pipeBytesAvail`/`readPtyChunk`/`pollOnce` ~lines 270-400;
  `newTtySession` ConPTY setup ~lines 520-710; `close` ~1490-1570;
  `expect` post-exit drain ~1310-1330.
- `tools/conpty_smoke.nim` — standalone smoke (fastest iteration).
- `tests/tty/test_conpty_diag.nim` — in-harness diagnostic (tests P/A0/A/B/C).
- `src/threecode.nim:89` — `ensureBash` gate (already done).
- `tests/stub_helpers.nim` — `ensureStubBinary` (builds the stub).
- `.github/workflows/windows.yml` — CI; currently runs only the diag in
  diagnostic mode. **Revert `Run tests` to `testament --print --megatest:off cat tty` once green**, then to `testament all`.
- `cybernetic-plan.md` — source of truth; **update "Current state" as you go.**

## Once the relay works

1. `test_conpty_diag.nim` test C (`expect "\u276f"`) passes.
2. Run the real test: `testament r tests/tty/test_quit_signals.nim` (or
   `nim c -r --path:src --path:tests tests/tty/test_quit_signals.nim`).
3. Run the full category: `testament cat tty`. Expect some timing-sensitive
   failures (child-side sync hooks `emitTestFrameEvent`/`waitForTestContinue`
   are POSIX-gated in `src/`; frame-event/ticker waits timeout bounded and
   tests settle via `drain()` — some may need tolerance tweaks).
4. Revert `.github/workflows/windows.yml` `Run tests` to `testament all`.
5. Update `docs/windows-testing.md`.
6. Final: `grep -rn 'disabled: "win"' tests/` returns only files with a
   concrete, documented, irreducible blocker (`test_broken_stdout_exit.nim` —
   execCmdEx+bash+python3+POSIX-pipe; `test_netthread_blocks.nim` —
   shutdownCachedFd is a no-op on Windows).
7. There are ~30 wip commits on the branch; consider squashing the diagnostic
   wip commits before merge (keep the 3 real fix commits distinct).

## Constraints (from the task)

- Do NOT push or merge to `main` (release-level action per `~/p/3CODE.md`).
- Commit per coherent step. Short one-line messages.
- `tests/api/test_api.nim` fails under testament (pre-existing streamhttp 0.4.4
  drift) — NOT your problem.
- Push to `origin timing`; CI gate is `gh workflow run windows.yml --ref timing`
  (but you now have beck, so prefer local iteration).

## SSH note

`ssh beck` emits a post-quantum warning each time — harmless. Non-interactive
`ssh beck '<ps command>'` works. For an interactive session, just `ssh beck`.
