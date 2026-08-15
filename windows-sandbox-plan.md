# Cybernetic plan: working sandwall sandbox on Windows

Baton file. **Read `status.md` first** - it has the full evidence
trail, the beck runbook, and the blocker description. This file is
only the todo loop.

## Standing orders

- One todo at a time. After each item: update its status IN THIS FILE
  (and any finding that changes the picture into `status.md`), commit
  both files with the code change, then **relaunch yourself with the
  `clear` tool** passing an updated version of this prompt. Work
  handed to a fresh context survives; work held in memory does not.
- Short one-line commits, no coauthor, no auto-push, no auto-install.
- Verify on beck (the quickemu VM) - builds and local tests are not
  evidence. Deploy needs `icacls <exe> /grant sandwall:(RX)` after
  every scp (scp replaces the file; grants don't survive).
- If a step disproves the plan's assumption, stop coding, write the
  finding into status.md, mark the step `[blocked]`, and relaunch with
  a revised plan rather than improvising a new architecture mid-loop.
- Non-admin test user on beck: **carlo / carlo**. Admin: Quickemu.
  Real interactive tests run IN the VM console as carlo, not over ssh.
- No Nim macros. No em dashes. Style per repo AGENTS.md.

## The goal (unchanged)

A working sandwall on Windows: the bash tool runs sandboxed (fs
confinement per policy, host rules enforced through the wall proxy),
from a normal non-admin interactive 3code session, without the
latency cliff. Everything else is negotiable.

## Todos

1. [ ] **Baseline: interactive-console reproduction.** Log into the
   beck VM console as carlo (non-admin). Run the current `3code
   sandbox restrict %TEMP% -- cmd /c whoami` in a real console
   window. Record in status.md: does it stall, die, or work? Also
   test as Quickemu in the console. This pins down whether ANY of the
   schtasks/ssh harness artifacts were the real story. (The old
   evidence: stalls from schtasks session 0 AND session 1 `/it`;
   worked from elevated ssh session 0 with the standalone cplw.exe
   parent at 0.4.0.)
2. [ ] **Decisive experiment: standalone parent.** Deploy standalone
   `sandwall.exe` (cross-build from ~/p/sandwall, CLI supports
   `RULES -- CMD`) to beck. As carlo in the console, run
   `sandwall <policy> -- cmd /c whoami`. Two outcomes: works => the
   runner-binary architecture is confirmed, proceed to 3. Stalls =>
   parent identity was never the variable; skip to 4.
3. [ ] **Restructure: sandwall.exe as the Windows runner.** Installer
   (install.ps1 + release packaging) ships sandwall.exe next to
   3code.exe. The bash tool (streamexec.nim windows branch) execs
   sandwall.exe instead of re-execing 3code. `3code sandbox` stays
   for POSIX; on Windows it can stay as a thin alias or be hidden.
   initSandbox's backendWorks probe must run through sandwall.exe
   with a short timeout (it currently re-execs 3code and hangs the
   startup ~30s when spawn is broken). fs + net matrix on beck as
   carlo: whoami, home write denied, temp write allowed, msys2 bash,
   `-1.1.1.1` policy blocks through the proxy (the original bug),
   latency < 1s after first run.
4. [ ] *(only if 2 stalls)* **Two-hop runner (Codex shape).** CPLW
   launches ONE long-lived runner process as the sandbox user (try
   LOGON_WITH_PROFILE - never tested; loads the profile hive), the
   runner receives commands (named pipe or temp-file protocol) and
   spawns them with plain same-session CreateProcessW. Read OpenAI's
   "Building a safe, effective sandbox to enable Codex on Windows"
   first. This lives in the sandwall repo.
5. [ ] **Cleanup + hardening.** Revert dead experiments (wall/stdio.nim
   if superseded, desktop_shim if unused). Fix the minline escape
   garbage printed by `3code sandbox restrict` on exit. ChangeLog +
   version bumps both repos. `3code unsetup` + `3code setup` on beck
   as the final idempotency check.
6. [ ] **Release.** Tag sandwall (0.5.0 - backend change), push,
   watch CI (this release may be pushed - it is the deliverable).
   3code side: bump the sandwall requirement, update README/manual
   install section (sandwall.exe now ships alongside), commit.

## Current state snapshot (update me)

- sandwall main @ 13a0ee1, 3code windows @ 7120e2b, both clean.
- The stall: CPLW child of 3code.exe blocks at ntdll loader init
  (LpcReply) in interactive contexts; full matrix in status.md.
- Perf fix (hasSidAce), idempotent setup, setup/unsetup CLI, bash
  tool wiring, Windows proxy export - all committed and working
  independently of the blocker.
- Beck: sandwall user exists (in Users now), fence installed,
  leftover test exes in C:\Users\Quickemu are harmless.
