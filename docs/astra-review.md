# Astra review

Original review scope: test architecture, screenshot-driven development, transport/session boundaries, and the GPT-family prompt, against baseline `645409a`. The original review changed only the prompt and its integration tests. The implementation follow-up below supersedes its change/verification limits; neither is a whole-repository correctness certification.

## Implementation follow-up (stages 1–6)

The findings below describe the review baseline, not the current implementation.
Stages 1–5 landed in `c3ee0a6`, `227ba75`, `56b1b6c`, `1330e9f`, and `0e0ffee`.
Stage 6 integrated them without regenerating visual fixtures.

| Finding | Resolution / boundary |
|---|---|
| 1 — false-pass expectations | Unmet assertions fail after exit and deadline; negative PTY contracts cover both. |
| 2 — lossy capture | Continuous JSONL preserves modeled cells, attributes, cursor, wrap and geometry; raw bytes remain the authoritative escape stream. |
| 3 — stale binaries | One serialized incremental compiler wrapper, atomic publication and option-specific stub paths; source/include/staticRead/config/concurrency regressions. Integration also fixed literal quotes in out-of-tree dependency flags. |
| 4 — hidden runner failures | Shared metadata-aware testament dispatcher, quoted selections and aggregate status; missing testament is an error. |
| 5 — watchdog ownership | Only descendants of the owned test runner are eligible for termination; duration arithmetic is POSIX-compatible. |
| 6 — session collisions | Atomic random-suffixed reservations and canonical full-path lock keys; symlink resolution and empty-reservation draft semantics tested. Hard-link and case-fold aliases are not unified by pathname identity. |
| 7 — connection identity | Scheme/TLS participates in reusable connection identity; library initialization explicitly rejects concurrent singleton ownership. This is not multi-session isolation. |
| 8 — viewer/comparator | Shared structured parser, dump, compare and style rendering; negative comparator and CLI contracts. |
| 9 — settling | Monotonic bounded polling, quiet-cap failure, semantic readiness/checkpoints independent of diagnostic capture. Integration uses a 40ms post-match quiet window below the live GUI's 80ms cadence; removing settling entirely reproduced dropped initial keystrokes. |
| 10 — selection/platforms | Exact compiled-scenario selection and explicit stress lane with revision/checksum/timing. Disabled source blocks are not advertised; old environment filtering cannot silently skip an exact selection. Native quarantines remain, not falsely declared fixed. |

### Stage 6 visual review

Reviewed the final states in simple, multiline, bash and other-tool fixtures
against actual recordings. Newly retained startup, cursor-only and streamed
intermediate frames are expected consequences of continuous capture, not a stable
golden sequence. Those scenarios now assert the historical final text state,
with the visible final cursor restored, and emit structured semantic checkpoints.
Row joins and cursor stripping were not reinstated. A negative contract verifies
that a changed physical row boundary fails. Text compatibility still masks version
and elapsed values and does not assert style; structured comparison is the new
contract for style-sensitive tests, not a claim that these old fixtures are lossless.

The command fixture embeds machine-specific paths previously collapsed by the
normalizer. Its replacement contract asserts every command result, the actual
random-suffixed session ID and the recalled-input caret, retaining full diagnostic
and checkpoint artifacts. The pre-existing disabled resize/main-visual block is
still disabled and no longer appears as a runnable selector success.

### Verification evidence and limits

Linux x86_64, Nim 2.2.10; terminal surface is POSIX PTY bytes interpreted by ttty,
**not an emulator screenshot**. No rendering discrepancy required a real-emulator
reproduction. No packages installed or pushed.

- Initial `sh tests/tools/test_dispatch.sh all` exercised all six categories. API probes
  exposed the dependency-quote bug; the API file then passed in 59.32s. The run
  recorded 29 core, 7 config, 4 shell, 6 stream and 5 other API file passes.
  Overlapping exploratory runs were stopped by owned process tree; this is not
  presented as a single clean full-suite pass.
- Full functional file passed through testament in **298.94s** after fixing the
  reservation assertion: a pre-turn session owns exactly one empty `.3log`, not
  no file. `/tmp/astra-functional6-verified.log`.
- Build provenance, frame and selector contracts pass in
  `/tmp/astra-contracts6-final.log`; PTY negative assertions pass in
  `/tmp/astra-contracts6.log`. The frame suite includes the new negative legacy
  final-state comparison; the selector rejects disabled names before compilation.
- Selected shakedown and command scenarios pass: build 5s, run 9s/13s,
  `/tmp/astra-harness6b.log`. Four active final-state goldens pass in
  `/tmp/astra-goldens6b.log`; draft restoration passes in `/tmp/astra-draft6.log`.
- Broader TTY rerun verified live GUI (242.64s), spinner race stress (128.65s),
  provider editing/cancellation, quiet-network interruption, resize and signal
  paths. The completed `/tmp/astra-tty6-final.log` has **33/35 file passes**;
  its two failures were the intermediate frame-contract compile error and a
  real-stream teardown hang. Both corrected files pass on rerun. The latter was
  reproduced in one iteration and traced with bounded `strace`: Nim 2.2's default
  SafeDisconn send loop spins on EPIPE after child teardown. Mock sends now raise
  on disconnect and close the accepted socket on error. Both mock-server consumers
  pass in `/tmp/astra-mock6-final.log` (12-iteration real-stream test 25.58s,
  network interruption 47.46s). This is broader coverage plus corrected-file
  reruns, not a claim of one clean full-suite invocation.
- `sh tests/tools/build_binary.sh /tmp/astra-release6 src/threecode.nim -d:release`
  passed (cold 30.479s, final incremental 10.746s); `--version` reports the tested
  working-tree revision. `/tmp/astra-release6-final.log`.
- Configured `stefani` VM probe with batch mode and strict known-host checking was
  refused at 127.0.0.1:22222. macOS and Windows are **unverified**; no remote CI
  was triggered. Exact selectors support native reproduction when access exists.
- Remaining boundaries: ttty does not retain RGB components from its dependency
  model (raw bytes do); canonical pathname locks do not unify hard links or
  case-fold aliases; library state remains singleton; no behavioral model A/B
  evaluation or speculative prompt-module split was performed.

## Prioritized findings

### 1. High: a missing expectation can pass after child exit

`tests/tty_expect.nim:1440-1479`: `expect` is discardable and normally asserts on timeout, but its exited-child branch returns `false` instead. A caller using the normal statement form does not fail. This gives a crashed or prematurely exited child an escape route from the assertion.

Reproduced locally with `newTtySession("/bin/true")`, `expectExit(0)`, then `expect("THIS TEXT WAS NEVER PRODUCED", timeoutMs = 30)`. Execution continued and exited zero. Surface: actual POSIX PTY process with the ttty harness, not a screenshot.

Recommendation: separate `waitForText(): bool` from `expectText()` which always raises on failure. Add negative tests of the harness itself: early exit, absent content, stale content, deadline expiry. Every assertion helper should have a demonstrated failing case.

### 2. High: visual recordings discard changes the screenshot contract needs

`tests/tty_expect.nim:174-203`: recorded frames are deduplicated on text rows alone before cursor state is stored. A cursor-only move or visibility change is dropped. `normalizeFrameRows` at line 1239 additionally removes trailing cursor markers. `frameRowsWithCursor` at line 1248 counts runes as cells, which misplaces the cursor overlay after wide or combining characters. Recorded rows use `rowText`, so style is not part of the golden comparison.

`normalizeWrappedPathTail` at line 1391 joins a row ending `.m` with a following `d` row. This is not just redaction: it erases a real row boundary, and it is not constrained to a skill-path field. A wrapping defect can therefore compare equal.

Recommendation: compare structured cells and explicit cursor state. Normalize identified dynamic fields without changing occupied cell widths or row counts. Fix environment-dependent path lengths before rendering, rather than rewriting geometry afterward. Retain raw bytes and dimensions for replay. Model-level checks must be supplemented by actual emulator captures for wrap/scroll/erase disagreements.

### 3. High: cached test binaries do not reliably represent current inputs

`tests/stub_helpers.nim:103-155`: `ensureStubBinary` invalidates only for newer `.nim` files under `src`; edits to the included `tests/testdata/stub/provider.nim` and `http.nim` do not invalidate it. The neighboring `buildBinary` implementation at lines 61-101 already accounts for the stub directory, demonstrating drift between duplicated build paths.

Neither helper tracks compiler identity, changed defines for the same output name, config files, skill text embedded by the build, or develop-linked dependency changes. Both build into shared output/cache paths without synchronization. Concurrent categories or local runs can race a cold build or invalidation. The race is a source-based risk, not reproduced here.

`threecode.nimble:62-64` separately implements another incomplete freshness check for the production executable.

Recommendation: one build entry point, one configuration identity, and serialized publication of shared artifacts. Prefer invoking Nim's incremental build over maintaining partial dependency scanners. Record the build identity in failure artifacts. Never diagnose a renderer until the executable's provenance is known.

### 4. High: named test runs can hide an earlier failure

`threecode.nimble:55-69`: multiple testament commands are joined with `;`, with no failure accumulation or `set -e`. If an earlier named test fails and the last succeeds, the inner shell returns success. The no-testament fallback has the same issue in its loops. It also compiles helpers/probes and bypasses testament metadata such as platform disabling and test-specific commands.

Recommendation: use one runner for local and CI invocation, aggregate every selected test's status, and fail explicitly if testament is unavailable rather than approximate its semantics. Add runner tests with a failing first test and successful last test. Quote file arguments rather than concatenating them into shell syntax.

### 5. Medium: the watchdog can kill tests belonging to another run

`tests/tools/ci_tests.sh:78-94` searches the machine's process list for matching `tests/<category>/test_*` command names, without checking ancestry against this invocation. The global timeout path similarly uses broad process-name matching. Another worktree or concurrently running developer test can be killed once it exceeds this runner's threshold.

`tests/tools/ci_tests.sh:59` also uses `10#` arithmetic with a `/bin/sh` entry point. This is supported by bash, including this review machine's `sh`, but not portable POSIX shell syntax. It needs validation on the actual CI shell; no dash runtime was available here.

Recommendation: scope every watchdog action to owned descendants. Use portable decimal parsing or explicitly require the shell whose syntax is used. Test timeout attribution and exit status with short-lived dummy process trees.

### 6. High: session names and lock keys collide across isolated sessions

`src/threecode/session.nim:67-69` gives new sessions only second-resolution timestamp names. `sessionLockPathFor` at lines 210-214 keys the shared temporary lock directory by that basename, not the complete session path or data root. Independent data roots started in the same second can contend for the same lock. Starts in the same data root also generate the same prospective log path.

The CI runner's comment at `tests/tools/ci_tests.sh:61-64` already describes second-granularity collisions as a source of library-test failures. This is a production identity problem, not something longer test delays should solve.

Recommendation: collision-resistant session identities and atomic creation; namespace locks by the actual resource identity. Test simultaneous creation both within one data root and across isolated roots. Preserve existing session lookup compatibility.

### 7. Medium: connection cache identity omits transport security

`src/threecode/api.nim:704`, `1198`, `1484`, and `1684` key cached connections only by hostname and port. The four request paths permit loopback HTTP when `testPlainHttp` is defined, and `config.nims:28` enables that define for ordinary builds too.

Switching from `http://localhost:PORT` to `https://localhost:PORT` can reuse the existing plaintext connection instead of making a TLS connection. This is a conditional source-level finding; no live credential-bearing request was sent. Plain HTTP is restricted to loopback names, so this is not a general remote plaintext allowance.

Recommendation: include transport mode in connection identity and test scheme changes on the same host/port. Decide whether loopback HTTP is a supported product feature or test-only capability, then configure it explicitly. Centralize URL validation, connection acquisition, and stale-connection recovery; keep protocol-specific decoding separate. The four repeated acquisition paths are a recurring maintenance trap.

### 8. Medium: visual fixture review lacks one dependable interface

`meaningfulFrameText` at `tests/tty_expect.nim:1304` emits randomly numbered `===== NNN =====` headers. `tests/tools/pty_frames.nim:19-20` only recognizes `===== frame ... =====`. Thus the viewer can read raw `frames.txt` recordings but not the meaningful golden/actual files produced by the comparator. The comparator at lines 1420-1438 reports two paths, not the first differing frame/cell. Random frame identifiers add noise without stable references.

Root `AGENTS.md` also directs agents to `.agents/testing.md` and `.agents/osx-testing.md`, neither present in this checkout. Several historical plans describe older harness states. These broken entry points cost every fresh model exploration time.

Recommendation: one versioned artifact format accepted by capture, diff, and viewer; stable scenario/checkpoint names; first mismatch coordinates and a short expected/actual crop. Restore the canonical testing guide and clearly mark historical reports as archival.

### 9. Medium: time-based settling is still a costly, incomplete readiness contract

`tests/tty_expect.nim:530-553` waits for 120 ms of silence, capped at 3 seconds, but returns no indication that the cap expired. `expect` invokes it on a match. Silence does not prove readiness, and continuous valid output can hit the cap. Deadlines throughout the harness use `epochTime`, which is sensitive to wall-clock changes.

The harness already has frame events and acknowledgements; this is not an entirely sleep-driven suite. The remaining problem is using quiet windows as semantic completion, while suppressing frame recording during expectations. Intermediate regressions may be absent from the artifact even when bytes passed through the PTY.

Recommendation: explicit readiness/checkpoint events, monotonic hung-child deadlines, and failures that distinguish timeout from child exit. Keep raw capture continuous; select semantic comparison checkpoints separately. Measure quiet-wait time before optimizing it.

### 10. Medium: broad coverage and platform coverage are coupled too tightly

`tests/tty/test_tty_functional.nim` contains 46 tests across 3,102 lines, but its file-level spec disables the whole file on macOS and Windows because of hangs. The notes describe a threaded rendering deadlock on macOS and output-pipe pressure on Windows. Those are unresolved product/harness boundary risks, not just slow tests.

Recommendation: retain a broad shakedown but extract shared scenario setup and make scenarios selectable by stable identifier. Run the supported scenarios on each platform; quarantine only a specifically demonstrated failing scenario with an owner and reproduction. Keep race/load stress separate from deterministic screenshot matching. Do not split every assertion into another separately compiled executable.

## Target screenshot-to-test workflow

A prompt containing a command-line screenshot should require one short path:

1. Select an existing scenario and state terminal dimensions, input mode, startup/config state, and intended checkpoint.
2. Encode expected cells, geometry, style, and cursor independently of actual output. A screenshot alone may not reveal logical columns, font metrics, or hidden scrollback; record uncertainty instead of inventing it.
3. Run only that scenario against a provenance-checked binary. Synchronize to semantic events, not arbitrary delay budgets.
4. Return a compact mismatch: checkpoint, row/column, expected/actual crop, raw capture, and replay metadata.
5. For suspected terminal semantic disagreement, drive the reported emulator and inspect a non-empty real screenshot at the same dimensions. Do not substitute ttty's interpretation as proof.
6. Run affected regression scenarios; promote race cases to a separate stress lane.

Suggested command shape, not implemented: `visual run shakedown/queued-prompt --cols 119 --rows 32`, followed by `visual diff <artifact>` and `visual view <artifact>`. The important feature is a shared artifact and scenario identity, not another wrapper script.

## Quality priorities for economical model work

- **Trustworthy failure first.** Assertion helpers and runners need negative-path tests before more product cases are added.
- **Explicit ownership.** Process trees, network connections, locks, and mutable state must have one owner and clear lifetime. Inspect the library's process-global transport/UI state before promising concurrent sessions; `promptAsync` alone does not make it session-isolated.
- **One policy location.** Consolidate build identity, connection acquisition, and expectation failure semantics. Avoid blanket DRY refactors across genuinely different protocols.
- **Discoverable boundaries.** Split `prompts.nim` by provider metadata, tool schemas, prompt text, and installation logic when touching those areas. Its current 3,360 lines mix all four and force broad reads and compilation for unrelated edits. Do not introduce a generic plugin framework merely to move strings.
- **Deterministic artifacts.** Stable names, explicit dimensions, lossless raw capture, semantic checkpoints, controlled dynamic fields, and no geometry-changing normalization.
- **Measured performance.** Record cold/warm build time, per-scenario runtime, quiet-wait time, and timeout/retry counts. Establish a fast focused lane, broader platform lane, and opt-in stress lane. No full-suite timing claim was established in this review.
- **Small handoffs.** One current development/testing entry point and concise reproducible failure reports. Historical plans must not masquerade as present architecture.
- **Evaluate prompts behaviorally.** String-presence tests protect wiring, not agent quality. Compare representative models on the same tasks: screenshot mismatch, early child exit, stale binary, blocked permission, unrelated dirty files, and recovery from a failed experiment. Measure successful completion, unwanted edits, total tokens, commands, latency, and unsupported verification claims.

## GPT prompt revision

Kept one GPT-family prompt and the existing Sol identity. There is no measured reason here to create Luna/Astra/Sol forks; older GPT models retain the same contract. GPT-OSS and other families are unchanged.

The revision emphasizes total task cost rather than shortest replies, discriminating experiments, observable success, bounded persistence, explicit blockers, assertion/binary provenance, screenshot verification surfaces, untrusted-content handling, and concise handoffs. It removes two counterproductive absolutes: never retry unchanged even for a demonstrated transient failure, and never yield with pending work even when permission or input is missing.

This plays to careful reasoning without demanding long narration. It does not claim that prompt text alone solves the infrastructure defects above or that a particular persona makes a model more capable.

## Original review verification and limits

- `nimble setup` generated local dependency paths; no package installation or push.
- `nim c -r --out:/tmp/astreview-prompts tests/api/test_prompts_compact.nim`: **84 tests passed**, including shared GPT prompt/tool routing and the existing compact tests. Pure integration tests, no renderer or model API evaluation.
- A temporary Nim probe reproduced the exited-child expectation false pass against `/bin/true` under a POSIX PTY with the ttty harness.
- `git diff --check` passed before finalization.
- No full-suite run, runtime benchmark, real emulator screenshot comparison, macOS/Windows execution, or behavioral model A/B evaluation was performed. Findings not labeled reproduced are source-derived. Architectural fixes remain recommendations, deliberately outside this review's code changes.
