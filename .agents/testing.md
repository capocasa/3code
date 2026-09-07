# Terminal test workflow

Read `design.md`, `development-guide.md`, and root `AGENTS.md` first.
Build locally with `nimble setup` once, then plain `nim c`; never install.

## Legacy fixture integration

Continuous recordings are diagnostics, not scheduling-stable goldens. The active
simple, multiline, bash and other-tool scenarios compare the final semantic text
frame against the reviewed historical fixture, retaining physical row boundaries
and adding the formerly omitted final prompt cursor. They also emit structured
checkpoints. This compatibility assertion remains lossy (not a style golden);
new visual contracts should use `expectCheckpoints` with explicit physical-cell
redactions, plus intermediate behavioral assertions. The command scenario asserts
each result and the recalled-input cursor instead of collapsing machine-specific
skill paths to fit its obsolete continuous fixture. No fixtures were regenerated.

The selector excludes the historical `when false` block and clears the old
`THREECODE_TTY_ONLY` filter so an exact selection cannot silently skip its body.

## Run, inspect, compare

```
tools/test_dispatch.sh files tests/tty/test_frame_contract.nim
nim c --out:/tmp/pty_frames tools/pty_frames.nim
/tmp/pty_frames testdata/output/tty/<run>/frames.txt.jsonl
/tmp/pty_frames --dump testdata/output/tty/<run>/frames.txt.jsonl
/tmp/pty_frames --diff expected.jsonl actual.jsonl
```

The viewer accepts both historical `===== 123 =====` fixtures and raw
`===== frame ... =====` recordings, plus versioned JSONL frames. Space pauses,
up/down change playback speed/direction, q exits. Use a terminal at least as
large as the capture; viewing in a smaller window crops, it does not reflow.
`--diff` returns nonzero on mismatch and reports zero-based frame/cell coordinates,
cursor state, and neighboring rows. Timestamps are diagnostic, not compared.

`writeFrameArtifact` writes readable text, exact unmodified PTY bytes (`.raw`),
and structured cells (`.jsonl`). JSONL preserves all attributes available in
ttty, physical widths, cursor visibility/location, pending wrap, and geometry.
Continuous frame IDs are capture indices. `checkpoint("turn-1/idle")` selects
an independent semantic snapshot; `writeCheckpoints` and `expectCheckpoints`
use the same JSONL format and comparator as the viewer. Select after `waitUntil`
observes live readiness (or after a frame/ticker acknowledgement), not a sleep.
All harness deadlines use a monotonic clock. Quiet-window cap expiry fails
explicitly; continuous capture is never disabled by polling assertions.
`redactCells` masks explicit cell ranges without moving columns or merging rows.
Do not normalize away cursor position or wrapped lines. Legacy meaningful text
is a lossy convenience projection, not proof of style equivalence. Do not blindly
regenerate fixtures after changing the harness; review differences against design.

## Verification surfaces

Harness contract tests feed terminal sequences directly into ttty; functional
PTY tests drive the real binary but still interpret output with ttty. Neither
proves real-emulator conformance. ttty currently does not preserve RGB components;
exact raw bytes remain available, but RGB appearance needs emulator verification.
For model/physical disagreement follow the root real-terminal screenshot rules:
match width/config/version state and verify nonempty screenshots of the actual
reported emulator. Report the surface and platform tested, not just pass counts.

## Selectable scenarios and stress

```sh
sh tools/tty_scenarios.sh --list
sh tools/tty_scenarios.sh 'initial prompt without -i runs once and exits (oneshot)'
sh tools/tty_scenarios.sh --stress
```

Selection uses exact unittest test names, rejects unknown names before building,
reuses one incremental binary, and prints build/run seconds, revision and binary
checksum. `--stress` explicitly selects the broad interrupt/multiline shakedown;
it is not a golden-regeneration lane. Normal testament runs retain broad coverage.
The selector can reproduce an individual case on macOS/Windows POSIX shell even
though testament still quarantines the full functional file. Do not claim those
platforms fixed without native evidence; their recorded hangs are not yet narrowed
to specific scenarios. See osx-testing.md for the native investigation workflow.

Review legacy fixture differences rather than copying all diagnostic frames:
continuous recordings now expose cursor-only states and previously suppressed
intermediate paints. Prefer named structured checkpoints for new goldens, with
explicit geometry-preserving volatile-field masks. Keep raw diagnostics intact.

## Guidance authority

Root `plan*.md`, `report*.md` and `impl*` documents are historical working notes,
not current harness API specifications. Preserve their historical evidence;
this guide, development-guide.md, design.md and osx-testing.md are the canonical
workflow entry points. The Astra review records its baseline separately from
subsequent implementation evidence.

The canonical runner is `tools/test_dispatch.sh` (testament metadata honored).
Build serialization and provenance are in `tools/build_binary.sh`.
