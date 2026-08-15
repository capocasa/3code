# Cybernetic plan: working Windows sandbox (rtoken backend) in 3code

Baton file for this task. The `cybernetic-plan.md` in this repo belongs to a
different task (library API); this file is the Windows-sandbox baton. Most
edits land in `~/p/sandwall`, verification happens on the beck VM, wiring
lands here.

## Standing orders

Short one-line commits, no coauthor. No auto-push/install except the
explicit sandwall release steps at the end (user asked for the release).
Commit per verified step. Do not come back unless blocked.

## Context

3code's Windows fs sandbox was just re-based in sandwall from AppContainer
(killed msys2/cygwin) to a write-restricted token + Job
(sandwall/src/sandwall/rtoken.nim, untracked; process.nim/restrict.nim/acl.nim
modified, uncommitted). Model: `restrictImpl` stamps a synthetic write SID
(S-1-5-21-3738981842-2241542906-1872314022-4093) ACL grant on each writable
root; `buildWriteRestrictedToken` makes a WRITE_RESTRICTED primary token;
`spawnSandboxed` CreateProcessAsUserW suspended, assign KILL_ON_JOB_CLOSE Job,
resume. 3code re-execs itself as `3code sandbox restrict ...` (box.nim
Windows branch calls runSandboxed, threecode.nim:230-235 early dispatch).

Live shakedown on beck (Windows 11 quickemu VM, user Quickemu) with
0.6.0-windows-e836e2c0 found:

- **F1 (blocker): fs confinement is a no-op.** Write to `%USERPROFILE%`
  under `sandbox restrict %TEMP%` succeeds (LEAKED). Cause:
  rtoken.nim:284-309 puts the token **user SID** into the restricted-SID
  list (added after probe rt5 to keep cygwin's signal pipe alive). A
  write-restricted token grants a write only if normal SIDs AND >=1
  restricted SID allow it; with the user SID in both lists, every
  user-writable path passes. Deny-narrowing (DENY ACE for the synthetic SID
  only) is bypassed the same way. Note: the TokenDefaultDacl fix
  (rtoken.nim:326-346, grants user+logon+everyone+sand on created objects)
  may postdate rt5, so the user-SID crutch may no longer be needed.
- **F2: HTTPS broken in-sandbox.** Sandboxed curl:
  `schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS`
  (google.com and 1.1.1.1). Plain http to both works (301). Parent curl
  works. Prime suspect: `LUA_TOKEN` in the CreateRestrictedToken flags
  (rtoken.nim:313) - Codex's recipe uses DISABLE_MAX_PRIVILEGE|WRITE_RESTRICTED
  only.
- **F3: host-rule network denial unreachable via 3code on Windows.**
  Windows default policy has no host rules (net open, by design), and the
  kernel fence doesn't apply to rtoken children anyway: WFP filters key on
  the sandwall *user* SID or AppContainer SID, a restricted token keeps the
  normal user SID, and ALE_USER_ID/WFP conditions cannot see restricted
  SIDs. box.nim ignores `inetOk` on Windows. So host rules = silently open.
- **F4: setup command undiscoverable.** `3code wall setup-windows
  [--status|--uninstall]` exists (wall.nim:116+, README.md:102) but
  `3code --help` (threecode.nim:53) never mentions the `sandbox`/`wall`
  subcommands.

Local build facts: 3code cross-compiles with
`nim c -o:3code.exe --os:windows --cpu:amd64 --opt:none --debugger:native
--gcc.exe:x86_64-w64-mingw32-gcc --gcc.linkerexe:x86_64-w64-mingw32-gcc
src/threecode.nim` (host gcc lacks windows.h; must pin the mingw gcc).
nimble.paths points at ~/p/sandwall/src, so the working tree is live.

Beck runbook (parent sandbox denies /dev/tty, so askpass+setsid):

    printf '#!/bin/sh\necho quickemu\n' > /tmp/askpass && chmod +x /tmp/askpass
    export SSH_ASKPASS=/tmp/askpass SSH_ASKPASS_REQUIRE=force DISPLAY=:0
    setsid ssh beck 'cmd'          # cmd is cmd.exe syntax
    setsid scp file beck:'name'    # locked exe: taskkill /IM 3code.exe /F first

Deploy target: `C:\Users\Quickemu\3code.exe` (cwd of the ssh session).
Useful: `%TEMP%` = C:\Users\Quickemu\AppData\Local\Temp, msys2 tree at
`%LOCALAPPDATA%\3code\msys64` (bash.exe under usr\bin).

## Current state

**DONE (validated end-to-end on beck through 3code.exe).** The
dedicated-user backend shipped: sandwall 0.4.0 (tag faca4d4, pushed)
runs children as the `sandwall` user via CreateProcessWithLogonW
through a C shim (the real prototype is 11 args; a Nim import with the
CreateProcessAsUserW shape SIGSEGVs), stamps ALLOW ACEs for that user
on writable roots + traverse ACEs on profile ancestors, DENY-narrows
with rollback, and the pre-existing WFP fence blocks the user's
non-loopback egress. Verified on beck through 3code.exe: TEMP write
ok, home + C:\Windows denied, deny-subpath denied with siblings ok,
off-loopback connect BLOCKED by the fence. 3code 7d4b203: honest
fence-absent warning in box.nim, `sandbox`/`wall setup-windows` in
--help, requires sandwall >= 0.4.0. Windows CI: fs tests gate on
backend presence (skip on runners, no sandbox user); the remaining
test_rules failures on windows-latest are PRE-EXISTING at tag 0.3.2
(verified in run 31840491912) and out of scope. Caveats recorded: the
child's console stdio does not attach in the ssh session-0 context
(production spawns from the interactive session with pipes - streamexec);
`setup` AC-fence re-install errors when filters already exist (legacy
path, harmless); deny on a nonexistent path is skipped (accepted gap).
Beck cleanup done (test users, tasks, probes, grants removed).

(Historical session notes below.)

**Architecture decision (validated on beck, hardware): the same-user
write-restricted token backend cannot work for 3code.** msys2's signal
pipe fails (Win32 error 5) with restricted list [synthetic, logon,
Everyone] even though cmd/powershell pipes work - msys-2.0.dll creates
its named pipe with an explicit owner-only DACL, and the write check
needs a restricting SID in that DACL; only the user SID would satisfy it
(A/B: adding user SID back makes msys2 run AND re-opens the home write
leak - F1 again). This is Codex issue #17459 / HanaAgent #1787
territory; Codex's working solution is the ELEVATED model: children run
as a DEDICATED sandbox user (CreateProcessWithLogonW, no restricted
token needed - the user boundary IS the confinement). Validated on
beck: msys2 bash + ls + cmd + whoami run fine as dedicated user
`swtest` via CPLW with lpDesktop="winsta0\\default"; home + C:\Windows
writes correctly denied for non-admin swtest; writable roots need an
explicit ACL grant for the user (TEMP grant worked while admin;
traverse through private profile dirs is the caveat - writable roots
under the real user's profile need ancestor traverse grants).

Other verified findings from this session:
- F1 fixed in-tree (user SID removed): home + C:\Windows writes denied,
  temp allowed. NOT enough (msys2 breaks).
- F2: LUA_TOKEN dropped; schannel https STILL fails with
  SEC_E_NO_CREDENTIALS inside the restricted token (Codex bug #17459,
  same symptom, unresolved upstream). Works as dedicated user instead.
- ACCESS_MODE enum had denyAccess/revokeAccess SWAPPED (DENY=3,
  REVOKE=4); fixed; deny-narrowing now works: deny %TEMP%\sub blocks
  sub, sibling writes allowed, DENY ACE rolled back after run
  (icacls clean).
- Deny stamp on a NONEXISTENT path raises (GetNamedSecurityInfo err 2)
  and kills the whole run - needs handling (create-first or skip).
- `3code wall setup-windows` (elevated ssh on beck is admin) works:
  creates sandwall user + 12 WFP filters; sandwall user SID
  S-1-5-21-2584252185-3584240435-1410252772-1001, credentials.dat in
  %LOCALAPPDATA%\sandwall.
- CPLW via the mingw-built C helper worked for cmd/msys2 (cplw.c in
  /tmp on host; copy on beck). err 87 appeared late in the session for
  stale deployed cplw.exe on beck (rebuilt + redeployed = works again;
  the real cause was never the API). RESOLVED understanding: CPLW from
  the session-0 ssh context gives console children 0xC0000142
  (conhost allocation denied for non-admin users in session 0) -
  VERIFIED non-console children run fine as the non-admin dedicated
  user from session 0 (guichild.exe test: combo 0 OK, exit 0, output
  file written). In production 3code spawns from the INTERACTIVE
  session with named-pipe stdio (streamexec), so the console issue is
  a validation-environment artifact. sshd is now AUTO_START on beck.
  Implement the dedicated-user backend:

In-tree state: COMMITTED 22626d4 on sandwall main (rtoken backend with
F1 user-SID removal + F2 LUA_TOKEN drop + ACCESS_MODE order fix;
linux suite passes except 3 pre-existing failures, identical on HEAD
before the change). NOT tagged/released - the backend is now known
insufficient for 3code (msys2), release should wait for the
dedicated-user model. Beck has: sandwall-new.exe (fixed rtoken),
sandwall.exe (old AC backend), rtprobe.exe, cplw.exe,
swtest/swfresh test users (swtest non-admin, swfresh admin), test
policy files sw-pol*.txt in ~, WFP fences installed, VM rebooted
(stuck - see above). 3code/windows at 7481d4f (plan only).

## Decisions (made now, do not relitigate without new evidence)

- **D1:** restricted-SID list = [synthetic, logon, Everyone] (Codex recipe);
  the user SID is REMOVED. Cygwin survival must be re-proven with the
  default-DACL entries in place (rt5 predates them). If cygwin still dies,
  iterate on the default DACL / named-object side, never on re-adding the
  user SID (it re-opens F1).
- **D2:** drop `LUA_TOKEN` from the flags unless a probe shows it is
  load-bearing for something else; it is the prime F2 suspect.
- **D3:** per-run kernel net fencing for rtoken children is out of scope
  (no WFP condition matches restricted SIDs; dual-spawn-as-sandwall-user is
  the documented follow-up). Ship an honest posture: host rules present on
  Windows => warn "network rules not enforced on this backend" and run open.
  Matches the existing documented degrade posture; removes the silent lie.
- **D4:** Everyone-in-restricted-list may re-enable writes to
  Everyone-writable dirs (e.g. C:\Users\Public). Probe once; if it leaks,
  accept for now (Codex posture) and note it in the CHANGELOG, unless the
  probe shows something egregious (e.g. user profile dirs).
- **D5:** sandwall release = 0.4.0 (backend replacement, not a patch).

## Steps

1. [x] Triage the sandwall worktree (committed clean in 22626d4; junk
   left untracked).
2. [x] F1 fix: user SID removed from restrictSids; verified on beck
   (home + C:\Windows denied, temp allowed).
3. [x] F2 fix: LUA_TOKEN dropped. VERDICT: schannel still fails inside
   the restricted token (upstream Codex bug #17459, same symptom);
   https works as dedicated user instead - folded into the new backend.
4. [x] ACCESS_MODE deny/revoke swap fixed (bonus find); deny-narrowing
   verified working incl. rollback.
4b. [ ] NEW BACKEND: dedicated sandbox user + CreateProcessWithLogonW
   (lpDesktop winsta0\\default, desktop grant needed for sandbox user),
   stamping the USER SID (not synthetic) on writable roots + traverse
   grants on ancestors; WFP fence stays keyed on that user for net
   rules; `3code wall setup-windows` becomes REQUIRED on first run
   (docs + --help). Design points validated on beck: non-console child
   runs fine as non-admin dedicated user from session 0; console child
   in session 0 dies 0xC0000142 (conhost) - 3code's streamexec uses
   pipes so production is unaffected; sandbox-user account must be
   ACTIVE with a password (net user reset can disable it - mind
   UF_ACCOUNTDISABLE); writable roots need grants + ancestor traverse
   when they live under private profiles. Credentials: DPAPI
   credentials.dat under the CALLER %LOCALAPPDATA% (elevated setup ran
   as admin - quickemu ssh is admin, so decrypt works; on real hosts
   setup runs from an elevated 3code and the file lands in the real
   user's LOCALAPPDATA - spawnAsSandwall reads it from the same user
   context. VERIFIED OK.)
4. [ ] Cross-compile standalone sandwall.exe (same mingw pin as 3code),
   deploy to beck, run the probe matrix:
   - `sandwall <policy> -- cmd /c echo hi > %TEMP%\t.txt` (allowed; file
     appears) then home write (must FAIL with access denied), C:\Windows
     write (must fail), project-dir write (allowed).
   - `deny` narrowing: allow %TEMP%, deny %TEMP%\sub => write sub fails,
     write temp succeeds, DENY ACE rolled back after (icacls clean).
   - msys2 bash inside: `... -- bash -c 'echo ok > /tmp/x && cat /tmp/x'`
     with bash from the 3code msys64 tree (D1 risk: cygwin signal pipe).
     If it dies: escalate default-DACL entries / \BaseNamedObjects grants;
     bounded, do not re-add the user SID.
   - https: curl -sS https://google.com and https://1.1.1.1 (expect 301,
     no schannel error). If still SEC_E_NO_CREDENTIALS: flag-matrix probe
     (LUA_TOKEN / WRITE_RESTRICTED / default DACL) on standalone builds.
   - Everyone leak probe (D4): write C:\Users\Public\w.txt; record result.
5. [ ] Record probe outcomes in this plan (Current state) and in
   rtoken.nim's header comment where they correct the record (rt5 story).
6. [ ] F3 honest posture: in box.nim (or runSandboxed's caller path), when
   the resolved policy has host rules on Windows, print one stderr warning
   "network rules are not enforced on the Windows backend; running open"
   and proceed. Update README.md + docs/manual.md network-wall paragraphs
   to say the Windows fence applies to the (legacy) AC/sandwall-user path
   only. No fake enforcement.
7. [ ] Rebuild 3code.exe from the fixed tree, redeploy to beck (taskkill
   first), rerun the full shakedown through the real binary:
   - `3code.exe sandbox restrict %TEMP% -- <each matrix case>`
   - `3code.exe sandbox restrict` with a policy file exercising
     allow-bare (project dir) + deny home.
   - oneshot smoke: `3code.exe -x "..."` if a provider is configured on
     beck; otherwise note it and rely on the sandbox subcommand paths
     (validation, not CI).
8. [ ] F4: add `sandbox`/`wall` subcommand lines to usage()
   (threecode.nim:53-68), including the one-time `3code wall setup-windows`
   note for Windows. Keep it terse, match local help style.
9. [ ] sandwall: run the Linux test suite (`nimble test`) + mingw
   cross-compile of both sandwall.exe and 3code.exe as gates. Add a small
   compile-only or windows-gated test only if one fits the existing suite
   cheaply; otherwise the beck matrix is the evidence.
10. [ ] Commit sandwall backend: one commit for the rtoken backend + fixes
    (rtoken.nim, acl.nim, process.nim, restrict.nim + doc updates), e.g.
    "windows: replace AppContainer backend with write-restricted token".
11. [ ] CHANGELOG entry (F1 mechanism, cygwin/LUA findings, net posture),
    bump 0.4.0, commit "bump version".
12. [ ] Release sandwall: tag 0.4.0, push origin main --tags, `gh run
    watch` (workflow exists). This is the release the user asked for.
13. [ ] 3code side: bump sandwall requires to >= 0.4.0 (threecode.nimble /
    wherever the constraint lives, cf. commit a326643), commit the box.nim
    posture + usage() help together, e.g. "windows sandbox: honest net
    posture, list sandbox/wall in help; require sandwall 0.4.0".
14. [ ] Final review: re-read the full diff (both repos) against F1-F4,
    confirm no leftover AC references that now lie, confirm the beck
    matrix results are recorded here, leave the tree clean.

## Verification matrix (beck, expected)

| case | expected |
|---|---|
| write %TEMP% | allowed |
| write %USERPROFILE% | DENIED (was leaked) |
| write C:\Windows | denied |
| write project dir (bare allow) | allowed |
| write %TEMP%\sub with deny sub | denied, siblings allowed |
| msys2 bash -c inside sandbox | runs (signal pipe ok) |
| curl https://google.com | 301, no schannel error |
| curl https://1.1.1.1 | 301, no schannel error |
| host rules in policy | stderr warning, network still open (D3) |
| icacls %TEMP% after runs | synthetic grant present, idempotent |
