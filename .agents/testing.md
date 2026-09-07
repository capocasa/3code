# Terminal test workflow

Read `design.md`, `development-guide.md`, and root `AGENTS.md` first.
Build locally with `nimble setup` once, then plain `nim c`; never install.

## Run, inspect, compare

```
tools/test_dispatch.sh tests/tty/test_frame_contract.nim
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
Frame IDs are capture indices; selected checkpoints should use semantic IDs.
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

The canonical runner is `tools/test_dispatch.sh` (testament metadata honored).
Build serialization and provenance are in `tools/build_binary.sh`.
