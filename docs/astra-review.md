# Astra review

Scope: test architecture, screenshot-driven development, transport/session boundaries, and the GPT-family prompt. Reviewed against baseline `645409a`. This is a targeted source review, not a whole-repository correctness certification. Only the prompt and its integration tests were changed.

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

`tests/stub_helpers.nim:103-155`: `ensureStubBinary` invalidates only for newer `.nim` files under `src`; edits to the included `testdata/stub/provider.nim` and `http.nim` do not invalidate it. The neighboring `buildBinary` implementation at lines 61-101 already accounts for the stub directory, demonstrating drift between duplicated build paths.

Neither helper tracks compiler identity, changed defines for the same output name, config files, skill text embedded by the build, or develop-linked dependency changes. Both build into shared output/cache paths without synchronization. Concurrent categories or local runs can race a cold build or invalidation. The race is a source-based risk, not reproduced here.

`threecode.nimble:62-64` separately implements another incomplete freshness check for the production executable.

Recommendation: one build entry point, one configuration identity, and serialized publication of shared artifacts. Prefer invoking Nim's incremental build over maintaining partial dependency scanners. Record the build identity in failure artifacts. Never diagnose a renderer until the executable's provenance is known.

### 4. High: named test runs can hide an earlier failure

`threecode.nimble:55-69`: multiple testament commands are joined with `;`, with no failure accumulation or `set -e`. If an earlier named test fails and the last succeeds, the inner shell returns success. The no-testament fallback has the same issue in its loops. It also compiles helpers/probes and bypasses testament metadata such as platform disabling and test-specific commands.

Recommendation: use one runner for local and CI invocation, aggregate every selected test's status, and fail explicitly if testament is unavailable rather than approximate its semantics. Add runner tests with a failing first test and successful last test. Quote file arguments rather than concatenating them into shell syntax.

### 5. Medium: the watchdog can kill tests belonging to another run

`tools/ci_tests.sh:78-94` searches the machine's process list for matching `tests/<category>/test_*` command names, without checking ancestry against this invocation. The global timeout path similarly uses broad process-name matching. Another worktree or concurrently running developer test can be killed once it exceeds this runner's threshold.

`tools/ci_tests.sh:59` also uses `10#` arithmetic with a `/bin/sh` entry point. This is supported by bash, including this review machine's `sh`, but not portable POSIX shell syntax. It needs validation on the actual CI shell; no dash runtime was available here.

Recommendation: scope every watchdog action to owned descendants. Use portable decimal parsing or explicitly require the shell whose syntax is used. Test timeout attribution and exit status with short-lived dummy process trees.

### 6. High: session names and lock keys collide across isolated sessions

`src/threecode/session.nim:67-69` gives new sessions only second-resolution timestamp names. `sessionLockPathFor` at lines 210-214 keys the shared temporary lock directory by that basename, not the complete session path or data root. Independent data roots started in the same second can contend for the same lock. Starts in the same data root also generate the same prospective log path.

The CI runner's comment at `tools/ci_tests.sh:61-64` already describes second-granularity collisions as a source of library-test failures. This is a production identity problem, not something longer test delays should solve.

Recommendation: collision-resistant session identities and atomic creation; namespace locks by the actual resource identity. Test simultaneous creation both within one data root and across isolated roots. Preserve existing session lookup compatibility.

### 7. Medium: connection cache identity omits transport security

`src/threecode/api.nim:704`, `1198`, `1484`, and `1684` key cached connections only by hostname and port. The four request paths permit loopback HTTP when `testPlainHttp` is defined, and `config.nims:28` enables that define for ordinary builds too.

Switching from `http://localhost:PORT` to `https://localhost:PORT` can reuse the existing plaintext connection instead of making a TLS connection. This is a conditional source-level finding; no live credential-bearing request was sent. Plain HTTP is restricted to loopback names, so this is not a general remote plaintext allowance.

Recommendation: include transport mode in connection identity and test scheme changes on the same host/port. Decide whether loopback HTTP is a supported product feature or test-only capability, then configure it explicitly. Centralize URL validation, connection acquisition, and stale-connection recovery; keep protocol-specific decoding separate. The four repeated acquisition paths are a recurring maintenance trap.

### 8. Medium: visual fixture review lacks one dependable interface

`meaningfulFrameText` at `tests/tty_expect.nim:1304` emits randomly numbered `===== NNN =====` headers. `tools/pty_frames.nim:19-20` only recognizes `===== frame ... =====`. Thus the viewer can read raw `frames.txt` recordings but not the meaningful golden/actual files produced by the comparator. The comparator at lines 1420-1438 reports two paths, not the first differing frame/cell. Random frame identifiers add noise without stable references.

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

## Verification and limits

- `nimble setup` generated local dependency paths; no package installation or push.
- `nim c -r --out:/tmp/astreview-prompts tests/api/test_prompts_compact.nim`: **84 tests passed**, including shared GPT prompt/tool routing and the existing compact tests. Pure integration tests, no renderer or model API evaluation.
- A temporary Nim probe reproduced the exited-child expectation false pass against `/bin/true` under a POSIX PTY with the ttty harness.
- `git diff --check` passed before finalization.
- No full-suite run, runtime benchmark, real emulator screenshot comparison, macOS/Windows execution, or behavioral model A/B evaluation was performed. Findings not labeled reproduced are source-derived. Architectural fixes remain recommendations, deliberately outside this review's code changes.
