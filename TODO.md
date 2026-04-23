# todo

## the pitch

**3code, the economical coding agent.**

Every feature should be weighed against that. Other agents splurge; 3code
doesn't. This is priority number one now that the basics run. Mention it in
README, nimble description, wizard first-run, and `:help` header.

## token economy — shipped

- **supersede compaction**: earlier full-body writes + reads to a path are
  elided once a later write/patch/read on that path lands (runs every
  turn, lossless for the next call)
- **system prompt trim**: 4,447B → 2,314B (~530 tokens saved per call)
- **tool schema trim**: 2,063B → 1,408B (~165 tokens saved per call) —
  dropped filler descriptions; names + types carry the signal
- **bash body omits `$ cmd` echo**: the model already has the command in
  its own tool_call arguments; display still renders it locally
- **stable system prompt prefix**: dropped per-profile "Running X via Y"
  line so the bytes are identical across calls, sessions, and profile
  switches. Enables automatic prefix caching on providers that honor it
  (Anthropic, OpenAI, DeepInfra) — up to 90% off prompt tokens on hit.
- context-window compaction at 80% of model window (old compactHistory)
- tight tool-output clip: 4KB stdout / 2KB stderr
- `[exit 0]` suppressed from the display (stderr + non-zero still shown)
- system prompt nudges: default to `patch` after first write; do not
  re-read to verify a successful write

## token economy — queued: CACHING

This is the win we want next. Everything else is noise until this is in.

### code work

- **read `usage.prompt_tokens_details.cached_tokens`** from the API
  response in `callModel` and show it in the per-turn stats line and
  the spinner. Without surfaced cache-hit numbers we can't tell whether
  caching is actually firing.
- ~~**anthropic `cache_control`**~~: **skipped for now.** 3code's pitch
  is third-party providers, economically. If you have an Anthropic
  account, just use Claude Code — that's what it's for. Stance may
  change if users ask.
- **structural prerequisite — already shipped**: stable system prompt
  prefix (win E). No dynamic content in `SystemPrompt`; `buildSystemPrompt`
  returns the const verbatim.

### known-good caching providers (whitelist)

Recommend these in the wizard / `:help` and tag them in the shortlist
with a little cache mark.

- **DeepInfra** — explicit prompt caching on OpenAI-compatible endpoints,
  reports `prompt_tokens_details.cached_tokens` in `usage`, ~50% discount
  on cached portion. Works across Qwen3-Coder, DeepSeek, Llama hosts.
  Our top recommendation: transparent, multi-model, already in config.
- **DeepSeek (official API)** — automatic, reports
  `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens` in `usage`,
  ~90% off cached. Cleanest implementation, but only serves DeepSeek
  models.
- **Anthropic (via explicit `cache_control`)** — 90% off cached portion
  on hit. Manual opt-in; see code work above.
- **Together AI** — documented prefix caching ("dedicated endpoint
  caching" on some tiers, automatic on others). Less transparent than
  DeepInfra but should just work.
- **Fireworks** — prefix caching on serverless endpoints; doesn't
  surface cache-hit stats, so we get the discount silently but can't
  verify it.

### unknown / avoid for caching

- **Groq** — no prompt cache. Speed comes from the hardware, not
  caching.
- **Nebius** — caching not clearly documented. Assume off.
- **Cerebras, SambaNova** — caching on some endpoints, mostly pitched
  on speed; revisit if/when we get a caching provider hint from them.

### practical default

**DeepInfra + Qwen3-Coder-480B** is the pick: agentic-code-grade model,
transparent caching, and we can verify hits via `cached_tokens` in
`usage` once the code work above lands.

## recommended models

ship an opinionated shortlist of agentic-code models. don't hard-block
others — just warn. surface it in README, `:help`, and the wizard
model-pick ("models outside this list are your cash to burn").

### tier 1 — defaults

- moonshotai/kimi-k2.5
- moonshotai/kimi-k2-thinking          (plan-first variant)
- qwen/qwen3-coder-480b-a35b-instruct
- z-ai/glm5                             (and glm-5.1 when available)
- anthropic claude sonnet / opus (via api)
- openai gpt-5 family (via api)

### tier 2 — solid alternates

- deepseek-ai/deepseek-v3.2  (or -v3.1-terminus fallback)
- qwen/qwen3.5-397b-a17b
- mistralai/devstral-2-123b-instruct-2512

### tier 3 — cheap / small-task

- qwen/qwen3-next-80b-a3b-thinking
- openai/gpt-oss-120b

### avoid for agentic code

- minimaxai/minimax-m2.5, m2.7        (burned 500k tok on a dice roller;
                                        tool-loop thrashing, language leaks,
                                        whole-file rewrites instead of patches)
- nvidia/*-nemotron-*                  (safety/chat-tuned, not agentic)
- google/gemma-*                       (too small, not agentic)
- meta/codellama-70b, bigcode/starcoder2-15b  (dated)
- ibm/granite-*                        (enterprise chat, weak at tools)
- any embedding / guard / safety / reward model — not a chat model, will
  refuse or error

## field notes

- qwen3-coder-480b via deepinfra: burned 154k tok on a small nim tool.
  zero `patch` calls across 21 tool calls, seven consecutive full-file
  writes, two `rm -rf` project resets, read-back-after-write paranoia.
  no language leaks, good layout — conviction-rewrite failure mode, not
  confusion. supersede compaction should cut this case ~40%.
- minimax-m2.5-fast via nebius: 500k tok on the same shape of task.
  confusion-rewrite mode: read CLAUDE.md twice, violated its layout rule
  anyway, leaked a Chinese token into a shell flag. avoid outright.
