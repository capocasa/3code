Changelog

**Unreleased**

- **Caret flicker in the spinner, finished.** The drawn-caret rework
  left one `?25h` at every turn end: nothing ever re-hid the cursor,
  so from the second turn on the terminal's own blinking caret sat
  parked on the bar row, in and around the braille spinner. The
  physical cursor now stays hidden for the whole session as designed
  (one hide at startup, one show at exit). Two masked bugs surfaced
  once it really was hidden: after a queued autosend the idle prompt
  drew no caret at all (a leftover `pendingCaret` suppressed the drawn
  cell; the visible cursor had been standing in for it), and the
  frame-artifact renderer drew the caret from the physical cursor, so
  it now draws the reverse-video cell instead.

- **Space Bunny stealth model known-good on OpenRouter and OpenCode
  Zen.** `stealth/space-bunny-alpha` (OpenRouter) and `space-bunny-free`
  (Zen) are a free anonymous preview (1M context, 524k output cap,
  text+image+video input) whose tokenizer and reasoning wire shape
  match the MiniMax M-series, so it rides the minimax family:
  enable_thinking + reasoning_split are accepted on both routes and
  thinking comes back split from content. Reasoning is mandatory:
  upstream offers an effort ladder minimal..max but rejects `none`
  ("Reasoning is mandatory for this endpoint and cannot be disabled")
  and ignores enable_thinking=false, so `:reasoning` offers no knob
  (same rule as kimi-k2.7-code). The OpenRouter stealth route also
  omits reasoning deltas from the stream unless `include_reasoning` is
  sent; 3code sends it for that mount only. OpenRouter banners the
  model as going away October 5, so expect that row to vanish then;
  Zen's free mount has no listed end date.

- **Session listing scope, transcript search, and paging.** `-l` still
  lists this directory's 20 newest sessions; `-a`/`--all` now widens it
  (and the new search) to every directory, printing each session's cwd.
  New `-f`/`--find TERMS...` searches saved `.3log` transcripts:
  case-insensitive, whitespace-agnostic phrases (a quoted argument is a
  phrase that matches across line breaks), OR across terms, ranked by
  match frequency with newest-first ties, one snippet per hit with the
  3log formatting stripped. The scan reads each file once and matches
  through libc `memmem` (the grep -F engine), so ~500 MB of history
  searches in about a second; only displayed pages pay for snippet
  extraction. `--page N` pages both listings and search results, and
  `:sessions all` now lists everything instead of refusing.

- **Windows: console keys are read as records and translated to the VT
  grammar in-process.** `ReadFile` under `ENABLE_VIRTUAL_TERMINAL_INPUT`
  wedges forever when the record-queue head is a charless event (a
  key-up): later keys pile up behind it and never wake the read, and the
  bytes it has already translated sit in a kernel-side buffer invisible
  to every readiness probe - Ctrl-C went dead mid-turn and the prompt
  could not be quit. The editor now consumes `INPUT_RECORD`s with
  `ReadConsoleInputW` (which handles every event type) and emits the
  same CSI/Alt-chord grammar itself; the ESC-tail probe and the startup
  drain work on the same byte view, and the drain only drops structural
  bytes inside a sequence that began with ESC (it used to eat typed
  hex letters `a`-`f` that landed in its window). Selection and
  modifier keys still arrive as full VT sequences.

- **Keyboard text selection and standard edit ops in the prompt (#44).**
  The input buffer is now a real text widget: Shift+Arrows / Shift+Home
  / Shift+End extend a reverse-video selection (Ctrl+Shift+Arrows by
  word, Ctrl+Shift+Home/End to the buffer ends), typing or any delete
  replaces it, plain motion drops it, Ctrl+X cuts, Alt+W copies (OSC 52
  to the system clipboard where the terminal allows), Ctrl+V pastes
  from the system clipboard (pbpaste / wl-paste / xclip / xsel /
  PowerShell, kill-ring fallback), Ctrl+Y yanks the last cut. New edit
  commands: Ctrl+K delete-to-eol, Alt+D / Ctrl+Delete delete-word-right
  (ctrl+delete used to delete the word on the LEFT), Ctrl+T transpose
  chars, Ctrl+Left/Right word jumps are now first-class configurable
  bindings. Every command is rebindable in `[shortcuts]`, with
  modified-key names (ShiftLeft, CtrlShiftLeft, CtrlDelete, ...).
  Windows enables ENABLE_VIRTUAL_TERMINAL_INPUT so the console speaks
  the same VT key grammar as every other platform (legacy conhost
  keeps the `_getch` pair codes); the modified-key CSI decoding and
  selection rendering are shared verbatim. Keys are read via ReadFile
  under VT input: `_getch` decodes the console's key records and on
  live consoles still emits the legacy 224/0 pair encoding with the
  flag set, silently stripping modifiers.

- **Byte-envelope 400 recovery (issue #48).** Gateways reject oversized
  request bodies with an opaque 400 (`inference_failed` on OpenCode Zen)
  while the token count is still far under the advertised context window,
  so the token-based summarize threshold never fired: every resend
  carried the same history and 400'd again, and `:summarize` could not
  rescue either because its meta-call replayed the same oversized
  payload (upstream anomalyco/opencode#35013 documents the same
  envelope tripping OpenCode's own TUI). A turn that dies on a 400 with
  enough history now collapses it once and retries: a real recap when
  the summarizer call succeeds, otherwise the middle is dropped
  locally so the session still recovers instead of dead-ending
  forever. The summarizer payload is also clipped to ~768KB of message
  text, so the rescue call itself fits the envelope that killed the
  main request. On top of the reactive recovery, a proactive guard
  measures the exact serialized request body after every call and, for
  the Zen-family providers only (`opencode`, `opencodego`), collapses
  the history once it crosses 1MB — under the tightest route envelope
  observed — so the oversized request is never sent at all; token
  counts cannot predict a byte limit, but the body size 3code just
  sent can. Cached transport connections that the server closed
  (`Connection: close`) are no longer reused: a non-blocking peek
  drops the dead socket before `send` can wedge in an unobservable
  spin, which the recovery retry could hit when the gateway closed
  the rejected connection.

- **Flail guard: streak signal no longer flags verification retries.**
  The stuck-streak signal read a long same-tool run of near-identical
  calls as a doom loop even when the run was legitimate
  output-capture debugging: retrying one pytest command with cycling
  capture tails (`| tail -2`, `| grep -E 'passed|failed' | tail -2`,
  redirect-to-file) tokenizes to the same subject set, because the
  varying tails fall under the 6-char token minimum, so a converging
  retry sequence and a cosmetic-variant doom loop were shape-identical
  (20260930 astropy session; escalations landed mid-diagnosis and the
  step-2 message forbade the retry the work needed). The ring behind
  the signal now restarts on a subject change: a call sharing no
  distinctive token with the ring's consensus (the tokens a majority
  of ring members carry, so prose `#` comments cannot bridge a subject
  change) empties it. An uninterrupted run of near-identical calls
  still fills the ring and still escalates; interleaved genuinely
  different work no longer accumulates into one. Replayed against
  400 recorded sessions: the mergepdf doom loop, ssh-boilerplate loop
  regions, and spaced failed repeats all still fire.

- **`3code provider` subcommand.** Non-interactive provider management
  for scripts and keyless first setup: `provider add <name|url|api-key>
  [--key KEY] [--models "a b c"]`, `provider models <name> <model...>`
  (replace the list), `provider rm <name>`, and `provider list`. Same
  first-field resolution as the wizard (catalog name, URL under
  --experimental, API key, subscription login via browser OAuth);
  without `--models` the provider's full known-good list is stored. No
  verification ping; a bad key surfaces on the first turn.

- **Claude Sonnet 5.5, GPT-6 Sol / Luna, GPT-6.1 Sol.** `claude-sonnet-5-5`
  is known-good for `anthropic` (API key) and `claudecode` (Pro/Max
  subscription): 1M context, 128k output, adaptive thinking with effort
  low..max. Its `off` knob maps to Anthropic's new `between_tools`
  setting (Sonnet 5.5 rejects `disabled`), and its thinking blocks ride
  the drop_block fallback like Opus 5.5's. `gpt-6-sol`, `gpt-6-luna`,
  and `gpt-6.1-sol` are known-good for `openai` and `chatgpt` plus the
  openrouter / opencode / nanogpt / venice gateways: 1.05M context,
  128k output cap; Sol/Luna keep `none` on the effort ladder, 6.1 Sol
  always thinks (low..max like Astra). Live-verified: gpt-6-sol,
  gpt-6-luna, and gpt-6.1-sol on openrouter; gpt-6-luna on the chatgpt
  subscription (the Codex backend serves a per-account model list and
  may not offer sol yet); opencode and venice reached upstream (402
  balance); anthropic and nanogpt keys here lack credit/a valid
  session, so those rows stay table-verified.

- **Test build: browser-backed `web_fetch` behind `browserfetch = on`.**
  When the plain fetch survives tag-stripping as almost nothing (a JS
  shell, e.g. a Reddit profile), the fetch is redone in a shared headless
  Chrome and the rendered page text is returned instead. One browser per
  machine (own throwaway profile, 127.0.0.1:9223, launched by the first
  3code that needs it and reused by every later one), one tab per fetch.
  Default off; `ws` is a new dependency. Anti-bot walls still apply: a
  fresh headless profile gets Reddit's "Prove your humanity" challenge.

- **The occasional "submit deletes the line above the prompt" is fixed.**
  A multi-row draft in the buffered mid-turn editor (history recall,
  shift+enter, typing during the stream) made the answer-start erase
  leave the cursor on the erased block top with the chrome row model
  wiped; the repaint after it then re-anchored up to `editor rows - 1`
  rows too high and overwrote the wrapped tail of the just-committed
  prompt echo. Single-row drafts canceled the arithmetic out, which is
  why it only showed sometimes. The content-start transition now parks
  the cursor back on the editor caret row and keeps the painted-chrome
  count. The multiline golden fixture is regenerated: it had recorded
  the bug (the first echo's `second line` row missing).

- **Wrapped `:commands` no longer strand stale rows above their echo.**
  Both command submit paths cleared the editor's row model before the
  commit walked up (the idle path via its beforeRepaint hook, the
  mid-turn path in the submit handler itself), so a command wrapping
  the editor to three or more rows erased from inside its own block:
  the resting bar and the editor's top rows survived as junk between
  the previous content and the committed echo. The model reset now
  happens inside the commit, after the walk-up has consumed the
  pre-submit geometry (`clearEditor`). Single-row commands were never
  affected.

0.8.0  private mode, per-model params, cache-hot resume, commandcode and
       platte providers, PortableGit in the Windows installer
  - anthropic provider: Claude on the native Messages wire (Opus 5.5,
    Sonnet 5, Fable 5.1, Haiku 4.5) with an sk-ant- key — system prompt
    as a top-level field, tool_use/tool_result content blocks, and the
    `:reasoning` knob on the model's thinking surface (adaptive effort
    low/medium/high/xhigh/max on 4.6+/5.x, the legacy token budget on
    4.5; Opus 5.5+ and Fable cannot disable thinking). Thinking blocks
    replay across tool loops with their signatures; the prefix-binding
    models (Opus 5.5+, Fable) request drop_block so an interrupted or
    compacted history degrades instead of 400ing. No sampling params
    (the 4.6+ generations reject them). `claudecode` is the Claude
    Pro/Max subscription twin: browser OAuth on the Claude Code public
    client, Bearer + oauth beta against api.anthropic.com, the Claude
    Code line leading the system prompt
  - xiaomi provider; MiMo 2.6 Pro/Flash on xiaomi, OpenRouter, OpenCode Zen/Go
  - editor buffer hard-capped at 512KB: oversized inserts and pastes cut
    at a rune boundary and ring the bell instead of growing forever
  - release-build crash typing large wrapped prompts fixed (caret past a
    wrap gap built a negative slice); the wrap walk can no longer spin on
    terminals too narrow for the prompt plus a rune, nor slice past the
    buffer when a raw paste ends mid-rune
  - thinking replay (think-back) is configurable per provider in [params]
  - dead oauth refresh token ends the turn with a re-login hint, not a crash
  - harness autosends (steer, flail prods) show exact text in scrollback
  - Grok 4.7 known-good: xai, OpenRouter, OpenCode Zen (same shape as 4.6)
  - MiMo 2.6 known-good on DeepInfra and nano-gpt; Grok 4.7 on nano-gpt
    and Venice (flattened grok-4-7 id)
  - retry-backoff notice boxed by blank rows, absorbed on reconnect
  - -c/--config switch reads an alternate config file (docs always promised it)
  - [settings] max_timeout raises the bash timeout ceiling; THREECODE_MAX_TIMEOUT wins per run
  - reference: env-var section (XDG roots, diagnostics); -c and max_timeout documented
  - shortModel canonicalizes after slash-strip; zai-glm-5-3 shows glm-5.3
  - prompt caret carries the palette's white tone, not the terminal default
  - token bar survives usage-less turn ends (repainted from last label)
  - catalog sweep: crof dropped, dead combos gone, stragglers added
  - session reservations 0600 again (decimal 0644 parsed as 0o1204)
  - Windows installer bundles PortableGit; resolveBash prefers it
  - Windows bash detection: bash_path, Git for Windows, MSYS2, legacy
  - no bash found: tool dropped with a warning instead of a hard fail
  - sandbox = off silences the Windows host-rules warning at launch too
  - Windows net-fence state resolved at startup; warns when it is gone
  - new commandcode provider: one key for the open-model lineup
  - SSE parser strips the optional space; Hetzner data:{...} streams
  - new platte provider: GLM 5.3 on EU infrastructure
  - union-alpha stealth preview on OpenRouter; generic other family
  - GLM-5.3 on Mistral: 1M context, thinking-only low/high/max
  - session files store the skills catalog, not the verbatim prompt
  - OpenCode zen gateways take top-level reasoning_effort
  - startup error line when the OS sandbox cannot confine bash
  - JSON error bodies: detail convention read, longest string leaf picked
  - pre-TLS connect failures say "host is not responding", not TLS
  - Windows sandboxed bash no longer wedges (env-passed cmd, bounded reap)
  - caret parks at the right margin instead of wrapping to the next row
  - patch edits with empty search/replace rejected, file untouched
  - caret steps over typed trailing spaces
  - drawn caret, hidden physical cursor: no flicker, fewer bytes
  - payload-fresh frame-model copies end the Termux write-after-free
  - retry waits show an hourglass; braille spinner is in-flight only
  - long-session memory leaks fixed (SSL ctx cache, thread-local frees)
  - GLM-5.2 on Mistral: reasoning_effort ladder, chunked thinking folded
  - Windows sandbox works when setup ran as another account (sandwall)
  - resolveBash falls back to Git for Windows; installer bundle optional
  - Esc clears the draft; only an empty prompt cancels the turn
  - Hy4 and Mistral join the known-good registry
  - DeepSeek V4.1 Flash known-good on all five providers serving it
  - typing no longer flickers the turn clock to 0s
  - private mode: -p/--private, allow-private providers, magenta bar
  - [params] per-(provider, model) overrides: temperature, max-tokens...
  - retry notices live on one row instead of stacking in scrollback
  - resume re-sends byte-identical history (prompt-cache friendly)
  - GPT-6 Astra known-good on openai and chatgpt

0.7.0  key rebinding, editor integration, smarter stuck-loop guard
  - [shortcuts] config rebinding for every key command
  - Alt+E edits the draft in $EDITOR; :! runs a shell command yourself
  - flail guard: nudges a spinning model twice, then aborts the turn
  - faster rendering: frame skip, diff-painted keystrokes, ghostty fix
  - Kimi K3 first-party reasoning knobs; GLM-5.3 effort ladder, 32k cap
  - User-Agent on every request; opencode gateways get session header
  - catalog: Qwen 3.5-3.8, DashScope, Omen-alpha, Aki, GreenPT, Lyceum
  - resume replays through shared transcript formatters
  - Termux release tarball with autoupdate
  - transcript: checkpoint markers stripped, empty replies skipped

0.6.3  catalog sweep
  - catalog: GLM-5.3, Qwen 3.8, DeepSeek V4 on 15 more providers

0.6.2  GLM-5.3-Flash
  - catalog: GLM-5.3-Flash on zai/zaicode; GLM-5.3 on regular z.ai API

0.6.1  --no-sandbox, paste-aware input, catalog refresh
  - --no-sandbox flag; pasted newlines kept as one draft
  - wizard experimental mode lists the full /models output
  - catalog: 0xalpha stealth preview, current free tiers
  - terminal: late OSC 11 replies, Windows startup keys, macOS openpty

0.6.0  filesystem sandbox, subscription logins, network wall
  - filesystem sandbox: one policy, deny/readonly/allow per line
  - kernel enforcement: Landlock, Seatbelt, Windows restricted tokens
  - network wall: host rules proxy bash egress (netns, Seatbelt, WFP)
  - ChatGPT and SuperGrok subscription logins via browser OAuth
  - OpenAI requests move to the Responses API; :reasoning lists levels
  - patient retry: 429/5xx/network backoff, up to ~36 hours
  - provider wizard: one field, parallel checks, known-good registry
  - Windows: in-process bash capture; macOS: Seatbelt, own workflow
  - AgentSession blocking API; example/webserve.nim web frontend
  - Termux arm64 release archive
  - terminal/input fixes: shared geometry, resize, ctrl-c/esc/ctrl-d

0.5.2  search engine overhaul: Exa, Brave, and Parallel backends
  - search: Exa MCP default, Brave and Parallel REST engines
  - per-engine keys (exa-key, brave-key); Exa runs keyless

0.5.1  new providers, GLM-5.2 reasoning fixes, Qwen family
  - new providers: OpenCode Zen/Go, Kimi, nano-gpt, zaicode
  - GLM-5.2 reasoning fixed on Together/OpenRouter; variant bug fixed
  - Qwen3.x first-class family (vLLM enable_thinking)
  - provider config: shared keys/URLs allowed, clear dup-name error
  - internals: KnownGoodCombos named fields replace tuple indices

0.5.0  Windows support, new providers, big stability push
  - Windows support: MSYS2 bash, session locking, color palette
  - new providers: Ollama, Eurouter, Lyceum, Regolo, TensorX, Novita
  - streaming: network-quiet timeout, truncated SSE retry, ctrl-c
  - resume: O(1) per-cwd index, full replay, stale lock reclaim
  - rendering: resize redraw, single GUI thread, one byte-path renderer
  - bash tool: native timeout and computeDiff, no GNU tools needed
  - robustness: UTF-8 sanitize, binary diff guard, graceful exits
  - packaging: --version provenance, nightly branch+commit strings

0.4.0  error icons for failed tools, bottom-pinned bar, no raw JSON

0.3.5  $/r/w tool bullets, bright cyan receipts, bar ticks

0.3.4  initial docs site, -i/--interactive flag, streaming ping test

0.3.3  icon-based tool banners, history fixes, display polish

0.3.2  native read command, binary guard for bash, deepseek known-good

0.3.1  update_plan tool, gpt-oss reasoning tuning

0.3.0  --good subcommand, ctrl-c cancel during stream, linux-arm64 builds

0.2.7  inline receipts, gpt-oss grounding prompts

0.2.5  token bar with cache indicator, skill autoloader, web-research

0.2.1  per-model tool dispatch, multiline input, markdown table fit

0.2.0  initial public release
