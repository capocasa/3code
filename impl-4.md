# impl-4: Integrate, stress, reproduce-or-close

**Read first:** `plan.md` (master plan + TODO), `impl-3.md` (immediate
predecessor), `TICKER_RACE_HANDOFF.md` (the bug being killed).

This is the final integration + verification + close step. No source
changes are expected *unless* the dead-code audit finds collapsed
atomics, or the reproduction shows the race is not gone.

## Goal

Confirm the single-GUI-thread architecture (impl-1/2/3) actually kills
the ticker-line-removal race, then either close it or report honestly.

## What chunk 3 left for this step

- The GUI animation thread owns the entire viewport+footer composite
  during `amBarTick` (no controller thread rendering the viewport).
- `updateToolViewportSymbol` is deleted; the GUI thread operates on a
  local copy of viewport rows.
- Build clean; stress/functional/resize tests green as of impl-3.

## Tasks

### 1. Build

```
nimble build
```

### 2. Full tty suite (generous timeouts — these are slow)

```
timeout 300 nimble test tests/tty/test_spinner_race_stress.nim
timeout 300 nimble test tests/tty/test_tty_functional.nim
timeout 200 nimble test tests/tty/test_resize_ticker.nim
```

All three must be green. If a stale stub binary is suspected:
`rm -rf build/3code_stub build/stub_cache` before re-running.

### 3. hy3 reproduction (TICKER_RACE_HANDOFF.md step 1)

The race needs the spinner thread actively painting during
`startContent`'s footer teardown. Hammer it: loop many turns against a
reasoning-heavy prompt under tmux, capturing `capture-pane -p -S -200`
each iteration and diffing for missing lines. The goal is a LONG
reasoning burst so the spinner animates for 1-2s before content starts.

Requirements:
- A live provider that streams reasoning fast (hy3 is the canonical
  case; any reasoning-heavy provider works). If no provider is
  configured, **document this honestly** and rely on the stress test
  (which uses a stub that drives the spinner through backoff windows).
- Run `./3code` (the local slurp binary), NOT `~/.local/bin/3code`
  (which points at main).
- Capture the pane before and after each turn; a missing line above the
  prompt is the bug signature.

If the race **cannot be reproduced** after a determined attempt (multiple
iterations, reasoning-heavy prompt, tmux ground-truth capture), close it:
note the reproduction attempts in the plan.md TODO learnings.

If the race **is reproduced**, do NOT paper over it — re-instrument
`walkUp`/`noteFooterPainted`/`noteNoFooter` with `debugOut` tagged by
`getThreadId()`, capture the stale paint between `stopSpinner` and the
next controller paint, and report.

### 4. Dead-code audit

`grep -n` for these symbols. Remove ONLY those that have zero live
callers. If still referenced (by `guiLoop` or `turns.nim`), leave them
and note that they did not collapse:

- `commandSymbolIndex` / `nextCommandSymbol` — the live currency-symbol
  rotation in `guiLoop`'s `amBarTick` branch still advances these. Only
  dead if that rotation was removed.
- `commandStatusActive` — still set by `setCommandStatusActive` in
  `turns.nim` and read by `guiLoop`. Only dead if both are gone.
- `barTickStart` — still used to compute the elapsed-suffix in `guiLoop`
  and `reserveEditorFooterForRedraw`.
- `testTickerControl*` — this is the **test harness's** ticker driver
  (`advanceTicker()` in `tty_expect.nim` sends 't' bytes that
  `testTickerControlLoop` reads, then calls `requestTestSpinnerFrame`).
  It has NOT collapsed — it is the mechanism by which tty tests get
  deterministic spinner frames. Do NOT remove it.

### 5. Commit + handoff

- Update `plan.md` TODO: mark impl-4 done, record learnings (test
  results, reproduction outcome, dead-code audit result).
- One-line commit message, no coauthor trailer. Stage only changed
  files (NOT `TICKER_RACE_HANDOFF.md` or `slurp-report.md` — leave
  untracked).
- `context_clear` with a handoff summary.

## Acceptance

- Build clean.
- All three tty tests green.
- Reproduction attempted (and either closed or escalated with evidence).
- Dead code removed where genuinely collapsed; documented where not.
- `plan.md` TODO updated.
