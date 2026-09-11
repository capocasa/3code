# Chunk 3: Mistral Large 3 + Medium 3.5 known-good rows

## Goal

Add known-good rows for **Mistral Large 3** and **Mistral Medium 3.5**
on the first-party `mistral` provider and on OpenRouter, verify the wire
ids and reasoning surface against the live APIs, and confirm the
normalized names round-trip.

Large 3 and Medium 3.5 only. Skip Large 2.x, Medium 3.1, Small, and
Ministral (out of scope per `plan-hy4-mistral.md`).

## Read first

- `plan-hy4-mistral.md` (Mistral evidence).
- `impl-hy4-mistral-2.md` (what chunk 2 built: preambles, reasoning
  helper, level gating).
- `src/threecode/prompts.nim`: any first-party Mistral-like block as
  template (e.g. the `kimi` first-party block, `poolside` for a single
  provider's rows), `KnownGoodCombos`.
- `src/threecode/config.nim`: `ProviderCatalog` (`mistral` entry,
  ~line 957) and `KeyPrefixCatalog`.

## Instructions

### 1. Confirm the provider host

`ProviderCatalog` already holds `("mistral", "https://api.mistral.ai/v1")`.
No catalog change needed. Confirm the key-prefix catalog does not need a
Mistral entry (only add one if Mistral keys have a distinctive prefix;
they typically do not, so likely no change).

### 2. Verify the wire ids live

With a Mistral key in the environment:

```
curl -s https://api.mistral.ai/v1/models \
  -H "Authorization: Bearer $MISTRAL_API_KEY" \
  | python3 -c "import sys,json;print([m['id'] for m in json.load(sys.stdin)['data'] if 'large' in m['id'] or 'medium' in m['id']])"
```

Expected ids include `mistral-large-2512` (or `mistral-large-latest`)
and `mistral-medium-3-5`. **Use `mistral-medium-3-5` (hyphens), not the
dotted `mistral-medium-3.5`** (a known integration typo). Pick the dated
id for reproducibility; use the `-latest` alias only if the dated id is
absent. If no key is available, extract ids from `docs.mistral.ai/models`
and mark the live check as not performed in the handoff, do not claim
it.

Cross-check OpenRouter (no key needed):

```
curl -s https://openrouter.ai/api/v1/models \
  | python3 -c "import sys,json;print([m['id'] for m in json.load(sys.stdin)['data'] if m['id'].startswith('mistralai/')])"
```

Expected `mistralai/mistral-large-2512` and `mistralai/mistral-medium-3-5`.

### 3. Confirm the reasoning surface live

Send a tiny first-party request with `reasoning_effort: "high"` and
with `"none"`; both must return 200. Send `"medium"` and confirm it 422s
(expected `Input should be 'none' or 'high'`). Capture the exact
response shape of the thinking chunk (`reasoning_content` field?) to
decide `thinkBack`. If the field name differs, adjust `callModel`'s
reasoning parser only if a generic path does not already cover it; do
not special-case prematurely.

If Large 3 rejects `reasoning_effort` (400/422), set its row reasoning
to `""` and let `knownGoodReasonings` return `@[]` for it (chunk 2
already gates on the `medium` variant).

### 4. KnownGoodCombos rows

Insert a Mistral block (after the `mimi`/`kimi` first-party blocks is
fine). Suggested rows, to be reconciled with step 2/3:

```
# mistral (api.mistral.ai/v1; bare model ids). Large 3 (675B-A41B MoE,
# Apache 2.0) and Medium 3.5 (128B dense, Modified MIT), both 256K ctx,
# multimodal. Medium 3.5 reasoning_effort none/high; Large 3 has no
# advertised knob.
("mistral", "mistral-large-2512", "mistral", "", "large", "", 0.2, 8192, tbNone, false, 262_144, false),
("mistral", "mistral-medium-3-5", "mistral", "", "medium", "high", 0.7, 8192, tbNone, false, 262_144, false),
("openrouter", "mistralai/mistral-large-2512", "mistral", "", "large", "", 0.2, 8192, tbNone, false, 262_144, false),
("openrouter", "mistralai/mistral-medium-3-5", "mistral", "", "medium", "high", 0.7, 8192, tbNone, false, 262_144, false),
```

Notes:
- `variant` must be `large` / `medium` to match the chunk-2
  reasoning-level gating.
- `thinkBack`: start `tbNone` (Mistral thinking chunks are not expected
  to be replayed); switch to `tbCurrentTurn` only if a tool-loop smoke
  test shows the model needs it. Verify in step 5 of chunk 4.
- `temperature` 0.7 for Medium (Mistral's recommendation for
  `high`); 0.2 for Large (no documented preference, keep cool).
- `maxTokens` 8192 for both; raise Medium to 16384 only if a smoke test
  is truncated mid-tool-call.
- `contextWindow` 262_144 for both.
- `allowPrivate` false (Mistral first-party is not on the curated
  zero-retention list).

If the dated Large id is absent and the alias is used, use
`mistral-large-latest` in both the first-party and OpenRouter rows only
if OpenRouter exposes the same alias; otherwise keep the OpenRouter row
on `mistralai/mistral-large-2512`.

### 5. Normalization round-trip

Confirm the config write-back does not mangle the ids:

```
nimble test tests/config/test_modelname.nim
```

and, if a config round-trip test exists, extend it to cover
`mistral-medium-3-5`.

## Verification

```
nimble test tests/config/test_modelname.nim
nimble test
```

Both green. `:model mistral` and `:model mistral-medium-3-5` must be
selectable without `--experimental` against a configured `mistral`
provider.

## Next step

When complete and verified, call context_clear with:
- summary: "Chunk 3 done: Mistral rows added. Wire ids verified (or not,
  state which), reasoning surface none/high confirmed/assumed, rows for
  mistral + openrouter, variant large/medium set. <paste pass lines>."
- instructions: "Read impl-hy4-mistral-4.md and execute the instructions
  there."
