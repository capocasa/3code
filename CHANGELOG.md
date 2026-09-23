Changelog

0.8.0  private mode, per-model params, cache-hot resume, commandcode and
       platte providers, PortableGit in the Windows installer
  - xiaomi provider; MiMo 2.6 Pro/Flash on xiaomi, OpenRouter, OpenCode Zen/Go
  - new yolo-auto provider: yolo and yolo-small aliases, flat rate
  - thinking replay (think-back) is configurable per provider in [params]
  - dead oauth refresh token ends the turn with a re-login hint, not a crash
  - harness autosends (steer, flail prods) show exact text in scrollback
  - Grok 4.7 known-good: xai, OpenRouter, OpenCode Zen (same shape as 4.6)
  - retry-backoff notice boxed by blank rows, absorbed on reconnect
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
