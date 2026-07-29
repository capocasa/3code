# Cybernetic Plan: wall verification - Windows setup, macOS Seatbelt fix, smoke tests

## Context

The sandwall/wall milestone (impl-1..7) is code-complete: Linux netns
fence + per-run proxy work; commits `26444e7`, `4861571`, `844f6db` in
this repo, sandwall (`~/p/sandwall`) through `fb94a26`. What remains is
platform verification and two defects found while smoke-testing.

### Defect 1: macOS Seatbelt breaks exec (blocker)

`sandbox_init_with_parameters` succeeds and in-sandbox file ops enforce
correctly, but the subsequent `execv` of ANY binary aborts with
SIGABRT. Reproduced minimally on stefani (macOS 14.8.7 arm64 VM, x86_64
Rosetta toolchain): forked or not, `(version 1)`, kitchen-sink allows
(`mach-lookup`, `/dev` rw, `sysctl-read`) - always aborts at exec time.
sandwall CI on `macos-26` fails `test_sandbox` identically (rc 134) but
the job reports green because the workflow doesn't gate on test
failure (`.github/workflows/ci.yml` "Run tests" has no failure
propagation - verify). So the Seatbelt backend has been unverified
since it was written; `3code box` on macOS is a hard abort.

Test scaffolding on stefani: `~/sandwall` (HEAD tarball), `~/3code`
(HEAD tarball), deps `~/streamhttp ~/ttty ~/tinotify` + unicodedb in
pkgs2, `~/3code/nimble.paths` points at them. Build:
`nim c -d:ssl -d:testPlainHttp --path:src --path:tests --path:$HOME/sandwall/src ... -o:build/3code src/threecode.nim`
(see shell history; PATH needs `$HOME/.nimble/bin:$HOME/.local/bin`).
Minimal repros at `/tmp/sbtest*.nim` on stefani; `/tmp/sbtest16.nim`
locally is the raw-FFI version.

Known facts: `restrict` in-process works (sbtest2); fork+restrict+exec
where restrict happens in the fork child ALSO aborts (sbtest12); v0
profile rejected; `(allow network*)` no help; `file-map` op unknown to
the macOS 14 parser. Hypotheses to try, most promising first:
  1. The exec'd image's dyld needs `(allow file-read* (subpath
     "/private/var/db/dyld") ... )` - already in baseline via
     baselineRead (check it's in the emitted profile; sbtest16 lacked
     it). Try full baseline profile text from buildProfile.
  2. process-exec must be paired with `file-map-executable` or
     `process-exec*` with `file-read*` on the exact literal of the
     target binary, not just subpaths.
  3. Signal/exception ports: add `(allow signal (target self))` or
     mach exception-port allows.
  4. Ask what changed in macOS 14/26: sandbox_init deprecation may now
     hard-abort on first violation instead of logging - get the abort
     reason via `log show --predicate 'process == "sandboxd"' --last 1m`
     on stefani right after a repro.
Get the sandboxd log FIRST (step 1) - blind profile permutations
already burned effort.

### Defect 2: sandwall Windows build red (blocker for Windows work)

`src/sandwall/wall/proxy.nim` imports `std/posix` unconditionally;
windows-latest CI build fails (`ambiguous identifier: SocketHandle -
winlean vs posix`). proxy.nim / connect.nim / netns.nim are POSIX-only
modules (sandwall.nimble comment says wall.nim as a whole doesn't
cross-compile for that reason). Fix: gate imports + bodies behind
`when defined(posix)` so windows-latest builds the main binary, and
make the CI "Run tests" step actually fail the job on test failure
(it currently swallows it - see how the macOS job passed with FAILED
tests; probably nimble exit code is lost; check and fix).

### Windows wall: never run on hardware

wfp.nim + winuser.nim are compile-only (`a03a76a`). `3code wall
setup-windows` is wired in `src/threecode/wall.nim`. `ssh beck` =
Windows 10.0.26200, repo at `C:\Users\Quickemu\p\3code` (tarball push
via scp; see HANDOFF-windows-completion.md for the push/build loop).
Needs: build 3code.exe with the sandwall wall modules, run elevated
`3code wall setup-windows`, verify `wfp-probe` + behavioral check.

## Current state

- Defect 2 (windows build): NOT STARTED.
- Defect 1 (seatbelt exec): reproduced minimally; sandboxd log not yet
  captured; no fix.
- beck: VM booting, ssh still timing out as of last check. Retry loop:
  `ssh -o ConnectTimeout=10 beck 'echo BECK_UP'`.
- stefani proxy smoke (POSIX half) PASSED on 2026-07-29: `3code wall
  proxy --port 61080` on stefani, allowed CONNECT to 127.0.0.1
  negotiated, denied host got `HTTP/1.1 403 Forbidden`. Only the
  seatbelt fence is broken.

## Steps

- [ ] 1. Fix sandwall Windows build: `when defined(posix)` gate
  proxy/connect/netns imports and wall.nim re-exports so windows-latest
  builds. Also fix CI "Run tests" so a failing suite fails the job
  (macOS job passed with FAILED tests - find why, likely nimble
  task exit code or missing `--error` propagation). Verify with
  `nim c --os:windows -d:mingw --cpu:amd64 --compileOnly` locally if
  mingw exists, else push and watch CI. Commit in sandwall.
- [ ] 2. Capture the sandboxd abort reason on stefani: run
  /tmp/sbtest16.nim (raw sandbox_init + execv), then immediately
  `log show --last 2m` filtered for sandboxd/kernel denial messages.
  The violation name tells exactly which allow is missing.
- [ ] 3. Fix the seatbelt profile (seatbelt.nim buildProfile/baseline)
  from step 2's evidence; verify: sbtest-style exec of /usr/bin/true
  exits 0, then `cd ~/sandwall/tests && nim c --path:../src -r
  test_sandbox.nim` green on stefani. Commit in sandwall.
- [ ] 4. Full macOS smoke on stefani: rebuild sandwall + 3code there,
  `3code box --policy <host-rule policy> restrict /tmp -- curl ...`:
  direct connect fails, via-proxy succeeds, denied host 403. Record
  results. If stefani remains a hopeless environment for seatbelt
  (VM/Rosetta quirk), verify via sandwall CI macos-latest after step
  1 makes tests gate, and note it.
- [ ] 5. Windows on beck: push 3code tarball, build 3code.exe,
  `3code wall setup-windows` elevated, `--status` behavioral verify,
  wfp-probe. Then fenced-launch smoke: policy with host rules spawns
  the bash tool path (streamexec currently warns-only on Windows per
  impl-6; confirm warning text appears; full spawnAsSandwall wiring is
  UNPLANNED). Record results.
- [ ] 6. Docs + sweep: docs/manual.md platform verification matrix
  updated with what was actually verified where; plan-network-firewall.md
  notes; commits in both repos.
