.. title:: 3code - the economical coding agent

## Introduction

3code is the coding agent I wanted for my own work: capable, quiet, and not
forever looking for new ways to spend tokens. It works with OpenAI-compatible
providers, including free tiers, flat-rate coding plans, and local servers.

The design rule is simple: get a correct result with the least model work,
token use, and computer time. Open models, especially GLM, are good enough for
most of my programming work. 3code gives them a focused prompt, a small tool
set, persistent sessions, and a terminal interface that stays out of the way.

The standard way to use 3code is also the simplest one: type what you want,
like `fix the flickering caret in the resize path` or `add tests for the
parser edge cases`, and press Enter. Current models read the code, do the
work, and report back, without asking you anything in between. If a task is
overly broad (`improve this project`), you will get questions or a plan
first; narrow it down and it is back to hands-off. The interface exists to
stay out of that loop: scrollback is plain terminal history, the footer is
two rows, and everything else is your terminal's own scrolling, search, and
selection.

This manual is organized how-to style: getting a provider, daily use, the
screen, sessions, the sandbox, embedding. The dry inventory of every config
key, command-line switch, and `:` command lives in the
[reference](reference.html).

## Quickstart

First, give 3code somewhere to run inference: an API provider or a local
OpenAI-compatible server. Local models can work (Ollama and friends speak
the same API), though small ones still have a rough time with difficult
coding tasks.

### Get a provider

There are plenty of compatible providers. A free tier is a good place to
start. Pay for one after you know which model actually works for your projects.

#### Free providers

[NVIDIA Build](https://build.nvidia.com) and
[Novita](https://novita.ai) often have useful free models. The lists and rate
limits move around, as free things tend to do, so check before signing up.

#### Flat-rate coding plans

The [z.ai coding plan](https://z.ai/subscribe) is my main setup. GLM is capable,
inexpensive, and happy to keep working through a long task.

3code can also log in with ChatGPT Plus/Pro and SuperGrok or X Premium+
subscriptions. These are separate from OpenAI and xAI API billing, despite the
similar names.

#### EU providers

When data must stay under EU jurisdiction, I use
[GreenPT](https://greenpt.com). Nebius and Eurouter are also in the provider
catalog.

#### Low-cost providers

DeepInfra, OpenCode, nano-gpt, Novita, and similar aggregators serve quantized
open models cheaply. Quality and availability vary, so a little comparison
shopping pays off.

#### Other models

DeepSeek, MiniMax, Kimi, Tencent Hy, Qwen, Grok, and LongCat are all supported
somewhere. The registry changes too often for a copied list to age gracefully,
so ask 3code for the current one:

```
3code --good
```

OpenRouter and Eurouter are handy when you want to try many models through one
account. Once you settle on one, a direct provider account removes a service
from the request path and is often cheaper. The [provider
catalog](#provider-catalog) below lists who hosts what, where, and which ones
serve quantized weights.

### Install

```
# macOS / Linux
curl -fsSL https://3code.capocasa.dev/install | sh

# Windows (PowerShell)
irm https://3code.capocasa.dev/install.ps1 | iex
```

### Manual install on Windows

The PowerShell one-liner also downloads a private PortableGit tree (bash
+ unix tools) into `%LOCALAPPDATA%\3code\git`, so 3code always has a shell
of its own. If you would rather not, install
[Git for Windows](https://git-scm.com/download/win) and run 3code from a plain
release folder:

1. Download `3code-windows-amd64.zip` from the
   [latest release](https://github.com/capocasa/3code/releases/latest) and
   unpack it, for example to `C:\tools\3code`. The zip carries `3code.exe`,
   the OpenSSL DLLs, and `cacert.pem`, so the folder is self-contained.
2. Put the folder on your `PATH`, or call `3code.exe` by full path.
3. Run it. 3code resolves bash in this order: a `bash_path` setting, then
   the installer's own PortableGit tree (`%LOCALAPPDATA%\3code\git`), then
   the Git for Windows install, then a standalone MSYS2 (`C:\msys64`), then
   the legacy `%LOCALAPPDATA%\3code\msys64` tree. With Git for Windows
   present, no MSYS2 download is needed. A `bash` setting overrides
   the automatic order with a full path to the shell (any OS); `auto`
   (the default) keeps the order above. Both keys are documented in
   [settings in the reference](reference.html#settings).

The bash tool has its own timeout and diff computation built in, so it
needs no GNU coreutils on the host; a bare PortableGit or MSYS2 bash is
enough. If no bash can be found at all, 3code warns and drops the bash
tool (file tools keep working) instead of failing to start.

The one-time `3code setup` (sandbox user + network fence) is still required
on Windows. It needs admin rights: run it from a console/RDP session and it
asks for them via the Windows UAC prompt (from ssh it prints what to do
instead; there the run must come from an admin account or elevated shell).

### Termux on Android arm64

Inside Termux, the same one-liner installs the Android arm64 build:

```
curl -fsSL https://3code.capocasa.dev/install | sh
```

It detects Termux via `$PREFIX` and installs to `$PREFIX/bin`, which is
already on PATH. If you prefer to build where it will run, Termux only needs:

```
pkg install nim git openssl
nimble install https://github.com/capocasa/3code
```

The binary uses Termux OpenSSL for TLS. Android has no OS sandbox or desktop
notifications, but the in-process path checks still apply. Notifications do
nothing. To update, install again or unpack a new archive.

### Add a provider

Run `3code` in your project directory. With no provider configured, it goes
straight to the setup wizard. You can return to the wizard later with:

```
:provider add
```

The first field accepts:

- a catalog name, such as `nvidia`, `zai`, `xai`, or `openai`
- a provider URL when `--experimental` is enabled
- an API key with a recognized prefix
- `supergrok` for SuperGrok or X Premium+ login
- `chatgpt` for ChatGPT Plus/Pro login

The wizard lists the provider's known-good models (a curated registry of
combinations 3code has tested) and saves your selection as-is. With
`--experimental` the wizard queries the provider's models endpoint and
verifies each selection with a 1-token call; press Esc to stop verification.

### Run your first prompt

```
❯ Build a Hello World program in Nim
```

That is enough to get started.

The same prompt given as a command-line argument runs once and exits, for
scripts and one-offs; `-i`/`--interactive` runs it and then drops you into
the REPL. All switches are in the
[reference](reference.html#command-line-switches).

## Providers and authentication

`:provider` lists configured providers and marks the current one, along with
the model a switch would land on. `:model` does the same for its models. Both
commands have tab completion, so there is no need to memorize catalog names.
Model choices are sticky per provider: switching back with `:provider` returns
to the model you last used there, not the first one in its list. The current
provider and model are also sticky per directory: each project starts where
it last left off, while directories never touched by `:provider` / `:model`
keep the global config default. All of this lives in the config file; see
[config file in the reference](reference.html#config-file) for every key.

```
:provider nvidia
:model gpt-oss-120b
```

### API keys

Most providers use an API key, and the wizard recognizes the common prefixes.
For an unknown provider or a custom URL, start 3code with `--experimental`.
The flag is deliberate: compatibility is likely, not promised.

### xAI and SuperGrok

An `xai-` key creates a normal `xai` provider. Enter `supergrok` instead to
sign in with a SuperGrok or X Premium+ subscription. They can live side by
side, which is useful if you have both kinds of account.

The browser OAuth flow stores tokens in:

```
$XDG_DATA_HOME/3code/auth/xai.json
```

On POSIX systems the file is created with mode 0600, and tokens refresh
automatically; a refresh token that dies ends the turn with a re-login
hint, not a crash. Switch accounts with `:provider xai` and
`:provider supergrok`.

### OpenAI and ChatGPT

An OpenAI API key creates an `openai` provider. Enter `chatgpt` instead to use
a ChatGPT Plus/Pro subscription. As with xAI and SuperGrok, both providers can
exist together.

ChatGPT login opens the OpenAI browser OAuth flow and stores tokens in:

```
$XDG_DATA_HOME/3code/auth/openai.json
```

On POSIX systems the file is created with mode 0600, and tokens refresh
automatically; a dead refresh token ends the turn with a re-login hint
rather than a crash. ChatGPT model listings and requests go through the Codex backend
at `chatgpt.com/backend-api/codex`.

OpenAI and ChatGPT use the Responses API. Other OpenAI-compatible providers use
Chat Completions. The Codex backend is internal, unversioned, and intended for
first-party clients. It works, but using it through 3code is your
responsibility.

Switch accounts with:

```
:provider openai
:provider chatgpt
```

### Command Code

A Command Code plan (GOAT, Pro, Max, or the Provider plan) gives API access
through their provider gateway. Generate a key in Command Code Studio (the
same key authenticates their `cmd` CLI) and add it with `:provider add
commandcode`, or paste the key and pick `commandcode` when asked:

```
:provider add commandcode
```

The open-model lineup (DeepSeek, GLM, Kimi, MiniMax, Grok, MiMo) rides the
gateway's OpenAI-compatible `/provider/v1/chat/completions` endpoint.
Usage is metered against the plan's credits.

## Provider catalog

Everything the wizard knows about, grouped by where inference actually
runs. A `★` marks the providers on the [home page
rotation](https://3code.capocasa.dev), which is the shortlist I recommend.
Rows marked **quantized** serve fp8 or fp4 weights: cheaper per token, but a
long agentic run hits the quality floor sooner than the same model at full
precision, so treat them as bulk workhorse power, not the model you trust
with a hard refactor. Hosting location is where your
prompts run, not where the company is registered; for retention policies see
[Picking a private provider](#picking-a-private-provider). `3code --good`
prints the validated provider/model pairs for whichever of these you
configure.

### Model labs

First-party APIs from the labs that trained the models. Two of the home page
names are subscription logins rather than catalog entries: `chatgpt` is a
ChatGPT Plus/Pro login that rides on `openai`, and `supergrok` is a SuperGrok
or X Premium+ login that rides on `xai`.

| provider | hosting | notes |
| --- | --- | --- |
| ★ zaicode | China (Z.ai, intl endpoint) | GLM coding plan, flat rate, my main setup |
| ★ zai | China (Z.ai, intl endpoint) | GLM pay-as-you-go |
| ★ deepseek | China (intl endpoint) | DeepSeek V4 line |
| ★ kimi / kimicode | China (intl endpoints) | Kimi API and Kimi coding plan subscription |
| moonshot / moonshot-cn | China | same models; `moonshot-cn` is the domestic endpoint |
| minimax / minimax-cn | China | `minimax-cn` is the domestic endpoint |
| qwen / qwen-cn / qwen-us | China (Alibaba) | intl, domestic, and US-hosted DashScope endpoints |
| tencent | China (intl endpoint) | Hunyuan on Tencent MaaS |
| ★ openai | US | API key, or log in as `chatgpt` on a Plus/Pro subscription |
| ★ xai | US | API key, or log in as `supergrok` on SuperGrok/X Premium+ |
| anthropic | US | Claude |
| google | US | Gemini through the OpenAI-compatible surface |
| mistral | France (EU) | Mistral first-party, plus hosted GLM |

### US inference clouds

| provider | hosting | notes |
| --- | --- | --- |
| baseten | US | |
| cerebras | US | wafer-scale serving, fast GLM |
| deepinfra | US | **quantized** (fp8 weights) |
| fireworks | US | zero data retention by default |
| groq | US | fast small models |
| hyperbolic | US | |
| nvidia | US | free credits to start |
| sambanova | US | |
| together | US | no training on API data by default |
| venice | US | privacy-leaning |
| arcee | US | |
| friendli | US | Korean-founded inference cloud |
| perplexity | US | |

### EU providers

Where to point 3code when data must stay under EU jurisdiction.

| provider | hosting | notes |
| --- | --- | --- |
| ★ greenpt | EU | **quantized**; my EU pick anyway |
| nebius | EU (Netherlands) | |
| inceptron | EU (Sweden) | zero data retention, EU residency |
| ovh | France | no training, billing-only retention |
| scaleway | France | |
| hetzner | Germany | free experiment, **quantized** (fp8/fp4 ids) |
| together-eu | EU | Together's EU endpoint |
| ★ platte | Germany | EU sovereign host; url embeds your username, wizard asks for it |
| aki | EU | |
| lyceum | EU | |

### Routers and aggregators

One account, many models. The model you get is the model some upstream
provider served; quantization, price, and policy vary by route, so check the
route before blaming the model.

| provider | hosting | notes |
| --- | --- | --- |
| ★ openrouter | US company, upstreams worldwide | the easy way to try many models |
| novita | Singapore | free tier; often **quantized** |
| nanogpt | varies | crypto payments; often **quantized** |
| opencode / opencodego | gateway | OpenCode Zen (metered) and Go (subscription) gateways |
| huggingface | varies | router to partner clouds |
| cheaperinference | varies | discount aggregator |

The known-good registry also covers a few providers that are not in the
wizard catalog: TensorX (EU, Dublin and Helsinki), poolside, kilo, LongCat,
and Xiaomi MiMo. Add those by hand as custom providers when wanted.

## Interactive use

At the interactive prompt, describe the result you want or enter a command
beginning with `:`. Tab completes commands, provider names, model names, and
paths where supported.

3code loads `3CODE.md` and `AGENTS.md` from the project directory and its
parents. These are good homes for project rules, build commands, and style
requirements. To include a file directly in a prompt, prefix its path with
`@`:

```
Review @src/parser.nim and add tests for malformed input.
```

To run a shell command yourself without sending anything to the model,
prefix it with `:!`:

```
:! cargo test
```

The output appears in your scrollback only; the model never sees it. The
command runs through the same sandbox policy as model-run commands.

Useful input keys:

| key | action |
| --- | --- |
| Enter | submit |
| Shift+Enter or Alt+Enter | insert a newline |
| Up / Down | move through visual rows, then history |
| Ctrl+Arrow | move by word |
| Ctrl+U | clear the input buffer |
| Ctrl+W | delete the previous word |
| Ctrl+L | clear the screen |
| Alt+E | edit the input buffer in $VISUAL/$EDITOR |
| Ctrl+X Ctrl+E | same (emacs edit-and-execute-command) |
| Ctrl+C | clear current input; cancel the turn when it is empty |
| Esc | same as Ctrl+C |
| Ctrl+D | exit |

If you forget one, `:help` prints the current command and key list. The
full command table is in the [reference](reference.html#interactive-commands).

Pasting behaves the way you want: a multi-line paste stays one draft instead
of submitting on the first embedded newline, so you can paste a code block,
edit it, and submit with Enter. `:!` and `@file` prefixes still work inside
a pasted draft.

### Rebinding keys

Keys are commands, and commands are reassignable in the config file
(`~/.config/3code/config`; see [config file in the
reference](reference.html#config-file) for every platform). Add a
`[shortcuts]` section that maps a command name to a space-separated list of
keys:

```
[shortcuts]
cancel = DoubleESC
```

Now a single Esc does nothing and two quick Esc presses cancel the current
turn, handy if you keep brushing Esc by accident. Values are merged onto the
defaults, so a command keeps its built-in keys until you override it. An
empty value unbinds a command entirely:

```
[shortcuts]
suspend =
```

The commands: `cancel`, `clear`, `quit-if-empty`, `home`, `end`, `left`,
`right`, `word-left`, `word-right`, `up`, `down`, `history-previous`,
`history-next`, `backspace`, `delete`, `insert`, `delete-word-left`,
`delete-to-boundary-left`, `clear-screen`, `suspend`, `complete`,
`reverse-complete`, `edit-in-editor`, `insert-newline`.

Key names look like `Ctrl+C`, `Alt+F`, `ShiftTab`, `Home`, `End`, `Up`,
`Down`, `Left`, `Right`, `Backspace`, `Delete`, `Insert`, `Tab`, or `ESC`.
`Ctrl` chords are case-insensitive (`CtrlC` and `ctrl+c` are the same key),
and `Double` requires two quick presses, as in `DoubleESC` or `DoubleCtrlC`.

`:help` always shows the bindings currently in effect.

## The screen

3code is not a TUI. The screen is ordinary terminal history scrolling up
(your terminal's own scrollback, search, and mouse selection all work), plus
a small live footer at the bottom: a thinking ticker row and a token bar
above the prompt. Everything committed below the footer stays in the
scrollback forever and can be re-read or copied like any shell output.

### Scrollback contents

Each conversation event gets a one-character marker or banner icon:

| icon | item |
| --- | --- |
| `❯` | your prompt, echoed as submitted |
| `●` | assistant message, rendered as markdown (headings, code fences, tables fitted to the terminal width) |
| `»` | a harness-autosend: a note 3code itself sent to the model (empty-reply steer, loop nudges), with the exact text shown |
| `$` | bash command with its command line; the icon turns `Ø` when the exit code is nonzero |
| `r` | file read (path and line range) |
| `w` | file write (path; the diff follows) |
| `p` | patch, banner shows the first changed line |
| `▸` | `update_plan` call, rendered as a checklist |
| `⌕` | web search (query) |
| `⇊` | web fetch (URL) |
| `⟳` | context clear, followed by the handoff prompt for the fresh context |
| `✉` | `dmail` (kimi family only): revert context to a checkpoint, keep the files |
| `✕` | error, or a tool 3code does not know |

Tool output below the banner is dimmed to keep the model's prose the
loudest thing on screen. Long output is elided in the middle (`... N lines
omitted :show N for full`); `:show N` prints the whole capture, `:log` lists
every tool call of the session. Diffs are painted green/red, and a long diff
is clipped with a `git diff` hint rather than flooding the screen. Failed
tools mark their banner so a red `Ø`/`✕` scan tells you where a turn went
wrong without reading anything.

Grey `·` rows are 3code's own commentary: the context gauge warning before
auto-summarization, the elapsed time when a turn ends without usage, the
`● resumed` banner after `--resume`. The `»` rows deserve a second look when
something odd happened: they are the interventions described in
[when the model misbehaves](#when-the-model-misbehaves), shown verbatim
instead of hidden, so you can see exactly what was sent on your behalf.

### The token bar

While a turn runs, the footer's bottom row is the token bar:

```
⠋ ◔25%  ↑4.2k  ↻18k  ↓1.1k  00:12
```

| field | meaning |
| --- | --- |
| `⠋` | braille spinner: a request is in flight; during a retry backoff it becomes an hourglass `⧗` while the notice row counts down |
| `◔N%` | context window used; the circle fills (`○ ◔ ◑ ◕ ●`) as the window fills, one glance tells you how close you are to summarization |
| `↑` | fresh input tokens this turn |
| `↻` | cached input tokens: served from the provider's prompt cache, usually a tenth of the price |
| `↓` | output tokens |
| `00:12` | elapsed time for the live turn |

The bar is an instrument panel, not a decoration: watch `↻` dominate `↑`
to confirm the cache is hot (resuming a session re-sends byte-identical
history precisely so it stays that way), watch the filling circle to decide
between `:summarize` now and a clean `:clear` later, and treat a nonzero `Ø`
together with a stuck spinner as your cue to look at the last `»` row. In
[private mode](#private-mode) the whole bar repaints magenta so the mode is
visible from across the room. Its color is configurable
([token-bar in the reference](reference.html#colors)).

### The thinking ticker

The row above the token bar is a one-line ticker. While a reasoning model
thinks, its planning text scrolls through it like a stock ticker, then the
row goes quiet when the answer starts. It is an activity indicator and a
quick-glance channel: enough to see the model is reasoning about the right
files, not a panel to read. Nothing on it enters the transcript or the
session; reasoning text is replayed to the provider only when the model's
family needs it (the `think-back` parameter, see
[params in the reference](reference.html#params)). The same row doubles
as the notice row for retry countdowns and live warnings.

### Receipts and conversation cost

Each response ends with a compact token receipt spliced under the last
scrollback item of the turn:

```
  ○12%  ↑4.2k  ↻18k  ↓1.1k  8s
```

| field | meaning |
| --- | --- |
| `○N%` | context window used at that turn |
| `↑` | fresh input tokens |
| `↻` | cached input tokens |
| `↓` | output tokens |
| `Xs` | elapsed time |

The receipts are a per-turn cost ledger. `↑` and `↻` are what the provider
bills as input (cached usually at a steep discount), `↓` is the output you
waited for, and the percentage tells you how much of the window the turn
consumed. Adding the `↑`, `↻`, and `↓` columns down the scrollback gives
the token cost of the whole conversation, which is usually more interesting
than any single turn: it shows the cache working (a hot session is mostly
`↻`), the moment a task went sideways (a jump in `↑`), and the true price of
those `just one more thing` follow-ups. `:tokens` totals the same columns
for the session so far. If a field is missing, the provider did not report
it. 3code declines to invent accounting.

## Patient retry

Patient retry is enabled by default. On `429` limits, `5xx` responses, and
network failures, 3code backs off exponentially rather than failing
immediately. Delays are capped at 2048 seconds and retries can continue for
about 36 hours, long enough to outwait a rolling limit or a bad connection.

After the short initial retry period, attempts become part of the transcript:

```
Usage limit reached for the past 5 hours. (code 429). retry 42/64 in 2048s
```

Use these commands to inspect or change the setting:

```
:retry
:retry off
:retry on
```

Even with patient retry off, 3code gives transient failures about a minute
before returning to the interactive prompt. The setting is stored as
`patient_retry` in `[settings]` ([settings in the
reference](reference.html#settings)). Press Esc to cancel the wait.
A stream that stalls network-quiet or arrives truncated mid-response is
detected and retried on its own, regardless of the setting.

For a provider whose streaming is the problem rather than its availability,
`:streaming off` switches requests to plain request/response mode: the
reliable fallback when a provider's SSE implementation drops or truncates
responses. The setting is per session, or permanent as `streaming = off`
in `[settings]`.

## When the model misbehaves

Two failure modes are common enough across providers that 3code guards
against them automatically. Both guards are deliberately small: a few
hundred tokens of mechanism for a failure mode that would otherwise burn
millions. Provider API errors along the way surface as formatted messages,
never raw JSON bodies.

### The flailing detector

Sometimes a model gets stuck repeating the same tool call: the same failing
patch, the same unhelpful grep, a loop it cannot think its way out of. Every
repeat burns another round trip and another batch of output tokens while
making no progress. The flailing detector fingerprints each tool call and
watches the recent window for repeats: identical calls back to back,
A-B-A-B cycles, or a long streak of near-identical calls to the same tool.

When it sees one, it intervenes in the model's voice of authority: a tool
result is replaced by a short `SYSTEM` note naming the loop and demanding a
strategy change. Two more escalations follow if needed, the last one
telling the model to stop and report what is blocking it. A fourth flagged
repeat aborts the turn and hands control back to you. Every intervention
appears in the scrollback as a `»` row with the exact text sent, so nothing
happens invisibly. A genuinely new tool call resets the ladder; normal
work never sees it.

### The empty response handler

Some providers occasionally return a reply with no content and no tool
calls: the model spent its budget thinking, or the gateway clipped the
response. 3code refuses to accept that as an answer. Depending on what the
response signaled, it either raises the output budget (the reply was cut
off by `length`) or sends a short steering note demanding a real answer,
then retries. Bare empties are retried up to twelve times with increasing
backoff, and each attempt is visible as a grey or `»` scrollback row
saying why and when the next attempt fires. If the provider stays empty,
the turn ends with a notice instead of a silent nothing, and the scrollback
shows exactly what was tried.

## Private mode

Private mode is incognito mode for the agent: off by default, on for one
session only, never persisted. While it is on, turns only run on providers
you have marked as trusted with your data, and the live token bar repaints
in the private color (magenta by default) so the mode is always visible.
Scrollback receipts keep the normal color, so old receipts also show which
turns ran private.

Turn it on either way:

```
3code -p            # from the start
:private on         # mid-session (turns the bar magenta)
```

A provider or model is *allow-private* when:

1. you set it explicitly with `:private allow`, or in the config:

   ```
   [params]
   provider = "together"
   allow-private = "true"

   [params]
   provider = "zai"
   model = "glm-5.3"
   allow-private = "true"
   ```

   With `model` empty the whole provider is trusted; a model-scoped entry
   beats a provider-wide one, and `allow-private = "false"` revokes.

2. or its known-good entry is curated for a provider whose published policy
   is zero data retention with no training on API data. Curated today:
   `together`, `fireworks`, `ovh`, `novita`. Everything else, including all
   first-party labs, must be allowed explicitly.

Everything else is refused at the gate with a pointer to the fix:

```
zai.glm-5.2 is not allow-private (trust it with :private allow zai, or
switch to a zero-training provider; :private lists)
```

### Picking a private provider

Pick a provider with a zero-training policy you are satisfied with (a strict
zero data retention policy, or at least a no-training plus bounded retention
policy). A shortlist by region:

| region | provider | policy |
| --- | --- | --- |
| EU | [TensorX](https://tensorx.ai) | zero data retention; GPUs in Dublin and Helsinki, Irish/EU jurisdiction (add it as a custom provider, it is not in the catalog) |
| EU | [OVHcloud AI Endpoints](https://www.ovhcloud.com/en/public-cloud/ai-endpoints/) | no training on your data, retention for billing only; hosted in France (catalog: `ovh`) |
| USA | [Together AI](https://together.ai) | no storage of inputs/outputs by default; training is opt-in and off (catalog: `together`) |
| USA | [Fireworks AI](https://fireworks.ai) | zero data retention by default; no logging of prompts or generations (catalog: `fireworks`) |
| Asia | [Novita](https://novita.ai) | zero data retention by default, no training on your content, per their terms of service (catalog: `novita`) |
| Asia | Z.ai pay-as-you-go | routing guides report zero retention on the paid API; read the current DPA before trusting it (catalog: `zai`) |

Or pick any provider you trust, and allow it explicitly. That is a judgment
call, not a recommendation.

### Walkthrough

```
❯ :provider myprovider
❯ :model glm-5.3
❯ :private allow myprovider glm-5.3   # persisted as [params] allow-private
❯ :private on                         # bar turns magenta, turns are gated
```

`:private` with no argument shows the mode, whether the current model is
allowed, and which configured providers are trusted. `:private deny`
removes trust. The bar color is configurable like the other colors
([colors in the reference](reference.html#colors)):

```
[colors]
private-bar = "\x1b[95m"
token-bar = "\x1b[36m"
```

## Reasoning

`:reasoning` lists the levels the current model actually supports and marks the
active one:

```
:reasoning
:reasoning high
:reasoning off
```

The valid values depend on the model:

- binary reasoning models use `off` and `on`
- many models use `low`, `medium`, and `high`
- GLM 5.2 uses `off`, `high`, and `max`
- GLM 5.3 uses `low`, `high`, and `max` (thinking cannot be disabled)
- OpenAI o-series models use `low`, `medium`, and `high`
- GPT-5.0 uses `minimal`, `low`, `medium`, and `high`
- GPT-5.1 and later add `none`
- GPT-5.4 and GPT-5.5 add `xhigh`
- GPT-5.6 adds `max` and does not use `minimal`
- GPT-6 Astra uses `low`, `medium`, `high`, `xhigh`, and `max`; thinking cannot be disabled
- GPT-5.5 Pro uses `medium`, `high`, and `xhigh`; GPT-5 Pro uses `high`
- GPT-4.x has no reasoning setting

3code sends the right provider-specific field for the selected model.
Providers have not settled on one common reasoning scale.

When a provider streams reasoning text, 3code keeps it moving through a
one-line ticker above the interactive prompt. It is not added to the
transcript.

## Web research

The model has two web tools: `web_search` (titles, URLs, snippets) and
`web_fetch` (a URL rendered to readable text, boilerplate stripped). Ask
for research in plain language and the tools load; the system prompt's web
skill is only injected when the task needs it, so ordinary coding turns do
not pay for it.

The search backend is configurable: Exa (default, runs keyless), Parallel
(keyless), and Brave (needs a free API key). Pick one in the config:

```
[search]
engine = "brave"
brave-key = "..."
```

There is no automatic failover between engines; the chosen one is used as
is. See [search in the reference](reference.html#search) for all keys.

## Known-good models

Provider APIs differ in small, consequential ways. 3code therefore keeps a
registry of combinations tested with the right prompt, reasoning settings,
token fields, and context size.

Print the current registry with:

```
3code --good
```

For combinations outside the registry, `--experimental` opens the gate.

## Sessions

List the 20 most recent sessions for the current directory:

```
3code --list
# or
3code -l
```

Resume the latest session:

```
3code --resume
```

Resume a session by ID:

```
3code --resume=abc123
# or
3code -r:abc123
```

Sessions are listed per working directory, so unrelated projects stay out of
each other's history. Provider prompt caches may expire before a saved session
does. The session will still resume, but its old context may no longer get the
cache discount.

A resumed session replays the full prior conversation into your scrollback
(the same `❯`/`●`/tool banners, receipts included) so you land back in
context, and the history is re-sent byte-identically to the provider, which
keeps the prompt cache hot: a resume usually costs cached-input prices on
everything before your new prompt.

Session files are ordinary JSON under 3code's data directory and are
created readable only by your user (mode 0600 on POSIX). Also note that
3code refuses to run as root: it executes the shell commands the model
proposes, and root blast radius is unacceptable. Run it as your normal
user (`THREECODE_ALLOW_ROOT=1` overrides, for containers).

## Notifications and auto-update

When a turn ends, 3code can fire a desktop notification, useful when you
switched to a browser while a long turn grinds. It is on by default where
supported; toggle it with `:notify on|off` or the `notify` setting. On
Termux there is no notification service, so the setting does nothing.

Prebuilt binaries self-update in the background: a detached worker checks
GitHub releases at most every four hours, downloads the matching tarball,
and atomically swaps the binary for the next launch. One dim line on the
first launch after a swap is the whole visible footprint. Source builds do
not self-update by default (what you built should not quietly replace
itself); the `auto_update` setting overrides the default either way. Both
settings are covered in [settings in the reference](reference.html#settings).

## Context management

`:clear` starts a new conversation with the same provider and model:

```
:clear
```

`:summarize` replaces older turns with a generated recap. It is useful when the
task must continue but the context has become expensive:

```
:summarize
```

If the old work is no longer relevant, clear it. A fresh context is safer than
a summary of things the model no longer needs.

## Chunked mode

For a large mechanical task, ask the model to split the work into files. Each
chunk ends by calling the `clear` tool with instructions for the next one. The
model carries the plan forward and leaves the spent context behind.

Example:

```
Divide this task into 4-6 chunks in impl-N.md files.
End each file by calling clear with instructions to read the next file.
Then execute chunk 1.

Task: add test coverage to the parser module.
```

Chunked mode works best when little human input is needed, such as adding basic
tests across many modules. If the model forgets to load the next chunk, the
task was probably too difficult or the plan too vague.

## Skills

A skill is a markdown file with instructions for a class of task: how to
run a systematic debug, how to write release notes, how to behave as a
thinking partner. Skills are cheap by construction: the system prompt
carries only the file list (one bullet per skill), and the model reads a
skill file with the normal `read` tool only when the task calls for it.
Nothing is preloaded, so a skill you never use costs nothing.

Skill files are found in these directories, first match wins on a name
collision:

1. `.3code/skills/` in the project
2. `.agents/skills/` in the project (the vendor-neutral name)
3. `~/.config/3code/skills/` (your overrides)
4. `~/.local/share/3code/skills/` (built-ins, extracted by 3code itself)

The built-ins shipped today are the role skills (conversational, sysadmin,
thinking partner, writing), task-debug-systematic, and cybernetic-plan.
To override one, put a file with the same name in a directory higher up
the list. To add your own, drop a `.md` file in any of those directories
with an instructive name: the filename is the trigger, so
`release-notes.md` loads when the task smells like release notes.
There is deliberately no MCP-style plugin protocol: a skill file plus
command-line tools covers the same ground at a fraction of the context
cost.

## Cybernetic mode

Cybernetic mode is the sturdier option for a long coding task. Give the model a
worktree and ask it to use the built-in cybernetic planning skill.

The skill:

1. writes a plan file with concrete tasks
2. implements one task
3. updates the plan with results and new information
4. clears context and tells the next session to load the plan
5. repeats until all tasks are complete
6. reviews the completed work

The current task keeps its detailed context while the plan file keeps the
durable state. This loses less information than repeatedly summarizing all the
old work.

## No sub-agents

3code does not provide sub-agents. They use plenty of tokens, and I have not
seen enough benefit to justify the little management consultancy they form.
For parallel or long-running work, use worktrees with cybernetic mode.

## Sandbox

The model is useful, but it does not need the run of your entire computer.
3code applies a filesystem policy to every tool call. Bash commands also enter
an OS sandbox, and host rules can fence their network access.

The sandbox is questionless: it never interrupts the turn to ask whether a
command may run. That is a deliberate trade. An agent that asks is an agent
that costs a round trip and a context refresh every time it touches a new
directory, which in practice means either an agent that nags or an agent
whose guardrails get switched off. Instead the boundary is enforced by the
kernel (Landlock, Seatbelt, Windows restricted tokens), decided by a policy
you wrote before the turn started, and a denial is simply a failed command
the model can read and route around. The tradeoff is that the policy needs
setting up first: a couple of minutes once per project, and after that it
does not stop on trivialities.

In practice:

- The project directory is writable out of the box (`allow ./` is in the
  built-in default), plus the temp directories. A fresh clone needs no
  setup at all.
- Other directories need a rule. When a task will wander (a monorepo
  sibling, `~/go`, the directory where you keep checkouts), consider adding
  them broadly (`:sandbox allow ~/src`) rather than playing whack-a-mole
  one path at a time; the model reads the policy and works within it
  without asking.
- Keep backups of what the sandbox protects. The fence is there so a
  confused model cannot rewrite `~/.ssh` or dotfiles; it is not a substitute
  for version control, and `git` inside a writable project remains your
  real undo.
- Use `deny` for sensitive data you know the model should never see or
  send: `deny ./secrets`, `deny ~/.ssh`, credentials directories. Denial is
  cheap, silent, and total (read, write, and network), so err on the side
  of denying.

Exactly one policy source is active:

1. `.sandbox` in the project directory, if it exists
2. `~/.config/3code/sandbox`, if you created it
3. the built-in default, held in memory

Policies do not cascade or merge. One file wins, so what is allowed remains
inspectable. A project file replaces the user file. 3code never creates the
user file; create it yourself to set defaults for projects without `.sandbox`.

The first `:sandbox allow`, `:sandbox readonly`, `:sandbox deny`, or
`:sandbox edit` command in a project copies the effective policy to `.sandbox`
before changing it. You get a complete project policy, not a mysterious patch
on top of another file.

### Policy format

A policy has one rule per line:

==============  ==============================================
Word            Meaning
==============  ==============================================
``deny``        no read, write, or network connection
``readonly``    read and execute, for paths only
``allow``       read and write a path, or connect to a host
==============  ==============================================

The target type is determined by its first character:

==============  ==============================================
Start           Target
==============  ==============================================
``/``           absolute path
``X:``          Windows drive path
``~``           path under the home directory
``.``           path relative to the project directory
letter/digit    hostname or IP address, with an optional port
==============  ==============================================

Paths are intentionally explicit. Use `./foo` for a project-relative path. An
access word on its own means the project directory itself:

```
deny /
allow
readonly /var
deny ./secrets
```

Rules are read from top to bottom and the last matching path rule wins. In this
example the project is writable, `/var` is read-only, and `./secrets` is denied.
Everything else is denied because unmatched paths are denied by default.

Blank lines and lines beginning with `#` are ignored. An access word only has
special meaning when followed by whitespace or the end of the line, so a host
such as `deny.example.com` remains a hostname.

### Built-in default

On macOS, Linux, and other POSIX systems, the built-in policy is:

```
deny /
allow /tmp
allow /var/tmp
allow ./
allow *
```

This lets the model write in the project and temporary directories, not wander
through other user files. System programs, libraries, configuration, and device
files get a read-only baseline so commands can still run. `allow *` leaves the
network open.

On Windows, the built-in policy is:

```
deny /
allow ~/AppData/Local/Temp
allow ./
```

Windows grants network capability when no host rules are present.

When no policy file exists, the built-in default is materialized into a
per-run temporary file for the Bash sandbox; nothing is written into the
project or the config directory. The default grants the project directory
itself (`allow ./`), so a fresh project is writable out of the box.

### Network rules

With no host rules, every host is allowed. `allow *` says the same thing
explicitly. To close the network completely, use:

```
deny *
```

Host targets may be domains or IP addresses. A single `allow` rule turns the
policy into an allowlist: that host works and all others do not.

```
allow api.example.com
```

A single `deny` rule does the inverse: that host is blocked and the rest of the
network stays open.

```
deny telemetry.example.com
```

IP addresses work the same way, for example `allow 192.0.2.10` or
`deny 192.0.2.10`. The spelling matters: bare `foo` is a hostname, while
`./foo` is a file or directory named `foo` in the working directory.

A host without a port matches every port. Add one when it matters, as in
`allow github.com:443`. Wildcards work too: `allow *.example.org` allows that
domain pattern.

As with paths, the last matching rule wins. Any `allow` host rule makes
unmatched hosts denied. With only `deny` host rules, unmatched hosts remain
allowed. This is the small detail that decides whether you have made an
allowlist or a blocklist.

On Linux and macOS, fenced commands reach the network through a local CONNECT
and SOCKS5 allowlist proxy. Linux puts the command in a network namespace;
macOS confines it to loopback with Seatbelt. 3code sets the standard proxy
variables and a Git SSH proxy command for the child process. Denied HTTP
connections return 403.

On Windows, host rules require one admin setup command:

```
3code setup
```

It asks for admin rights through the UAC prompt when run unelevated from a
console or RDP session; over ssh (no screen for the prompt) it says so and
exits - run it from an account with admin instead.

Without that setup, 3code warns and runs the command without a network fence.
That is safer than pretending the fence exists. Set `sandbox_wall_warn = off`
in `[settings]` if you no longer need the warning. `3code unsetup` removes the
firewall filters; it is safe to run repeatedly.

### Editing the policy

Use an editor or the sandbox commands:

```
:sandbox
:sandbox show
:sandbox edit
:sandbox allow /opt
:sandbox readonly /var
:sandbox deny ./secrets
:sandbox on
:sandbox off
```

`:sandbox edit` tries `$VISUAL`, then `$EDITOR`, then the platform default.
Changes take effect when the editor exits. Rule commands store project paths in
portable `./foo` form and reload immediately.

`:sandbox off` disables filesystem and network enforcement for the session.
The setting is stored as `sandbox = off` in `[settings]`. Use `:sandbox on` to
restore enforcement. The one-shot equivalent is the `--no-sandbox` flag, and
`3code sandbox --policy FILE restrict -- CMD` runs a single command under a
policy without starting the REPL.

To allow the full filesystem, replace the policy with `allow /`. Without host
rules, the network is unrestricted too. This is yolo mode. 3code makes you ask
for it explicitly and will not have the bright idea on its own.

### Policy file protection

A policy is not much use if the model can edit it. The file tools therefore
cannot change `.sandbox` or `~/.config/3code/sandbox`. After loading the policy,
3code adds hidden read-only guards for both files. They do not appear in
`:sandbox show`, and later rules cannot override them.

macOS and Windows enforce these guards for Bash and in-process tools. Landlock
cannot subtract a read-only file from an already writable root. On Linux, the
in-process tools still enforce the guard, but a Bash command under `allow /`
can write the policy file. Avoid `allow /` if policy-file protection matters.

A denied Bash command usually reports `Permission denied`. 3code includes the
active policy path in denial messages, saving you from debugging the wrong
layer.

### What is sandboxed

The read, write, and patch tools check paths inside 3code itself. Bash needs a
stronger boundary, so commands are re-executed through:

```
3code sandbox --policy FILE restrict -- COMMAND
```

`3code sb` is the short alias. The command and all its children inherit the OS
restriction. The sandbox process reads the policy afresh, so an edit applies to
the next Bash launch.

### Platform behavior and fallback

The Bash backend uses Landlock on Linux, Seatbelt on macOS, and restricted
tokens plus ACLs on Windows. 3code probes it at startup rather than assuming it
works. Old Linux kernels and containers whose seccomp policy blocks Landlock
can fail the probe.

If the OS backend is unavailable, Bash runs without filesystem confinement.
The in-process read, write, and patch checks remain active. This keeps 3code
usable, but the distinction matters: an arbitrary Bash command is then outside
the filesystem fence.

## Colors

3code detects whether your terminal has a dark or light background by
querying it directly (OSC 11) and picks the matching palette, so a light
theme just works without configuration. Terminals that do not answer are
assumed dark. To pin a palette regardless of the terminal:

```
[settings]
tone = "light"
```

The white family (prompt text, help, banners) adapts between tones; the
functional colors (cyan receipts, green/red diffs, magenta private bar) are
the same in both. Every white-family color plus the two bar colors can be
overridden with quoted ANSI escapes under `[colors]`; see
[colors in the reference](reference.html#colors).

## Design decisions

Why 3code looks and behaves the way it does. The through-line is economy:
the least tokens, the least computer time, the least of your attention.

### No TUI

3code renders plain scrolling text, not a full-screen terminal interface.
Committing to the shell/REPL paradigm buys a lot for free: your terminal's
own scrollback, search, copy-paste, and font rendering keep working; the
transcript is history in the literal sense, so yesterday's session is
`3code -r` and a scroll up; logging and terminal multiplexers capture it
unchanged. A TUI owns the screen, reimplements all of that worse, and adds
a rendering surface that can itself be buggy (every terminal-rendering bug
3code ever had lived in the footer, never in the history). The live
surface is deliberately two rows.

### Kernel enforcement, no questions

The sandbox asks nothing and enforces at the kernel (Landlock, Seatbelt,
Windows restricted tokens). The alternative architectures were worse. A
judge model re-reading every command is unacceptable: it burns tokens on
guesswork, adds latency to every tool call, and is security by vibes, a
second model approving what the first one wrote. Approval prompts are
security by interruption, and in practice train users to mash yes. A
static kernel policy uses zero tokens, adds microseconds, and fails
closed; the cost is the one-time setup described in
[the sandbox section](#sandbox). And the honest calibration: most coding
agent sessions run effectively unfenced anyway (yolo mode, `--dangerously-
skip-permissions` and friends), so a fence that is cheap to set up and
never interrupts is a real improvement over both the nagging gate and the
absent one, even before it stops anything.

### One model, small tool set

No sub-agents, no trees of delegated prompts. A single conversation with
bash, file tools, plan, and web access, plus skills loaded on demand, keeps
the token budget on the work instead of on orchestration. When a task
outgrows one context, chunked and cybernetic modes split it along files and
worktrees instead of spawning agents.

## Library API

A Nim program can embed the same agent loop without bringing along the terminal
interface:

```nim
import threecode

let session = initAgentSession(
  AgentOptions(model: "deepinfra.deepseek-v3.2"))

# blocking: run a full turn (model calls + tool calls) and get the reply
let reply = session.prompt("what does this project do?")

# streaming: same call, events as they happen
session.onEvent = proc(event: AgentEvent) =
  case event.kind
  of aevDelta: stdout.write event.text        # assistant text chunks
  of aevRetry, aevTool: stderr.writeLine event.text  # tool results, notices
  of aevDone: echo event.usage                # per-call token usage
  else: discard
discard session.prompt("Run the tests and fix the failure.")

# colon commands work too
echo session.command(":tokens")
session.close()
```

`AgentOptions` mirrors the CLI flags: `model`, `cwd`, `resume`/`resumeId`,
`sessionPath`, `experimental`, `debug`. `prompt` blocks until the model
finishes calling tools and returns its reply. Meanwhile, `onEvent` receives
text, reasoning, tool output, retry notices, and usage. `promptAsync` puts the
turn on a library-managed thread and reports failures with `aevError`;
`interrupt` cancels it. Sessions use the same provider config, filesystem
policy, locks, and saved format as the CLI.

Only one `AgentSession` may be active in a process, and calls on it are not
thread-safe. In an asynchronous server, keep the session on one worker thread
and pass prompts and events through queues. This avoids sharing session state
across threads.

`example/webserve.nim` is the complete example: a web frontend that serves a
chat page, keeps the session on a worker thread, and streams replies to the
browser over server-sent events. `nim c -r example/webserve.nim` and open
http://localhost:8501.

## Build from source

```
nimble install https://github.com/capocasa/3code
```

Requires [Nim](https://nim-lang.org) >= 2.0 and `curl` on `PATH`.

## Contributing

Patches welcome at [github.com/capocasa/3code](https://github.com/capocasa/3code).

- **Known-good provider/model pairs** with test results
- **Bug fixes** with a clear reproduction case

Bug reports welcome, but make sure you give enough specific information to
reproduce the issue. Terminal rendering bugs need a visual PTY test that shows
the bad frame before the fix. A test that cannot show the bug has not
reproduced it yet.

Developer API documentation is generated at `docs/dev/threecode.html`:

```
nimble devdocs
```

## Prior art

3code is influenced by Claude Code, Goose, Pi, and Codex. It chooses different
tradeoffs, but the family resemblance is intentional. As a European, using
Claude Code can feel like driving a turbocharged Ford F-150 to buy a pack of
gum. It is still a fine truck.

3code omits features that do not help it write software reliably with fewer
resources. Economy is the feature, not a billing surprise.
