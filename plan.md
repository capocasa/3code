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
- Not yet started: items 4, 5, 6.
- The alternate stdout renderers still exist and are still called by `replaySessionTail`, `showTool`, `listTools`.

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

### 4. Route `:show` (`showTool`) through the byte path
`showTool` (display.nim:956) currently writes its own banner + body. Change it to reconstruct the `Action` (from item 3's bridge) and write `toolTranscriptBytes(act, rec.output, rec.code, n, "")`. Note `:show` prints a `── T{n}` header, not the normal tool banner — keep that header, only the BODY should come from the shared renderer. So this item is: replace the body-rendering part of `showTool` with the byte path's body builder (`toolResultBytes`), keep the `── T{n}` header.
- [ ] Implement.
- [ ] Add a test: build a `ToolRecord` (bash kind, multi-line output) and assert `showTool` output equals the `── T{n}` header + `toolResultBytes` body.

### 5. Route `:tools` (`listTools`) through the byte path (or justify leaving it)
`listTools` (display.nim:986) prints a one-line summary per tool (`T1 ✓ banner (N lines)`), not a full render. It does not duplicate the per-kind body logic — it just counts lines and shows a status mark. This may NOT need unification; it's an index, not a render. Decide:
- [ ] If `listTools` shares no logic with the byte path, leave it and note why here. If it reimplements banner/mark logic, unify the shared parts.
- [ ] Whatever the decision, record it here so the next context knows.

### 6. Delete the alternate stdout renderers
Only after items 2, 4, (5) reroute every caller:
- [ ] Delete `printToolResult`, `renderToolBanner`, `printBashScroll`, `printCompactHeadTail`, `printDiff` (the stdout-writing variants). Keep the byte-producing equivalents.
- [ ] Grep for any remaining callers (including tests — `tests/stream/test_streaming_view.nim` tests `printBashScroll` directly; those tests must be rewritten to test the byte equivalent `bashScrollBytes` or deleted if redundant).
- [ ] Build + run all core/stream test suites. Note any tty-suite hang separately.
- [ ] Confirm `rg 'proc (printToolResult|renderToolBanner|printBashScroll|printCompactHeadTail|printDiff)\b' src/` returns nothing.

### 7. Final review + commit
- [ ] Re-read the whole diff. Confirm: exactly one renderer per concept (banner, body, diff, plan). No stdout-writing duplicate of a byte builder remains.
- [ ] Build release: `nim c -d:release -o:/tmp/tc src/threecode.nim`.
- [ ] Run `tests/core/test_display.nim`, `tests/core/test_session.nim`, `tests/stream/test_streamexec.nim`, `tests/stream/test_streaming_view.nim`.
- [ ] Commit: `remove alternate tool renderers; unify on the live byte path` (or split into per-item commits if cleaner — one commit per item is fine and preferred).
