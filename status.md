# Status: Windows sandbox (dedicated-user backend) - mid-task handoff

Goal: **a working sandwall on Windows.** Current state: fs sandbox +
net fence verified working in *ssh session 0* contexts; the spawn of
sandboxed children **stalls in interactive (session 1) contexts**.
Everything below is verified-on-hardware evidence, not theory.

## Repos / binaries

- `~/p/sandwall` main @ 13a0ee1 (uncommitted: none). sandwall 0.4.0
  tagged/released earlier; the new commits are not released.
- `~/p/3code/windows` branch windows @ 7120e2b (uncommitted: none,
  `3code-linux` untracked build artifact).
- Cross-build (from `~/p/3code/windows`):
  `nim c -o:3code.exe --os:windows --cpu:amd64 --opt:none --debugger:native --gcc.exe:x86_64-w64-mingw32-gcc --gcc.linkerexe:x86_64-w64-mingw32-gcc src/threecode.nim`
  and for sandwall: same flags, `src/sandwall.nim`, out `sandwall.exe`.
- Deploy: `scp 3code.exe beck:'C:\Users\Quickemu\3code.exe'`. The
  deployed binary must get `icacls ... /grant sandwall:(RX)` after
  every deploy (scp replaces the file, grants don't survive).

## Beck (Windows 11 quickemu VM)

- Admin user **Quickemu** (ssh works, askpass recipe in the old plan
  files). NEW: non-admin user **carlo / carlo** (untested, first task
  should use it - closest to a real 3code user).
- `schtasks` gotcha that burned a whole afternoon: by default tasks
  run in **session 0**. `/it` runs them in session 1 (interactive)
  but NOT necessarily with a visible console. When validating, always
  print `$PID -> (Get-Process -Id $PID).SessionId` first.
- Procdump at `C:\Users\Quickemu\pd\procdump64.exe` (may be cleaned);
  dumps parse locally with `/tmp/mdvenv/bin/python` + `minidump`
  package (recreate venv if gone).

## What works (verified)

- ACL fs sandbox as the `sandwall` user: home/C: writes denied,
  writable-root writes allowed, deny-narrowing + rollback.
- WFP fence: `3code setup` (idempotent now) creates user + 8 filters;
  wfp-probe as the sandwall user is blocked off-loopback.
- The **54s-stall fix**: `acl.hasSidAce` pre-check skips redundant
  ancestor traverse stamps (NTFS subtree walk). restrict: 26s -> 0.27s.
- CLI: `3code setup` / `3code unsetup` (Windows-only), `wall` is an
  internal undocumented subcommand, bash tool now routes through
  `sandbox restrict` + wall proxy env (code in streamexec.nim).
- Wall proxy compiles on Windows (WSAPoll portability layer) and is
  exported from sandwall/wall.nim now.
- msys2 bash, cmd, whoami all ran fine as a sandbox user **when the
  CPLW parent was a tiny standalone helper (cplw.exe) from elevated
  ssh session 0** (old plan notes, 0.4.0-era validation).

## The blocker (read this twice)

`spawnSandboxed` (rtoken.nim) uses CreateProcessWithLogonW (C shim
`csrc/spawn_shim.c`) to run the child as the `sandwall` user. In
interactive-session contexts the child **stalls at loader init**:
single thread, 2-16 modules loaded, blocked `ntdll+0xd1d08` (past the
last named export), wait reason **LpcReply** - waiting on a CSRSS/
console ALPC reply that never comes. Sometimes the child dies with
0xC0000142 instead. Exhausted matrix (all on beck):

- console vs GUI-subsystem child: both stall/die
- lpDesktop = winsta0\default vs NULL vs private station+desktop
  (private station created in the shim, Everyone DACL): all stall
- flags 0 / CREATE_NO_WINDOW / DETACHED_PROCESS (CPLW rejects
  DETACHED with 87/183)
- with/without our KILL_ON_JOB_CLOSE Job assign
- schtasks session 0 vs session 1 (`/it`) vs `/rl HIGHEST`
- sandwall user in no groups vs added to Users
- window station + desktop ACL grants on session-1's winsta0
  (grantws.exe helper, rc=0) - still stalls
- a stdio-relay hop (`3code wall stdio-relay`, sandwall/wall/stdio.nim,
  named pipes NIMBOX_OUT_PIPE) - relay itself is the CPLW child, so it
  stalls too

Crucial confound: **every failure had 3code.exe as the CPLW parent;
every success had the standalone cplw.exe helper as parent** (from
elevated ssh). Parent binary identity vs caller context was never
separated. That is the first experiment to run.

## Agreed direction (with the user)

Keep the dedicated-user approach. Try: **sandwall.exe as a separate
runner binary on Windows** (Codex's codex-command-runner.exe shape).
The user's instinct: have the installer ship the regular sandwall
binary next to 3code.exe; 3code's bash tool execs sandwall.exe (not
itself) as the sandbox parent. Note: keep the sandwall *library*
import for policy parsing; drop the compiled-in execution path on
Windows only.

If the standalone parent doesn't fix it, the next shape is the full
Codex two-hop: CPLW launches a long-lived runner *as the sandbox
user*, which then spawns commands with plain same-session
CreateProcessW (nothing cross-session ever happens). OpenAI article:
"Building a safe, effective sandbox to enable Codex on Windows" -
read it before redesigning.

## Immediately actionable next steps

1. Deploy standalone `sandwall.exe` to beck; run its restrict CLI as
   the CPLW parent from a REAL interactive console (login as carlo
   non-admin in the VM console, run there - not ssh, not schtasks).
   This is the decisive experiment for parent-binary identity.
2. If it works: restructure (installer ships sandwall.exe; bash tool
   execs it; remove self-re-exec on Windows). If it stalls: implement
   the two-hop runner (long-lived, LOGON_WITH_PROFILE likely needed
   for profile/hive load - we never tried that flag).
3. Then the full matrix: fs deny/narrowing, msys2 bash, host rules
   through the wall proxy (the original 1.1.1.1 bug), latency.
4. Then cleanup: revert `wall/stdio.nim` experiments if superseded,
   CHANGELOG, version bumps, release.

## Loose ends

- The `probe` in initSandbox still re-execs `3code sandbox restrict`
  (backendWorks); on a broken spawn this hangs the interactive
  startup ~30s (probe child stalls + dirlock waits). Any fix must
  give the probe a timeout or route it through the new runner too.
- `3code sandbox restrict` on Windows prints box's own minline
  escape garbage ([?25h[0m[?2004l) on exit - cosmetic, from cleanup
  exitprocs running in the box process.
- The wall proxy path for Windows is compiled but unexercised end to
  end (needs a working child first).
- tests/core/test_cli_args.nim `setup` test needs a writable HOME
  (sandbox deny on ~/.config makes it fail locally; green with
  HOME=/tmp/fakehome). CI is unaffected.
- Beck has leftover: `t.exe`, `test_winpath.exe`, `sandwall-usersid.exe`
  in C:\Users\Quickemu (harmless), sandwall user in Users group,
  winsta0 ACL grants for sandwall on session 1. A `3code unsetup` +
  re-setup at the end should be part of final verification.
