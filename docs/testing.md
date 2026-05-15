# Testing

## Visual Terminal Tests

The fat prompt contract is tested with PTY-backed visual tests in
`tests/test_tty_functional.nim`. These tests run a provider stub, capture every
terminal frame, and assert visual invariants over those frames instead of
matching raw ANSI byte streams.

The current visual suite records whole frames and checks the important rows,
spacing, caret placement, prompt anchoring, and selected frame-series snapshots.
The next step is a stricter semantic full-frame verifier where every nonempty
row in every frame must be explained as transcript, receipt, live token bar,
ticker, editor, or allowed chrome.

Run the visual suite:

```sh
nim c -r tests/test_tty_functional.nim
```

Run the full suite:

```sh
nimble test
```

Visual artifacts are written under:

```text
tests/output/tty/<test-name>_<pid>/frames.txt
```

`tests/output/` is gitignored so frames persist locally between runs without
entering commits.

Review the latest recorded animation:

```sh
nim r tools/pty_frames.nim
```

Review a specific artifact:

```sh
nim r tools/pty_frames.nim -- tests/output/tty/visual_12345/frames.txt
```

Viewer controls:

- `Space` pauses or resumes playback.
- `Up` increases forward speed.
- `Down` slows playback, then reverses at negative speeds.
- `q` or `Esc` exits.

When changing prompt, token bar, streaming, or tool-output behavior, update or
add visual tests first. The important failures are transient frames: duplicated
bars, hidden scrollback, prompt jumps, caret outside the editor area, and output
inside reserved editor rows.
