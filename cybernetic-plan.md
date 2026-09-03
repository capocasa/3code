# Cybernetic Plan: hint line corrupted on FIRST submit (xterm, always)

## Context

Bug: on the **first** prompt submit (Enter) after launching 3code, the welcome hint line
`  type a prompt. :help for commands. :q or Ctrl-D to exit.` is visually corrupted — the echo
`❯ <prompt>` lands ON the hint's row, overwriting its tail. Happens ALWAYS on first turn, in
xterm, at ~119 cols (user's sway half-screen), with the user's kimicode/k3 config. Later turns
do NOT corrupt anything.

Evidence from user's xterm (`/tmp/sc.png`, `/tmp/sc.txt`): after submit, the screen shows
`_ type a prompt.,` (only the styled bright prefix of the hint survived) and the echo on the
SAME row — i.e. the volatile-erase walked one row too far UP into the hint, or the hint was one
row LOWER than the model believed and the erase-from-cursor consumed it.

DSR instrumentation on the user's machine (THREECODE_TERMDBG) showed the app's row model is
internally consistent: `commit cursor=(16,18) walkUp=2 targetRow=14 ed=0 ft=2 vp=0 lv=0` and
`welcomeAfterHint cursor=(14,1)`. Model says: hint row 13, gap 14, bar 15, prompt 16; erase
targets 14-15. Yet the hint dies. So either (a) the physical screen disagreed with the model
at erase time (something re-painted between the probe and the erase — the probe is BEFORE
SyncBegin), or (b) an earlier frame (a keystroke renderFooter during typing) already damaged the
hint and Enter only makes it visible, or (c) xterm scrolls/reflows on the bulk `\x1b[J` in a way
the model doesn't track. THE MODEL BEING SELF-CONSISTENT DOES NOT PROVE THE SCREEN MATCHES IT —
this is the lesson of this whole session.

**CRITICAL METHODOLOGY (see AGENTS.md "Reproducing terminal-rendering bugs", added this session):
verify against REAL xterm SCREENSHOTS, never ttty's Grid. ttty shares the app's row-math
assumptions and renders every broken frame "correct". Scratch replay tools hardcode width=80 —
use width-aware `replay2`/`rows_at2` only, and even then never as the verification surface.**

## Current state (FINAL - verification complete)

**OUTCOME: Could NOT reproduce the corruption on the current binary through 9+ real-xterm
screenshot-verified runs at 119 cols, typed per-keystroke input, both stub and real (google)
provider, matching welcome (provider/model/reasoning + update banner present).**

Reproduction harness that WORKS (screenshot-verified, this is the methodology the bug demanded):
`/tmp/hintcheck/fifo_capture.sh <binary> <tag>` — launches a REAL xterm on Xvfb :88 via
`setsid xterm -geometry 119x24 -e`, drives the app through a FIFO (stays alive, per-keystroke
typing), screenshots the xterm window with scrot at idle/typed/enter/final, OCRs with tesseract.
Key setup facts: Xvfb must be 1400x900 (an 800x600 screen clips the 119-col window to black);
`setsid` is required under the sandwall sandbox; the `-S/3` slave-fd xterm renders NOTHING on
this Xvfb (use `-e` + FIFO, not the pty-slave relay); OCR needs bright-text crop + invert +
2-3x upscale (thresh ~100 to catch the dim hint).

Every run: `hint_full=True truncated=False echo=True` at the enter frame — the full hint
`:q or Ctrl-D to exit.` survives on its own row, the echo `❯ this is a test just reply` lands
on the row BELOW it. Verified on:
- HEAD `8b91b36` (real google provider, reasoning=on, banner): 3/3 runs
- HEAD `8b91b36` (stub provider): 4/4 runs  
- `8a9fcbb` source (when user last saw the bug): 3/3 runs
- earlier: 6/6 + 8/8 + 5/5 runs across configs

The two commits since `8a9fcbb` (374605b, 8b91b36 merge) touch NO rendering files
(minline/engine/display/terminal) — only interrupt tracing + tests. So the rendering code is
identical to what the user last reproduced on.

**Conclusion: the corruption does not reproduce in this clean environment on current code.
It is either (a) already fixed incidentally, (b) dependent on something in the user's live
environment my fresh HOME doesn't replicate (their real kimicode config contents, their sway
resize timing, their xterm version/options), or (c) intermittent in a way 9 consecutive clean
runs didn't hit. The AGENTS.md ground rules (verify via real-xterm screenshot, not ttty) are
committed and are the correct methodology going forward.**

What was NOT done (no reproduction = no fix to make): no app source change, no ttty change.
Source tree has NO rendering modifications. Only AGENTS.md (ground rules) + this plan differ.

Next step if the user still sees it: get a screenshot + `script -f` byte capture from THEIR
terminal at the moment of corruption, plus `tput cols` and their xterm version — the divergence
is environmental, and only their-machine ground truth can close it.

## Original Current state

- HEAD: `8a9fcbb` (= 146a85c content + reverts; tree has the renderFooter liveContentRows fix,
  NO other rendering changes). AGENTS.md modified (ground rules — KEEP, commit at end).
- Reproduction environment CONFIRMED WORKING:
  - `setsid` is REQUIRED to launch xterm under the sandwall sandbox (bare `xterm` dies with
    "open ttydev: Permission denied"; `setsid xterm ...` works). Same for the relay scripts:
    they use pty+setsid already and worked.
  - Xvfb :88 + openbox running. Screenshot pipeline VERIFIED: `DISPLAY=:88 xdotool search
    --class xterm` → window id → `import -window <id> out.png` → OCR with tesseract. Read
    "MARKER" off a test window. A ~200-byte png = blank/failed capture, distrust it.
  - Fresh-HOME real-provider config at /tmp/freshhome (google/gemini-flash-latest, key from
    $GEMINI_API_KEY). 119-col relay with per-keystroke typing: /tmp/hintcheck/relay_type.py.
- PRIOR FAILED ATTEMPTS (do not retry blindly): af95544 freshPrompt (destroyed the bar —
  reverted); per-row \x1b[2K instead of bulk \x1b[J (user: still happens — reverted).
- All prior "hint survives" results were ttty-model results = WORTHLESS for this bug.
- Stub config with 3-line welcome (reasoning=on): /tmp/xhome/.config/3code/config.

## Steps

1. [ ] **REPRODUCE on real xterm, verified by SCREENSHOT.** Relay (pty bridge, real xterm on
   :88 via setsid, 119 cols, fresh /tmp/freshhome, google provider, per-keystroke typing of
   "this is a test just reply" + Enter). Screenshot the xterm window by id BEFORE typing,
   AFTER typing (before Enter), IMMEDIATELY after Enter (~0.5s, before reply streams), and at
   end. OCR each. REPRODUCTION = hint row visibly truncated/overwritten in the after-Enter
   shot. If the google/provider path doesn't reproduce, try: stub provider; the update banner
   forced (`echo 0.0.0-old > /tmp/freshhome/data/3code/last-version`); kimicode-IDENTICAL config
   (provider name "kimicode" + reasoning on in welcome — the welcome text/row count must match
   the user's: provider/model/reasoning lines). KEEP the failing capture + screenshots.
2. [ ] **Localize the frame.** From the failing capture bytes, find the exact byte offset where
   the hint's row is erased/overwritten (compare after-typing vs after-Enter screenshots; disasm
   the capture around the echo-commit frame: is it the commit `\x1b[<N>A\r\x1b[J`, a keystroke
   renderFooter, or the assistantContentStart erase?). Then instrument walkUp components +
   DSR at THAT site (env-gated, REVERT after). Compare model target row vs the hint's actual
   row on screen (from screenshot row positions).
3. [ ] **Fix ttty.** Whatever divergence step 2 proves (erase semantics, scroll-on-ED0,
   pending-wrap, DSR-vs-model), make ~/p/ttty grid reproduce it: replay the failing capture
   through ttty must show the hint dying at the same byte offset as xterm. Add a ttty-level
   regression test. This makes the bug reproducible in the fast harness FOREVER.
4. [ ] **Fix the app.** Smallest diff at the geometry source. af95544 lesson: do NOT skip the
   volatile-footer walk-up; the fix must keep footer repaint intact.
5. [ ] **Verify.** (a) the step-1 screenshot protocol on the fixed binary: hint intact
   immediately after Enter, ≥5 consecutive runs; (b) pre-fix binary still corrupts in the same
   protocol; (c) fixed ttty regression test green; (d) `nohup nimble test` to completion,
   73 PASS/0 FAIL baseline; (e) report exact per-run screenshot OCR results.
6. [ ] **Cleanup + commit.** Revert instrumentation. Commit fix + AGENTS.md rules. Leave
   docs/index.html and untracked scratch alone.

## Rules

- Verify ONLY via real-xterm screenshots (import+tesseract) until step 3 lands; ttty after.
- `setsid` for any xterm launched from a sandboxed shell.
- Never pkill bare `3code`; only `3code-stub` / `xterm.*-S` / relay PIDs.
- Update "Current state" after every step. Revert probes before commit.
- Do NOT stop between steps. Do NOT report back until step 5 passes with screenshot evidence.
