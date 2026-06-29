# Testing

## Visual Terminal Tests

The fat prompt contract is tested with PTY-backed visual tests in
`tests/test_tty_functional.nim`. These tests run a provider stub, capture every
terminal frame, and compare the complete frame stream to reviewed golden
artifacts instead of matching raw ANSI byte streams or selected surface rows.

Functional surface tests must not contain row-analysis assertions such as
"find these rows and prove their spacing". The surface is the full screen. Use
expect-style helpers only to drive the scenario and wait for progress; the
acceptance check is the full frame artifact.

All new tests for terminal-facing behavior should be primarily visual and
interactive whenever the behavior can be reached through the CLI. Drive the
real binary through the PTY harness, send the same keystrokes a user would send,
and record the resulting frame stream. Assertions against logs, saved session
files, command return values, raw stdout, or isolated helper state are secondary
checks only; they do not replace the visual artifact for behavior that appears
on screen.

For input flows, the test must cover the visible interaction, not just the
final state. Wizard entry, masked input, cancellation, buffered prompt handoff,
history navigation, command rejection, and active-turn output all need frames
showing the prompt or editor before typing, while typing, and after completion
or cancellation. If a bug report says "the screen is blank", "text appears
late", "typed input leaks", or "cancel shows stale text", the reproducer must
fail by showing that screen reality in the PTY frames before implementation
changes begin.

The PTY harness groups raw terminal bytes into artificial test ticks. It feeds
bytes into `ttty` immediately, then records a complete frame after a 16ms quiet
window, with forced flushes before sends, resizes, and process exit. This gives
the tests a gapless user-like view without changing production rendering.

Run the visual suite:

```sh
nim c -r tests/test_tty_functional.nim
```

Run the full suite:

```sh
nimble test
```

`nimble test` runs `tools/test.sh`, which compiles all tests in parallel
(roughly N-core faster than nimble's default sequential runner), builds the
`./3code` binary the spawn-based tests need, then runs the tests in order.
For fast iteration on one test, skip the suite and invoke the script
with a name filter:

```sh
tools/test.sh test_util        # compile + run a single test
tools/test.sh --compile         # compile everything, don't run
```

Visual artifacts are written under:

```text
tests/output/tty/<test-name>_<pid>/frames.txt
tests/output/tty/<test-name>_<pid>/meaningful_frames.txt
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
inside reserved editor rows. Prefer expanding an existing broad visual flow; add
a narrow PTY test only when the interaction cannot be covered cleanly there.
Do not substitute unit tests for visual tests unless the changed code is a pure
formatter/emitter with no terminal interaction.

Golden files live under:

```text
tests/fixtures/tty/
```

Do not bless a golden that contains known-bad visual behavior just to make the
suite pass. Fix the visual stream first, then promote the reviewed artifact.
