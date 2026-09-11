# Chunk 2: Mistral family scaffolding

## Goal

Introduce a `mistral` family so Mistral models can be known-good: family
registration, preamble, tool surface, `setup()` branch, a
`applyMistralReasoning` wire helper (`reasoning_effort` with only
`none`/`high`), the `actions.nim` dispatch entry, and modelname tests.

This chunk does **not** add the Large 3 / Medium 3.5 rows (chunk 3).
It only makes the family resolvable and promptable.

## Read first

- `plan-hy4-mistral.md` (master plan, Mistral evidence section).
- `src/threecode/modelname.nim` (`ModelFamilies`, `normalizeModelName`).
- `src/threecode/prompts.nim`: a simple preamble as template
  (`LongcatPreamble` or `HyPreamble`), `xSetup` block (~line 2910),
  `setup()` (~line 2940), `knownGoodReasonings` (~line 3330).
- `src/threecode/api.nim`: `applyHy3Reasoning` (~line 2245),
  `applyReasoning()` (~line 2400).
- `src/threecode/actions.nim:162` (the `dispatchGlmOrQwen` list).
- `tests/config/test_modelname.nim`.

## Instructions

### 1. `ModelFamilies`

In `src/threecode/modelname.nim`, add `"mistral"` to `ModelFamilies`.
Place it so it does not shadow another family prefix; `mistral` and
`mixtral` do not collide with anything else in the list, so append
before `"nemotron"` (order only matters for prefix family wins; none
here).

Check parsing after the change:

- `mistral-medium-3-5` -> `mistral-medium-3-5` (family `mistral`,
  designator `medium`, qualifiers `3`,`5`, version empty).
- `mistral-large-2512` -> `mistral-large-2512` (designator `large`).
- `mistral-large-latest` -> `mistral-large-latest`.

The dated ids parse fine as-is; no `ModelAliases` entry is required. If
you prefer `mistral-medium-3.5` to round-trip to the hyphen form, add a
`ModelAliases` pair, but only if a real wire id needs it.

### 2. Preamble

Add `const MistralPreamble = """..."""` next to the other preambles.
Content: you are backed by Mistral (Mistral Large 3, 675B-A41B MoE, or
Mistral Medium 3.5, 128B dense), both 256K context, Apache 2.0 / open
weights, built for general reasoning, agentic work, and coding. Note
the reasoning knob: `high` enables a full thinking chunk (use for real
engineering and agentic coding), `none` turns it off for cheap direct
responses. Keep the shared 3code body (act/verify/report, reading and
editing rules) parallel to `HyPreamble`.

### 3. Tool surface + setup branch

Mistral speaks the standard OpenAI `tool_calls` surface, so reuse
`glmAndQwenTools`:

```
mistralSetup = (prompt: MistralPreamble, tools: glmAndQwenTools)
```

Add to `setup()`:

```
of "mistral": mistralSetup
```

### 4. Reasoning wiring

Add `applyMistralReasoning` in `api.nim` near `applyHy3Reasoning`:

```
proc applyMistralReasoning(p: Profile, body: JsonNode) =
  ## Mistral reasoning is a top-level `reasoning_effort` that accepts
  ## exactly "none" and "high" (422 on anything else). First-party
  ## (api.mistral.ai) takes the field directly; OpenRouter rides the
  ## normalized `reasoning.effort`. No wire param means the server
  ## default (none) applies.
  if p.reasoning == "": return
  case providerOf(p)
  of "openrouter":
    body["reasoning"] = %*{"effort": p.reasoning}
  else:
    body["reasoning_effort"] = %p.reasoning
```

Add the branch in `applyReasoning()`:

```
of "mistral": applyMistralReasoning(p, body)
```

Verify against a live first-party call in chunk 3 that `reasoning_effort`
is the correct top-level key and that `none`/`high` are the only
accepted values; adjust the `case` if OpenRouter needs the top-level
form instead.

### 5. Reasoning levels

In `knownGoodReasonings`, add:

```
if fam == "mistral":
  # Mistral Medium 3.5 exposes reasoning_effort none/high. Large 3 does
  # not advertise the parameter; gate on the designator.
  if combo.variant.startsWith("medium"): return @["none", "high"]
  return @[]
```

Adjust the `variant` test to whatever chunk 3 sets the row variants to
(expected `medium` / `large`).

### 6. Tool dispatch

In `src/threecode/actions.nim:162`, add `"mistral"` to the
`dispatchGlmOrQwen` case list so tool actions route the standard way.

### 7. Tests

In `tests/config/test_modelname.nim` add:

```
test "mistral family":
  check normalizeModelName("mistralai/mistral-large-2512") == "mistral-large-2512"
  check normalizeModelName("mistral-medium-3-5") == "mistral-medium-3-5"
  check normalizeModelName("mistral-large-latest") == "mistral-large-latest"
```

If `knownGoodReasonings` is unit-tested elsewhere, add a case asserting
Mistral Medium returns `@["none", "high"]`.

## Verification

```
nimble test tests/config/test_modelname.nim
nimble test
```

Both green. `setup(Profile(family: "mistral", ...))` must not hit the
`unknown family` die. (A scratch call or an existing api test that
exercises `setup()` suffices; do not add a throwaway test if a broad
one already runs.)

## Next step

When complete and verified, call context_clear with:
- summary: "Chunk 2 done: mistral family scaffolded. ModelFamilies,
  MistralPreamble, mistralSetup + setup() branch, applyMistralReasoning
  (none/high), actions dispatch, modelname tests green. <paste pass
  lines>. Note: reasoning-level variant keying assumes chunk 3 uses
  variants 'medium'/'large'."
- instructions: "Read impl-hy4-mistral-3.md and execute the instructions
  there."
