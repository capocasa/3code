# GLM 5.3 cache and benchmark analysis

## September 5/6 rerun

Source: `~/p/3code-swe/tokens-proxy-glm-5.3-CORRECTED.tsv`,
`tokens-claude-glm-5.3-20260906.tsv`, and `summary-glm53-rerun.md`.
Ten SWE-bench Verified tasks, 600 seconds per task. This is a small,
web-enabled practical comparison, not a clean unaided benchmark.

The corrected proxy TSV columns are **fresh input, cached input, output**.
Do not subtract cached input again. The uncorrected TSVs and 3code session
receipts contain invalid prompt counts from the LiteLLM stream accounting
bug. Some receipts even show hits above 100%.

| Agent | Resolved | Fresh input | Cached input | Output | Cache hit | API-equivalent cost |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 3code | 9/10 | 216,049 | 4,768,512 | 80,087 | 95.67% | $1.895 |
| OpenCode | 9/10 | >=74,460 | 9,780,352 | 132,271 | <=99.24% | >=$3.229 |
| Pi | 6/10 | 505,192 | 6,400,384 | 320,230 | 92.68% | $3.780 |
| ZCode | 6/10 | >=305,023 | 13,534,208 | 339,200 | <=97.80% | >=$5.438 |
| Hermes | 7/10 | >=560,489 | 16,011,648 | 215,569 | <=96.62% | >=$5.896 |
| Claude Code | 8/10 | 631,509 | 22,250,624 | 236,372 | 97.24% | $7.709 |

OpenCode, ZCode, and Hermes fresh-input figures are lower bounds because
exact tool-schema token counts were not recoverable. Their hit percentages
are therefore upper bounds, not lower bounds as labeled in the summary.

Dollar figures use the published Z.AI API rates retrieved September 7:
$1.40/M fresh input, $0.26/M cached input, $4.40/M output.
They are normalized model-token estimates, **not actual invoices**, and
exclude web-tool fees and local execution. Coding Plan calls consume
subscription quota rather than these per-token dollar charges.

At these rates, 3code costs at least 41.3% less than OpenCode for the same
nine solved tasks: $0.211 versus >=$0.359 per solved task, including the
failed task's cost. OpenCode saves at most $0.198 in fresh input relative
to 3code, but adds $1.303 in cache reads and $0.230 in output.

Using the currently published Coding Plan weights (6.9 fresh, 1.7 cached,
24 output, divided by 10,000), the same traffic would consume off-peak
credits of 576.0 / >=1015.7 / 1102.6 / >=1662.7 / >=1813.0 / 2392.8 in
3code/OpenCode/Pi/ZCode/Hermes/Claude order. These are normalized estimates,
not recovered historical quota deductions. Peak credits are twice those.

### Per-task model-token cost

| Task | 3code | OpenCode lower bound | 3code result |
| --- | ---: | ---: | --- |
| astropy-14369 | $0.4363 | $0.6211 | resolved |
| django-15037 | $0.1486 | $0.3539 | resolved |
| django-15368 | $0.0941 | $0.2588 | resolved |
| matplotlib-26342 | $0.3786 | $0.5759 | resolved |
| requests-1766 | $0.0228 | $0.1977 | resolved |
| xarray-6461 | $0.1661 | $0.2106 | resolved |
| pytest-7236 | $0.2020 | $0.4566 | resolved |
| scikit-learn-14087 | $0.1009 | $0.2717 | timeout |
| sphinx-8056 | $0.3075 | $0.2474 | resolved |
| sympy-23534 | $0.0378 | $0.0355 | resolved |

3code is cheaper on eight tasks even against OpenCode's lower bounds.
Sphinx and SymPy are candidates for closer comparison, not proven cost
losses given the incomplete OpenCode input accounting.

### Comparability limits found in raw records

- The retained September 5 3code run used `https://api.z.ai/api/paas/v4`.
  Proxy usage records during the run confirm this. OpenCode's September 6
  rerun used the Coding Plan endpoint. The summary's blanket endpoint
  description does not describe the retained run. Preserved-thinking
  defaults differ between those endpoints.
- 3code fetched upstream patches. For example,
  `~/.local/share/3code/sessions/20260905T022022.3log:498` fetches
  `https://github.com/pydata/xarray/pull/6461/files`.
  `20260905T023749.3log:1409` fetches the Sphinx task's upstream PR.
  These scores cannot establish independent patch-discovery ability.
- The scikit-learn trace (`20260905T022748.3log`) spends repeated tool calls
  building old native extensions, then ends during another build attempt.
  Lines 863, 882, 959, and 988 show repeated `setup.py build_ext` calls.
  This is a concrete environment-recovery/time-budget problem, not evidence
  that another four percentage points of cache hits would solve the task.
- One run of ten tasks does not establish a general quality ranking.
  Overall elapsed run windows mix inference, tools, setup, and evaluation.

## Reasoning preservation

3code collects `reasoning_content`, but `api.callModel` strips it from
all non-DeepSeek requests, including GLM. Z.AI recommends returning GLM
reasoning unchanged for interleaved tool use and preserved thinking.
The standard API needs `thinking.clear_thinking: false` for preserved
thinking; the Coding Plan endpoint enables preservation by default.
Other hosting stacks need their own capability checks.

Reasoning is not a free metadata channel. It is output when generated;
when incorporated into later model context it counts as input, eligible
for cache-read pricing. Replaying it can increase cumulative input a lot.
It can also reduce repeated reasoning and preserve generated-prefix cache
reuse, so the net effect must be measured rather than inferred from hit rate.

At the stated API prices, one million additional cached input tokens cost
$0.26. That needs about 59,091 fewer output tokens to break even if nothing
else changes. Moving 3code's existing prompt volume from 95.67% to 99.24%
would save only about $0.203 across the ten tasks, assuming unchanged
input volume and output. This is a hypothetical ceiling comparison, not a
prediction for reasoning preservation.

Do not enable preservation solely to reach 99%. A useful A/B keeps the
endpoint, model, reasoning effort, task environment, and web policy fixed,
and compares correctness, fresh input, cached input, output, and time.

## Prompt stability change

The live session now snapshots its system prompt for the selected profile.
Subsequent skill catalog changes append a replacement listing to the newly
submitted user message. Skill bodies are still read on demand, never loaded
by catalog discovery. Editing a skill body does not change the system prompt.
Changing a prompt override takes effect on a fresh session or profile change.

Explicit model/provider changes still rebuild the system prompt. Clear
remains a reset boundary. Saved sessions store the dynamic inputs the
prompt was built from (the skills catalog, stamped with the profile
identity that built the prompt) instead of the prompt itself; resume
reconstructs it from the profile substituting the persisted catalog, which
re-sends the live bytes and keeps the provider cache hot. The template
lives in the binary, so resuming across a 3code upgrade that changed it
re-sends a fresh prefix once. Compaction retains the existing system
snapshot but necessarily replaces conversation history. New skills are
announced on the next user submission.

Verification covers stable prefixes, new/removed skills, body-only edits,
reasoning versus model changes, compaction, clear, and the web example's
second HTTP prompt with a newly installed skill. The example test's build
now excludes parent-project configs and uses the current checkout's absolute
source path; its old build accidentally imported the enclosing checkout.

## Next improvements

1. Bound environment repair time and switch to a smaller validation strategy
   before repeated builds consume the task budget. Never report unrun tests
   as passing, but do not postpone all patch work until a legacy build works.
2. Measure reasoning preservation on the same endpoint before changing it.
3. Record per-request usage, model/endpoint, elapsed time, and stable-prefix
   fingerprints without storing credentials. Keep raw provider usage.
4. Repeat matched tasks with network access to benchmark solutions blocked
   if the goal is independent coding ability. Keep a separate web-enabled
   practical benchmark if that is the product goal.

Sources:
- https://docs.z.ai/guides/overview/pricing
- https://docs.z.ai/devpack/overview
- https://docs.z.ai/guides/capabilities/thinking-mode
