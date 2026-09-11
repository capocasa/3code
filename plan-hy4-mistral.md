# Plan: add Hy4 and Mistral to 3code

Master plan for a chunked implementation. Chunks live in
`impl-hy4-mistral-1.md` .. `impl-hy4-mistral-4.md`. Execute them in
order, each in a fresh context, per the chunked-implementation workflow.

## Decisions (from the model survey, Sep 2026)

| Candidate | Decision | Reason |
|---|---|---|
| Tencent Hy4-preview | **ADD** | Frontier OSS, Apache 2.0, 770B-A49B, 1M ctx, on OpenRouter day one. 3code has hy3, no hy4. |
| Nemotron 3 | skip | User call. (Note: `nemotron` is in `ModelFamilies` and has a preamble but zero `KnownGoodCombos` rows; leave as-is.) |
| Mistral Large 3 + Medium 3.5 | **ADD** | Both confirmed open weights (Large 3 Apache 2.0, Medium 3.5 Modified MIT). User wants a `mistral` provider + these two only. |
| Motif 3 | defer | See "Motif 3 verdict" below. Not wired now. |
| Arcee / Gemma / Mistral small / Ornith | skip | User call. |
| Muse (Glimmer / Spark) | research only | See "Muse" below. Not open weights for Spark; Glimmer too weak. |

## Scope

### In
- **Hy4**: extend the existing `hy` family with Hy4-preview rows, a Hy4
  preamble, and Hy4-specific reasoning levels (`no_think`/`high` only,
  narrower than Hy3's `no_think`/`low`/`high`). Provider routes:
  OpenRouter (`tencent/hy4-preview`), first-party Tencent TokenHub
  (`hy4-preview`), and any aggregator already carrying hy3 that also
  lists hy4.
- **Mistral**: new `mistral` family (preamble, tools, setup, reasoning
  dispatch) plus known-good rows for **Mistral Large 3** and
  **Mistral Medium 3.5** on the first-party `mistral` provider
  (`https://api.mistral.ai/v1`, already in `ProviderCatalog`) and on
  OpenRouter.

### Out
- Nemotron, Arcee, Gemma, Mistral Small/Ministral, Ornith, Motif, Muse.
- Niche: Seed 2.0 (API-only, not open weights), Mercury 2 (API-only
  diffusion dLLM), "Llama 5" (no credible release), Ernie, Command A+,
  Granite, Exaone, Sarvam, LFM.

## Evidence (fetched this session)

### Hy4-preview
- Tencent, 770B total / 49B active MoE, **Apache 2.0**, released
  2026-08-28. 1M ctx (960k max input, 64k max output).
- Reasoning: chat template accepts **exactly `high` (default) and
  `no_think`**, raises on anything else. Sends `reasoning_content`;
  preserved across multi-turn tool calls.
- Recommended sampling: `temperature=0.9`, `top_p=1.0`.
- Wire id `hy4-preview` everywhere. OpenRouter slug `tencent/hy4-preview`.
- TokenHub base URLs: `https://tokenhub-intl.tencentcloudmaas.com/v1`
  (Singapore/Global), `https://tokenhub-us.tencentcloudmaas.com/v1`
  (US), `https://tokenhub.tencentcloudmaas.com/v1` (Guangzhou).
- Source: github.com/Tencent-Hunyuan/Hy4-preview, huggingface.co/tencent/Hy4-preview,
  tencentcloud.com/document/product/1300/80695, openrouter.ai/tencent/hy4-preview.

### Mistral
- **Mistral Large 3**: 675B / 41B active MoE, 256K ctx, multimodal,
  **Apache 2.0**. API id `mistral-large-2512`, alias `mistral-large-latest`.
- **Mistral Medium 3.5**: 128B dense, 256K ctx, multimodal, **Modified
  MIT** (open weights, revenue carve-out). API id `mistral-medium-3-5`
  (hyphen, not dot), alias `mistral-medium-latest`, SWE-bench Verified
  77.6%.
- Reasoning: **top-level `reasoning_effort`, accepted values `none` and
  `high` only** (422 on anything else). `high` for agentic/coding.
  Temperature 0.7 with `high`. Large 3 docs do not advertise
  `reasoning_effort`; assume no knob unless a live call proves otherwise.
- OpenRouter slugs: `mistralai/mistral-large-2512`,
  `mistralai/mistral-medium-3-5`.
- Sources: mistral.ai/news/mistral-3, docs.mistral.ai/models/mistral-large-3-25-12,
  docs.mistral.ai/models/mistral-medium-3-5-26-04,
  huggingface.co/mistralai/Mistral-Medium-3.5-128B, openrouter.ai/mistralai/*.

## Motif 3 verdict (investigation result)

**Not worth wiring now; revisit if it lands on a mainstream gateway.**

- Substance: 314B / 13.2B active MoE, MIT, 256K ctx. Genuinely strong
  for its size: 76.2 SWE-bench Verified, 74.9 Terminal-Bench 2.1,
  AAII 47 (9th globally, 4th open-weight, 1st in South Korea as of Aug
  2026). The weights and MIT license are real.
- Friction: it is **not on OpenRouter** (verified live this session: 437
  models, zero `motif` matches) and Artificial Analysis lists no API
  providers. Access is the lab's own early-access API
  (`motiftech.io/en/openapi/`) plus self-host (vLLM, B200/H200). A
  first-party early-access key with no SLA is a maintenance liability
  for a small model registry.
- Call: skip for this pass. Add a `motif` family only when it appears on
  OpenRouter or a provider 3code already trusts, or if a user commits to
  self-hosting. The scaffolding cost is identical to Mistral's, so a
  later add is cheap.

## Muse (research answer)

- **Muse Spark** (Meta Superintelligence Labs, API-only, NOT open
  weights). Muse Spark 1.3 (2026-09-02): 1M ctx, text/image/video/audio/pdf.
  Yes, it codes, and well: DeepSWE v1.1 75.4, SWEAtlas QnA 59.4,
  Terminal-Bench 2.1 ~88.8-89.2, ties GPT-5.6 Sol at roughly half the
  cost per task; #6 on the Artificial Analysis Intelligence Index.
  Pricing is two SKUs of the same checkpoint: standard `$1.25 / $4.25`
  per M tokens (cache read `$0.15`), or "Contributor" `$0.10 / $0.20`
  (cache read `$0.002`) if Meta may train on your prompts. On OpenRouter:
  `meta/muse-spark-1.2`, `meta/muse-spark-1.3`,
  `meta/muse-spark-1.3-contributor`.
- **Muse Glimmer 30B** is the open-weight one (Apache 2.0, 30B dense,
  local-agent focused) but much weaker (AA index 35). On OpenRouter as
  `meta/muse-glimmer-30b`.
- Call: no add. Spark is a strong hosted model but not open weights, so
  it does not fit this pass; a hosted `muse` family is a separate
  decision if 3code ever wants the Contributor tier's economics.

## Architecture: where a family/model lives

A model addition touches up to six places. Grep `nemotron` and `0xalpha`
in `src/` as the worked template.

1. `src/threecode/modelname.nim`: `ModelFamilies` (and `ModelAliases` if
   a bare alias is needed).
2. `src/threecode/prompts.nim`: the family preamble const, the
   `xSetup = (prompt:, tools:)` tuple, the `setup()` case branch, the
   `KnownGoodCombos` rows, and the `knownGoodReasonings` per-family
   levels.
3. `src/threecode/api.nim`: an `applyXReasoning` proc and the
   `applyReasoning()` case branch.
4. `src/threecode/actions.nim:162`: the tool-dispatch case (add the
   family to the `dispatchGlmOrQwen` list when it uses the standard
   tool surface).
5. `src/threecode/config.nim`: `ProviderCatalog` (only when a new
   provider host is introduced).
6. Tests: `tests/config/test_modelname.nim` for normalization;
   config/api tests for reasoning wire shape.

## Chunks

- **Chunk 1** (`impl-hy4-mistral-1.md`): Hy4 support. Preamble, setup
  branch, reasoning levels, `KnownGoodCombos` rows (OpenRouter +
  TokenHub + aggregators if present), modelname tests.
- **Chunk 2** (`impl-hy4-mistral-2.md`): Mistral family scaffolding.
  `ModelFamilies`, preamble, setup, `applyMistralReasoning`,
  `actions.nim` dispatch, modelname/tests.
- **Chunk 3** (`impl-hy4-mistral-3.md`): Mistral known-good rows for
  Large 3 + Medium 3.5 (first-party `mistral` + OpenRouter), params,
  live wire verification.
- **Chunk 4** (`impl-hy4-mistral-4.md`): full build + test suite,
  optional live smoke test, `CHANGELOG.md` + `docs/manual.md`, commit.

## Acceptance

- `hy4` and `mistral` resolve as known-good; `:model hy4` / Mistral ids
  work without `--experimental`.
- Hy4 reasoning offers only `no_think`/`high`; Mistral offers only
  `none`/`high`.
- `nimble test` green (full suite); new modelname/config tests present.
- `CHANGELOG.md` entry written; `docs/manual.md` model list updated if it
  enumerates families.
- One-line commit, no coauthor trailer, no AI traces.
