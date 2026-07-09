# Plan: kill tty test flakiness via content-based frame splitting

Supersedes `plan-flakiness.md` (whose Step 1, event-driven `expect`, landed
in commit 3122d91) and the earlier draft of this file. This version is
grounded in a full reproduction + bisect done against HEAD (c0541ed).

## What hy3 got right and wrong

hy3's `plan-frame-split.md` correctly identified that frame *splitting* is
the remaining source of flakiness and that the child already emits the
signals needed to split deterministically. Two claims were wrong:

1. **"Frame count flickers" / "over-splits or under-splits."** Measured:
   frame count is *stable* across pass/fail runs. `harness_commands` produces
   exactly 35 frames whether it passes or fails; `simple` produces 6 every
   time. The flakiness is **boundary placement drift**, not count drift. The
   same logical renders get grouped into frames at different seams depending
   on poll timing, so a given render's bytes land in frame N on one run and
   frame N+1 on the next. `meaningfulFrameText` compresses adjacent identical
   frames, but when content moves between frames the compressed sequences
   differ and the golden comparison fails.

2. **"This is purely a splitting defect."** It is not. Two of the consistent
   failures (`simple`, `multiline`) are **stale golden fixtures** caused by a
   real rendering change, not splitting noise. See "Phase 0" below.

hy3's core mechanism — split on the child's render-burst signal, not on a
settle timer — is correct and is the heart of this plan. The improvement is
to key the split on the **sync protocol** the child already emits
(`SyncBegin`/`SyncEnd` = `\x1b[?2026h`/`\x1b[?2026l`), which is a stronger
signal than the "zero-wait poll" heuristic hy3 proposed (a single child
`flushFile` burst can still arrive as several `read()` returns under load, so
"poll returned no POLLIN" does not reliably mean the writer stopped).

## The two failure classes (measured at HEAD, 5 sequential runs)

Deterministic (fail every run) — stale fixtures:
- `simple one-turn prompt and reply`
- `multiline prompt and queued multiline autosend`

Flaky (fail intermittently) — frame-boundary drift:
- `harness commands are transcript items`
- `bash tool success and nonzero exit`
- `consecutive turns never accumulate extra blank separator lines`
- `initial prompt with -i stays in the interactive REPL`
- `idle ctrl-c clears typed line without eating the row above`

The deterministic pair must be fixed first or they mask progress on the
flaky set.

## Phase 0 — regenerate the two stale golden fixtures (prerequisite, not optional)

Bisect: `simple`/`multiline` passed at `f9c75d0` (where the fixtures were
regenerated) and first failed at `2bb7199` ("Merge branch 'polish'"). That
merge introduced a rendering change — the blank separator row between the
"type a prompt" hint and the prompt echo disappeared (prompt echo now paints
one row higher), and when the turn starts the separator inserts and content
scrolls, dropping "type a prompt" from later frames. The fixtures were never
regenerated after the merge.

Concretely, at `f9c75d0` frame 0001 had `changed=@[1,2,3,5,6,8,10]` with a
blank row 9 between "type a prompt" (row 8) and the echo (row 10). At HEAD
frame 0001 has `changed=@[1,2,3,5,6,8,9]` — echo on row 9, no blank.

This is a real rendering behavior change, not a bug to revert. Action:
**regenerate `testdata/fixtures/tty/simple.txt` and `multiline.txt`** by
running the tests with the current binary and promoting the
`*_actual.txt` outputs, after confirming (by eye) the new layout is
correct. Do NOT regenerate the flaky tests' fixtures yet — those must
stabilize via Phase 1 first, or we'd be baking in a particular frame
partition that drifts again.

Note: `b7902e3` ("strip leading/trailing blank lines from assistant
content") and `6c73037` ("new line fix") are later rendering changes on the
same theme; eyeball the regenerated fixtures against the design doc's visual
contract (`.agents/design.md`) before committing.

## Phase 1 — content-based frame splitting (the core fix for the flaky set)

### Mechanism: commit a frame on every `SyncEnd`

Every render burst on the main path is wrapped in exactly one
`SyncBegin..SyncEnd` pair followed by `flushFile` (`engine.nim`
`renderFooter`/`renderToolViewport`/`appendTranscript`; `terminal.nim`
`syncWrite`/`beginEditorRedraw`..`finishEditorRedraw`). The harness already
parses these via `noteSyncState` and tracks `syncDepth`, and `flushFrame` is
already gated on `syncDepth == 0`. The fix is to make `flushFrame` fire
**exactly when `syncDepth` transitions back to 0** (a `SyncEnd` was parsed),
rather than only when a poll happens to return no bytes.

This makes each frame = one child render burst, deterministically. The
boundary signal comes from the child's own output stream, so it is
load-independent. This is the content-based split hy3 sought, implemented
on the protocol that already exists.

Changes (all in `tests/tty_expect.nim`):
- `noteSyncState`: when it decrements `syncDepth` to 0, call `flushFrame()`
  (commit the just-completed burst as a frame). Keep `markFrameDirty` on
  byte arrival so the frame captures the burst's net effect.
- `flushFrame`: keep the `syncDepth > 0` guard (don't flush mid-burst) and
  the `pendingFrame` guard (don't double-commit). The new call site from
  `noteSyncState` is the primary commit path.
- `pollOnce`: the idle-path `flushFrame` (when poll returns no bytes)
  becomes a fallback for non-sync writes (`writeRaw`, `enterPromptInput`,
  ui.nim wizard writes) that have no SyncEnd. Keep it, but it is no longer
  the pacing mechanism for the main path.

### Honor explicit frame events as hard boundaries (already mostly done)

`emitTestFrameEvent` (called from `turns.nim` at streaming/tool boundaries
and `config.nim` at the experimental-gate refusal) writes one byte to the
frame-event pipe and **blocks on an ack**. `pollOnce` already drains the PTY,
flushes a frame, and acks on event arrival. Keep this. With Phase 1's
SyncEnd split, the frame event becomes a redundant-but-harmless hard
boundary: the burst that preceded it already committed via its SyncEnd, and
the event ensures a frame even for boundaries with no visible sync write.

Gap to audit: `emitTestFrameEvent` has only 5 call sites (all in turns.nim
streaming/tool paths + config gate). The prompt-echo commit
(`commitTranscriptBytes`), the final assistant content commit, and the idle
prompt repaint do NOT emit frame events. With SyncEnd splitting these are
covered (they're sync-wrapped), so no new emits are strictly required. But
if a specific flaky test still drifts after Phase 1, the cause is a missing
sync wrap on that path — add a `syncWrite`/SyncBegin..SyncEnd there, not a
new frame event.

### Make `drain` deterministic

`drain(settleMs)` is called all over test bodies as a "let it settle" pause.
Repurpose it to mean "capture all frames until the child is quiet" with no
wall-clock floor:

- Loop `pollOnce(0)` while bytes/events keep arriving. Stop when a poll
  returns nothing.
- Keep a hard cap (2s) purely as a dead-child safety net, not pacing.
- Drop the `sleep 1` from the settle loop.

This removes the timing that causes boundary drift. The frame stream
becomes a function of the child's output, identical run to run.

### Finish the two remaining wall-clock pollers

`plan-flakiness.md` Step 1 converted most `expect*` to `waitForOutput`, but
two still use `sleep 5` busy-loops:
- `expectNo` (tty_expect.nim:774,777)
- `expectTokenBar` (tty_expect.nim:961,970)
- `expectAlive` (tty_expect.nim:833) uses `drain(5)`

Convert these to the `waitForOutput`-then-check pattern so they don't
starve under load. `expectNo` is trickier (it asserts absence over a window)
— keep its deadline but drive the polls via `waitForOutput` not `sleep`.

## What stays untouched

- All `expect*` assertion signatures and call sites in test bodies.
- `expectMeaningfulFrameArtifact`, `meaningfulFrameText`, all normalizers
  (`normalizeElapsed`, `normalizeSpinnerPhases`, `normalizeVersionBanner`,
  `normalizeTtyRunRoots`, `normalizeWrappedPathTail`, `stripFrameBlanks`,
  `normalizeFrameSeparators`).
- `TtyFrame.ms` (diagnostics only; no assertion reads it — verified).
- The `advanceTicker` / ticker-pipe deterministic spinner drive.
- `src/` production code (no new emits unless Phase 1 surfaces a gap).

## Verification

1. After Phase 0: `simple` and `multiline` pass 5/5.
2. After Phase 1: run each previously-flaky subtest 20x in isolation +
   20x under full `testament all` parallel load: 0 failures.
3. Diff `meaningful_frames.txt` for `harness_commands` across 5 runs:
   byte-identical (proving the split is now deterministic).
4. Full `testament --megatest:off all` 5x: 0 failures, no exit-code flips.

## CI timing / parallelism (secondary goal)

Current state: `testament all` runs 6 categories (stream, core, api, config,
shell, tty) as parallel `execProcesses` children; within a category, tests
run sequentially. Locally ~5min wall; CI Linux amd64 ~4m13s. The tty
category is the long pole (~44s for `test_tty_functional.nim` alone, plus
12 other tty files sequentially).

The "under 1 minute" goal is not achievable for the whole suite on a 2-core
GitHub runner via testament alone — compilation of 6 category processes
dominates. But once flakiness is killed:
- Tests stop timing out/retrying, removing the largest source of variance.
- The tty category can be split into 2-3 sub-categories (e.g. `tty_visual`
  vs `tty_regression`) so testament parallelizes them. This is the highest-
  leverage timing win: `test_tty_functional.nim` is 44s; splitting it
  roughly halves the tty long pole. Do this ONLY after Phase 1 lands and is
  stable — splitting flaky tests just multiplies the flake surface.
- Consider `--batch` sharding if further reduction is needed later.

There is also a **separate CI masking bug**: the "Run tests" step throws an
OSError/nimscript error when testament exits non-zero, but the GitHub job
still reports ✓ (verified on run 28999965132, which had `FAILURE! total: 12
passed: 10 failed: 2` yet shows green). This means flaky failures are
silently swallowed in the dev hot path. Investigate separately — likely
nimble's nimscript `exec` not propagating the sh exit code. Not blocking
this plan but worth a follow-up so green CI actually means green tests.

## Execution order

1. **Phase 0**: regenerate `simple.txt` + `multiline.txt`, verify 5/5 pass.
2. **Phase 1a**: implement SyncEnd-driven `flushFrame` in `tty_expect.nim`.
3. **Phase 1b**: rewrite `drain` to be event-driven (no settle timer).
4. **Phase 1c**: convert `expectNo`/`expectTokenBar`/`expectAlive` to
   `waitForOutput`.
5. Verify per the checklist above.
6. (Optional, post-stability) split the `tty` category for parallelism.
