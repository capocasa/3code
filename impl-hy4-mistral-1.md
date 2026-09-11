# Chunk 1: Hy4 support

## Goal

Add Tencent Hunyuan Hy4-preview as a known-good model on the existing
`hy` family: a Hy4 preamble, a `setup()` branch keyed on version 4,
Hy4-specific reasoning levels (`no_think`/`high` only), and
`KnownGoodCombos` rows for OpenRouter and Tencent TokenHub (plus any
aggregator already carrying hy3 that also lists hy4).

## Read first

- `plan-hy4-mistral.md` (master plan, Hy4 evidence section).
- `src/threecode/prompts.nim`: `HyPreamble` (~line 1407), the `hy`
  `KnownGoodCombos` rows (~line 291), `hySetup` (~line 2926), `setup()`
  (~line 2940), the `knownGoodReasonings` hy branch (~line 3363).
- `src/threecode/api.nim`: `applyHy3Reasoning` (~line 2245),
  `applyReasoning()` (~line 2400).
- `src/threecode/modelname.nim`: `ModelFamilies`.
- `src/threecode/config.nim`: `ProviderCatalog` (~line 933).
- `tests/config/test_modelname.nim`.

## Instructions

### 1. Confirm normalization (no code change expected)

`normalizeModelName("tencent/hy4-preview")` must yield `hy4-preview`:
family `hy` (glued on the digit), version `4`, designator `preview`.
`hy` is already in `ModelFamilies`. Add assertions in chunk step 6.

### 2. Hy4 preamble

- Keep `HyPreamble` as the Hy3 prompt.
- Add `const Hy4Preamble = """..."""` immediately after it. Content
  must state: Tencent Hy4 (770B total / 49B active MoE), 1M token
  context, Apache 2.0, agent-first for reasoning/coding/long-horizon
  tool use. Reasoning section describes the **two-level** knob:
  `high` (default, deep chain-of-thought, use for real engineering) and
  `no_think` (direct response for trivial lookups, renames, format
  passes). Note the native tool format is still the Hunyuan XML
  envelope, normalized by the harness to OpenAI `tool_calls`. Copy the
  reasonable end of `HyPreamble` (act/verify/report, reading, editing
  rules) so the two prompts stay otherwise parallel.

### 3. `setup()` branch

Add near the other setup tuples:

```
hy4Setup = (prompt: Hy4Preamble, tools: glmAndQwenTools)
```

Change the `of "hy":` arm in `setup()` to:

```
of "hy":
  if p.version == "4": hy4Setup
  else: hySetup
```

### 4. Reasoning levels

In `knownGoodReasonings`, split the `hy` branch on version:

```
if fam == "hy":
  # Hy3 exposes no_think/low/high on the vLLM reasoning_effort surface;
  # Hy4's chat template accepts exactly high and no_think and raises on
  # anything else.
  if combo.version == "4": return @["no_think", "high"]
  return @["no_think", "low", "high"]
```

### 5. KnownGoodCombos rows

Insert after the existing hy block (~line 291). Wire id is `hy4-preview`
on every route; version `4`, variant `preview`, context 1M, max output
64k, `tbAllTurns` (Hy4 preserves `reasoning_content` across tool
turns).

```
# Hy4 preview (Tencent Hunyuan v4, Aug 2026): 770B-A49B, Apache 2.0,
# 1M ctx (960k in / 64k out). Two-level reasoning, high (default) or
# no_think; preserved thinking. Recommended temperature 0.9.
("openrouter", "tencent/hy4-preview", "hy", "4", "preview", "high", 0.6, 65536, tbAllTurns, false, 1_000_000, false),
("tencent", "hy4-preview", "hy", "4", "preview", "high", 0.6, 65536, tbAllTurns, false, 1_000_000, false),
```

Temperature: start at `0.6` rather than the card's `0.9`. This is an
agentic harness; confirm tool-call reliability in chunk 4 and keep the
lower value unless a smoke test argues otherwise. Note the choice in
the row comment.

Then check the aggregator model lists already hosting hy3:

- `novita`: `GET https://api.novita.ai/openai/v1/models` (or the site)
  for a `hy4` id.
- `deepinfra`: `GET https://api.deepinfra.com/v1/openai/models` for
  `tencent/Hy4`.
- `openrouter`: `tencent/hy4-preview` (confirmed).

Add a row per provider that serves it, mirroring that provider's
existing hy3 row's field style (allowPrivate true for novita).

### 6. New provider: Tencent TokenHub

Add to `ProviderCatalog` in `config.nim`, in the alphabetical block:

```
("tencent",     "https://tokenhub-intl.tencentcloudmaas.com/v1"),
```

If a US-default is preferred, use the US host instead:
`https://tokenhub-us.tencentcloudmaas.com/v1`. Document the chosen
region in a one-line comment. No `auth`/oauth wiring is needed; it is a
plain bearer-key OpenAI-compatible endpoint.

### 7. Tests

In `tests/config/test_modelname.nim`, extend the glued-family test:

```
check normalizeModelName("tencent/hy4-preview") == "hy4-preview"
check normalizeModelName("hy4") == "hy4"
```

Add a `format` assertion mirroring the existing hy3 one:
`format(ModelName(family: "hy", version: "4")) == "hy4"`.

## Verification

```
nimble test tests/config/test_modelname.nim
nimble test
```

Both green. Spot-check the live row wire-up with the stub or a
configured key via `:model hy4` (must not need `--experimental`).

## Next step

When complete and verified, call context_clear with:
- summary: "Chunk 1 done: Hy4 added. Hy4Preamble, setup() hy-version-4
  branch, no_think/high reasoning levels, OpenRouter + TokenHub (+ any
  aggregator) rows, tencent provider in ProviderCatalog, modelname tests
  green. <paste the exact test pass lines>."
- instructions: "Read impl-hy4-mistral-2.md and execute the instructions
  there."
