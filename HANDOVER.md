# Handover: 3code line-math bugs (erase scrollback line / prompt jump)

## The bugs (user-reported, REAL, reproducible)

Seen on **foot** and **ghostty** (user switched to ghostty, gets them
immediately). NOT reproduced on xterm.

1. **Bug 1**: after `:provider kimicode` prints its profile block
   (`provider/model/reasoning`), typing into the prompt erases the last
   block line (`reasoning low` becomes empty).
2. **Bug 2**: after typing a prompt and pressing return, the prompt line
   moves one row up or down, then scrollback continues.
3. Related: an extra line appears ABOVE the prompt after `:provider`, then
   vanishes when typing starts. User suspects the status/token line is
   hidden initially before the first prompt.

## Structural root cause (established)

The erase/walk-up sites in 3code compute cursor geometry from a shared row
model (`ed.renderRow`, `paintedFooterRows`, `liveContentRows`,
`toolViewportRows` in `src/threecode/engine.nim`). A one-row lie in any of
them = exactly these symptoms. ttty (the in-memory test model) applies the
SAME model to interpret captured bytes, so a model-vs-physical desync is
self-concealing in every ttty frame: the harness and the code share the
wrong assumption. This is why many ttty-based attempts never found it.

**Ground truth must come from an independent real terminal**, read back via:
- `CSI 6 n` (DSR) → terminal's real cursor row/col.
- `CSI 0 i` (Media Copy, print screen) with
  `-xrm 'xterm*printerCommand: cat > f'` → terminal's exact screen text.

## KEY LEAD: DEC 2026 synchronized output

Strongest hypothesis for "xterm clean, foot/ghostty broken":

- 3code emits DEC 2026 sync frames (`\x1b[?2026h` / `\x1b[?2026l`) in
  `src/threecode/minline.nim` `redrawBytes` and `SyncBegin/SyncEnd` in
  `src/threecode/terminal.nim`.
- **xterm ignores 2026. foot and ghostty HONOR it.** That is a concrete,
  verifiable behavioral split matching the observed pattern exactly.
- In the very first real-terminal run (this session, piped stdin), the raw
  output contained a DOUBLED sync-end: `...❯ [2C\x1b[?2026l\x1b[?25h\x1b[?2026l`.
  An unmatched/mis-nested 2026 frame on a 2026-honoring terminal can batch
  or drop rows differently than the model expects. Worth auditing every
  2026h for a guaranteed-paired 2026l (exceptions, early returns,
  `redrawWrappedExternally` paths in minline.nim:618-620).
- Other 2026-adjacent suspects: ED0 (`CSI J`) at the bottom margin,
  pending-wrap at the last column, scroll-on-LF at bottom — but these would
  likely also differ on xterm, so 2026 is the prime suspect.

## What was built (all working, committed/released unless noted)

### ttty 0.4.0 (~/p/ttty, tagged + pushed + nimble-installed)

- `src/ttty/x11oracle.nim` — headless Xvfb + xterm oracle.
  `startOracle(cols,rows, run=, runEnv=)`, `feed` (byte replay), `cursor`
  (DSR), `screenText` (media-copy), `typeKeys` (XTEST, holds Shift for
  shifted chars — CRITICAL, otherwise `:` arrives as `;`), `focusWindow`
  (CRITICAL on bare Xvfb, else keystrokes vanish). Supervisor mode runs a
  real interactive program (3code stub) inside the oracle.
- `src/ttty/conformance.nim` — `compareToOracle`: ttty Grid == xterm on
  cursor + screen text.
- `tests/test_x11_conformance.nim` + `tests/corpus/*.raw` — 6 real 3code
  streams conform. `nimble conformance` runs it.
- Process gotchas baked into code/plan: execCmdEx/execShellCmd HANG in the
  agent shell — always posix fork/exec; fresh oracle per stream (shared
  xterm carries scroll state).

### 3code linebugs branch (~/p/3code/linebugs, UNCOMMITTED — do not lose)

- `src/threecode/terminaldbg.nim` — opt-in DSR probe. Set
  `THREECODE_TERMDBG=<path>`; at each commit/erase it logs the model's
  walkUp WITH COMPONENTS (`ed= ft= vp= lv=`) vs the terminal's real cursor
  row. This is THE instrument that pinpoints which row-model field goes
  stale on a given terminal. `probeErase` + richer `probeDetail`.
- `src/threecode/engine.nim` — `probeDetail` call site at
  `appendTranscriptLiveAnchored` (commit.liveAnchored), plus probeErase at
  commit.floating + assistantContentStart.
- `tests/tty/probe_linebugs.nim`, `tests/tty/probe_resume_bar.nim` —
  interactive PTY repro drivers (clean under ttty, as expected).
- Stub rebuild (needs dep paths since CI install isn't set up locally):
  ```
  cd ~/p/3code/linebugs
  PATHS=""; for p in unicodedb streamhttp ttty tinotify procbox; do
    PATHS="$PATHS --path:$(nimble path $p | tail -1)"; done
  nim c -d:ssl -d:providerStub --threads:on --path:src $PATHS \
    -o:build/3code_stub src/threecode.nim
  ```

## Probe evidence collected (interpret carefully)

- First xterm session: cursor 12→17→23 across three `:provider` commits.
  I first called this "+1 drift"; it is actually CORRECT +5/+6 advancement
  (item = echo + blank + 3 profile + blank = 6 rows). Not a bug.
- `ft=2, walkUp=2` probe lines were captured while a mistyped `;provider`
  ran as a real PROMPT (spinner turn, legitimate footer height 2). Not
  proof of a stale model — but also NOT disproven on a 2026 terminal.
- xterm media-copy dumps: `:provider` x3 and streaming-during-typing render
  perfectly. xterm is clean — and likely clean BECAUSE it ignores 2026.

## What I got wrong (so the next agent doesn't repeat it)

1. Declared "drift reproduced" from data that was correct advancement.
2. Declared "3code clean" from xterm-only evidence — wrong generalization.
   The bug is terminal-behavior-specific; xterm was never the failing
   terminal. foot and ghostty are.
3. Nearly "fixed" `beginEditorRedraw` (`renderRow + max(1,
   footerRowsAboveEditor)` over-walk) — my patch made it worse, reverted.
   That line predates the bug; the geometry there is consistent on xterm.

## Next steps (in order)

1. **Reproduce on ghostty with the probe armed** (fastest path to truth):
   commit terminaldbg.nim + engine.nim probe site to a branch, build the
   REAL 3code (not stub, or stub is fine for :provider), and in a ghostty
   window run `THREECODE_TERMDBG=/tmp/t.log 3code`, do `:provider kimicode`,
   type a few chars, submit, then read /tmp/t.log. The `ed/ft/vp/lv`
   components + real cursor row will name the stale field on a
   2026-honoring terminal.
2. **Audit DEC 2026 pairing**: every `\x1b[?2026h` must have exactly one
   matching `\x1b[?2026l` on every exit path (minline.nim redrawBytes
   `synchronized` flag, terminal.nim SyncBegin/SyncEnd, exception paths,
   `redrawWrappedExternally`). Fix any unbalanced emission; re-test on
   ghostty.
3. **Extend the oracle past xterm** (only if step 1-2 don't pin it):
   ghostty/foot are Wayland — run under a headless compositor (weston
   headless) with the same supervisor pattern, or drive the user's real
   ghostty with the probe and media-copy equivalent (ghostty has no
   printerCommand; use the probe + screenshots/selection dump instead).
4. Wire the repro as a regression test once the bug is pinned (per
   AGENTS.md: reproduce in a visual test before fixing).
5. Decide whether to mainline terminaldbg as a permanent opt-in diagnostic
   (recommend yes, it's cheap and proven).

## Skill/process

cybernetic-plan skill updated: when updating a plan, fold newly discovered
sensible tasks into the Steps list rather than asking the user.

## RESUMED 2026-07-26 — nested 2026 frames found and fixed (97b9dba)

Audit of DEC 2026 pairing found the imbalance WITHOUT needing the ghostty
repro: `appendTranscriptLiveAnchored` (engine.nim:533) and
`appendTranscriptFloating` (engine.nim:577) called
`redrawBytes()` (default `synchronized=true`) while already inside an outer
`SyncBegin` — emitting a nested `?2026h..?2026l` plus the outer `?2026l`.
This is exactly the doubled sync-end seen in the very first real-terminal
run. Fixed by passing `synchronized = false` at both sites (matches the 4
other in-frame callers). ttty suites pass; stub + real builds rebuilt.

### Next: verify on ghostty (user-driven)

Built `build/3code_real` (full providers) and `build/3code_stub` on the
linebugs branch WITH the fix. In a ghostty window:

    cd ~/p/3code/linebugs
    THREECODE_TERMDBG=/tmp/t.log ./build/3code_real

Do `:provider kimicode`, type a few chars, submit. Expected: Bug 1 and
Bug 2 gone. If either persists, /tmp/t.log names the stale row-model field
(ed/ft/vp/lv components vs real cursor row) — continue from step 1 of the
original next-steps. If clean: close out, write the regression test
(step 4), decide on mainlining terminaldbg (step 5).

## CLOSED 2026-07-28 — fixed, verified on ghostty, regression-guarded

User confirmed on ghostty: both bugs gone with 97b9dba (nested DEC 2026
frames in appendTranscriptLiveAnchored/Floating). Probe log post-fix shows
walkUp == physical reality on every commit (no stale ed/ft/vp/lv field) —
the model was always right; the doubled ?2026l made 2026-honoring
terminals render a different frame than the model assumed.

Shipped on the linebugs branch:
- 97b9dba  the fix (synchronized=false at the two nested redrawBytes sites)
- 273499b  probe hardening: inputInterceptHook in minline captures DSR
           replies in the input thread; queryCursorPos prefers the stash.
           Kills the self-inflicted "DSR no-reply" readings. Hook is nil
           in production (zero cost); terminaldbg stays opt-in and is
           mainlined as a permanent diagnostic (handover step 5: yes).
- 1ad1087  regression test tests/core/test_sync_frames.nim — asserts
           exactly one ?2026h/?2026l per commit path; verified red against
           pre-fix engine.nim, green after.

Remaining housekeeping: merge linebugs → main when convenient. ttty
oracle (xterm) never saw this bug class — by design, xterm ignores 2026.
A foot/ghostty headless oracle (weston) would catch 2026-semantics
regressions; not built, noted as future work if 2026-adjacent bugs recur.

## UPDATE 2026-07-29 — terminal-fidelity hardening (plan: cybernetic-plan.md)

Shipped on linebugs (3code) and ttty 0.5.0:

- 3code 069ff11: minline drops unsolicited terminal replies (DSR `CSI
  row;col R`, DECXCPR `CSI ?..R`, DA `CSI..c`) in production read paths —
  shape-validated so modified arrows (CSI 1;5R) pass. terminaldbg slimmed
  to a replyCaptureHook. Class-2 (reply-leak) closed at the root.
- ttty 0.5.0 (tagged/pushed/installed): grid validates DEC 2026 pairing
  (g.violations + checkStreamClosed); 8-stream xterm edge-case corpus
  found+fixed 3 real ttty divergences from xterm (ED-at-pending-wrap
  clears wrap and next print overwrites the last cell; ED0 blanks rather
  than truncates; deferred-wrap re-arm). 14/14 streams conform.
- 3code ca79b29: every tty test now asserts zero stream violations on
  session close — malformed-sync net by construction (class 1 by proxy).

OPEN — user's xterm sighting of "that bug": the 2026 fixes can't explain
it (xterm ignores 2026). If reproducible on xterm with build/3code_real,
capture the stream (tty_expect s.raw) and replay through ttty's xterm
conformance oracle; a cursor/row divergence there is the bug made visible.
