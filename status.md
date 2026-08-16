# Status: Windows sandbox - WORKING

**The Windows sandbox works end to end.** The blocker (children
stalling/dying at loader init in interactive contexts) is solved and
root-caused; every layer is verified on beck hardware in both ssh
session-0 and interactive session-1 contexts.

## What was actually wrong (the blocker, dissected)

Three independent bugs stacked on top of each other:

1. **The setup-time desktop grant never applied (and crashed).**
   `sw_grant_desktop` (csrc/desktop_shim.c) heap-corrupted
   (0xC0000374) after granting the window station: LocalFree on the
   old DACL from GetSecurityInfo is fatal in session-0 callers on
   Win11 26100, and the LookupAccountNameW domain buffer was one
   terminator short. Setup died before the fence install (which is
   why the fences showed installed=false at session start) and before
   the default-desktop ACE. The winsta0 ACE limped through (applied
   before the crash point), the desktop ACE never did.

2. **lpDesktop="winsta0\default" kills CPLW children (0xC0000142).**
   With BOTH the winsta0 and default-desktop ACEs actually in place,
   an explicit lpDesktop string makes console-subsystem children fail
   their cross-session desktop connect. lpDesktop must be NULL: the
   child then initializes in the caller's desktop and works - in
   session 0 AND session 1. (The historical "the desktop string is
   REQUIRED" note was an artifact of bug 1: without the grants, NULL
   also failed, and the string was the only variant probed after a
   crash-free run happened to apply the winsta0 ACE.)

3. **The child environment was never passed.** CPLW with env=NULL
   gives the child a fresh block: NIMBOX_OUT_PIPE (the stdio relay
   pipe name) and the wall-proxy vars never arrived, TEMP/TMP pointed
   into the sandwall user's absent profile, and the relay silently
   produced nothing. Fixed with GetEnvironmentStringsW +
   CREATE_UNICODE_ENVIRONMENT (the flag is mandatory; without it CPLW
   rejects the block with error 87).

Plus two smaller ones found while wiring 3code to it:

4. The stdio relay: pipe client handle not inheritable, pump thread's
   Thread object stack-allocated (died with scope), relay command
   mismatch (`<self> wall stdio-relay` vs the actual CLI), and
   argv-quoting that mangled embedded quotes (the `bash -c` script
   string - `source "..." <"..."` became garbage).

5. 3code's `backendWorks` probe used shell redirections in
   execCmdEx, which on Windows has NO shell (raw CreateProcess): the
   literal `</dev/null` argv reached the probe child as arguments and
   the probe failed, silently disabling the sandbox (bash ran
   unfenced, unsandboxed, as the admin user).

## What is verified on beck (Windows 11 26100, admin Quickemu)

- `sandwall setup` / `3code setup`: idempotent, no crash; both
  fences install (8 user + 4 AC filters). unsetup/setup cycle clean.
- `3code sandbox restrict %TEMP% -- cmd /c whoami` prints
  `...\sandwall`, exit codes propagate (exit 42 -> 42), in BOTH ssh
  session 0 and schtasks /IT session 1. ~0.8s per sandboxed command.
- fs matrix: TEMP write allowed; home, C:\Windows, deny-subpath
  writes denied (with the EACCES hint appended).
- WFP fence: off-loopback connect from the sandbox user times out.
- Wall proxy: allowlisted host fetches through the proxy; raw-IP
  and non-allowlisted hosts blocked (HTTP CONNECT and SOCKS5 paths).
- Full production bash-tool path (driver over runStreamingBash with
  real initSandbox): msys2 bash runs as `sandwall`, clean output
  (HOME is the per-run tmp; no .bashrc noise), allowlisted host via
  proxy OK, non-allowlisted blocked.
- 3code TUI (provider-stub build) in session 1: prompt -> bash tool
  dispatch -> sandboxed execution -> turn completes, OUTER_EXIT=0.
  (The stub build disables the sandbox by design; the enforcement
  evidence is the driver runs above.)
- 3code test suite: 65 PASS, 0 FAIL locally (Linux).

## Repos

- `~/p/sandwall` main @ 36caac4 (0.5.0: lpDesktop NULL, env
  passthrough, relay fixes, desktop-shim heap fix, argv quoting).
- `~/p/3code/windows` @ cfa489d (stdio-relay dispatch, Windows probe
  child + no redirects, HOME=tmp, probe dir cleanup, escape-garbage
  suppression, unsetup wording).

## Post-release check (2026-08-16, deny 1.1.1.1 report)

User report: `.sandbox` in `~/foo` with `deny 1.1.1.1` still let
curl through. Reproduced, then cleared: the deployed exe was a stale
build (0.6.0-windows-8675bb47-unstaged, 01:41) predating the probe
fix cfa489d. Its backendWorks probe still appended POSIX redirects
(`</dev/null >/dev/null 2>&1`) to `cmd /c exit 0`; cmd.exe fails the
redirect ("The system cannot find the path specified"), the probe
exits nonzero, procboxExe clears, and bash runs completely
unfenced - host rules included.

Redeploying the current build (b466423) needed two setup-side
actions, both worth remembering:

- Replacing 3code.exe resets its ACLs; the `sandwall`-user
  read+execute grant from setup must be re-applied (`icacls
  3code.exe /grant "sandwall:(RX)"`) or CPLW fails with error 5.
- After a VM reboot the CPLW child died 0xC0000142 again until
  `3code setup` was re-run (it re-grants winsta0 + default desktop
  and re-stamps exe/msys64 execute grants). Setup is idempotent;
  run it after deploying a new exe.

Verified on the current build through the production bash-tool path
(bashtool_driver over runStreamingBash in `~/foo`): `deny 1.1.1.1`
returns `sandwall proxy: DENY 1.1.1.1:443`, curl code=000 exit 7;
example.com through the same policy passes with code=200. The
default probe shape (`cmd /c exit 0`, no redirects) exits 0.

## 2026-08-16 follow-up: console-window flash per sandboxed command

User report: constant extra terminal windows opening while 3code ran
sandboxed bash commands. Root cause: the CPLW spawn passed no console
flags. CreateProcessWithLogonW defaults to CREATE_NEW_CONSOLE and a
cross-logon child cannot inherit the caller's console, so every run
delegated a fresh console to Windows Terminal (the Win11 default
host), one visible window per command. Fixed in sandwall
(737dde4): CREATE_NO_WINDOW + STARTF_USESHOWWINDOW/SW_HIDE on the
CPLW spawn; the relay's plain CreateProcessW child then inherits the
invisible console (default flags inherit). Verified on beck: the
functional matrix (temp write, whoami=sandwall, home/Windows write
denied, exit propagation, pipelines) passes 6/6 in session 1, session
0 still works, and WMI start-trace shows only windowless conhosts
per run. Note for repro: window-visible samplers must account for
the harness's own console (schtasks /IT gives the PS harness a
console delegated to Windows Terminal) and session-0 observers see
nothing; the CPLW child runs as `sandwall`, whose hive has no console
delegation override.

## Leftovers / next steps

- sandwall 0.5.0 tag + push + CI watch (release step; user asked for
  the release to be pushed when ready).
- The 3code installer should ship `sandwall.exe` next to `3code.exe`
  (the standalone runner works now); today 3code re-execs itself,
  which also works - the runner split is optional hardening.
- CI: windows runners have no sandbox user; the fs tests gate on
  backend presence (unchanged).
- Beck still has the pre-existing harmless leftovers (t.exe,
  test_winpath.exe, sandwall-usersid.exe in C:\Users\Quickemu).
