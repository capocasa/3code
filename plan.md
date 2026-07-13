# Plan: Unify tool rendering to the live byte path; remove the alternate stdout renderers

## Context (read this first)

There are two parallel tool-result rendering systems in `src/threecode/display.nim`. This duplication is the root cause of the "plans show glyphs live but words in history" bug that started this work, and it is the reason a fix in one path can silently not apply to the other.

**The live byte path** (produces a `string`, caller writes it to scrollback via `commitTranscriptBytes`). Used by the live transcript in `turns.nim`:

- `toolBannerBytes(banner, kind, code, elapsedS)` → banner row
- `toolResultBytes(kind, res, code, idx, diff)` → body rows, dispatches per kind
- `toolTranscriptBytes(...)` overloads → banner + body composite
- helpers: `wrappedSubtleBytes`, `compactHeadTailBytes`, `diffBytes`, `planResultBytes`, `planTranscriptBytes`

**The alternate stdout path** (writes to `stdout` directly, no byte string). Used by session replay (`replaySessionTail`), `:show`, and `:tools`:

- `renderToolBanner(banner, kind, code)` → banner
- `printToolResult(kind, res, code, idx, diff)` → body, dispatches per kind
- `printActionResult(act, ...)` → thin wrapper over `printToolResult` (currently unused — delete it)
- `showTool(arg, toolLog)` and `listTools(toolLog)` → `:show` / `:tools`
- helpers: `printBashScroll`, `printCompactHeadTail`, `printDiff`

The two paths reimplement the same per-kind logic independently, and they drift. The plan tool drift is one instance; there are others latent.

The fix shape: the byte path is the **superset** (live streaming needs the volatile partial-row machinery, replay does not). So the stdout path should be deleted, and the three remaining callers (`replaySessionTail`, `showTool`, `listTools`) should reconstruct an `Action` (or read the `ToolRecord`) and call the **same byte builders** the live path uses, writing the returned bytes to stdout. One renderer per concept.

## The second bug (separate, pre-existing — do NOT bundle)

The other thing reported this turn: a streamed two-item numbered list rendered the first item twice and dropped the second, with no list glyph. That is in `src/threecode/fatprompt/runtime.nim` (`feedContent` / `commitPendingLine` / `renderPendingPartial`), the **live assistant text streamer**. Commit `805cf1e` (the plan-tool fix) did not touch `runtime.nim`, so this is **pre-existing**, not a regression from this work — it surfaced because close attention was paid.

It is out of scope for THIS plan (which is about tool rendering duplication). File it as its own item: "live markdown streamer drops/duplicates lines under some chunk boundaries." Reproduce it first (feed a chunked `"1. ...\n2. ..."` through `feedContent`) before touching `runtime.nim`. Do not fold it into the renderer unification.

## What changed already (commit 805cf1e)

- `ToolRecord` now carries `plan: seq[PlanItem]` (types.nim).
- `planResultBytes(plan)` is the single shared plan renderer (display.nim:315); live transcript, replay, and `:show` all route through it.
- `(N items)` banner title replaced with `"update plan"` (actions.nim bannerFor).
- `printToolResult`'s akPlan branch deleted.
- Tests added in `tests/core/test_display.nim`.

Known loose ends from that commit (to be cleaned up as part of item 1):
- `toolResultBytes` (the LIVE byte path) still has a dead `elif kind == akPlan: result.add wrappedSubtleBytes(res)` branch at `display.nim:~660` — unreachable because plans route through `planTranscriptBytes` first. Remove it.
- `printActionResult` (display.nim:409) is exported but has zero callers. Delete it.

## Execution format (follow exactly)

This plan is executed in a loop, possibly across context clears. Each item:

1. Pick ONE incomplete item below.
2. Implement it.
3. Update this plan: mark the item done, and record anything learned that changes later items (a signature changed, a caller moved, a test needed reshaping). Keep the "Current state" section below accurate — it is the handoff.
4. If context is getting full, run `clear` with a prompt pointing at this file and summarizing progress. The next context resumes by reading `plan.md`.
5. When all items are complete, do the final review, run the full build + the relevant test suites, and commit.

Rules:
- One item per pass. Do not implement two at once even if they look easy.
- After every item: build (`nim c -o:/tmp/tc src/threecode.nim`) and run `tests/core/test_display.nim` + `tests/core/test_session.nim`. The tty suite hangs in some environments (120s timeout) — if it hangs, run the core/stream suites only and note it.
- Never edit a file you haven't read in the current context.
- Use `write` for new files / full rewrites, `patch` for surgical edits. No shell heredoc rewrites.

## Current state (handoff — update after every item)

- `805cf1e` landed: plan tool unified to glyphs across live + replay + `:show`. `ToolRecord` carries `plan`.
- **Item 1 DONE**: dead `akPlan` branch in `toolResultBytes`, `printActionResult`, and the stale `planResultBytes` docstring all removed. Build green; `test_display` + `test_session` green.
- **Items 2+3 DONE**: `replaySessionTail` now routes through `toolTranscriptBytes` (string-banner overload, stored banner) + `planTranscriptBytes` (plans). Bridge decision: no `ToolRecord` change needed — use the stored banner directly. Replay tests added and green.
- **Item 4 DONE**: `showTool` body routes through `toolResultBytes` (plans unchanged via `planResultBytes`). Old green write/patch branch removed. Test added.
- **Item 5 DONE**: `listTools` left as-is (it's an index, shares no body-render logic with the byte path).
- **Item 6 DONE**: all alternate stdout renderers deleted (`printToolResult`, `renderToolBanner`, `printCompactHeadTail`, `printDiff`, `printBashScroll`, `printLine`, `writeWrappedLine`). Every caller now routes through the byte builders. All core/stream/shell suites green.
- Only item 7 (final review + release build + commit) remains.

## Items

### 1. Remove dead code left by the plan-tool fix  ✅ DONE
- [x] Delete the unreachable `elif kind == akPlan` branch in `toolResultBytes` (display.nim:~660). Confirmed unreachable: the `act` overload of `toolTranscriptBytes` dispatches `akPlan` itself to `planTranscriptBytes` before ever calling `toolResultBytes`, and no caller invokes the string-banner overload with `akPlan`.
- [x] Delete `printActionResult` (display.nim:409) — zero callers.
- [x] Updated `planResultBytes` docstring (315) to drop the stale `printToolResult` reference; it now names `planTranscriptBytes` + `showTool`.
- [x] Build OK; `tests/core/test_display.nim` + `tests/core/test_session.nim` green.

### 2. Route session replay (`replaySessionTail`) through the byte path  ✅ DONE
- [x] The per-tool_call loop now routes through the byte builders: plans via `planTranscriptBytes(act)` (matches live `≡ ──────────` header + glyphs), all other kinds via the string-banner `toolTranscriptBytes(banner, kind, output, code, idx)` overload passing the STORED banner. No `Action` reconstruction needed for the body path — the string-banner overload takes the banner as a param, so the stored `rec.banner` is used directly and there is no bannerFor-recompute mismatch.
- [x] Tests added: `tests/core/test_display.nim` suite "display: replay routes through the live byte builders" — bash + plan cases assert the captured replay stdout `.contains` the live `toolTranscriptBytes` output for the same action, plus glyph/header checks.
- [x] `renderToolBanner`/`printToolResult` NOT deleted — `showTool` (item 4) still uses them. Item 6 will remove them after showTool reroutes.

### 3. Decide the `ToolRecord` ↔ `Action` bridge  ✅ DECIDED: neither — use the stored banner, no Action needed
Neither (a) nor (b). The string-banner overload `toolTranscriptBytes(banner, kind, res, code, idx, diff)` takes the banner as a PARAM, so the stored `rec.banner` is passed directly — no `Action` reconstruction, no `bannerFor` recompute, no banner-mismatch risk. For plans, `planTranscriptBytes(act)` reads only `act.plan`, so a minimal `Action(kind: akPlan, plan: rec.plan)` suffices. No change to `ToolRecord` or session save/load required.

Caveat carried to item 4: `showTool` currently renders write/patch body from `rec.output` only (the summary line). The live byte path's akWrite branch renders the file CONTENT via `diff` (not stored on `ToolRecord`). So routing `showTool`'s body through `toolResultBytes` with `diff=""` reproduces the CURRENT (summary-only) `:show` behavior — not a regression, but a known fidelity gap (the live transcript shows full file content; `:show` does not). This is pre-existing and out of scope to fix here.

### 4. Route `:show` (`showTool`) through the byte path  ✅ DONE
`showTool` keeps its `── T{n}` header (per plan) but the body now routes through the shared byte builders: plans via `planResultBytes(rec.plan)` (unchanged), every other kind via `toolResultBytes(rec.kind, rec.output, rec.code, n)`. The old per-kind branches (printLine for bash/read/web, green-on-success for write/patch) are gone — that green rendering was the drift; `:show` now matches the live transcript (grey subtle).
- [x] Implemented.
- [x] Test added: `showTool body matches toolResultBytes for multi-line bash` asserts the `── T1` header + that the captured stdout `.contains` `toolResultBytes(akBash, output, 0, 1)`.

### 5. Route `:tools` (`listTools`) through the byte path (or justify leaving it)  ✅ DECIDED: leave it
`listTools` is an index, not a render: one line per tool (`T1 ✓ banner (N lines)`). It shares NONE of the byte path's per-kind body logic — it does not call any banner/body/diff/plan builder. Its status mark (`✓`/`✗`) is a trivial `code == 0` check distinct from the banner path's icon set (`$`/`Ø`/`▸`/…). Its banner is printed raw from `rec.banner` (no `bannerFor`, no icon). It counts lines, which the byte path does not expose.
- [x] Decision: leave `listTools` as-is. It duplicates no renderer logic; unifying it would force the index into the shape of a full render, which is the wrong abstraction.

### 6. Delete the alternate stdout renderers  ✅ DONE
- [x] Deleted `printToolResult`, `renderToolBanner`, `printCompactHeadTail`, `printDiff` from display.nim; deleted `printBashScroll`, `printLine`, `writeWrappedLine`, and the now-orphaned duplicate `trimBoundaryBlank` from toolstream.nim. (display.nim keeps its own `trimBoundaryBlank`, used by the byte path.) The byte-producing equivalents all remain.
- [x] `tests/stream/test_streaming_view.nim`: removed the 3 `printBashScroll` tests + the now-orphaned `captureStdout` helper + unused `os` import. The byte-path bash body is covered by the replay/showTool tests in test_display.nim.
- [x] Fixed a stale module docstring (`printLine` → `handleMdLine`) and the `renderToolPending` docstring (`renderToolBanner` → "final tool banner bytes").
- [x] Fixed 2 pre-existing-stale tests in `tests/shell/test_actions_extra.nim` that asserted the old `(N items)` plan banner (removed by 805cf1e); now asserts `bannerFor(akPlan) == "update plan"`.
- [x] Build green; `test_display`, `test_session`, `test_streaming_view`, `test_streamexec`, `test_actions_extra` all green.
- [x] tty suite (`tests/tty/`) skipped — hangs in this environment per the plan note.
- [x] `rg 'proc (printToolResult|renderToolBanner|printBashScroll|printCompactHeadTail|printDiff)\b' src/` returns nothing. Full `rg` across src/ + tests/ for all six names returns nothing.
- NOTE: `renderToolPending` (display.nim) also has zero callers but is NOT a byte-builder duplicate (it's the volatile pre-execution banner) and was out of the item-6 list — left in place. Also `wrappedRows` in toolstream.nim was already dead before this work (pre-existing) — left.

**Note for item 7:** `:tools` (`listTools`) is the only remaining stdout-writing tool renderer, and it is an index (item 5), not a per-kind render — so it correctly does not share the byte path.

### 7. Final review + commit
- [ ] Re-read the whole diff. Confirm: exactly one renderer per concept (banner, body, diff, plan). No stdout-writing duplicate of a byte builder remains.
- [ ] Build release: `nim c -d:release -o:/tmp/tc src/threecode.nim`.
- [ ] Run `tests/core/test_display.nim`, `tests/core/test_session.nim`, `tests/stream/test_streamexec.nim`, `tests/stream/test_streaming_view.nim`.
- [ ] Commit: `remove alternate tool renderers; unify on the live byte path` (or split into per-item commits if cleaner — one commit per item is fine and preferred).
