# Changelog

**Unreleased**

- **JSON error bodies never surface verbatim.** Providers answering
  with FastAPI-style `{"detail":"..."}` bodies (NVIDIA NIM and friends)
  showed the raw JSON as the error message. `extractErrorMsg` now knows
  the `detail` convention, and any other unrecognized JSON object yields
  its longest string leaf (ids, codes and urls are short; the human
  sentence is the longest field) instead of dumping the body. OpenAI/
  Anthropic `error.message` and Gemini flat `message` keep working, and
  non-JSON bodies still pass through untouched.

- **Windows: sandboxed bash tool calls no longer hold forever.** Every
  bash tool call (`:! CMD` and model `bash` calls) on a set-up sandbox
  wedged without output, timeout, or ESC cancel. Two stacked defects:
  the CPLW wrapper handed `quoteCmdLine`-escaped text to `cmd.exe`,
  whose parser does not honor `\"` escapes - the inner redirects leaked
  out as cmd operators, cmd died resolving the bash script's POSIX path
  as a network path before ever opening the output pipe, and the
  parent's pipe pump parked in `ConnectNamedPipe` forever; `endRun`
  then joined the parked pump and never returned. The command now
  travels via the environment and runs through `cmd /v:on /c
  !NIMBOX_CMD!` (expansion happens after operator parsing, so the text
  reaches the child byte-for-byte); the pump reap is bounded and never
  joins a pump that never connected; and the in-process sandbox path
  arms the same cancel/timeout watchers as the plain path (ESC kills
  the job tree, the 120s cap returns exit 124). Requires the sandwall
  develop checkout (same fix landed there).

- **The caret parks at the right margin instead of wrapping to the next
  row.** When the drawn caret cell landed exactly on the last column
  (content that fills the row exactly, or trailing spaces typed up to
  the margin), the reverse-video cell wrapped onto the next physical
  row: the caret appeared one row below the prompt at column 0, and the
  editor block later settled one row low with a stray blank row above
  the prompt. The caret now parks on the row's last painted cell, the
  same place a physical cursor parks in deferred wrap.

- **A patch edit with an empty search string is rejected instead of
  prepending to the file.** Streamed tool-call arguments occasionally
  arrive with a lost `search` or `replace` value. An empty `replace`
  deletes the searched span (visible in the returned diff); but an
  empty `search` hit `strutils.find("") == 0` and silently PREPENDED
  the replace text at the top of the target file, corrupting it. Both
  the `patch` tool and `apply_patch` update hunks now hard-error with
  the offending edit index and touch nothing. Same guard, V4A path.

- **The caret advances over typed spaces again.** The drawn caret is
  painted after the row's last non-space cell, so trailing spaces the
  user just typed (never painted as content) left the caret frozen in
  place until the next non-space character. The caret cell now steps
  over the invisible break-spaces, one column per space, matching where
  the physical cursor sat before the drawn-caret switch.

- **The caret no longer flickers.** The caret at the prompt is now a
  drawn reverse-video cell inside the editor rows; the physical terminal
  cursor stays hidden for the whole session (shown only at exit, Ctrl-Z
  suspend, and external-editor handoff). Previously every repaint hid and
  re-showed the real cursor: once per keystroke, and every 80ms GUI tick
  while a turn ran, which read as continuous flicker on Windows Terminal.
  Repaints now emit bytes only when content actually changed.

- **Termux hardened_malloc aborts greatly reduced (again).** The Sep 2
  frame-model ORC fix (d3dc825) was partially reverted three hours later
  by the gui-join deadlock fix (700fb41): `getFrameModel` again handed
  reader threads a copy whose destroy fires outside `frameModelLock`,
  racing the controller's `setAnim*` writes; the input thread's editor
  redraws read `fatPromptState` fully unlocked; and the draft flusher
  again snapshotted the editor's `line.text` under `inputStateLock`
  while the input thread mutates it under the terminal write lock.
  Android's hardened_malloc detects the resulting refcount corruption
  as "write after free" (glibc tolerates it, so Linux/macOS never
  crashed). `getFrameModel` now returns a payload-fresh copy (every
  string/seq byte-copied under the lock), so reader threads never
  touch a refcount cell the controller owns, not even at destroy, and
  the lock is still never held across a render (the gui-join deadlock
  stays fixed). The amIdle frame read is serialized with
  `emitFatPromptEvent`, the draft snapshot copies under the terminal
  write lock, and the wizard handshake copies got the same treatment.

- **Retry waits show an hourglass, not the braille spinner.** The
  braille glyph in the token bar is now strictly the in-flight-request
  indicator. During a retry backoff (a wait between requests) the bar
  swaps it for the hourglass `⧗` while the magenta notice row above
  counts down; when the next attempt connects the notice clears, the
  row returns to the empty spacer, and the braille returns. The
  count-up turn timer is unchanged: it measures the whole turn, which
  can span many requests.

- **Long sessions no longer leak memory (issue #35).** Three leaks
  compounded into the ever-growing RSS (52 GB in the wild once).
  Every `newHttpClient` call built a fresh OpenSSL context whose
  `SSL_CTX` and parsed CA trust store (~0.8 MB) never freed, because
  `SslContext` has no destructor in std/net; the summarizer did this
  every compaction, `streamhttp` on every TLS connection. Contexts are
  now cached per process (streamhttp 0.4.6). The threaded streaming
  worker now frees its own strings on its own thread (string ownership
  never crosses threads: ORC leaks a block freed off its allocating
  thread, nim-lang/Nim#23361) and collects its heap before exiting,
  which stops cycle-registered connection refs from stranding entries
  in the global cycle table. 3000-turn repro: RSS pinned at 15.9 MB
  from turn 310 on (was +35 kB/turn forever). Regression test in
  `tests/api/test_memory_leak.nim` fails on master at ~111 kB/turn.
  Note: builds need Nim 2.2.12 or newer. 2.2.10's TLSF leaked per
  worker thread at 1.3 MB/turn (nim-lang/Nim#20542, fixed upstream).

- **GLM-5.2 on Mistral.** api.mistral.ai now hosts third-party
  `zai-glm-5-2` (1M context): known-good as `mistral.zai-glm-5-2`, on the
  platform's top-level `reasoning_effort` ladder (none/minimal/low/medium/
  high/xhigh/max, live-verified; `off` maps to `none`, the z.ai `thinking`
  object is extra_forbidden, and `reasoning_content` on replayed assistant
  messages 422s, hence tbNone). Mistral's chunked thinking — `delta.content`
  as an array of thinking/text chunks while reasoning, same shape in
  non-streaming `message.content` — now folds into the regular
  content/reasoning paths, so first-party `mistral-medium-3-5` benefits
  too.

**0.7.1** - private mode, per-model params, cache-hot resume, DeepSeek V4.1 Flash, GPT-6 Astra

- **Windows sandbox works when setup ran as another account.** Two bugs
  blocked issue #33 ("Windows sandbox is not set up"). The sandwall
  credential lived per-user under the elevated setup account's
  `%LOCALAPPDATA%`, so when a standard user elevated with a separate
  admin's credentials the real user could not decrypt it and every run
  reported the sandbox as unset up; it now lives in a machine-wide store
  (`%ProgramData%\sandwall`) under machine-scope DPAPI. And the sandwall
  account is spawned from the user's own MSYS tree, which the setup-time
  grant never touched (it used the setup account's `%LOCALAPPDATA%`); the
  bash tool now stamps read+execute on it at run time, in the invoking
  user's context. Both fixes land in sandwall 0.5.6.

- **Windows: run from a release folder with Git for Windows' bash.** 3code
  no longer needs the installer's bundled MSYS2 to find a shell. When the
  bundle is absent, `resolveBash()` falls back to a Git for Windows install:
  the `SOFTWARE\GitForWindows` `InstallPath` registry value, then
  `%ProgramFiles%\Git`, `%ProgramW6432%\Git`, `%ProgramFiles(x86)%\Git`, and
  `%LOCALAPPDATA%\Programs\Git`, preferring `bin\bash.exe` (its launcher
  sets `MSYSTEM` and a PATH carrying the unix tools and `git.exe`) over the
  bare `usr\bin\bash.exe`. So `winget install Git.Git`, unpack a release zip,
  run `3code.exe`. Fixes #34, where Git Bash was on the box but 3code still
  reported "bash not found".

- **Esc now clears the draft instead of cancelling the turn.** Esc and
  Ctrl-C behave identically: with a non-empty prompt they clear it
  (adding the discarded line to history) and leave the running turn
  alone; only an empty prompt cancels. Previously Esc always
  interrupted the in-flight turn, so a stray Esc discarded the typed
  follow-up and killed the turn.

- **Hy4 and Mistral added to the known-good registry.** Tencent Hy4
  preview (770B total / 49B active MoE, Apache 2.0, 1M context) lands on
  `openrouter` (`tencent/hy4-preview`) and the new first-party `tencent`
  TokenHub route (`hy4-preview`). Its chat template accepts exactly
  `high` (default) and `no_think`, so the hy family's reasoning knob
  narrows to two levels on v4. Mistral joins as a family with Mistral
  Large 3 (675B total / 41B active MoE, Apache 2.0, no reasoning knob)
  and Mistral Medium 3.5 (128B dense, Modified MIT, `reasoning_effort`
  none/high), on `api.mistral.ai` and OpenRouter `mistralai/*`.

- **DeepSeek V4.1 Flash everywhere it is served.** Added to the
  known-good registry on all five providers carrying it: `deepseek`
  (first-party, canonical id `deepseek-flash`; the old `v4-flash` /
  `v4-flash-vision-exp` ids route to it now and `v4-pro` follows on
  Sep 14), `deepinfra` (fp8), `novita`, `openrouter`, and `nanogpt`.
  552B causal-encoder-decoder architecture with native vision, 1M
  context, 384K max output, reasoning on by default. Verified against
  the live APIs: first-party takes `thinking.type` + `reasoning_effort`
  low/high/max (integers 400, `none` does not disable thinking), hosted
  stacks honor `reasoning_effort: none` as a true no-think; the
  existing tier mapping needed no changes. `:model deepseek4.1-flash`
  after adding the id to the provider's `models` line.

- **Typing no longer flickers the turn clock to 0s.** Every keystroke
  repaints the live token bar through the editor's diff painter, which
  rebuilt the frame from a model field the animation thread never
  updates, so for one frame per keystroke the elapsed counter showed
  `0s` (or, during tool bar ticks, lost its `Ns` suffix entirely) until
  the next 80ms animation frame restored the real clock. The bar-tick
  label and its elapsed counter are now derived from the last frame the
  animation thread actually painted, so a keystroke frame can never
  show a clock the screen never had.

- **Private mode.** `-p`/`--private` or `:private on` (default off,
  session-only, like a browser's private window). While on, turns only
  run on allow-private providers/models and the live token bar repaints
  magenta (`[colors] private-bar`, configurable like every other color;
  scrollback receipts stay cyan so old receipts mark which turns ran
  private). Trust is a `[params] allow-private = "true"` setting
  (provider-wide or per model, `:private allow <provider> [model]`
  writes it), or a curated known-good flag for providers whose published
  policy is zero data retention / no training on API data: together,
  fireworks, ovh, novita. Shortlist and walkthrough in the manual.

- **`[params]`: per-(provider, model) parameter overrides.** A new
  config section overrides any known-good model parameter:
  `temperature`, `max-tokens`, `think-back` (`none`/`turn`/`all`, how
  much of the assistant's own reasoning is replayed in the request
  history), and `context-window`. Each section names a `provider` and
  optionally a `model`; with `model` empty it covers every model of
  that provider, and a model-scoped entry beats a provider-wide one.
  Unset keys keep the curated value, so a section with only
  `think_back = "none"` silences reasoning replay for a strict
  provider without touching anything else. Off-table (experimental)
  models can now get these parameters sent at all. Hyphen and
  underscore spellings both work, values are schema-checked at load,
  and an explicit `temperature` overrides even the kimicode /
  Gemini 3 "omit temperature" endpoint quirks.

- **Retry notices no longer stack in scrollback.** A network-quiet or
  rate-limit notice is printed once on a live notice row above the token
  bar and dynamically replaced while the countdown ticks and later
  attempts fail, instead of appending one magenta line per retry. The
  countdown lives inside the notice; the token bar keeps token
  information and its count-up turn timer, now in `hh:mm:ss` form
  instead of bare seconds. On retry exhaustion the final error still
  commits through the ordinary path.

- **Resume re-sends byte-identical history.** `-r` used to rebuild the
  system prompt from the profile (busting the provider's prompt cache the
  moment you reopened 3code) and to round-trip message bodies through a
  lossy text codec: tool results lost their trailing newline and tool
  calls were re-serialized from a human-readable summary. The `.3log`
  format now persists the system prompt verbatim (stamped with the
  profile identity and skills digest that built it, so a real model
  switch still rebuilds), stores every tool call's original wire JSON in
  a `-- wire --` section, closes newline-ended bodies with a `~~`
  terminator, and splits user preambles on the exact grammar the live
  path emits. A resumed turn hits the cache exactly like the live
  session's next turn would; an end-to-end test asserts live and resumed
  continuations produce identical request bytes.

- **GPT-6 Astra.** `gpt-6-astra` is known-good for both the `openai`
  (API key) and `chatgpt` (Plus/Pro subscription) providers: 1.05M-token
  context, 128k architectural output cap, and a reasoning ladder of
  `low`/`medium`/`high`/`xhigh`/`max` (no `none`: Astra always thinks).
  `chatgpt` continues to route through the Codex backend with the same
  subscription login.

**0.7.0** - key rebinding, editor integration, smarter stuck-loop guard

- **`[shortcuts]` key rebinding.** Every key is a named command, and every
  command can be reassigned in the config file (`cancel = DoubleESC`, or an
  empty value to unbind). See the manual for the full command list.
- **Editor and shell integration.** `Alt+E` (or `Ctrl+X Ctrl+E`) edits the
  input buffer in `$VISUAL`/`$EDITOR`; `:! <cmd>` runs a shell command
  yourself, output lands in your scrollback only, the model never sees it.
- **Stuck-turn recovery ("flail").** When the model spins without progress,
  3code nudges it back to work twice before aborting the turn, and a
  windowed no-progress guard catches doom loops of ever-new commands.
  Healthy repeated builds no longer trigger it.
- **Faster, steadier rendering.** Identical frames are skipped, editor
  keystrokes are diff-painted instead of erase-repainting the block, and
  ghostty no longer loses a row on submit (DEC 2026 sync output off).
  Fixed: missing blank row after first submit, over-erased scrollback on
  live-content commit, multiline up/down eating scrollback, stacked curl
  progress meters in the tool viewport.
- **Kimi K3 and GLM efficiency.** Kimi gets first-party reasoning knobs
  (K3 `effort`, K2.x `thinking.type`) and a prompt rewrite that favors
  action over offers to continue. GLM-5.3 gains an effort ladder for
  length-starved turns and a 32k read cap.
- **OpenCode Zen/Go.** Every model request now carries
  `User-Agent: 3code/<version>` (previously none at all — Zen asked) and,
  on the `opencode`/`opencodego` gateways, `x-opencode-session` with the
  conversation's `.3log` id. The gateway routes/shards by that header and
  rejects headerless requests from 2026-09-06. The id is stable across a
  conversation's turns (token-cache affinity) and rotates with `:clear`,
  which starts a new conversation.
- **Catalog.** Qwen 3.5–3.8 lineup including small models, first-party
  DashScope, Omen-alpha on opencodego, and new providers Aki, GreenPT,
  Lyceum with known-good model lists. Model ids are normalized everywhere
  (input, config, wizard), so a listed-but-unserved variant quietly maps
  to the known-good wire id.
- **Resume.** Replays render through the shared transcript formatters, and
  web_search/web_fetch calls round-trip their queries.
- **Termux.** Release tarball with autoupdate and a one-liner install.
- **Notifications.** Transcript visibility rules strip checkpoint markers
  and skip empty replies.

**0.6.3** - Catalog sweep

- **Catalog.** GLM-5.3 / GLM-5.3-Flash, Qwen 3.8 and DeepSeek V4 known-good
  on 15 more providers (Baseten, Nebius, Together, DeepInfra, Novita,
  Tensorx, NanoGPT, Venice, Hetzner, Aki and friends).

**0.6.2** - GLM-5.3-Flash

- **Catalog.** GLM-5.3-Flash on `zai` and `zaicode`, same forced-thinking
  contract as GLM-5.3 (`low`/`high`/`max`). GLM-5.3 itself is now also
  known-good on the regular z.ai API, not just the coding endpoint.

**0.6.1** - --no-sandbox, paste-aware input, catalog refresh

- **`--no-sandbox`.** Disable kernel sandbox enforcement so bash runs
  unconfined. In-process read/write/patch checks still follow the policy
  unless you also turn the sandbox off live.
- **Pasted newlines.** A multi-line paste is kept as one draft instead of
  treating each line as a submit.
- **Provider wizard.** Experimental mode lists the full `/models` output;
  regular mode still offers only known-good ids.
- **Catalog.** 0xalpha stealth preview and current free tiers. Nemotron
  was catalogued then dropped from known-good.
- **Terminal.** Late OSC 11 replies no longer paint as a ghost prompt.
  Windows drains leftover startup keystrokes so a boot-time Up cannot
  recall history. macOS builds `openpty` from `util.h`.

**0.6.0** - filesystem sandbox, subscription logins, network wall

- **Filesystem sandbox.** Every tool call is confined by a one-rule-per-line
  policy: `deny`, `readonly`, `allow`. Exactly one policy is active: project
  `.sandbox`, else `~/.config/3code/sandbox`, else a built-in default that
  denies everything except temp dirs and the project itself (spelled
  `allow ./`), so a fresh project is writable out of the box and 3code never
  writes a policy into your project or config dir on its own. Bash runs under
  kernel enforcement via `3code sandbox` (Landlock on Linux, Seatbelt on
  macOS, restricted-token ACLs on Windows); the read/write/patch tools check
  the same policy in-process. A host without a working kernel backend
  degrades to unconfined bash with the in-process checks still on.
  `:sandbox show|on|off|allow|readonly|deny` inspect, change, and reload the
  policy live; `:sandbox edit` opens it in `$VISUAL`. Both policy files are
  hidden read-only to the model.
- **Network wall.** Host rules in the policy restrict Bash network access
  through a built-in allowlist proxy: Linux uses a network namespace, macOS
  confines to loopback with Seatbelt, Windows uses the one-time `3code
  setup` fence. The default policy leaves the network open.
- **ChatGPT and SuperGrok logins.** `:provider add chatgpt` (ChatGPT
  Plus/Pro) and `:provider add supergrok` (SuperGrok, X Premium+)
  authenticate via browser OAuth with refreshable tokens, and can sit beside
  API-key `openai` and `xai` providers.
- **Responses API and per-model reasoning.** OpenAI API and ChatGPT requests
  use the Responses API (Codex backend for ChatGPT). `:reasoning` lists the
  levels the active model really accepts, from `none` to `max` where
  supported.
- **Patient retry.** `429`, `5xx`, and network failures back off
  exponentially for up to about 36 hours, so a long session rides out a
  usage limit without dropping to the prompt. `:retry on|off` controls it;
  Esc cancels a running wait.
- **Provider wizard and catalog.** The add-provider wizard accepts a name,
  URL, key, or subscription login in one field, checks models in parallel,
  and trusts the known-good registry instead of the provider's `/models`
  endpoint. GLM-5.3, grok-4.6, Qwen3.8, and refreshed DeepSeek entries join
  the registry.
- **Windows and macOS.** Bash is captured in-process on Windows, piped stdin
  reads via ReadFile so pipe input and EOF work, and startup warnings
  explain a slow first launch or a missing sandbox setup. macOS gets
  Seatbelt enforcement and its own build workflow.
- **Library and web example.** The blocking `AgentSession` API exposes
  prompts, events, commands, interruption, persistence, and sandboxing
  without a terminal; `example/webserve.nim` is a threaded web frontend
  with SSE streaming.
- **Termux arm64.** Releases include an Android arm64 archive; Termux uses
  its own OpenSSL and temp dir, and unsupported OS sandbox and notification
  features degrade cleanly.
- **Terminal and input fixes.** Transcript and footer repainting share one
  geometry path; resize, interruption, and terminal-reply handling are more
  reliable. Ctrl+C clears input, Esc interrupts, Ctrl+D exits.

**0.5.2** - search engine overhaul: Exa, Brave, and Parallel backends

- **Search backends replaced.** The dead Startpage HTML scraper is gone.
  `web_search` now speaks Exa's hosted MCP endpoint (keyless by default, one
  stateless JSON-RPC call), with Brave and Parallel added as alternative
  REST engines. Engine is configurable via `[settings] engine`, with no
  failover between them.
- **Per-engine keys.** The single `[search] key` is split into
  engine-specific `exa-key` and `brave-key`; each is also read from its
  environment variable. Exa runs keyless without one.

**0.5.1** - new providers, GLM-5.2 reasoning fixes, Qwen family

- **New providers and models.** OpenCode Zen + Go gateways, Kimi API Platform, Kimi Code subscription, nano-gpt, and `zaicode` (Z.ai coding endpoint). GLM-5.2, GLM-5.1, GLM-5, DeepSeek-V4 Pro/Flash, MiniMax-M3, Kimi K3/K2.7-code/K2.6, Qwen3.6/3.7, and Tencent Hy3 across these aggregators.
- **GLM-5.2 reasoning fixed.** Together and OpenRouter now actually send `reasoning_effort`/`reasoning.effort` for 5.2 (previously dropped silently); OpenRouter maps `max` to its native `xhigh`. A `variant` data bug that made GLM-5.2 collide with GLM-5.1 is corrected, so `:reasoning` offers the right `high`/`max` levels for every 5.2 entry, including third-party hosts.
- **Qwen family.** Qwen3.x is now a first-class family with its own reasoning wiring (vLLM `enable_thinking`), `:reasoning` surface, and prompt branch.
- **Provider config.** Adding a provider no longer treats a duplicate API key as a blocker, keys and URLs may be shared across providers, and a duplicate name gives a single clear error and returns to the prompt.
- **Internals.** `KnownGoodCombos` uses named field access instead of magic tuple indices, so adding a field can no longer silently shift every lookup.

**0.5.0** - Windows support, new providers, big stability push

- **Windows support.** MSYS2 bash is the supported shell; the bash tool, session locking, and color palette all work on Windows. Linux CI is split into amd64 and arm64; macOS gets its own fast build+publish workflow.
- **New providers and models.** Ollama, Eurouter, Lyceum, Regolo, and TensorX in the provider catalog, alongside MiniMax (M3, M2.7), Tencent Hunyuan (hy3 prompt family), Longcat, GLM-4.7-Flash (free z.ai MoE), and Novita. Refreshed DeepSeek, gpt-oss, Kimi, and GLM reasoning prompts and per-(provider, model) context windows.
- **Stable and reliable streaming.** Network-quiet hangs and truncated SSE streams now time out and retry instead of freezing forever. Empty model replies are recovered via finish_reason-aware turn handling. Bounded streaming recv makes the quiet-network timeout actually fire, including at provider-connect time, where `verifyProfile` now uses the bounded `streamhttp` client instead of the unbounded `httpclient` that could deadlock. ctrl-c cancels mid-stream, mid-tool, and during provider connect, with no leftover freeze or stale echo. The caret no longer flickers when the streaming repaint races the input thread; assistant prose and the bash tool viewport carry their inter-item gap during live streaming; and a spurious timing line no longer prints on a mid-stream interrupt.
- **Session resume and locking.** O(1) resume via a per-cwd session index; resume replays the full session into the scrollback. Stale session locks are reclaimed automatically and locking is atomic on Windows. A prompt draft survives an unexpected shutdown.
- **Terminal rendering fixes.** Redraw the fat prompt on resize without stacking chrome or drifting the prompt. Single-GUI-thread ownership of the composite frame; spinner and bar-tick merged into one renderer (kills a thread leak that froze the bottom row). Tool banners, plan glyphs, and receipts now share one byte-path renderer across live streaming and session replay, with the old alternate renderers and dead plan code removed. Correct display width for CJK, emoji, and combining marks; unicode (UTF-8) input in the editor. Light/dark tone auto-detected via OSC 11 background query, with `[settings] tone` and `[colors]` config overrides.
- **Bash tool.** Native timeout (no GNU `timeout` dependency, default 120s, ceiling 600s) and native `computeDiff` (no external `diff`). The model is told its own timeout. File contents shown for write-tool display.
- **Robustness.** Sanitize wire body so invalid UTF-8 can't brick a session; guard `computeDiff` against binary content; exit gracefully if the working directory is deleted mid-session; no silent exit on a broken stdout mid-turn. Network quiet timeout tightened from 180s to 45s.
- **Packaging.** `--version`/`3code -v` reports build provenance; nightly builds carry branch+commit in the version string.

**0.4.0** - error icons for failed tool calls, pin bar+prompt to bottom during scrolling, suppress raw JSON on malformed tool args

**0.3.5** - `$`/`r`/`w` tool bullets, bright cyan receipts, bar ticks during tool execution

**0.3.4** - initial docs site, `-i`/`--interactive` flag, streaming ping test

**0.3.3** - icon-based tool banners, history fixes, display polish

**0.3.2** - native read command, binary guard for bash, deepseek in known-good

**0.3.1** - `update_plan` tool, gpt-oss reasoning tuning

**0.3.0** - `--good` subcommand, ctrl-c cancel during stream, linux-arm64 builds

**0.2.7** - inline receipts, gpt-oss grounding prompts

**0.2.5** - token bar with cache indicator, skill autoloader, web-research trigger

**0.2.1** - per-model tool dispatch, multiline input, markdown table fit

**0.2.0** - initial public release
