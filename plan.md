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
- Not yet started: items 2-6.
- The alternate stdout renderers still exist and are still called by `replaySessionTail`, `showTool`, `listTools`.

## Items

### 1. Remove dead code left by the plan-tool fix  ✅ DONE
- [x] Delete the unreachable `elif kind == akPlan` branch in `toolResultBytes` (display.nim:~660). Confirmed unreachable: the `act` overload of `toolTranscriptBytes` dispatches `akPlan` itself to `planTranscriptBytes` before ever calling `toolResultBytes`, and no caller invokes the string-banner overload with `akPlan`.
- [x] Delete `printActionResult` (display.nim:409) — zero callers.
- [x] Updated `planResultBytes` docstring (315) to drop the stale `printToolResult` reference; it now names `planTranscriptBytes` + `showTool`.
- [x] Build OK; `tests/core/test_display.nim` + `tests/core/test_session.nim` green.

### 2. Route session replay (`replaySessionTail`) through the byte path
Currently `replaySessionTail` (display.nim:867) calls `renderToolBanner` + `printToolResult` per tool_call. Change it to build the composite bytes via the same `toolTranscriptBytes(act, res, code, idx, diff)` the live path uses, and write those bytes to stdout. To do that it needs the `Action`; it already reconstructs one via `toolCallToAction` in the no-toolLog branch — extend the toolLog branch to reconstruct the `Action` too (the `ToolRecord` has `kind`, `output`, `code`, `banner`, `plan`; reconstruct a minimal `Action` from those, or better, store enough on `ToolRecord` — see item 3).
- [ ] Make the per-tool_call loop reconstruct an `Action` in both branches (toolLog present and absent).
- [ ] Replace `renderToolBanner` + `printToolResult` with `stdout.write toolTranscriptBytes(act, ...)`.
- [ ] Verify a resumed session (with a bash call, a read, a plan) renders identically to how it looked live. Add a test to `tests/core/test_display.nim` that feeds a small message list + toolLog through `replaySessionTail` (capture stdout via the temp-file swap already used in that test file) and asserts the banner glyph + body bytes match the live `toolTranscriptBytes` output for the same action.
- [ ] Do NOT delete `renderToolBanner`/`printToolResult` yet — `showTool` still uses them (item 5).

### 3. Decide the `ToolRecord` ↔ `Action` bridge
`replaySessionTail` and `showTool` need an `Action` to call the byte builders, but `ToolRecord` only stores `kind`, `output`, `code`, `banner`, `plan`. Two options:
  - (a) Reconstruct a minimal `Action` from the `ToolRecord` fields (set `act.kind`, `act.body = output`, `act.plan = plan`, leave path/edits empty). Works for rendering but loses the original banner text and diff.
  - (b) Store the original `Action` (or its render-relevant fields: `path`, `body`, `offset`, `limit`, `edits`) on `ToolRecord` so the byte path can reproduce the exact banner and body. More faithful; bigger change to types + both construction sites (turns.nim:497, session.nim:1005) + session save/load.
- [ ] Decide a or b. Prefer (b) only if (a) visibly misrenders a kind in replay. Record the decision here. The banner is the riskiest field: `bannerFor(act)` is computed from the action, but `ToolRecord.banner` is stored — so the byte path's `bannerFor(act)` must match the stored banner, or the byte path should use the stored banner directly. Check this per kind before committing.

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
