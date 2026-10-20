Changelog

Unreleased

- **Vertical cursor movement no longer repaints (and no longer crawls)
  on a pasted multi-line draft.** Two causes stacked: Up/Down picked
  their target with one `cursorVisual` - itself a full row-model walk -
  per rune boundary, which is quadratic in the buffer (a 200-line
  pasted draft spent 20+ seconds per arrow key), and every motion
  keystroke then erased and repainted the entire editor block on top.
  `verticalTarget` now finds the same target in one pass over the row
  model (verified against the old scan over a fixed corpus plus 400
  random fuzz buffers), and `moveOnlyRedraw` handles cursor-only
  keystrokes - left/right, up/down, word, home/end, buffer start/end -
  by walking the terminal cursor from the old cell to the new one: no
  erase, no prompt re-emit, a handful of bytes whatever the buffer
  size. The interactive app's drawn-caret path is unchanged (its
  row-diff painter already rewrites only the rows whose cells
  changed).

- **A `goal.md` on disk at startup now arms goal mode by itself.** Goal
  mode used to activate only at the first turn end: a `goal.md` written
  by hand (or by any other tool) sat inert until something - anything -
  ran a turn. The startup path now detects the file, loads it, and sends
  the same harness-autosent kickoff prompt `:goal <text>` produces, so
  work on the goal begins the moment the session opens, no keystroke
  needed. Fresh and resumed sessions alike; the kickoff keys off the
  session's project directory, the same authority as the turn-end
  satisfaction check.

- **3code owns the tty's output discipline (gh #54).** A shell left
  `-opost` by a crashed CLI or `stty -opost` used to break every wrapped
  row: with `OPOST` off, `ONLCR` is inert, so the bare `\n` 3code writes
  kept the previous row's column and paragraphs, tables, and the startup
  box art drifted right into unreadability. 3code now restores
  `OPOST|ONLCR` on the tty before the first paint and stops clearing
  `OPOST` in the editor's raw-mode switch, so rows render at column 0
  whatever the parent left behind - and the shell handed back at exit is
  readable too.
- **Quitting no longer leaves the terminal in no-echo mode after an
  edit-in-editor round-trip.** Alt+E / Ctrl+X Ctrl+E hands the terminal
  to `$VISUAL`/`$EDITOR` and re-applies raw mode when the editor
  returns; it also replaced the cooked termios snapshot that exit
  cleanup restores with that raw mode. Every quit afterwards
  "restored" raw mode, so the shell the user landed in echoed nothing
  until `reset`. The snapshot now survives the round-trip (gh #56).
- **Cmd+A selects all (#57).** The `select-all` command - present
  since the selection work but bound to no key - now ships bound to
  `CmdA`, so on macOS the Command key gets its usual meaning with no
  config: terminals that speak the kitty keyboard protocol (kitty,
  Ghostty, iTerm2, WezTerm, foot, Warp) report the chord and the whole
  buffer highlights; everywhere else the key stays inert and the
  Ctrl/Shift defaults are untouched. `select-all = ""` unbinds it
  like any other command.
- **Prompt-cache affinity on OpenAI Responses (gh #58).** The ↻ slot in
  the token bar was mostly absent on ChatGPT subscriptions because the
  cache misses were real, not a display bug: OpenAI's prompt cache is
  sharded and only serves hits when consecutive requests land on the
  same shard, and 3code sent none of the affinity signals that pin that
  routing (the Codex CLI sends a stable `prompt_cache_key` body field
  and a `session_id` header). Every /responses request now carries the
  conversation id (the `.3log` session id - stable across turns and
  resume, rotating on `:clear`) as `prompt_cache_key`, and `chatgpt`
  profiles additionally send it as the `session_id` header on the Codex
  backend, exactly matching what the first-party client pins. One-shot
  calls (verify, summarize) send neither; nothing is reused across
  them. First-party openai profiles get the body field (a documented
  public parameter); other providers never see it.
- **Prompt-typing RangeDefect (gh #59): fixed since 0.8.1, now pinned by
  regression tests.** The crash - `value out of range: -1 notin 0 ..
  high` while typing after navigating a wrapped prompt - reproduces on
  0.8.0 exactly as reported: a caret resting in a trailing space run
  at the wrap margin draws one row below the gap, on a row whose span
  starts past the caret and holds no whole rune, and `caretSliceBytes`
  built `text[9 ..< 8]` from a rune length it never clamped to that
  span. The clamp shipped in 0.8.1's caret/wrap rework; the
  keystroke-level repro (type `cac c` plus spaces past the margin,
  Left into the space run, End) and the span-model geometry are now
  tests that fail with the reported RangeDefect on 0.8.0, so the
  editor cannot regress there silently.
- **More clickable links wherever a file is named (#60).** The `r`,
  `w`, and `p` banners now hyperlink their path as an OSC 8 `file://`
  URL - click a read/write/patch banner to open the file itself,
  live viewport, transcript replay, and `:log` alike (terminals
  without OSC 8 still show the bare path). A patch's full diff
  always lands in the log dir as `T<n>.diff` with a linked
  `T<n>.diff ↗` row, even when the diff fit in the transcript
  un-truncated - one click from something `git apply` / `patch -R`
  can consume; the dumped file is the complete diff, first banner
  line included. And markdown links in model prose that point at
  paths instead of URLs - `Created [some-plan.md](some-plan.md).` -
  resolve against the project directory into working `file://`
  links instead of printing as literal markup (`#anchors` and
  unknown schemes still pass through verbatim).
- **`.NET` builds work in the macOS sandbox (#55).** Writable paths
  now carry their unix-socket rights in the seatbelt profile
  (sandwall 0.5.12): `system-socket` for AF_UNIX creation, plus
  `network-bind`/`network-outbound` scoped under each granted path.
  Seatbelt gates those as network operations no file rule reaches, so
  `allow /tmp` left MSBuild worker nodes and the dotnet diagnostic
  server socket-dead - the same wall codex and claude-code hit
  (openai/codex#12702, claude-code #41254). Read-only paths get
  connect only (`readonly /var/run/docker.sock` is now the shape for
  a service socket), denied paths lose their sockets with their
  files, and fenced builds keep their local IPC while TCP stays
  loopback-only. The manual ships the `dotnet` recipe (NuGet cache
  writable, NuGet config readable), an end-to-end test drives
  `dotnet build` through `3code sandbox` under exactly that policy,
  and on Linux nothing changed - Landlock already granted socket
  binds on writable paths.
- **Goal mode: `goal.md` keeps a session on one goal.** Drop a `goal.md`
  into the project root stating what must be true when the work is done,
  and the harness takes over from there: `:goal <text>` writes the file
  and sends the agent off in the same breath, no extra prompt needed.
  Every turn end runs a satisfaction check: a fresh side conversation
  with the same model judges the goal text against a harness-built
  evidence summary of the turn (tool calls and their recorded results,
  never the agent's own claims) plus the check-time working-tree diff.
  The verifier has no tools and answers in one call - orientation is the
  harness's job - and whatever it cannot confirm from runtime behavior
  it must name in its feedback instead of inferring. Its reply lands in
  scrollback as a dim, indented tier clearly below the agent's items.
  Not satisfied, the agent is sent back in with the verifier's words;
  satisfied, the file is renamed `goal-confirmed.md` and the session
  idles. `:goal` shows the goal, `:goal edit` opens it in
  `$VISUAL/$EDITOR`, `:goal!` replaces it and bare `:goal!` cancels
  into `goal-cancelled.md`; interrupt pauses the check, deleting the
  file ends goal mode silently. A failing check retries at the next
  turn end; the harness never gives up on its own.
- **Ctrl+R retries now; `:retry` is the command form.** During a
  patient-retry backoff, Ctrl+R cuts the wait short and resends while
  keeping the backoff schedule intact, so later failures back off
  exactly as they would have. Ctrl+R also cancels and resends a request
  that has not shipped any output yet; once model output is streaming,
  or at the idle prompt, it does nothing. Bare `:retry` does the same
  from the command line; `:retry on`, `:retry off`, and `:retry list`
  manage the patient-retry setting itself.
- **Sandbox `ask`: one-key approval for the gray zone.** `:sandbox ask
  P` denies exactly like `:sandbox deny P`, but when a sandboxed bash
  command is blocked on an ask-protected path, 3code puts one question
  in the tool output view - `sandbox ask: ~/vault/notes/x.md is
  ask-protected.  [f] ~/vault  [d] ~  [n]o  (60s)` - and one key answers
  it: `f` allows the ask-protected path (the `ask` rule's own target),
  `d` the directory around it, `n` keeps the denial. A grant is written
  into the active policy file, so it sticks for the session and beyond;
  no answer within 60 seconds counts as `n`, and the failed command is
  never retried without an explicit grant. The sandbox stays kernel-
  enforced and silent for everything else: `ask` covers the paths you
  would probably allow if you were watching (a browser profile, a notes
  vault) where `deny` costs a manual policy edit and `allow` feels too
  broad unattended.
- **ACP: 3code as an editor-native agent.** `3code --acp` speaks Agent
  Client Protocol v1 over stdio - newline-delimited JSON-RPC on
  stdin/stdout, the protocol Zed, JetBrains, and Neovim plugins use - so
  an editor can drive 3code like any other agent (Zed: agent settings,
  "Add custom agent", command `3code`, arguments `--acp`). One session
  per process; the session id is the `.3log` id, so `session/load`
  resumes any past 3code conversation. Prompt turns stream as
  `session/update` notifications (message and reasoning chunks, tool
  activity, token usage), and `session/cancel` is Ctrl-C over the wire.
  Model and provider come from the normal config (`-m` picks, `:model`
  philosophy otherwise); the sandbox and loop guard run exactly as in
  the terminal. Diagnostics go to stderr so stdout stays parseable
  protocol records.
- **Prompts and `:commands` queue while a turn runs.** Mid-turn input
  used to funnel into a single slot: the first prompt submitted during
  a turn was remembered (unechoed until it ran), every later line was
  silently dropped, and commands ran inline only if they were safe.
  Now each line submitted during a turn - prompt or command - echoes
  immediately as a `⧖` item in the scrollback and joins an ordered
  queue. When the turn ends the queue drains in order: each queued
  prompt runs its own full turn (anything queued during that turn
  lines up behind it), each queued command runs exactly as it would at
  the idle prompt, mutating and modal ones included. Backspace on an
  empty prompt pulls the last queued line back into the editor, joined
  file-editing style, so a typo spotted in the hourglass row can be
  fixed before the line ever reaches the model.
- **Vision: images in, images out.** Vision-capable models see images:
  `@mockup.png rebuild this` attaches the image to your message (echo:
  `@mockup.png [image attached]`), and `read` on an image returns a text
  receipt (`image logo.png 1920x1080 PNG -> delivered 1280x720 JPEG;
  attached below`, transcript: `· read img logo.png 1920x1080 -> 1280x720`)
  with the pixels riding the next user message — the OpenAI-compat shape
  every gateway accepts. Curated vision models: `zai`/`zaicode`
  `glm-5.3-flash` and the `deepseek-v4-flash-vision-exp` hostings;
  `[params] vision = "on"/"off"` overrides the curation per provider+model
  (third-party hostings are a patchwork — probe before flipping). On
  non-vision models both paths fail fast with a hint naming a vision model.
  Delivery is budget-driven: one deterministic encode to JPEG q85 inside a
  1280 px box and a 190 KB base64 budget (quality-then-scale ladder, needs
  ImageMagick or `sips` for big sources), capped at 3 images per message
  and 4 per turn; repeated reads of one image trip the flail detector.
  Sessions persist images as `path+sha1` records — never base64 — and
  resume re-embeds the exact delivered bytes (prompt cache stays hot);
  a missing or changed file becomes an `[image stale]` note, and
  compaction collapses image blocks to `[image WxH]` text notes.
  Works on chat-completions (verbatim `image_url` blocks) and the
  Responses API (`input_image` items) alike.

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
- **Plugins: native libraries hooking the host, on a dedicated
  thread.** A plugin is a dynamic library (`.so`/`.dylib`/`.dll`)
  dropped into `~/.local/share/3code/lib` - no manifest, no
  registration call, no RPC protocol: export `tc_on_prompt` and
  friends, and the host probes for them at startup. Hooks cover the
  lifecycle: prompts (mutable), the system prompt (memoized per
  provider/model), every tool call before execution (rewrite, veto,
  takeover, or wrap - host-side policy without touching the model) and
  after it (redact output, amend the exit code), turn, session,
  compact, file-write, and model-retry events, plus model-facing tools
  registered from plugin code behind an opt-in `[plugins] tools` gate
  (each schema rides every request, so it is a standing token cost).
  All plugin code runs on one dedicated host thread, one call at a
  time, in load order - a plugin needs no locks of its own to be safe
  against the host; sync hooks round-trip with a deadline so a slow
  plugin cannot stall a turn, async hooks land in a bounded
  fire-and-forget queue. `:plugins` lists libraries, subscribed hooks,
  and call counts; `:plugin debug on` traces calls, verdicts, and
  mutation diffs live. The Nim SDK in `src/threecode/plugin_sdk.nim`
  makes a plugin one file, and `docs/plugins.md` is the full author
  manual. Plugins are native code with your full user rights; the
  default sandbox already fences the model out of the lib directories.

0.8.4  macOS startup crash fixed (ad-hoc signing), OpenSSL static-linked
       with the CA bundle embedded, javac compiles in the macOS sandbox,
       output wraps in-app instead of relying on terminal luck, kitty
       Cmd keys, :resume, linked full tool output, gemini-4-argon

- **The macOS binary starts again (#50, #56).** Release binaries are
  ad-hoc signed (`codesign --force --sign -`, every slice before
  lipo); the unsigned x86_64 slice was the startup crash. OpenSSL is
  now static-linked at 3.5-LTS on mac/win, the bundled dylibs/DLLs
  are gone, and the CA bundle is embedded in the binary - nothing to
  re-sign, nothing to mismatch with Homebrew. Release archives extract
  flat: no wrapper directory inside the tarballs or the zip.
- **`javac` compiles under the macOS seatbelt by default (#66).** JDK
  homes under your home (`~/Library/Java`, `~/.jdks`,
  `~/.sdkman/candidates`) are read-only inside the fence, and the JVM's
  own startup needs (a `kern.grade_cputype` sysctl the kernel classifies
  as a write, plus opendirectoryd user lookups) ride the sandbox
  profile, so Java builds need no policy edits. Token-bearing files
  stay fenced.
- **Own your line breaks; wrap in-app, not by terminal luck (#58).**
  Overlong words are character-wrapped by 3code itself, so a frame
  renders identically on terminals whose wrap semantics disagree with
  the app's model, and a single newline in model output is a line
  break, not a paragraph - the initial-setup output no longer scrolls
  up and partly vanishes (kitty).
- **Kitty-protocol keys for Mac keyboards (#61).** On kitty-protocol
  terminals (kitty, Ghostty, iTerm2, WezTerm, foot) 3code enables the
  protocol automatically: Cmd/Super chords (`CmdE`, `CmdLeft`,
  `AltBackspace`, ...) become bindable keys for keyboards whose
  Option key composes characters. Defaults stay Ctrl everywhere; the
  manual ships the Mac block to paste. Shortcut values now mix plain
  keys and `A>B` chords.
- **`:resume` swaps sessions without a restart (#62).** `--resume`/`-r`
  takes its value attached, `=`/`:`-separated, or space-separated
  (`3code -r abc123`, `-rabc123`, `-r=abc123`), and every other
  value-taking option accepts the same forms. `:resume` lists this
  directory's sessions; `:resume abc123` moves the running REPL onto
  that session (scrollback is not replayed, scroll up or `:show`).
- **Truncated tool output keeps a linked full copy (#64).** The full
  text is dumped to `$TMPDIR/3code_out_<pid>/T<N>.log` and the elision
  row names the file and hyperlinks it (OSC 8); `:show N` prints the
  whole capture.
- **`:!` streams through the live bash viewport** instead of looking
  hung: output appears while the command runs. The fenced-network
  docs now state the fence honestly - REST over HTTP(S) only, `ping`
  (ICMP) and `host`/`dig` (own DNS) ignore the proxy vars and fail.
- **Fixed:** resize-paint use-after-free during a live viewport stream;
  tab completion appends the space after a unique command; `/help`
  works as a synonym for `:help`; gemini-4-argon joins the known-good
  combos (google, openrouter, zen, nanogpt).

0.8.3  flail guard cuts wedged thinking mid-stream and arms for every
       family, sandbox defaults keep git and toolchains working, oauth
       re-login, gpt-5.3-codex / 5.6 pro / haiku-5.5 rows, auto-update
       restored in linux and windows releases, patch folds other
       harnesses' field spellings

- **The thinking loop guard: wedged reasoning gets cut mid-stream.**
  Reasoning models have their own version of getting stuck: the
  thinking stream re-emits one phrase until the output budget dies or
  you interrupt, and no tool call ever fires, so the flailing detector
  watched in vain. While a reply is still pure thinking, the recent
  tail is scanned for a repeating phrase, and a wedged stream is cut
  mid-flight. What lands instead is an empty turn plus a `»` re-prompt
  naming what happened - "your reasoning kept repeating itself" - and
  two re-prompts that both re-wedge end the turn with a notice
  instead of burning retries. Calibrated against 63,479 recorded
  reasoning passes: thinking that merely repeats a topic phrase, or
  quotes dense tables, sails under it; every recorded loop trips it.

- **The flailing detector is armed for every family, with an
  escalation ladder.** It was glm-only before; mistral loops too. The
  streak now arms on output staleness, so windowed scans over many
  files don't read as loops; novel calls are fresh by definition and a
  batch escalates one rung at a time. A reply that dies on output
  length retries one rung down the model's own reasoning ladder
  instead of repeating the same budget mistake. Flagged calls still
  execute: they show in the transcript with the note riding on the
  result, `»` items are the harness-voice tier (bold marker, no
  magenta), and the old `auto:` context rows are gone - the `»` item
  carries the story.

- **Sandbox defaults keep git and toolchains working.** The default
  policy now reads version-control config (`readonly ~/.gitconfig`,
  `~/.config/git`, the matching mercurial paths - git aborts every command
  when its config exists but is unreadable) and grants writable
  access to the caches mainstream toolchains keep under the home:
  `~/go`, `~/.cache`, `~/.npm`, the cargo registry and git checkouts,
  `~/Library/Caches` on macOS, the npm/pip caches on Windows (cargo
  bin, config, and rustup stay read-only). Ruby moved from the
  default list to a recipe. Windows rules also stop path resolution
  at bare drive prefixes, and sandbox asserts show the contracted
  `./` form (sandwall 0.5.9).

- **`:provider edit` can re-login an oauth provider.** The edit wizard
  skips the api-key prompt for subscription twins and offers the
  browser login instead; a dead refresh token now ends the turn
  pointing at `:provider edit <name>` instead of `:provider rm` +
  add. `geminicli` re-marks as an oauth twin like the other
  subscription logins.

- **`gpt-5.3-codex` and the GPT-5.6 pro tiers known-good.** The 5.6/6
  `-pro` selections are not model ids on first-party /responses: the
  base model rides with a pro reasoning mode instead, while pre-5.6
  Pro ids (`gpt-5.5-pro` and older) are real models and pass through
  untouched.

- **`claude-haiku-5-5` known-good.** The first Haiku with the adaptive
  effort knob (low..max): plain `disabled` thinking is accepted with
  no between_tools mapping, 1M context, 128k output.

- **Tesseracted requests collapse before the vLLM message-count
  cap.** The tesseracted gateway (vLLM serving Kolibri-1) rejects a
  request with more than 80 `messages` entries with an opaque 400,
  far under the token window, so the same history collapse the byte
  guard uses now fires on message count for that route. Self-hosted
  kolibri carries no such cap and stays unguarded.

- **Uncurated google/geminicli models default to the gemini family.**
  A model id the curated registry doesn't know rides the gemini wire
  shape instead of failing dispatch.

- **The terminal tab title carries state.** A `3` brand plus a spinner
  glyph while a turn runs, a checkmark (or an ✗ when you cancelled)
  when it ends, and the project directory for wide tabs. Toggle with
  `:tab-title on|off` or the `tab-title` setting.

- **The Mistral preamble was rewritten economical, terse by example.**
  24% smaller than the Vibe-mined version it replaced, compressed
  against Mistral's own CLI prompt and the best sibling preambles,
  and one prompt for all family members now (the family split is
  gone). The anti-flailing sections it gained set the terse-budget
  test's 7.6KB watermark.

- **`patch` now folds other harnesses' field spellings.** Models
  trained on Claude-Code-style tools emit `old_string`/`new_string`/
  `file_path` (and `old_str`, `oldText`, ...) instead of 3code's
  `search`/`replace`/`path`, and the patch action silently produced
  empty edits. Exact synonyms are now accepted, with the canonical
  spelling winning any conflict so a mixed pair is never a coin flip.

- **CI toolchain downloads die on transient connect failures.** The
  pinned-download curls had no retry, and plain `--retry` doesn't cover
  curl exit 7 (couldn't connect) anyway, so one network blip failed
  the whole job (linux-amd64, Oct 12). All sha256-pinned downloads now
  use `--retry 5 --retry-all-errors`.

- **Green CI runs were dropping whole categories' failures.** The test
  harness's exit code came from the last testament dispatch only (the
  tty category, run alone at the end); any failure in the parallel
  api/config/core/shell/stream batch was silently discarded. Five real
  failures rode under green checkmarks since mid-October: the mistral
  terse-budget test (the preamble passed 7000 bytes at 7506), a stale
  vibe-cli max_tokens assertion (the curated row moved to 32768), two
  sandbox tests compiling against a September sandwall pin that
  predated the `./` path-contraction and Seatbelt writable-rule fixes,
  and the memory-leak test's mock reasoning stream (`word1 word2 ...`)
  tripped the new repetition guard's digit folding on every turn,
  stretching 120 turns into a watchdog kill on Linux.
  Every category dispatch now contributes to the exit code, the deps
  are re-locked (sandwall 0.5.9, ttty 0.5.4, tinotify 0.1.5, ws
  pinned), and the two test assertions match the curated rows. The
  mistral terse budget rides to 7.6KB with the anti-flailing sections
  that grew the preamble.

- **Release binaries shipped with auto-update dead.** Every linux and
  windows release since 0.8.0 was built without `-d:autoUpdate`, so the
  background self-update worker never ran; macOS and Termux were
  unaffected. Two CI faults stacked: the linux jobs moved into
  containers whose default step shell is POSIX `sh`, where the `[[ ]]`
  test in the compute-build-flags step fails silently and the flag never
  reaches the compiler, and the windows job packaged the test-phase
  rebuild, which compiles without the flag, instead of the release
  build. The flag steps are now POSIX `sh`, a tag build with empty build
  flags fails loudly, and windows packages before the test phase.
  Verified with real release assets on a real Mac and a real Windows
  box: a flagged build fetches the latest release and swaps itself in.
  Existing installs cannot self-heal, their worker is dead; update
  manually once.

- **The setting is `auto-update`, hyphen only.** The underscore spelling
  `auto_update` is no longer accepted and now fails config validation;
  it was the only multi-word settings key without its hyphen spelling.
  A config that still carries `auto_update` must drop or respell the
  line before it will load.

0.8.2  mistral large 4 known-good, mistral-vibe-cli model aliases,
       mistral system prompt mined from the vibe cli

- **Mistral Large 4 known-good.** Mistral's new frontier open-weight
  model ("le Chonk", 1.05T total / 49B active MoE, multimodal, public
  preview since Oct 6; weights promised end of month) is served as
  `mistral-large-4` on api.mistral.ai with a 524,288-token window per
  `/v1/models` (the docs page advertises 1M; the API figure is the
  safe one). It carries the same `reasoning_effort` ladder as Medium
  3.5 — exactly `none`/`high`, 400 on anything else — and streams
  thinking as chunked `thinking` content, the shape the Mistral-native
  parser already folds, so no wire changes were needed. Known-good
  row: reasoning high, temperature 0.2, 8192 output, tbNone (the
  platform's strict validator rejects `reasoning_content` on replayed
  assistant messages).

- **The Vibe CLI routing aliases are curated under `mistral`.**
  `mistral-vibe-cli-latest` (routes Medium 3.5, thinking high) and
  `mistral-vibe-cli-fast` (routes Small 4, thinking off) — the ids
  Mistral's own `mistral-vibe` CLI sends by default — are known-good
  rows on the plain `mistral` provider (one API key covers both, so
  the parked `mistralvibe` twin stays parked). Both ride the none/high
  ladder with temperature 1.0, what the Vibe CLI itself sends.

- **The Mistral system prompt is now Mistral's own, 3codified.**
  Mined from the open-source Vibe CLI (mistral-vibe 2.26.0,
  `vibe/core/prompts/cli.md`): the structure and content are Vibe's —
  instruction hierarchy (critical vs overridable, AGENTS.md
  precedence, external data as data), blast-radius rules (one-time
  approval doesn't generalize; state action and radius in one line),
  ambiguity handling (one question, no strategy menus, no silent
  partial completion), stop-when-stuck tripwires (same error twice,
  no-op edit, three edits to one file → re-read fresh, change
  strategy after two failures), and the voice rules (concise is not
  curt, no filler words, phase-transition signaling) — with 3code's
  tool surface and rules substituted and the phrasing tightened for
  density. Per-model variation is two splices on the shared body
  (header, reasoning section) instead of replace chains against GLM
  wording; Large 4, Large 3/Medium 3.5, and the vibe-cli aliases all
  render from it.

0.8.1  prompt text selection and transcript search, provider refresh
       commands and CLI, kolibri-1 and tesseracted providers, macOS
       universal tarball and Windows console keys fixed

- **`:provider update <name>`.** Re-runs just the models step of the
  provider wizard: the offered list refreshes (curated registry in
  regular mode, the provider's `/models` endpoint under
  `--experimental`), Enter keeps the current selection, and the key,
  url, and name pass through untouched. `:provider edit` remains the
  full wizard.

- **`:provider new` / `:provider pull`.** `new` lists the models a
  provider serves that its config doesn't list yet (curated registry
  growth in regular mode, the `/models` endpoint under
  `--experimental`), across every configured provider or just one by
  name. `pull` brings those models into the stored list, scoped the
  same way or down to named models (`pull nvidia glm-5.4`); nothing
  is removed, and under `--experimental` each addition is verified
  with a one-token call first.

- **The macOS universal tarball was arm64-only.** The OSX workflow
  lipos the arm64 and x86_64 slices into `./3code`, then the test
  suite runs, and its first step rebuilds `./3code` natively, silently
  replacing the fat binary before packaging. Every macos-universal
  tarball since the workflow appeared, including the 0.8.0 release,
  was thin arm64: fine on Apple Silicon, `bad CPU type in executable`
  on Intel Macs. The fat binary now lives outside the workspace where
  the test rebuild cannot touch it, and the build fails loudly if
  either slice is missing. Intel users of the 0.8.0 release asset stay
  broken until the next release; a fresh install from main works once
  CI has rebuilt.

- **Tesseracted: Kolibri-1 without the GPUs.** Tesseracted Labs (Munich)
  is hosting Kolibri-1 behind an OpenAI-compatible gateway at
  api.tesseracted.com/v1 (free during launch week, key via
  tesseracted.com/kolibri-1-chat/developers); `:provider add tesseracted`
  prefills the url. The known-good row reuses the kolibri family
  (same prompts, same Hermes tool surface, tbCurrentTurn, 262144
  window per the gateway's own input+output cap), with two gateway
  differences: `applyKolibriReasoning` sends top-level
  `reasoning_effort` (true `none` for off) instead of
  `chat_template_kwargs`, and `allowPrivate` is off (third party,
  usage metadata retained ~31 days) so private mode stays opt-in.
  Output is capped at 16,384 tokens by the gateway (not the model).
  `tl_live_` joins the key-prefix catalog, so pasting the key names
  the provider.

- **The provider wizard masks api keys in its multipurpose field.**
  The first field (provider name, url, or key) echoes as typed so
  names and urls stay readable, but the moment the buffer reads as a
  key (a recognized key prefix from the first character, an
  unrecognized secret once it outgrows any provider name) the line
  repaints masked, so at most the pre-detection prefix ever reaches
  the screen. The dedicated api-key fields remain fully hidden reads.

- **Kolibri-1 known-good: first harness with curated support for Aleph
  Alpha's open-weight model.** Kolibri-1 (78B MoE, 3.46B active,
  German/English, Apache 2.0) is served self-hosted on vLLM with the
  official aleph-alpha-inference plugin; `:provider add kolibri`
  prefills `http://localhost:8000/v1` and the known-good rows cover both
  weight ids (FP8 and BF16) under the `kolibri` family (alias
  `alephalpha`). Reasoning is the model's own graded chat-template knob:
  `:reasoning` offers off/low/medium/high mapped to
  `chat_template_kwargs.reasoning_effort` / `enable_thinking: false`,
  matching what the `kolibri1` reasoning parser reads server-side.
  Thinking replay is tbCurrentTurn, exactly the chat template's own
  contract (a turn's tool loop keeps its thinking, older turns drop
  it). Sampling follows the model card (temperature 1.0; top_p/top_k
  come from the repo's generation_config server-side), context window
  curated at the recommended 262144, allowPrivate on (self-hosted).
  The XML tool-call fallback now also parses Hermes-style JSON bodies
  (`<tool_call>{"name": ..., "arguments": ...}</tool_call>`), Kolibri's
  native emission, alongside GLM's arg_key markup. Dedicated Kolibri
  system prompt, tightened to the output-contract style and grounded
  in the model card; the model was RL-trained across randomized
  harnesses and prompts, so it takes the house style without a
  special recipe.

- **Stealth models left the known-good registry.** The curated table no
  longer carries anonymous/stealth mounts: `stealth/space-bunny-alpha`
  (OpenRouter), `space-bunny-free` (Zen), and `omen-alpha` (OpenCode Go)
  join 0xalpha and union-alpha off the table; a different mechanism will
  cover stealth models. They stay runnable via `--experimental` with a
  family override, and their context-window / output-cap substring
  fallbacks and the OpenRouter `include_reasoning` streaming fix remain,
  so an experimental run behaves as before.

- **Markdown links are OSC 8 hyperlinks.** `[text](url)` now renders
  as a clickable span instead of raw syntax. The target stays visible
  in the text (bare `url` when the text is the url, `text - url`
  otherwise), so terminals without OSC 8 support still show, and
  regex-detect, the address; width/wrap math skips OSC sequences like
  it already skipped CSI, and the library's plain-text surface strips
  them.

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
