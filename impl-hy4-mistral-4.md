# Chunk 4: build, full suite, docs, commit

## Goal

Verify the Hy4 and Mistral additions end to end, run the full test
suite, do an optional live smoke test, update `CHANGELOG.md` and the
README combo count, and commit.

## Read first

- `plan-hy4-mistral.md` (acceptance criteria).
- `impl-hy4-mistral-1.md` .. `impl-hy4-mistral-3.md` (what landed).
- `CHANGELOG.md` (top, the `**unreleased**` section).
- `README.md` (the "N known-good combos" line).

## Instructions

### 1. Build

Per `AGENTS.md`, build with plain `nim c`, not `nimble build` (a stale
`~/.nimble/pkgs2/threecode-*` install can shadow local modules):

```
nim c src/threecode.nim
```

Must compile clean. If symbols look stale, check for a pkgs2 copy and
remove it, then rebuild (`AGENTS.md`, "Builds").

### 2. Targeted tests

```
nimble test tests/config/test_modelname.nim
nimble test tests/config/test_config_extra.nim
nimble test tests/api/test_api.nim
```

All green. These cover normalization, known-good matching, and the
reasoning wire shape.

### 3. Full suite

```
nimble test
```

Read the output; the pass line must be visible. Any failure is data: if
it is unrelated, prove it fails on the commit before this work
(`git stash; nimble test; git stash pop`) and report it rather than
waving it away.

### 4. Live smoke test (best effort)

Only if a real key is configured for `mistral` / `tencent` /
`openrouter`:

- `:model hy4` then a one-line prompt that forces a tool call (e.g.
  "read README.md and summarize the first heading"). Confirm the turn
  streams, a tool call fires, and `:reasoning` cycles only
  `no_think`/`high`.
- `:model mistral-medium-3-5`: confirm `reasoning_effort=high` produces
  a thinking chunk and `:reasoning` cycles only `none`/`high`.
- `:model mistral-large-2512`: confirm it runs with no reasoning knob.

If no key is available, document that the live check was not performed
and rely on the unit tests plus the earlier live `curl` verification
from chunk 3. Do not claim a smoke test that did not run.

### 5. thinkBack tuning

If the Mistral tool-loop smoke test shows the model losing context
across tool turns, raise Medium's `thinkBack` from `tbNone` to
`tbCurrentTurn` and re-run chunk 4 steps 2 and 3. Otherwise leave
`tbNone`.

### 6. Docs

- **CHANGELOG.md**: add a bullet under `**unreleased**` covering both
  additions, in the existing prose style:
  - Hy4-preview (Tencent Hunyuan v4, 770B-A49B, Apache 2.0, 1M ctx) on
    OpenRouter and TokenHub; two-level reasoning (`high`/`no_think`).
  - Mistral family: Mistral Large 3 and Mistral Medium 3.5 (both open
    weights) on `api.mistral.ai` and OpenRouter; `reasoning_effort`
    `none`/`high`.
- **README.md**: bump the "N known-good combos" count to the new total.
  Recount from `KnownGoodCombos` (do not guess):
  `grep -c '^\s*("' src/threecode/prompts.nim` is approximate; count
  the entries in the const block precisely.
- `docs/manual.md`: only touch if it enumerates families or model ids
  (it currently does not list them exhaustively, so likely no change).

### 7. Commit

- Stage only the files this work changed (`plan-hy4-mistral.md`,
  `impl-hy4-mistral-*.md` may stay untracked unless the repo tracks its
  plans; check `git status` against how prior `plan-*.md` are handled).
- One-line message, no coauthor trailer, no AI traces, no em dashes.
  Example: `add hy4 and mistral large-3/medium-3.5`.
- Do not push (alpha-level feature work; push is release-time only).

## Verification

- `nim c src/threecode.nim` clean.
- `nimble test` green, pass line observed.
- Smoke test run or explicitly documented as not run.
- `git diff` reviewed; only intended files staged.

## Acceptance

- Hy4 and Mistral known-good; no `--experimental` needed.
- Hy4 `no_think`/`high`; Mistral `none`/`high` (Medium only).
- Full suite green.
- Changelog + README updated.
- Commit landed, not pushed.

## Next step

Task complete. Report to the user: what changed (files), the exact test
result, whether the live smoke test ran and against which surface.
