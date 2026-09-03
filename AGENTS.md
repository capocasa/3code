# Agent Notes

Before changing terminal rendering, read:

- `.agents/design.md` for the fat prompt architecture and visual contract.
  architecture and module MVC responsibilities.
- `.agents/testing.md` for visual test and frame viewer workflow.
- `.agents/development-guide.md` for agent development and bugfixing rules.
- `.agents/osx-testing.md` for reproducing and verifying macOS fixes via the
  stefani VM and the OSX-only CI workflow.

Bug reports must be reproduced in visual tests before implementation changes.
Prefer expanding the main shakedown or another broad visual test; add narrow
one-off tests only as a last resort.

## Reproducing terminal-rendering bugs: ground rules

These rules exist because a multi-hour debugging session once "verified" a
fix by driving a real xterm and then checking the result only through ttty's
Grid — a model that shares the app's own row-math assumptions, so any bug
caused by the app and a real terminal disagreeing (wrap, scroll, erase
semantics, width) is invisible there: both sides make the same wrong
assumption and the frame looks perfect.

1. **When reproduction is impossible in ttty, reproduce against a real xterm
   and make sure to check the xterm** — screenshot the actual window
   (`xdotool search --class xterm`, then `import -window <id> out.png`),
   and confirm the capture is non-empty (a ~200-byte PNG is a blank frame:
   wrong window, unmapped, or off-screen — the capture failed, so OCR/inspect
   it before concluding anything). Driving a real terminal while verifying
   only through ttty is the same blind spot as not driving one at all. If the
   report is from ghostty, screenshot ghostty.

2. **Check replay-tool defaults before trusting them.** Scratch tools in
   `/tmp/hintcheck/` (`replay.nim`, `trace.nim`) hardcode `g.width = 80`
   regardless of the pty width the app ran at; replaying a 119-col capture at
   80 invents/hides geometry bugs. Use the width-aware variants (`replay2`,
   `rows_at2`) with the capture's real width.

3. **Match the user's full environment before concluding "can't reproduce":**
   same config (the provider's `reasoning` line adds a welcome row), same
   version-marker state (the `· updated to v...` banner is one more scrollback
   row a fresh HOME never emits), same width, and typed (per-keystroke) input
   rather than an instant paste when the bug involves the editor redraw path.

4. **A passing instrumented probe is not a reproduction.** THREECODE_TERMDBG
   probes can prove the app's *model* is internally consistent while the
   screen is still wrong (model-vs-physical desync). "Probe says correct +
   user sees broken" means go to rule 1, not "the user is mistaken."

5. **State the verification surface in every report.** "N/N green" means
   nothing without saying what rendered the frames: ttty model, real xterm
   screenshot, or the user's own terminal. Unverified means unverified.

- Style skills

nim-style-guide
nim-code-organization

## Builds

Use `nimble setup` once per clone (generates `nimble.paths`), then build with
plain `nim c` — `nimble build` resolves `import threecode/<mod>` against any
previously `nimble install`ed copy of this package in `~/.nimble/pkgs2`, which
silently shadows local edits with stale modules. Do NOT run `nimble install`
during development; it is only a pre-release smoke test, and it is exactly
what poisons later `nimble build`s. If the binary behaves like an old commit,
delete `~/.nimble/pkgs2/threecode-*` and rebuild with `nim c`.

## Commits

Commit when a change reaches a sensible, complete state — don't wait to be
asked. Use a short, single-line commit message.
