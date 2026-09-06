# Changelog

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
