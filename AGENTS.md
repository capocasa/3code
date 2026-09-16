# Agent Notes

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

## Bisecting tests across revisions

A testament run inside a git worktree is not evidence about that worktree's
revision. Worktrees get `nimble.paths` via a symlink to the main checkout,
and that file lists the main checkout's src as an absolute `--path`, so the
test compiles against the main tree's CURRENT source while the revision
under test supplies only the test file. The false results go both ways
(passes that should fail and vice versa), and creating the worktree fresh
does not help; the symlink still points at main. For any cross-revision
comparison, compile the test by hand with `--noNimblePath
-p:<worktree>/src` plus the dependency paths copied from `nimble.paths`
(minus the self-referential src line), into a fresh `-o:` binary. Confirm
the suspected first-bad commit fails and its parent passes under that
manual harness before trusting the bisect.

## Builds

Use `nimble setup` once per clone (generates `nimble.paths`), then build with
plain `nim c` — `nimble build` resolves `import threecode/<mod>` against any
previously `nimble install`ed copy of this package in `~/.nimble/pkgs2`, which
silently shadows local edits with stale modules. Do NOT run `nimble install`
during development; it is only a pre-release smoke test, and it is exactly
what poisons later `nimble build`s. If the binary behaves like an old commit,
delete `~/.nimble/pkgs2/threecode-*` and rebuild with `nim c`.

Dependencies (ttty, streamhttp, sandwall, tinotify) resolve to their
checkouts in `~/p/<name>` through explicit `--path:"..."` lines in
`nimble.paths`, so local edits to a dependency are live on the next
`nim c`. Keep those lines pointing at the checkout src dirs. Current nimble
removed `nimble develop -g`, and `nimble develop --add <path>` from the
project both fails AND truncates `nimble.paths` to a bare `--noNimblePath`
as a side effect; restore the file by hand instead of rerunning it. Never
`nimble install` a dependency: the pkgs2 snapshot shadows the path and the
solver keeps reinstalling it. If a dep resolves to pkgs2, fix its
`nimble.paths` line (or delete the pkgs2 copy) and check
`~/.nimble/pkgcache/tagged_versions.json` for a stale pre-tag entry. See
`~/.agents/archive/guidelines-updated.md` section 8.

## Scratch docs

Plan, impl, and report scratch docs (`plan-*.md`, `impl-*.md`,
`report-*.md`, and friends) are agent working notes, never repo content.
Never commit them. Park them in untracked `.agents/archive/` when a chunk
of work hands off to the next session.

## Commits

Commit when a change reaches a sensible, complete state — don't wait to be
asked. Use a short, single-line commit message.
