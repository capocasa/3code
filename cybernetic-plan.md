# Cybernetic Plan: sandwall filesystem milestone

## Context

procbox (`~/p/procbox`) is a filesystem sandbox library (Landlock /
Seatbelt / Windows ACL+token) that 3code (`~/p/3code/sandbox`) uses via
`requires "procbox >= 0.1.0"` (verify develop-link vs installed copy in
step 1). 3code currently reimplements the sandbox policy language in
`src/threecode/sandbox.nim` (parsing, rule model, cascade, path checks)
and enforces it two ways: bash is wrapped in `3code box restrict ...`
(re-exec, `src/threecode/box.nim`, calls `procbox.restrict`), while
read/write/patch run in-process gated by `sandbox.checkRawPath`
(`src/threecode/actions.nim` ~428/488/506/547).

This milestone:

1. Moves the policy file format, parser, and rule model **into procbox**
   (`src/procbox/rules.nim`), with a new `+`/`-`/`*` syntax that also
   parses host rules (stored, not enforced; network is a later
   milestone, see `plan-network-firewall.md`).
2. Keeps read/write/patch **in-process** (user decision R3) but switches
   them to the *same* procbox code path the sandbox subprocess uses:
   one `checkPath(policy, path)` imported from procbox. The linguistic
   reimplementation is deleted, not moved. Only the unpredictable shell
   is kernel-sandboxed.
3. Passes the policy *file path* to `3code box` (user decision R1); box
   loads and resolves the cascade itself at launch, so every bash launch
   inherently uses the freshest policy. In-process tools reload on mtime
   change before each check.
4. Tells the agent where the boundaries are: when the sandbox is active,
   the system prompt gets a compact rendered rule summary plus the
   policy file path.

Locked decisions: procbox not renamed yet (rename = network milestone).
Zero backward compat with `.`/`o`/`O`. Default policy: `- /`, `+ /tmp`,
`+` (bare plus = project dir writable). No host rules, no network
fencing by default. Bare host = all ports; `host:port` allowed.
3code itself stays unsandboxed.

### The new file format

One rule per line: first char is the access code, the rest (after one
optional space) is the target. Blank lines and `#` comments skipped.

- `+` allow (writable path / connectable host)
- `-` deny
- `*` read-only (path rules only)
- `+*` special: no network restrictions (network milestone)

Target classification by first character:

- `/`, or letter + `:` (Windows drive `C:\...`) -> absolute path
- `~` -> home-dir path
- `.` -> path relative to the project dir (parent of `.3code/`); bare
  `+` with no target means the project dir itself
- alnum -> host rule: hostname, IPv4, or IPv6, optional `:port` suffix
  (bare = all ports, stored as port 0). `[v6]:port` form for IPv6+port.

### Rule model (procbox/src/procbox/rules.nim)

```nim
type
  AccessKind* = enum akDeny, akReadOnly, akWritable
  RuleKind* = enum rkPath, rkHost
  Rule* = object
    access*: AccessKind
    case kind*: RuleKind
    of rkPath: path*: string      # canonical absolute
    of rkHost: host*: string; port*: uint16  # port 0 = all ports
  Policy* = object
    rules*: seq[Rule]
```

Public API (names may shift in implementation):
`parsePolicy(text, projectDir)`, `loadPolicy(path)`, cascaded load
(system `getConfigDir()/"3code"/"sandbox"` + repo
`<project>/.3code/sandbox`, default text when absent),
`resolve(policy) -> (writable, readonly, hosts)`,
`checkPath(policy, path) -> AccessKind`, `renderPolicy(policy)`,
`appendRule(file, target, access)`. Host rules are parsed and carried;
`resolve` collects them for the future wall. This is the single code
path: 3code's in-process tools and the box subprocess both call these.

### Policy-file writability caveat (R1 fallout)

User requirement: "policy file always read-only; the subprocess can know
its policy but never change it." The repo policy lives at
`.3code/sandbox`, *inside* the project dir, which the default policy
makes writable. On Seatbelt (ordered rules, specific deny wins) and
Windows (DENY ACEs beat ALLOW), box can force the policy file read-only.
On Landlock, rules within one layer union, so a RO rule for a file under
a RW root does NOT subtract write. Approach: box force-adds the policy
file to the read-only set (works on macOS/Windows), and on Linux prints
a startup warning when the policy file sits under a writable rule,
recommending hard boundaries go in the system policy
(`~/.config/3code/sandbox`, covered by `- /` so read-only by default).
Document this in both READMEs. (Mitigation, not a fix; a fully writable
`/` policy is inherently self-modifying anyway.)

### Key files

- procbox: `src/procbox/rules.nim` (new), `src/procbox.nim` (export),
  `procbox.nimble` (minor bump), `tests/test_rules.nim` (new).
- 3code: `src/threecode/sandbox.nim` (rewrite to thin wrapper + mtime
  reload), `src/threecode/box.nim` (`--policy` loading), `actions.nim`
  (checkRawPath via procbox, auto-reload), `streamexec.nim` (pass
  `--policy` instead of resolved paths), `ui.nim` + `prompts.nim`
  (`:sandbox` verbs, help, agent-facing prompt section), tests.

## Current state

Step 1 done (2026-07-28): procbox reaches 3code as an installed nimble
snapshot (`~/.nimble/pkgs2/procbox-0.1.0-597...`, vcsRevision 380cc52);
repo HEAD 9af6e87 differs only by the package-rename commit. Workflow:
implement in ~/p/procbox, bump to 0.2.0 in step 5, `nimble install`
from the repo, 3code picks it up (requires "procbox >= 0.1.0").
Otherwise not begun. Recon done: procbox lib layout confirmed
(`src/procbox/{restrict,process,paths,baseline,landlock,seatbelt,acl}.nim`;
`src/procbox.nim` exports restrict+process, carries the CLI). 3code
sandbox.nim fully read (299 lines). streamexec.nim bash wrap at
329-372 (builds argv from `sandbox.current.resolve()`). actions.nim
checks at 428/488/506/547. ui.nim `:sandbox` at 73-76, 1029-1062; help
in prompts.nim 2084-2089. procbox baseline.nim already makes /dev/null
writable, so git works under the default policy. procbox dependency link
(develop vs installed) unverified, that's step 1.

## Steps

1. [x] **Verify the procbox dependency link.** Installed snapshot, see
   Current state. No nimble develop; nimble install at step 5.
2. [x] **procbox: `rules.nim`.** (done, committed with tests) Types, target classification,
   `parsePolicy`, path normalization (port of 3code's
   `normalizeSandboxPath`), host parsing/validation (hostname, IPv4,
   IPv6, `[v6]:port`, `host:port`, port 0 = all), `checkPath`,
   `resolve`, `renderPolicy`, `appendRule`. Pure logic; `loadPolicy` is
   the only file IO. No macros. Match procbox module style.
3. [x] **procbox: `tests/test_rules.nim`.** (all green) Every target class
   (absolute, drive-letter, tilde, `./rel`, bare `+`, hostname, IPv4,
   IPv6, `[v6]:port`, `host:port`), last-wins superseding, deny default,
   `*` read-only, `+*` host-all, comments/blanks, garbage lines skipped,
   `+*` with a space vs `+ *` (decide: bare `+*` only). Wire into
   procbox's test task. Green.
4. [x] **procbox: cascade + default policy.** (in rules.nim) Discovery paths,
   pure-text cascade core (like 3code's parseCascaded) + file-loading
   wrapper, default text `- /\n+ /tmp\n+`. Export everything from
   `src/procbox.nim`. Cascade tests.
5. [x] **procbox: bump + install.** (0.2.0 installed, committed) Minor version bump, `nimble
   install`, full procbox suite green.
6. [x] **3code: rewrite `sandbox.nim` as thin wrapper.** (done; mtime reload + sandboxPromptSection added) Delete
   Rule/Sandbox/parse/resolve/checkPath; import procbox rules. Keep
   `active`, `procboxExe`, `findProcbox`, `backendWorks`. Cascade loads
   become procbox calls. `checkRawPath` calls procbox `checkPath` and
   first calls `reloadIfChanged()` (compares mtimes of both policy files
   to stored values, reloads the cascade on change). Compile.
7. [x] **3code: `box.nim` takes `--policy`.** (done; box resolves policy itself, forces policy files RO, warns on Landlock union caveat, accepts empty writable with --policy) New global option:
   `--policy SYSFILE --policy REPOFILE` (repeatable, ordered); box
   cascades + resolves via procbox itself at launch. `restrict` keeps
   explicit-path args working (union with policy resolution when both
   given; the bash wrap will pass `--policy` + `--ro <tmpdir>`). Box
   force-adds each policy file to the read-only set and, on Linux, warns
   once on stderr when a policy file is under a writable rule (caveat
   above). Update usage text.
8. [x] **3code: actions.nim + streamexec.nim rewiring.** (done; streamexec passes --policy + --ro tmpdir, reload via checkRawPath) actions:
   `checkRawPath` already gates read/write/patch; confirm reload happens
   via the sandbox.nim change and drop nothing else (in-process stays).
   streamexec: replace the resolve()-argv construction with `--policy`
   args (+ existing tmpdir `--ro`), so bash always launches on the
   freshest file content. Remove now-dead resolve() usage.
9. [x] **3code: ui.nim + prompts.nim.** (done; :sandbox verbs write +/*/-, help updated, {{sandbox}} placeholder in all prompt constants + buildSystemPrompt) `:sandbox allow|readonly|deny`
   write `+`/`*`/`-` via procbox `appendRule`; `:sandbox show` via
   `renderPolicy`; help text to new syntax. Agent-facing prompt: when
   `sandbox.active`, append a compact section to the system prompt:
   rendered rules (or first N lines if huge) + "policy file:
   <repo path> (system: <path>); re-read when it changes". Find where
   the system prompt is assembled (prompts.nim) and keep it to a few
   lines.
10. [x] **3code: tests.** (done; cascade tests on new syntax, reloadIfChanged test, box --policy + reload integration tests in test_cli_args, harness fixture regenerated for new help text, full suite green) Update sandbox-syntax tests to `+`/`-`/`*`.
    New: mtime reload (edit policy, next checkRawPath/bash sees it),
    box `--policy` integration (bash `cat` a denied path fails EACCES,
    allowed path works), prompt section present when active. Extend
    existing broad tests where possible (project rule).
11. [x] **Docs.** (manual.md sandbox section rewritten to new syntax; procbox README policy section + Landlock caveat; CHANGELOG 0.2.0) procbox README policy section (format, cascade, host
    rules parsed-not-enforced, Landlock policy-writability caveat).
    3code docs/manual.md sandbox section. CHANGELOGs both repos.
12. [ ] **Full verification + review.** (in progress: both suites green, manual smoke found Landlock deny-under-writable limitation, documented) Both suites green. Manual smoke:
    deny a path, read tool refuses, bash `cat` EACCES, edit policy
    mid-session, next call picks it up. Review full diffs vs this plan.
    Commit per step group (procbox steps 2-5, then 3code steps 6-12).

### Smoke-test finding (accepted, documented)

`- ./sub` under a writable project dir does NOT deny on Landlock: layered
rules union, and procbox applies one layer. Seatbelt emits allows only
(deny default), so a sub-path deny is silently ineffective there too
(readonly under writable IS ineffective on all POSIX backends; it only
works for disjoint roots). This matches procbox's pre-existing
writable/readonly model: the lists are roots, not subtractive rules.
The policy language still records the intent (checkPath honors it for
the in-process tools, which DO deny correctly); kernel enforcement for
bash is coarser. Documented in procbox README. Possible future fix:
box could split into multiple stacked Landlock layers or rewrite
seatbelt profiles to order-specific denys; deferred.

## Decisions deferred (do not resolve this milestone)

- All network enforcement (see plan-network-firewall.md).
- procbox -> sandwall rename.
- Worker/subprocess execution of read/write/patch (rejected in R3;
  revisit only if in-process checks prove insufficient).
