Changelog

Unreleased

- **Goal mode starts work again when you reopen an open goal.** A launch
  with `3code -r` used to idle on a session whose goal was still armed:
  the kickoff stanza was already in the scrollback, and the resume guard
  read that as "nothing to do" even when the last check had said the goal
  was not met. The work-owed state is now a session flag maintained where
  it changes - a verdict step landing in scrollback clears it, a kickoff
  stanza reaching the model or a user cancellation sets it - so no launch
  walks the transcript to reconstruct it. Result: work starts on its own at
  the two points where nobody has to press a key, the arm itself and a
  reopen into an open goal, and never on its own after a user cancellation
  (an unanswered prompt is left alone) or after a satisfied check (the
  goal is retired).

- **Flail detector's identical-consecutive signal is progress-gated.**
  A back-to-back re-run of the exact same call no longer flags when the
  first call's result delivered a new output line: a legitimate poll
  (20261123T121757: `sleep 570; tail -1 build.log` re-run while a compile
  ground forward, fresh progress line each time, escalation 1 fired
  anyway). A repeat over a stale result still flags on the first repeat
  as before; the mistral doom-loop session 20261007T100839 still
  escalates and aborts on replay.

- **An internal error mid-turn no longer ends the program.** The
  release-build last-resort net used to `quit()` on any exception that
  escaped the turn loop, so one bad turn took 3code down with it. The
  net now saves the session, reports the failed turn and its stack
  trace on stderr, and returns to the prompt; the next turn runs
  normally. Debug builds still re-raise for developers.

- **`:btw` reads as a question and its answer, and answers reliably.**
  The typed line lands as a `?`-led item holding the question alone
  (the `:btw` dropped, the goal kickoff's shape) and the answer lands
  under a dim `!` block instead of the speech balloon. An aside that
  came back empty did so because the meta-call replayed the history's
  `tool_calls` with no tools parameter and the model answered with tool
  calls of its own: the aside's context now flattens every tool
  exchange to prose (`[tool call]` / `[tool result]` lines). The side
  request retries like a normal one (429, 5xx and transport failures
  back off power-of-two, Retry-After honored, an empty 200 counts as a
  failure) and an "interrupted by user" cancels it along with the
  running turn, the question then closing with a dim
  `! interrupted by user` row. The library's `command()` returns the
  `?` line with the answer and reports a cancelled aside as
  `btw: interrupted by user`.
  (`tests/core/test_btw.nim`, `tests/tty/test_btw_async.nim`)

- **`:goal edit` opens the editor at once, on a terminal an editor can
  work with.** Typed while a turn runs, which in goal mode is nearly
  always, the command queued behind the turn like any mutating write,
  so the editor only came up minutes later, at the boundary. The input
  thread now runs the editor the moment the command is submitted (the
  decision over the edited text still runs at the drain, so only the
  controller's thread touches the conversation). Every external editor
  (`:goal edit`, `:sandbox edit`, `:cmd N edit`, Alt+E) also goes
  through one handoff: stdin back in cooked mode with bracketed paste
  and the kitty keyboard protocol switched off (an editor that does not
  know the protocol received its key codes as stray escapes and
  commands), the input thread parked for the editor's lifetime (it used
  to keep polling the same stdin and repaint the prompt over the
  editor's screen), and SIGINT ignored while the editor runs (Ctrl-C
  inside vim reaches the whole foreground process group, and the
  interrupt hook cancelled the running turn or quit at the prompt
  afterwards). 3code's raw mode is restored the moment the editor exits.
- **`:clear` arms a follow prompt.** `:clear <text>` resets the
  conversation and then sends `<text>` as an ordinary prompt on the
  fresh context, in one submit. Scrollback shows the clear's divider
  and the `❯` prompt item below it — the typed `:clear` line itself is
  not echoed, the same discipline as a mode-verb arm write. Bare
  `:clear` is unchanged. (`tests/tty/test_clear_follow_prompt.nim`)

- **Vi editing mode.** A conceptual port of readline's `vi_mode.c` —
  the machinery behind bash's `set -o vi` — as a new `threecode/vim`
  module layered on the line editor. `editing = vim` or
  `editing = both` in `[settings]` (readline stays the default); ESC
  (or a rebound `[shortcuts] vi-mode` key) enters command mode with
  the bash vi-mode set: h l 0 ^ $ w b e W B E f F t T ; , %, x X r ~
  D C s S, d/c/y operators with counts, cc dd yy p P u J, i a I A R,
  and `/` / `?` history search. In `both` mode every readline binding
  survives and ctrl keys keep their meaning; when the vi-mode key is
  ESC it is withdrawn from readline's cancel/clear so the same key
  switches modes, while any other `vi-mode` key leaves ESC alone.
  (`tests/core/test_vim.nim`)

- **Ask answers gain spelled-out commands and one-key shortcuts.**
  `:allow`/`:deny` are the spelled-out forms of `:a`/`:d`, and
  `:allow-dir` grants the path's directory (basename shaved when the
  path names a file); all three answer a waiting ask in bare form like
  the shorthands do. While an ask waits, Ctrl+1 fires `:allow`,
  Ctrl+2 `:allow-dir` and Ctrl+4 `:deny` (rebindable in `[shortcuts]`;
  kitty-protocol terminals, inert elsewhere), and `retry` moves from
  Ctrl+Shift+R to Ctrl+9. A mid-draft answer stashes the draft and the
  next prompt brings it back.
  (`tests/core/test_sandbox_ask.nim`, `tests/core/test_minline.nim`)

- **First run means no config file.** The provider wizard opened
  whenever no profile resolved, so a config that existed but defined
  no working provider (no url, no key, no models) landed in a wizard
  that refused every name with "already configured". It now opens only
  when there is no config file anywhere; an existing config with
  nothing usable warns `no usable provider in <file>. use :provider add
  to configure one.` and goes straight to the prompt. The tty harness's
  `[test]`-only config is IPC plumbing, not user configuration, and
  does not count; an empty or comments-only file does (someone wrote
  it), and `-C` still sees an existing user config.
  (`tests/config/test_first_run.nim`,
  `tests/tty/test_no_config_bootstrap.nim`)

- **A profile that no longer resolves falls through the rungs instead
  of surfacing as "no provider configured".** Resuming a session whose
  provider or model left the config since lands on the config current,
  the way `:resume` keeps what is running. When nothing requested
  resolves, the last rung takes another model on the current provider,
  then another provider in config order, and aligns `activeCurrent` so
  `currentProvider()`, `:model` and completion agree with the profile
  actually running; the old `limitproviders`-only fallback is that rung
  now. An explicit model that does not resolve stays empty so the
  caller reports it instead of silently switching.
  (`tests/config/test_resume_profile.nim`)

- **GLM-5.4 joins the catalog on both first-party z.ai endpoints.**
  `zai.glm-5.4` and `zaicode.glm-5.4` are curated: vision reaches the
  flagship GLM for the first time (5.3 needed its flash sibling for
  images), the window is 1M (launch tag `glm-5.4[1m]`), and the Coding
  Plan quota is 1.5x 5.3's. Reasoning keeps the 5.3 effort ladder -
  `low`/`high`/`max` ride top-level `reasoning_effort` - but 5.4 takes
  a true `off` again: `thinking {"type": "disabled"}` answers 200 on
  both endpoints where 5.3 hard-rejects it, so `:reasoning off` is a
  real knob instead of a silent no-op. Compaction treats it as a
  1M-context model and the output cap stays 131,072 like 5.3. Weights
  are closed, so hosted providers (openrouter & co.) get no rows.
  (`tests/api/test_api_pure.nim`)

  The image hints follow: every "cannot see" message (`@img` on a
  text-only model, `read` on an image, `:computer` on a non-vision
  profile) now names `glm-5.4 on zai` instead of the 5.3 flash sibling.
  (`tests/api/test_vision_read.nim`, `tests/core/test_attach.nim`)

- **The sandbox ask gate counts down and answers with `:a`/`:d`
  commands.** The ask card is one line - `:a to allow <path>, :d or
  wait Ns to deny` - with the deadline ticking down on it, and the
  a/f/d one-key shortcuts are gone: typing flows to the editor while
  an ask waits, so a draft is never interrupted, and the answer is a
  submitted command. `:a` allows the path the card names (flipping an
  identical ask rule in place, appending otherwise) and retries;
  `:d` - or the countdown hitting zero - denies, persisting an
  explicit deny rule the same way, so an unanswered ask and a denied
  one leave the same policy behind. `:a` and `:d` double as
  shorthands for `:sandbox allow|deny @d` (the last path an ask
  requested) at the idle prompt, an explicit path standing in for
  `@d`; a `:sandbox allow|readonly|deny|ask` command now prints
  itself to the model without the colon as an agent-sent user
  message, so the next turn sees the policy change, and every sandbox
  edit lands in scrollback as a one-cell `▤` icon row carrying the
  phrase and the edit's patch-style diff.
  (`tests/tty/test_sandbox_ask_prompt.nim`)

- **Ungranted /dev device nodes are masked, not merely unopenable.**
  Landlock gates open(2) but not stat(2) or faccessat(2), so a fenced
  command probing a world-writable node like /dev/kvm saw the live
  device owned by nobody:nobody (the namespace maps only the
  launching user) and `test -r && test -w` printed "rw OK" - rw
  access nothing would honor, with no denial for the ask gate to
  redeem. box.nim now binds a mode-0000 user-owned scratch file
  over every /dev device node the effective grants do not cover
  (baseline nodes, policy roots, and /dev/ptmx plus runtime-created
  slaves stay live, so pty allocation and `2>/dev/null` keep
  working): listings show an owned permission-less file instead of
  nobody's device, the probes fail, and a real open dies EACCES -
  the denial shape the bash ask gate scrapes where the policy
  floors the path at ask, so `allow /dev/kvm` at the prompt lifts
  the mask on the next launch and the device opens for real. An
  accumulated `allow /dev/pts`-style grant still exposes every
  live pty slave on the box - the user's rule to narrow, not the
  fence's to override. Runs that never entered a user namespace
  keep the true owner display and skip the mask; unavailable
  namespaces degrade with a notice like every other backend gap.
  (`tests/core/test_sandbox_devices.nim`)

- **The whitespace patch strategy anchors at the first match.** The
  collapsed-whitespace fallback (taken when the search block differs
  from the file by interior whitespace runs) kept scanning past its
  first hit and patched the last matching position, while the exact
  and indent strategies both take the first; a search block that
  squashes equal in two places now edits the first occurrence like
  its siblings. Surfaced by the new UnnamedBreak warning, which
  showed the loop's `break` bound to the inner candidate block.
  (`tests/shell/test_actions_extra.nim`)

- **A write to a sandbox policy file names the real rule: only the
  user can change sandbox rules.** The policy slots ride every load
  as hidden read-only guards no rule in the file can weaken, so a
  read/write/patch/apply_patch aimed at one always denied - but with
  the generic `is read-only (policy: ...)` text, which sent the model
  digging for a rule to edit instead of asking. The denial now says
  what the file is: `./.sandbox is a policy file (sandbox rules can
  only be changed by the user, :sandbox edit)`. Every slot spelling
  under any prefix asks that way - the legacy root `.sandbox`, the
  store `.3code/sandbox`, and the user `3code/sandbox` under the
  config root - matched against the hidden guard that denied, so a
  plain `readonly` rule keeps the generic text and reads of the
  policy stay allowed (the denial hint points the model at the file).
  (`tests/core/test_sandbox_cascade.nim`)

- **Catalog sweep: 98 delisted rows out, DeepInfra Hy4-preview in.**
  Every known-good row was re-checked against its provider's live
  `/models` list, and the 98 host+model pairs a provider no longer
  serves are gone, so `3code --good` stops recommending ids that 404.
  The aggregator hosts took the deepest cuts (33 rows across tensorx,
  opencodego and opencode: kimi k2.5 through k2.7, glm 5 to 5.2,
  minimax m2.5 to m3, mimo v2.5, the older qwen ids). OpenAI
  first-party retired o1, o3-mini, o4-mini, gpt-4.1-nano and the base
  gpt-5.6 (the sol/terra/luna splits stay), xAI and OpenRouter
  dropped grok-build-0.1, xiaomi delisted its first-party mimo v2.5,
  and nebius dropped its GLM-5.1. Every model survives on each host
  that still lists it - only the dead pairs left the table. One
  addition: DeepInfra joins OpenRouter and tencent for
  `tencent/Hy4-preview` (DeepInfra's capital-H spelling, the same
  quirk as its Hy3 row) with the catalog's full 1,048,576-token
  window and the same high/no_think reasoning ladder
  (`tests/api/test_api.nim`, `tests/config/test_provider_wizard.nim`).

- **A resume replays the goal verify, not just its consequences.**
  The turn-end satisfaction check's verdict row (the `✓`/`✗` quote
  block) was display-only: nothing persisted it, so `3code -r` -
  loading scrollback from disk - dropped every check the session had
  run. The resumed scrollback showed the `⚑` goal-check continuation
  with the verifier's feedback embedded as text, but the verdict row
  itself (its icon, its own prose, its position between the reply it
  judged and the continuation it caused) was gone, and a satisfied
  history showed no `✓` at all. Each verifier step is now recorded on
  the session anchored to the message position it was committed at,
  written into the `.3log` as a `goal_check verdict=...` record at
  exactly that spot, and replayed through the same formatter the live
  commit used - replay/live parity restored, the rebreak window
  included (it renders from the same anchored records). The boundary
  that falls through without appending a message (SATISFIED retires
  the goal, a failed check without a discipline note) now checkpoints
  the session so the row reaches disk before the session idles;
  `:clear` and every compaction drop the records with the conversation
  they described, and the cybernetic mode's steps ride the same
  machinery
  (`tests/core/test_session.nim`, `tests/tty/test_goal_mode_ctrlr.nim`).

- **The sandboxed shell runs as you, not as nobody.** sandwall enters
  a user+mount namespace for the deny masks (and the network fence)
  and composed the namespace's id-map writes from ids read only AFTER
  unshare(2) - by then they already showed as the unmapped overflow
  65534, the kernel rejected the "0 65534 1" line (an unprivileged
  writer may map only its own id), sandwall degraded, and every
  fenced command ran stranded in an unmapped namespace: `id` said
  `nobody` while the inherited env said `USER=carlo`, every file in a
  listing read `nobody:nobody`, ssh and git tripped over a passwd
  home of `/` and dubious repo ownership, and a sandboxed agent
  naturally misread its own project as remotely owned. The fix
  belongs in sandwall and only there: the kernel binds a /proc
  id-map file to the task's user namespace at OPEN time and checks
  the write against the opener's credentials, so no wrapper-side fd
  trick can reach the stranded namespace (a pre-unshare handle names
  the immutable initial map; a handle opened after restrict() is
  EACCES under the Landlock domain). sandwall 0.5.15 reads the
  ids BEFORE the unshare and self-maps the user onto themselves, so
  the confined tree sees the world as the user who launched it;
  the manifest now requires sandwall >= 0.5.15. The box driver
  keeps a degrade guard (box.nim repairUsernsIds): it detects a
  still-unmapped namespace -
  sandwall too old, a nested run from an already-unmapped namespace
  where no outer id is expressible, or a run nested under an outer
  Landlock domain that denies the map-file opens outright - and says
  so instead of failing the run (`tests/core/test_sandbox_userns.nim`).
- **The token bar sums every side call at a rest, never just the
  latest.** A rest's token bar is the SUM of its requests - the turn's
  final call plus each harness side call that landed on it - but the
  side-call accounting recomputed that sum from the turn's usage plus
  the side call being handled, so a second side call at the same rest
  (a goal check plus a `:btw` answer arriving in the same idle, a
  retried check) REPLACED the earlier one's contribution on the bar
  instead of adding to it, and the resting gauge the next submit
  painted from the pending hint dropped back to the turn-only numbers:
  the bar showed one request's tokens or the other's, never the sum.
  `accountSideCallUsage` now accumulates: the base is the pending hint
  when one is armed (an earlier side call re-arms it with the running
  total), else the last assistant usage on the wire (the streamed-reply
  turn end consumes the hint into its receipt), and the sum re-arms the
  hint so the bar, the submit-time resting gauge, and the receipt the
  next submit commits all carry the same total. A rest whose calls
  painted no usage at all still shows the side spend - real spend is
  never dropped from display (`tests/core/test_goal.nim`,
  `tests/tty/test_goal_mode_ctrlr.nim`).

- **`nimdiff` is the diff engine.** The in-tree O(n*m) LCS (`lcsOps`)
  and its unified renderer are deleted; `computeDiff` keeps its
  signature and output contract but delegates to the `nimdiff`
  package - Myers O(ND) in its linear-space divide-and-conquer form,
  linked in as a library (zero forks, zero git, same stock-Windows
  story), pinned in `nimble.lock`. One engine now serves every diff
  in the binary: write/patch/apply_patch tool results, shell-mutation
  captures, and the goal-mode session feed. The input caps (256 KB
  combined / 5000 lines) retired with the DP table they guarded -
  the measured hazard was the 2 GB table, not the rendering, so a
  300 KB pair now renders real hunks in milliseconds instead of a
  name-only line, and the session feed's own per-path and total caps
  still bound what reaches the verifier. 3code's stricter binary
  classifier (ANSI-aware, 512-byte scan) stays at the wrapper
  boundary - nimdiff's NUL-only git rule would let control-character
  soup through (`tests/core/test_session_diff.nim`,
  `tests/shell/test_actions_text.nim`,
  `tests/shell/test_actions_extra.nim`).

- **Gemini 4 Carbon, Neon and Hydrogen join the google table, and
  `xhigh` arrives as a thinking level.** The 4.x family outgrew its
  single Argon row: Carbon (flagship), Neon (Nov 18, adapted from
  Carbon for long-running agent workflows) and Hydrogen (Flash
  successor) share Argon's wire surface - 1M unified window, 64k
  streamed output, thinking low/medium/high, no `minimal`, no off -
  so they share the row shape; Carbon defaults to `high` like every
  Pro tier, Neon/Hydrogen to `medium`. Neon and Hydrogen additionally
  accept an `xhigh` reasoning_effort above high (Carbon and Argon stop
  at high), wired through `knownGoodReasonings` and
  `applyGeminiReasoning`; `:reasoning xhigh` was already valid input
  for the grok/claude/gpt ladders, so only the gemini branches needed
  widening. Rows verified against the live `/v1beta/models` listing;
  chat turns themselves still await an AI Studio prepay top-up (402 on
  every call today).
- **Gemma 4 open weights are curated on google and venice.** The same
  generativelanguage endpoint chat-serves the gemma-4-31b-it /
  gemma-4-26b-a4b-it open models (262k context, 32k output cap), and
  venice serves the pair under flattened ids. They have no thinking
  surface, so the rows ride the `other` family: no reasoning level is
  offered or sent (`:reasoning` lists nothing for them, the first
  curated residents of that bucket). `maxOutputTokensFor` caps gemma-4
  at 32k so the escalation ladder stops at the weights' real ceiling
  instead of climbing to the 262k context figure.
- **Shift+Space types a space again.** Kitty-protocol terminals (kitty,
  Ghostty, foot) report shift+space as `CSI 32;2 u` because space has
  no shifted glyph to send as text, and iTerm2/xterm with
  modifyOtherKeys send `CSI 27;2;32 ~`; the CSI-u decoder had no case
  for the space key code, so the press vanished instead of typing.
  Space with only Shift (or no modifiers) now inserts a space;
  ctrl/alt/cmd+space chords stay unbound keys
  (`tests/core/test_minline.nim`).
- **Arming a goal mode takes a real snapshot: the fold diffs actual
  before-bytes.** Arming walks the project once (the manifest is still
  the cheap stat layer, now keyed by mtime, size and inode) and copies
  the walked set into `.3code/snapshot/` - a plain portable copy on
  the same volume, no git, no kernel facilities (the platform copy
  syscall picks up any clone acceleration for free). Every session
  mutation - tool writes, opaque shell work, deletions, renames - now
  has real before-bytes at the fold: a deleted or `python
  rewrite.py`-rewritten file renders a true minus-diff instead of the
  `changed via shell (original not captured)` marker, and a rename
  folds as one renamed entry instead of a delete+create pair (inode
  identity carries it). The marker floor survives only for paths
  mutated before the arm or past the store caps (1 MB per file, 64 MB
  per arm; past the budget a path keeps detection but not
  before-bytes). Re-arm while armed copies only the delta; disarm
  deletes the store. The walk now speaks gitignore syntax through a
  three-tier cascade - global defaults (`~/p/nimignore`, else the
  embedded copy: VCS internals, dependency trees, build caches,
  `.3code/` itself), the per-directory `.gitignore` chain
  deepest-wins, and `.3code/ignore` as the override, always last, `!`
  negation included; a directory is pruned only when no anchored
  negation from any source could match beneath it, so `build/` +
  `!build/output.txt` keeps `output.txt` reachable (git cannot do
  this). `computeDiff` gained input caps (256 KB combined
  before/after, 5000 lines) past which the pair degrades to a
  name-only line: the O(n*m) LCS table costs 810 ms and 2.0 GB peak
  RSS on a 520 KB pair, measured. Fifos and device nodes never enter
  the manifest - opening a leftover fifo read-only would hang the
  fold, and now the store copy too (`tests/core/test_ignore.nim`,
  `tests/core/test_session_diff.nim`).
- **`:retry` sends the current state as a request.** Bare `:retry`
  (and the Ctrl+Shift+R `retry` shortcut) is the empty submit now: it
  queues exactly what Enter on an empty prompt queues, and the
  controller answers with a turn that sends the conversation as it
  stands - no user message appended, nothing echoed beyond the command
  line. It needs an ongoing conversation (a system-only session has
  nothing to continue); at idle without one it does nothing. It never
  interrupts a request in flight or cuts a backoff short: typed while
  a turn runs, the submit lines up behind it and fires when the turn
  yields. The retry-now design this replaces - cutting a backoff wait,
  resending a data-less in-flight request, the `retryCut` scrollback
  hook, the `instant retry requested` line - was removed before ever
  shipping. Ctrl+R stays history search; the two are only
  distinguishable on terminals that speak the kitty keyboard protocol
  (the CSI-u decoder keeps ctrl+shift+letter a distinct key, falling
  back to the readline ctrl+letter meaning when nothing binds it),
  rebindable as `retry` in `[shortcuts]`
  (`tests/core/test_command_prefix.nim`, `tests/tty/test_retry_fixes.nim`).
- **Launching from a deleted working directory refuses with a straight
  error.** A terminal left in a directory that was deleted or renamed
  away (a rebuilt clone, a tmpclean sweep) crashed 3code at startup with
  an unhandled `getCurrentDir` OSError - a bare stack trace painted over
  the splash. Every frontend that roots its session at the process cwd
  (the TUI, oneshot prompts, `--headless`, `--gui`, `--rpc`) now checks
  the cwd up front (`requireLiveCwd`) and exits with
  `the working directory no longer exists (/vanished/path) — change to
  an existing directory and start 3code again` (exit 3; headless stays
  silent, the exit code reports). Without the gate the session would
  have silently re-rooted at `/` via `safeCwd`, pointing the sandbox
  policy, dir settings and session files at the wrong directory. Cwdless
  fast exits (`-v`, `-h`, `-l`, `-f`, `provider`, plugin subcommands)
  still answer from a deleted one, and `--acp` is exempt because its
  sessions root at the client-supplied cwd, not the process's.
- **Ctrl+R recall accepts on arrow keys, like the command line.** An
  incremental search ended by any key it does not own (Right, Left,
  Home, C-a, ...) used to abort back to the latest prompt, dropping
  the match you had found. Those keys now end the search keeping the
  shown match loaded for editing and then act on it, the way
  readline's ENDSRCH_CHAR termination does (C-g still aborts and
  restores the pre-search buffer).

- **Environment variables are gone: every runtime knob lives in the
  config file.** Every project-prefixed env variable (`ALLOW_ROOT`,
  `DEBUG_LOG`, `TRACE_FILE`, `TERMDBG`, `FORCE_SYNC_OUTPUT`,
  `ASK_TIMEOUT_MS`, `SCREENSHOT_SRC`, `GEOMETRY_AUDIT`,
  `PLUGIN_SYNC_MS`, `PLUGIN_TOOL_MS`, `STUB_*`, the harness channel),
  the loopback-proxy handoff between the sandbox parent and the
  `sandbox restrict` / `wall connect` children (now an internal
  `[wall]` file passed as `--config`), the search-engine-key
  env fallback, and `$VAR` expansion of config values are
  replaced by config keys (full variable-by-variable record:
  `docs/env-to-config.md`): user knobs in `[settings]` (`allow_root`,
  `debug_log`, `trace_file`, `termdbg`, `force_sync_output`,
  `ask_timeout_ms`, `google_project`), plugin tuning in `[plugins]`
  (`sync_ms`, `tool_ms`), harness hooks in a new `[test]` section, all
  served through the new `src/threecode/runtime.nim` store and
  cascading from the nearest directory store like every other
  `[settings]` key (see `docs/reference.md` "Runtime knobs"). No env
  fallback, no migration.
  The tty test harness merges the `[test]` channel (fd/pipe ids) into
  the child's config file; test-runner controls that were env switches
  (the tty-scenario filter, golden regeneration, build lock timeout,
  prebuilt-stub handoff) became CLI arguments or small config files,
  as did the installers' knobs (`sh install --dir=… --allow-root`,
  `install.ps1 -InstallDir …`) — they pass through the pipe via
  `sh -s --` / scriptblock parameters, so no pre-config env channel is
  left either. What stays env, deliberately: OS-standard variables the
  binary consumes (`XDG_CONFIG_HOME`/`XDG_DATA_HOME` — config
  discovery — `PATH`, `HOME`, `TERM`, `DISPLAY`, proxy vars for
  sandboxed grandchildren).
- **Goal mode's post-bash tree fold no longer hangs on a FIFO left in
  the project.** The fold reads back every path the manifest walk
  recorded, and Nim's `walkDir` reports a FIFO as a plain file, so a
  command that leaves one behind (a test suite's `mkfifo` fixture in
  `build/tests`) made the next fold `readFile` it: opening a FIFO
  read-only blocks until a writer appears, and none ever does. The
  session froze outside every cancel window (the bash timeout and the
  Ctrl-C/Esc watchers were already torn down; a resumed session in a
  repo whose tests leave such a fixture sat 25 hours in `fifo_open`,
  dead to Ctrl-C and Esc). The walk now passes `skipSpecial`, so FIFOs
  and device nodes never enter the manifest, and a special file that
  disappears later folds as a name-only deletion
  (`src/threecode/snap.nim`, test in `tests/core/test_session_diff.nim`).
- **Every `[settings]` key cascades now, and there is a provider
  whitelist: `limitproviders`.** The resolution ladder for any setting
  is: the compiled default, then the user config
  (`~/.config/3code/config`), then the nearest directory store
  (`./.3code/config`, or its twin under `~/.config/3code/dirs/` when
  the user config says `dirconfig = "user"`) — previously only the
  sandbox switches and `current` cascaded; every other key ignored the
  stores. The exceptions stay deliberate: `dirconfig` is read from the
  user config alone (a store can never relocate the stores, or it
  would grant itself authority), and the two sandbox switches keep
  their one-way clamp (a project store may tighten, never weaken).
  The one dialect is factored into `applySettingsValue`, shared by the
  config parse, plugin defaults and the new `applyDirSettingsOverlay`,
  so a store line behaves exactly like a user-config line. Config
  writes never leak a store's value into the user config: while a
  store overlay is in effect `writeConfigFile` serializes the user
  config's own line (or omits it at the default), and an in-session
  toggle (`:streaming off`, `:verifier on`, ...) claims its key so the
  user's explicit choice persists. The new `limitproviders` setting
  (default empty = no restriction) whitelists providers for a
  session: profile resolution, `:provider`/`:model` picks, completion
  and the verifier pool offer only allowed providers, a configured
  `current` outside the list falls back to the first allowed one, and
  provider management (`:provider add/edit/rm`, the CLI) keeps the
  full list so a limited directory never loses the providers it
  cannot run (`src/threecode/config.nim`, `src/threecode/dirsettings.nim`,
  tests in `tests/config/test_dirsettings.nim`,
  `tests/config/test_limitproviders.nim`).
- **The provider default, when nothing else names one, is the most used
  provider.** A config without `current` (fresh installs, a removed line)
  used to fall to the first `[provider]` section's first model — an
  accident of file order that read as a mystery "system default". Every
  start now counts in a tiny ledger (`~/.local/share/3code/provider-usage`,
  one `provider.model count` line per current, highest first) and the
  no-`current` floor picks the ledger's top entry that still resolves:
  the provider you actually run, and never a provider since deleted.
  Nothing changes when `current` is set or a directory's `.3code/config`
  store cascades one down — explicit picks keep winning, and a start on
  any of them counts toward its next default (`tests/config/test_most_used.nim`).
- **Backspace at column 0 of a multiline draft no longer leaves the
  rows below the caret in the wrong place.** The editor's row-diff
  painter paired rows by the caret's row movement, but the repaint is
  anchored at the block top; joining two lines (backspace with the
  caret at column 0) raises every row below the caret by one, and the
  risen row's text matched the vacated row below it, so the diff
  skipped repainting it, leaving the stale un-joined line on screen
  while the shrink cleanup erased the row that held the moved text.
  The diff now pairs rows by absolute block row, matching where the
  repaint actually paints them (`src/threecode/engine.nim`
  `paintVolatileRegion`, regression test in
  `tests/tty/test_tty_functional.nim`).
- **Config is a layer stack: project-local `.3code/config`, repeatable
  `-c`, and `-C` to clear.** 3code used to read exactly one config file;
  a repository can now pin providers, models, and settings for everyone
  who opens it — `.3code/config` discovered by walking up from the
  working directory applies as the last (strongest) layer, with `key`
  and `url` inherited from the user config when the project file omits
  them, so API keys stay out of committed files without duplicating
  provider definitions. `-c FILE` is repeatable (later files win per key
  and replace the user config, preserving the old single-`-c` isolation
  meaning), and `-C [FILE]` clears the stack — implicit layers included
  — for testing or for ignoring a repo pin. `current` from the project
  layer owns model selection (the per-directory sticky cannot defeat
  the pin), the security switches stay under the one-way project-store
  clamp (a repo may tighten, never weaken, and cannot relocate stores,
  nor silence the root refusal: `allow_root` is user-owned too), and
  writes still target the user config (or the last explicit layer):
  definitions from other layers are never copied into it and the
  project file is never written. Every layer validates with its own
  `path:line` errors, `3code -h` prints the exact read stack and write
  target, and rpc/acp take the repeatable flags too.

- **`:btw` never blocks the prompt anymore.** The side question fired
  its meta-call synchronously, freezing the UI for the whole round
  trip. It runs on a worker thread now (`btwthread.nim`): the command
  answers with a `💬` receipt at once, the answer lands asynchronously
  as a dim `💬 │` quote block whenever it arrives, and its burned
  tokens are added to the session ledger and onto the token bar as the
  sum of both requests (the goal-check accounting generalized into
  `accountSideCallUsage`). Added a dev-guidelines rule while at it
  (docs/dev.md): a system command must never block - its work happens
  on a separate thread and the result is delivered async, like a
  normal one.
- **A stream cut mid-reply retries instead of ending the turn.** A
  200 OK whose SSE body dies after partial deltas - no `finish_reason`,
  no `[DONE]`, no usage - used to be handed back as a complete
  assistant turn: half a sentence hit the scrollback ("Booting.
  Polling until the guest agent"), the `· Xs` bullet vanished, and the
  prompt returned as if the model had finished, no error, no token
  line. The truncation guard flags the cut as a retryable transport
  error so the request resends through the normal backoff curve (the
  patient curve rides out provider blips for hours); if every attempt
  dies, the turn ends with the network error committed to scrollback
  instead of a silent half answer. Same fix on the /responses path:
  EOF before `response.completed` no longer builds a partial message
  from the accumulator. The guard is armed again after its June-2026
  disable (the phantom-EOF TLS bug in streamhttp that starved it is
  fixed, `>= 0.2.0`), with one refinement: a stream that delivered
  `usage` counts as complete, so gateways that close after the final
  usage chunk without `[DONE]`/`finish_reason` never trip it.

- **Relace is a provider, live-tested on every model.** Relace's hosted
  open-weight coding line (GLM 5.2/5.3/5.3-flash, six DeepSeek V4/V4.1
  ids, Kimi K3 and K3.1 Pro) sits behind one `rlc-` key at
  `models.relace.ai/v1` - `:provider add` infers the provider from the
  key prefix alone. Eleven known-good rows, all 1M context; every one
  answered a real headless turn. The weights are fp4-quantized (per
  their /models catalog, noted in the manual), and kimi-k3.1-pro is in
  the live catalog though their docs table omits it. GLM-5.3 and the
  deepseeks ride the generic hosted-stack `reasoning_effort` knob,
  kimi takes the vLLM `enable_thinking` bool; their purpose-built
  apply/search models are separate non-chat endpoints and stay off
  the table.
- **System commands are prompt-log content now.** Commands submitted
  while a turn runs (`:retry`, `:model x`, ...) never reached the
  history file: the command hook's commit cleared the editor before
  readLineWith's own historyAdd ran, so the line could not be recalled
  with Up or Ctrl+R. Every submitted command is recorded at submit
  time now, exactly like a typed prompt (the idle path records before
  the controller's echo commit can race it).
- **GPT-6.2 Astra is known-good, live-tested through the ChatGPT
  backend.** The safety-cancelled 6.1-Astra line's successor shipped
  Nov 17: same 1.05M context, 128k output cap and text+image surface as
  the gen-6 line, and still rejects effort `none` — the ladder is
  low/medium/high/xhigh/max, base and pro alike. Rows: first-party
  `openai` (table-verified against the model page), OpenRouter and
  nano-gpt base + pro (both in their public /models catalogs; Venice and
  Cheaperinference have not listed it yet). The `chatgpt` twin resolves
  through the openai catalog and was verified live: a headless run
  against chatgpt.com/backend-api/codex streamed a real answer from
  `gpt-6.2-astra` at the table's medium effort (2k fresh tokens) — the
  slug serves even though the backend's /models listing still shows
  only 6.0/5.6. Wire shapes are shared with 6-astra: /responses with
  `reasoning.effort` and no temperature, `max_completion_tokens` on
  completions (`tests/api/test_api.nim`, `tests/api/test_prompts_compact.nim`,
  `tests/config/test_modelname.nim`, `tests/config/test_vision.nim`).
- **Bash children inherit the full 3code environment, and that is now
  policy, not accident.** Nothing filters variable names: anything the
  launching shell exported (`PASSWORD_STORE_DIR`, `DISPLAY`, tokens)
  reaches the command unchanged, and a test asserting that
  credential-shaped names pass through makes any future scrub a
  deliberate, visible change. The wrapper's fixed hygiene overrides
  (`PAGER=cat`, `TERM=dumb`, `NO_COLOR=1`, friends) are unchanged. The
  manual's sandbox chapter documents the boundary: the fence covers files
  and network, never the environment, and prompt-shaped tools still have
  no terminal (`export GPG_TTY=$(tty)` in the shell that starts 3code
  routes gpg-agent prompts to your terminal).
- **The bash tool runs in the shell 3code was started in, and never
  falls back to sh.** POSIX resolution was bash-only: `shPath()` picked
  `bash` from PATH or the standard locations and never looked at the
  login shell, so a zsh user's PATH (set in `.zprofile`) and any
  zsh-specific environment were invisible to every tool command. The
  order is now: a `bash_path`/`bash` config override, then `$SHELL`
  when it names a working bash-compatible shell (probed with a real
  `echo` one-liner, so a dead binary from a removed install or a
  `chsh` without install falls through), then bash, then zsh — and
  nothing else. The sh last resort (Termux `$PREFIX/bin/sh`, Alpine
  busybox) is gone: silently running a shell that rejects the
  language the prompts teach is the bug the bash-first order exists
  to prevent, so a host with no bash-compatible shell now halts with
  an error naming the fix instead of degrading. Non-bash login shells
  (fish, nushell, elvish, xonsh, csh/tcsh, and the plain-POSIX
  sh/dash/ash/ksh family) are skipped in favor of the fallbacks: the
  tool's contract and every prompt teach bash syntax, and those
  shells parse a different or reduced language. The resolution is
  memoized per thread; tests reset the cache to pin `$SHELL` per
  case.
- **Command prefixes are configurable: `system-command-prefixes`.** The
  hardcoded `/help` synonym is gone, replaced by a general mechanism:
  `[settings] system-command-prefixes = ": /"` makes every listed
  character introduce commands exactly like `:` — same recognition,
  dispatch, tab completion (the typed prefix is kept: `/he` completes to
  `/help`, never `:help`) and unknown-command errors. Each non-whitespace
  character of the value is one prefix, whitespace between them is
  optional (`:/` ≡ `: /`), duplicates are ignored, and a later line
  replaces the set; an empty value is a config error. The default `:`
  keeps existing sessions byte-identical in behavior except one thing:
  `/help` is no longer a built-in synonym — under the default it is
  ordinary prompt text, like `/foo` always was, so slash-prefixed paths
  and URLs never risk command interpretation. Users who want the slash
  form enable `system-command-prefixes = ": /"` (`src/threecode/util.nim`
  `colonForm` centralizes recognition; `tests/core/test_command_prefixes.nim`,
  `tests/config/test_command_prefixes.nim`).
- **The goal-mode snapshot landed: a cross-platform, filesystem-independent
  copy-on-write manifest replaces every git call.** The satisfaction
  check's second input used to shell out to `git status` / `git diff
  HEAD` — empty outside a repo, dependent on a git binary, and blind to
  which changes were the session's own. That feed is gone; the session
  change log is now the whole record, and it learned to see shell work:
  arming a mode takes one stat walk of the project (path, mtime, size
  per file — a manifest, no content copies), and after every bash run a
  re-walk folds each signature that moved into the change log like any
  write tool's target (`snap.nim`). `python rewrite.py`, a build, a
  `tar xf` now record; the command-line scraper's one-path-per-command
  limit no longer bounds what the log sees (it keeps its other duties:
  read-cache invalidation, ask-gating). Copy-on-write stays the capture
  rule — originals are copied at first observed mutation, never up
  front — so nothing assumes reflinks, APFS/btrfs, or hardlinks and it
  works on any filesystem on any OS, the bundled bash on Windows included.
  A path first seen already mutated by an opaque command has no
  recoverable original: it renders with an honest `changed via shell
  (original not captured)` header plus the current content instead of a
  fabricated before-state, and deletions render name-only. Oversize
  mutations (1MB/file, 4MB/run budgets) and binary content degrade to
  name-only lines; `.git`, `node_modules`, and build caches never enter
  the manifest. All of it arms only with a mode: no `goal.md`, no walk,
  no fold, no diffing — the change log outside goal mode records exactly
  what it always did. The verifier preamble now names the change log as
  an input, and a session inside a git repo gets the same prompt as one
  outside (`tests/core/test_session_diff.nim`).
- **Qwen4-Max joins the known-good table with graded reasoning.** The
  hybrid model takes a top-level `reasoning_effort` (low/high/xhigh,
  default high) alongside `enable_thinking` on DashScope, and
  OpenRouter normalizes the same levels to `reasoning.effort` with
  `reasoning.enabled=false` to cut thinking entirely; `applyQwenReasoning`
  now routes the `qwen`/`4` family to the right shape per provider. The
  1M context window lives in `contextWindowFor`, output is capped at
  262,144 (thinking + answer together), and `knownGoodReasonings` lists
  off/low/high/xhigh. Vision on the OpenRouter row was earned by a live
  probe that read ZORB off a real image; first-party stays unmarked
  until probed (`tests/config/test_vision.nim`).
- **Multiline goal text now indents under the `⚑` kickoff item.** A
  goal (or plan) description with multiple lines rendered its
  continuation lines flush at column 0 - only wrapped rows were indented
  under the flag - so a multi-paragraph goal read as a stack of separate
  items instead of one. The `⚑` item now indents every continuation row
  by two chars, matching the user echo and every other scrollback item
  (fix in `formatAgentPromptItem`, live arm and replay alike).
- **Windows asks before a per-file ask rule is pierced by a fresh
  create.** A deny (and an `ask`, which denies until answered) naming a
  file that did not exist yet was shadowed under the Windows ACL
  backend: with no object to stamp the DENY ACE on, the child created
  the file through the parent dir's inheritable ALLOW and `echo granted
  > vault/out.txt` under `allow ./` + `ask ./vault/out.txt` succeeded
  silently - no denial, no ask card, policy unchanged. The denied
  target is now materialized (empty file, or directory when it carries
  no extension) before the run so the ACE bites, and deleted again
  after the run when nothing landed in it, so a declined ask leaves the
  filesystem exactly as it was (sandwall's windows-user backend). The
  bash ask gate,
  the ask-path scraper, and the sandbox deny hint now also recognize
  the Windows `Access is denied` shape (cmd.exe and native tools; msys
  bash already prints `Permission denied`).
- **Ask card keys can no longer leak into the prompt draft.** The
  sandbox ask gate armed only after the whole question card had painted,
  so a decisive keypress sent (or typed) while the card was still
  rendering landed in the editor draft instead of the gate - the ask
  then timed out and denied. The gate now arms before the first card
  line renders and every keypress while it is armed diverts to the
  answer. The Windows tty harness rides the same fix: the test IPC
  channels cross the ConPTY spawn as named pipes (handle inheritance
  kills a pseudoconsole child outright on Win11), so the child's
  renders are paced against the harness the way they are on POSIX.
- **A grant now materializes the repo policy when only the default
  text is active.** The sandbox ask gate fires from the built-in default
  policy when no policy file exists anywhere, but a grant written in
  answer to it looked for the file, found none, and treated the ask as
  denied - the yes silently did nothing. The grant now writes the repo
  policy file from the effective text first, so the appended allow has
  a home the cascade reads.

- **A `:provider` switch sticks per-directory and stops hoisting into
  the config floor.** A directory's sticky `current` held a provider
  that differed from the startup baseline without an in-session
  switch, and the config merge read that difference as this instance's
  own switch: every unrelated write (`:reasoning`, `:streaming`, ...)
  hoisted the directory's pick into the user config, so the global
  `current` kept moving to whichever directory wrote last. The merge
  now keeps the disk's floor whenever it still resolves and repairs it
  with the caller's value only when its provider is gone; the
  `dirStickyCurrent` marker hack that tried to spot sticky boots is
  gone with the failure mode.

- **A 400-recovery collapse can no longer keep a tail too big to send.**
  The collapse pins tool results to their owning assistant, so one
  batched run of ~1900 tool calls survived it intact: the rebuilt
  request blew the route's byte limit again and the retry 400'd exactly
  like the call it was recovering from, bricking the session. The
  retained tail now also sheds its oldest entries head-first until the
  rebuild fits the byte cap, and the pairing repair makes the survivors
  legal again (orphan results drop, unanswered calls get synthetic
  results).
- **A hung provider can no longer wedge a worker thread for the life of
  the process.** The network worker was owned by the frame that spawned
  it: an interrupt cancelled the call but the thread stayed parked in an
  uninterruptible resolver or connect, every later call queued behind
  it, and a caller that gave up leaked the thread plus its connection
  caches. Workers are now heap-owned and retired by budget: a caller
  whose join budget expires moves on, a retired worker that finally
  wakes exits safely instead of writing into a dead frame, connection
  caches live with the job rather than the thread, and repeated short
  calls leave no live jobs, retired jobs, or locks behind.
- **Transcripts save atomically, and a failed save is never a silent
  success.** `saveSession` used to overwrite the live `.3log` in place
  and swallow errors into a stderr line: a truncated or half-written
  transcript silently replaced a valid one, and a failed first save was
  still indexed for resume. Saves now stage into a unique sibling file
  that is owner-only from creation (no world-readable window for prompt
  contents), fully written, flushed and synced before the atomic
  rename commits, so a failure leaves the previous transcript
  byte-for-byte intact and reloadable. The failure raises
  `SessionSaveError` instead of vanishing: a blocking library `prompt`
  surfaces it to its caller, headless runs exit non-zero, the RPC and
  ACP frontends answer with an error instead of a false `end_turn`, and
  interactive checkpoints report once per failing streak (the next
  committed save clears the latch) while the conversation stays in
  memory. The resume index is appended only after a real commit and
  self-heals on a later save. Prompt drafts stage through the same
  owner-only mechanism.
- **Session and directory locks are kernel-owned, not pid-file
  guesses.** Locking was an O_CREAT|O_EXCL race on a file holding the
  owner's pid, with liveness probing and a remove-and-retry dance to
  recover from crashes; a `kill -9`ed 3code left a stale file behind and
  a spawned tool process that inherited the fd could keep the lock alive
  after its parent died. The claim is now a kernel-level exclusive lock
  held open for the life of the process: a crashed or killed owner's
  session and directory are back the instant the process is gone, with
  nothing to delete, a non-owner's release cannot disturb someone
  else's hold, and a collision report names the live holder (pid and
  session id, plus the lock file). The lock files under
  `$TMPDIR/3code/lock` and `$TMPDIR/3code/dirlock` stay on disk as
  stable lock targets, emptied of owner text; a lock held by an old
  pre-kernel-lock release is still refused via its pid line, but mixed
  old/new versions are not fully mutually exclusive, so don't run them
  against the same session or directory.
- **`update` replaces a renamed executable in place.** The updater
  mapped the archive's canonical binary member to its own name (`3code`),
  so an install the user had renamed (a `3code-mine` on `PATH`, the
  `updatehandler` copy) gained a fresh `3code` sibling while the
  renamed binary they actually run went stale. The archive's binary now
  lands at the destination's real name and only the runtime library
  files are installed beside it; a bundle without the canonical binary
  member is rejected before any file is touched, as is a destination
  whose name would collide with a non-documentation bundle member.
- **Sessions have an enforced lifecycle, and switching is truthful when
  it fails.** The library `AgentSession` moves through an explicit
  idle → running → closing → closed state and every public call gates
  on it: a turn submitted into a closed or closing session raises
  `AgentError` before touching hooks, files, model state, or tools, a
  second concurrent submission (a `prompt` while `promptAsync`'s turn
  is in flight, or vice versa) is refused with the same error instead
  of racing through the conversation, and `close` refuses mid-turn
  (interrupt and join the turn first) and is safe to repeat. Failed
  initialization now releases every lock and hook it had already
  acquired instead of stranding them, and `promptAsync` returns a
  `TurnHandle` to `joinTurn` on rather than a raw thread. A failed
  transcript save is no longer swallowed: `close` reports the failure
  only after locks, hooks, and plugins are fully released, and the RPC
  and ACP frontends answer such a turn with an error instead of a
  false `end_turn`. Session replacement in both frontends goes through
  an explicit sessionless gap: the old session is closed and its
  identity dropped before the new init runs, so a failed switch leaves
  the frontend honestly sessionless (empty session id, `initError`
  naming why) and a later valid open recovers.
- **A `:provider` bail-out commits like an ordinary command.**
  Commands that never open a wizard field - `update`/`edit`/`rm` on an
  unknown name, usage errors, the read-only `new` report - now echo the
  typed line as scrollback, print their body under it, clear the editor
  to a fresh `❯`, and land the line in history for recall with the
  normal keys. Previously the modal path swallowed the echo, erased the
  typed row to blank, and left the text live in the editor: one Enter
  away from an accidental resubmit and unreachable from history. A
  wizard that actually runs (or a cancel inside one) keeps its old
  screen-owning behavior.
- **The token bar and receipts count raw fresh input again; rounding
  happens only at display.** Since the May rendering shake-down, the ↑
  slot on the token bar and the per-turn receipts showed the whole
  prompt (cached tokens included) instead of the fresh count — on
  DS 4.1 Flash, whose first-party API reports large cache-hit numbers
  every turn, a receipt read `↑12.5k ↻11.8k` as if the cached input was
  counted twice, and summing receipt columns as the manual documents
  over-counted by the cached share. The ↑ slot is back to the raw
  fresh input (prompt minus cached, clamped at 0 — `↻` carries the
  cached share on its own), matching the manual's receipt math, the
  `:tokens` session total, and the `.3log` `tokens` record; the numbers
  round to "12.3k" only when painted.
- **Windows startup no longer faults on a config with plugin
  defaults.** The early config parse (the one that gates plugin
  loading) asked the plugin registry for its registered defaults
  before the registry's lock had ever been initialized; on Windows an
  unheld CRITICAL_SECTION is undefined, and under ConPTY the
  first run with a config file died with SIGSEGV before the first
  frame. POSIX happens to tolerate a zeroed mutex, so only Windows
  users saw it. The accessors now initialize the lock on first use.
- **Very deep working directories no longer fail the directory
  lock.** The per-cwd lock, session index and draft names embed the
  full mangled path; past 200 characters that blew the filesystem's
  255-byte name limit and every startup under such a cwd died with
  "File name too long". Long names now keep a readable head and carry
  an FNV-1a digest of the full path, so distinct directories stay
  distinct.
- **Fenced `dotnet build` on Linux needs `XDG_RUNTIME_DIR` inside the
  fence.** dotnet's first-run NuGet migrations take their named mutex
  via mkdtemp in `$XDG_RUNTIME_DIR` (`/run/user/<uid>`), which no
  policy grants; the build died with EACCES before the first-use
  sentinel was ever consulted. The manual's dotnet recipe now says to
  run fenced builds with `XDG_RUNTIME_DIR=$TMPDIR`.
- **`-r` checks for a running 3code before session availability.**
  Resuming in a directory another live 3code holds now reports the holder
  (pid, session id, lock file) even when the holder has not saved its
  first session yet - previously that race died with the misleading "no
  saved sessions for" and the real collision surfaced only later, after
  skill extraction and the update fork had already run. The probe is
  advisory: a stale lock (dead or unparseable owner pid) still passes,
  and the enforcing claim stays in `acquireDirLock`.
- **Goal mode's check speaks with a solid rule and its tokens join the
  bar's total.** The verifier quote block in scrollback indents its rows
  with the solid box-drawing rule `│` instead of a punctuation `|`, so
  the block reads as one continuous vertical line under the verdict
  icon. The check's model call is also real spend, and it is now
  accounted exactly like a main call's: its tokens are added into the
  session ledger (`:tokens`, the `.3log` cost record, plugin turn
  events) and onto the resting token bar on top of the turn's own
  numbers - previously the side call repainted the bar with its own
  small readout, so every goal-mode turn ended with the bar showing
  only the check's tokens in place of the turn's. The check's prompt
  size still never reaches the next call's context gauge (its
  conversation is not the session's), and headless embedders no longer
  receive the verifier's usage as if it were a turn's.
- **The sandbox ask gate asks a question, not a menu.** A denied command
  or tool call on an ask-protected path now shows a card — `? <command>`,
  the failed run's error lines dropped, then `allow <read or write> access
  to <path>?` with the answers `(a) allow` (the path itself), `(f) allow
  the entire folder`, and `(d) deny` (also what a timeout decides). The
  old `[f] root [d] parent [n]o` line is gone. Answering allow only
  rewrites the rule that caused the denial when that rule names the
  granted target exactly (the path for `a`, the folder for `f`); the
  rule flips to `allow` where it stands. Anything broader keeps its
  meaning and the allow appends after every existing rule, so other
  paths the rule covers keep asking. `:sandbox allow` keeps rewriting
  an existing rule in its own line position, as before.
- **The built-in default asks before it denies.** The floor rule is now
  `ask /` on every OS, not `deny /`: a path the default table does not
  name stays closed (the OS backends enforce ask exactly like deny), but
  a call that lands on one offers the user the ask gate's one-key grant
  (`a` the path, `f` its folder, `d`/timeout keeps the denial) instead of
  failing silent and forever. Headless sessions are
  unchanged - an ask that cannot be answered denies. The same default
  now grants `readonly /usr/bin` and `readonly /bin` by rule (the file
  tools' in-process gate sees only the policy table, not the kernel
  baseline the bash fence auto-grants), and `~/.ssh` turns read-only:
  `ssh`, public keys, `known_hosts`, and `~/.ssh/config` keep working,
  while every OpenSSH default private-identity name (`identity`,
  `id_dsa`, `id_ecdsa`, `id_ecdsa_sk`, `id_ed25519`, `id_ed25519_sk`,
  `id_rsa`, `id_xmss`) is denied on top - a `.pub` sibling is a
  different path and stays readable. Existing `.sandbox` and user
  policy files are untouched; the new rules only apply where no policy
  file exists.
- **Bare `:sandbox` reports the enabled state; `:sandbox show` keeps the
  rules.** Bare `:sandbox` (and `:sb`) now prints one state line -
  `sandbox: off  (run unconfined)`, `sandbox: on  (session not armed;
  :sandbox on arms it)`, or `sandbox: on  (this session enforces;
  policy: <file>)` - instead of dumping the rule table under a state
  line you had to know was there. `:sandbox show` leads with the same
  line and then dumps the rules, so the dump is still one command away
  and the enabled state is always visible. The `:help` entries and the
  `harness_commands` fixture match the new wording.
- **The sandbox arms and disarms live in the running session.** `:sandbox on`
  no longer waits for the next launch: it arms the session with the same steps
  launch uses (guard rules, policy load, bash-fence backend probe), so bash,
  the file tools, and the ask gate fence immediately, and `:sandbox show`
  dumps the armed rules. `:sandbox off` disarms live: the fence lifts (ask
  approvals included), the wall proxy stops, and the rules drop from memory;
  a re-arm re-reads the policy file, so rules written while disarmed apply at
  once. A bash command already running keeps its fence until it exits. The
  persisted `[settings] sandbox` value and the launch-time behavior are
  unchanged; a session launched with the sandbox off reports
  `sandbox: off  (run unconfined)` until armed.
- **Terminal resize no longer repaints the transcript tail upside
  down.** The rebreak window (committed rows re-wrapped at the new
  width above the prompt on a width change) walked its budget scan
  newest-first and then painted that order as-is, so the newest item —
  the turn's final answer — landed at the top of the re-rendered tail,
  above the older items it answers. Emission now reverses the scan:
  oldest at the top (head-truncated as before), final answer directly
  above the prompt, harness notices in commit order.

- **A directory's provider choice no longer leaks into the user
  config.** Since the `.3code` store landed, a session that booted on
  a directory's sticky `current` held a provider that differed from
  its startup baseline without an in-session switch — and the config
  merge read that difference as this instance's own edit. Every
  unrelated flush (`:reasoning`, `:streaming`, `:verifier`, ...) then
  hoisted the directory's pick into the user config, and adopted
  whichever value another directory had left there, so `current`
  kept drifting back to long-stale defaults (nvidia gpt-oss-20b
  medium, baseten) with no switch command anywhere in sight. Startup
  now records the sticky overlay, and the merge only honors a
  `current` that differs from both the baseline and the overlay.
- **Neuralwatt joins the catalog, an energy-metered hosted vLLM stack.**
  `api.neuralwatt.com/v1` bills per kWh or per token and reports Wh and
  CO2 per request on every response. Seven known-good rows: GLM-5.3 and
  GLM-5.3-Flash, DeepSeek V4.1 Flash, Qwen 3.8 27B and Qwen 3.6 35B,
  MiMo V2.6 Pro, and Kimi K3, each riding its family's prompts and tools
  on a 1M window (262K for the qwens). One graded reasoning knob for
  every family: a top-level reasoning_effort where `none` truly skips
  the reasoning phase (first-party Kimi K3 always thinks) and the
  server folds per-model aliasing (qwen3.8's high lands on its native
  xhigh, qwen3.6 is high/none binary, mimo's max folds onto high), so
  all four 3code levels are valid wire values everywhere. Vision flags
  and contexts come from their public /v1/models metadata, not a live
  image probe yet. The nw-* tracking aliases and the -flex/-speed
  scheduling tiers stay off the table: aliases re-point at newer models
  under the same id, and tiers only change scheduling and price.
- **Sessions can carry a name, and every session lookup accepts it.**
  `:rename Feature xyz` names the running session (issue #67), bare
  `:rename` shows the stored name, `:rename off` clears it. The name
  rides the session record's body in the `.3log`, so the listing peek
  reads it without parsing the message tree, `--find` matches it like
  any other content, and copy/move of the file carries it along
  (a header arg would not survive, the space-split args would split
  "Feature xyz"). `:sessions`, `--list`, and `--search` show the name
  quoted next to the id, and `:resume` / `-r` resolve an exact id, a
  unique id prefix, or a name, case-insensitively, ids before prefixes
  before names; several matches at one stage are an error listing the
  candidate ids, never a silent pick. `:clear` and the turn-rotation
  fresh id start unnamed, and a rename never touches the terminal tab
  title (`:tab-title` stays the owner of display chrome).
- **The latest Kimi, MiMo and GPT generations land on every provider
  that serves them.** A live `/models` sweep of every keyed provider
  found no generation newer than Kimi K3.1 Pro, MiMo V2.6 and GPT-6.1 —
  but plenty of hosts carrying them that the catalog lacked. Kimi K3.1
  Pro joins BaseTen, Tensorx, Together, DeepInfra, Nebius and
  Fireworks (their dedicated `models/kimi-k3p1-pro` spelling), taking
  the family to twenty-eight rows on twenty hosts; each id was pinged
  live with a one-token completion where a working key existed (all
  six answered). Nebius' row stays vision-off with the rest of that
  host — its proxy still rejects image parts. MiMo V2.6 Pro/Flash is
  known-good on Novita, Tencent's tokenhub gateway and Cheaperinference
  (Flash only on Venice), and the `pro-ultraspeed` speed edition — same
  checkpoint, ~10x output — turned up public on the first-party API,
  OpenRouter, nano-gpt and Cheaperinference; it rides the V2.6-Pro
  wire shapes as variant `pro-us`. GPT-6.1 Terra (a true effort off:
  `none` verified live on Cheaperinference and Venice) is known-good on
  OpenAI first-party, OpenRouter, nano-gpt, Venice and Cheaperinference,
  and the pro-mode tiers reconcile across the line: `6-astra-pro`
  (live-verified on Venice) joins Venice, OpenRouter and nano-gpt while
  `6.1-sol-pro`/`6.1-terra-pro` join OpenRouter. OpenRouter and nano-gpt
  keys here are placeholder/invalid, so those
  rows are table-verified against their public catalogs; the OpenCode
  Zen and Go keys have expired, so those catalogs are unverified this
  round. Also seen and left alone: `kimi-k2.8-preview` lists on
  Tencent only (a prior-line preview, not the latest), and Tencent's
  key currently can't call even its existing known-good rows.
  Neuralwatt (which landed after this sweep ran) turned up K3.1 Pro on
  its public `/v1/models` catalog — multimodal, graded reasoning, 1M
  window — and joins with that row; completions there are key-gated
  here, so it is table-verified, and the `-flex` tier stays off the
  table like every other scheduling tier.
- **A mode arm announces with the `⚑` kickoff item alone.** `:goal
  <text>` (and `:cyber ...`) used to commit the echoed command line and
  a `goal armed (...), starting now` receipt on top of the flag item —
  the goal text spelled twice in a row. The arm write's echo is now
  dropped (typed mid-turn or at the prompt alike; the typed rows are
  consumed and the kickoff lands in their place), the receipt is gone,
  and the kickoff turn starts on the Enter that submitted the command.
  A refused arm still echoes above its refusal, and cancel/`edit` keep
  their ordinary echoed receipts — those have no flag item to double.

- **Jarvislabs' Token Factory joins the catalog.** The India GPU cloud's
  per-token API (`models.jarvislabs.net/v1`) is known-good: GLM-5.3 on
  the served 230K window, GLM-5.3-Flash and DeepSeek V4.1 Flash (plus
  the `-cyber` variant) at 1M, Nemotron 3.5 Super VL NVFP4, and Qwen
  3.8 27B FP8, each riding its family's prompt and tools. Rows start
  vision-off until an image probe earns the mark, and allowPrivate
  stays an explicit opt-in because the no-retention line is a site
  claim, not published API terms.
- **Plugins can override default config values, own a GUI in-process,
  and the binary runs headless — including as a native Windows GUI
  app.** The plugin ABI grows three surfaces. `tc_register_config` +
  `overrideDefault(section, key, value)` lets a plugin retune the
  `[settings]` DEFAULTS (max_timeout, sandbox, notify, tone, ...) with
  a strict ladder: compiled default < plugin default < the user's own
  config line < a CLI flag — a plugin never overrides what the user
  wrote, and provider selection is not defaultable at all; refusals
  are listed in `:plugins`. `tc_frontend` + the `agent*` services give
  a plugin a whole frontend: `3code --gui` runs headless, hands every
  frontend plugin its own thread, and the plugin drives the internal
  API in-process (open, start, poll events, command, scrollback —
  same session, sandbox, and saves as the terminal, no sockets).
  `3code --headless` is the same zero-output run without a frontend
  (exit code is the whole report; nothing prints on success OR
  failure). `nimble gui` builds `bin/3code-gui` with `--app:gui
  -d:tcNativeGui`: a real Windows GUI-subsystem binary (WinMain, no
  console ever attached) that runs `--headless`/`--gui` only and
  alerts with a MessageBox on anything else; on macOS it links the
  GUI frameworks, on Linux it equals the console build. New module
  `pluginagent.nim` (the in-process agent backend), `--headless`/
  `--gui` dispatch in the entry point, and docs/plugins.md + the
  manual cover the full contracts.
- **Crash exits restore the terminal.** A crash used to die with the
  signals' default disposition and so skip every exit proc: the shell
  the user landed in inherited raw mode, invisible typing until `reset`
  (the macOS crash reports). A fatal-signal handler (SIGSEGV, SIGBUS,
  SIGILL, SIGFPE, SIGABRT) now restores termios and writes the
  mode-reset escapes (sync-mode off, cursor, attributes, bracketed
  paste, kitty keyboard pop) with a single async-signal-safe write(2)
  before re-raising with SIG_DFL: the stdio lock may be held by
  whichever thread crashed, so buffered output would hang instead of
  dying. SIGPIPE is deliberately left to the runtime instead: a broken
  stdout surfaces as IOError(EPIPE), which 3code turns into a clean
  exit whose ordinary exit procs restore the terminal
  (`test_broken_stdout_exit`).

- **Diff rows link into the edited file at their line.** Every painted
  row of a `w` write block's diff is a `file://path:line` hyperlink
  (the line is the number after the last colon), so a terminal `file:`
  handler that understands `path:line` (a `$VISUAL` wrapper, an IDE)
  lands on the exact spot; the `r`/`w`/`p` banner paths link the same
  way, and a clipped long diff keeps the per-line links through the
  hidden middle.

- **The installers verify published checksums, and the docs say
  download-read-run.** `install/` in the repo now versions
  `install.sh` and `install.ps1` (the site serves those copies), and
  each verifies the downloaded release archive against the
  `SHASUMS256.txt` published with the release before installing. The
  quickstart dropped the pipe-to-shell one-liner for download, read,
  then run, Termux included: an installer you can read first is the
  one you can trust.

- **Goal mode display and the once-per-arming kickoff.** The kickoff
  stanza is fed exactly once per arming: `goalNotified` persists in the
  session record (`goal_notified=1`), and a `Goal armed:` content lead
  in the conversation witnesses sessions saved before the latch
  existed, so resuming a session no longer re-feeds the goal text to
  the model — the end-call boundary goes straight to the check. The
  `goal.md detected implementing` hint line is gone; the kickoff's
  scrollback item is the whole announcement, and it shrank to the `⚑`
  flag plus the goal text alone (the `Goal armed:` scaffold and the
  trailing instruction paragraph never reach scrollback, live or
  replay; replay also gives old, marker-less kickoffs the flag). A
  failed or unreadable check now speaks as the same red `✗` verdict
  row the verifier steps use — `check unavailable (...), retrying
  next turn` or a no-verdict note — instead of a cyan receipt.

- **Java runs under the macOS sandbox.** The JVM's first startup call
  resolves its temp dir through the `com.apple.bsd.dirhelper` mach
  service, and under the bare `(deny default)` that bootstrap lookup
  EPERMs and every `java` hangs on `mach_msg` before `main` (#64).
  The sandbox profile now allows that one lookup (next to the
  opendirectoryd allow it sits beside) and tags the default deny with
  `with message "sandbox_3code"`, so `log show --predicate
  'eventMessage contains "sandbox_3code"'` can tell 3code's denies
  apart from every other sandboxed process on the box. The manual
  names the new profile rider, and the macOS CI matrix runs plain
  `java -version` under the sandbox.

- **The optional headless-Chrome `web_fetch` tier is now compile-time
  disabled and undocumented.** `browserfetch` (the shared headless
  Chrome that re-fetched JS-shell pages) is out of the docs and out of
  packaged builds; the config line stays accepted but is inert. The
  tier lives on behind a build switch for developer use.
- **`:show N` follows a running tool call live.** While a bash call
  streams, `:show N` (or `:show` bare, or a click on the capped
  viewport) flushes the held lines into scrollback and every new line
  lands as it arrives; `:unshow` (or another click) returns to the
  capped viewport, and the fold pins only the banner plus the dump
  link instead of re-committing the body. A click during a call's
  quiet stall toggles the same follow, so no command is needed. The
  manual and `:help` document the live form of `:show` next to the
  existing `:cmd` view.
- **`max_timeout` raises the default too, and prompts quote the live
  numbers.** One config line now covers long builds from both ends:
  `max_timeout = 1800` raises the 600s ceiling (what a model-requested
  `timeout` is clamped to) *and* the 120s default (what a run gets when
  the model passes no `timeout`), so a 30-minute compile survives with
  no model cooperation. Every family prompt and the bash tool schema
  fill `{{bash_default}}`/`{{bash_ceiling}}` tokens from the live
  `[settings]` values at request time (`force_timeout` flattens both to
  its value), so the model is never told a cap the harness would not
  honor, and a mid-session `max_timeout` edit rebuilds the prompt for
  the next request (the timeout pair is part of the profile identity).
  The kill message got plainer about the way out: it names which cap
  killed the run (the one you requested, the default, the user's
  `max_timeout`, or `force_timeout`) and what unblocks a rerun.
- **Directory-specific settings: the `.3code` store, cascading up the
  parents.** Every directory can carry its own settings store — a
  `.3code` directory right in it (default), or a per-directory
  directory under `~/.config/3code/dirs/` when `[settings]
  dirconfig = "user"` says so. The store holds the directory's `config`
  (a `[settings]` override: `current`, `sandbox = off`,
  `sandbox_wall_warn`), its `sandbox` policy file, and the harness mode
  files (`goal`, `achieved`, `goal-cancelled`, `cybernetic`, ...).
  Resolution cascades: the directory's own store wins, then each
  ancestor's, nearest first; the user config is the floor. This fixes
  the "default provider reverts to the first `[provider]` section"
  report: a provider picked at a project root now sticks in every
  subdirectory (`:provider`/`:model` still write the per-directory
  sticky into the store's `config`). `sandbox = off` in a `.3code`
  config now turns the sandbox off for that tree without touching the
  user config, and `writeConfigFile` never leaks a directory's
  effective value into it. The sandbox policy file moves to
  `.3code/sandbox` (the legacy root-level `.sandbox` still reads and
  still gets edited in place; the selection walks parents, nearest
  wins, and `./` targets in an ancestor's policy resolve against the
  ancestor). goal/cyber mode files arm into the store
  (`.3code/goal`); a legacy `goal.md` on disk stays detected and
  retires the way it always did, so nothing breaks on upgrade.
- **Community prompt findings folded into every shipped system
  prompt.** kay-is's tools-section rewrite (community thread 9, born
  from DS 4.1 Flash failing the patch tool) now rides every family
  prompt that documents the bash/read/write/patch surface, not just
  DeepSeek's: a nonzero `exit=N` is a failure to investigate, large
  output keeps only the tail, the 120s cap is a hard kill, `read`
  documents the 250-line cap, 2KB line skip and `limit:-1`, `write`
  overwrites unconditionally, and `patch` teaches the real semantics
  - first match through the fuzzy ladder (exact, indent,
  whitespace), 2-3 lines of unique context, verbatim search text,
  all-or-nothing application with the entire call resent, empty
  search rejected. The patch tool schemas dropped the false "must
  match exactly once" description that caused the flailing. warp's
  findings (thread 14) went into the GPT prompts: a failure named in
  test output comes before new work, the incidental-wording tests
  rule hardened to "never", generated docs state what is and what
  changed (never what you won't do or what stays unchanged), and the
  gpt-oss prompt traded prose for lists throughout. Total prompt
  bytes landed under the pre-change total, and a new golden-fixture
  suite (`tests/testdata/fixtures/prompts/`, 21 families, prompt
  plus tool descriptions, byte-compared in test_prompts_compact)
  locks every prompt against drift; regenerate deliberately with
  `THREECODE_REGEN_GOLDEN=1`.
- **`:provider` teaches its verbs where you stand when a key dies.**
  After OpenCode revoked its API keys, the way back in,
  `:provider edit <name>`, was findable only by asking the forum:
  `:help` lists it, but nothing at the point of need did. Tab in the
  `:provider ` argument slot now offers the verbs (`add edit update
  new pull rm`) ahead of the provider names, so `:provider e<tab>`
  completes `edit`, and the bare `:provider` listing ends with
  `verbs: add edit update new pull rm (edit <name> re-enters its key
  or renews a login)`. The manual's API-keys section gained the
  matching paragraph: what a dead key looks like (the provider's own
  401 on the next turn) and the one-paste-plus-Enters re-entry, with
  the same wording the auth-error hints use.
- **Provider errors say whose they are, and auth failures point at the
  fix.** An expired key used to surface as the raw provider body with no
  indication which side produced it. Retry notices now read `500 from
  zaicode: quota exceeded`, and a terminal failure reads `opencode
  error: This API key has expired. Create a new API key (code 401).
  re-enter the key: :provider edit opencode` - the provider's name
  leads, the status rides as a parenthetical, and 401/403 name the exact
  `[provider]` section to re-key. A dead stored OAuth grant points the
  same way (`opencode login expired (...). re-login: :provider edit
  opencode`). Verbose pretty-printed error bodies condense to one line
  (whitespace runs collapse, a cut ends in an ellipsis), while failures
  that are 3code's own - a body-less transport error, network quiet -
  still say so (`3code: ...`), so the two sides stay legible apart.
- **`:model` takes `provider.model`: what `--good` prints is what you
  type.** `3code --good` lists curated combos as
  `opencodego.deepseek-v4.1-flash`, but `:model` resolved its argument
  only against the current provider, so pasting a printed id answered
  "unknown model". `:model provider.model` (or `provider/model`) now
  switches provider and model in one step - sticky per provider,
  persisted, and gated like any other selection - and every id the
  listing prints resolves verbatim, slash-carrying wire ids
  (`baseten.zai-org/GLM-5.2`) included. A bare name still selects on
  the current provider, a dotted bare id (`glm-5.3`) is never mistaken
  for a prefix, and an explicit prefix wins over a same-named model on
  the current provider. The unknown-model error got helpful: it names
  the provider it looked on, offers the model's real homes as
  prefixed specs (`did you mean deepseek.deepseek-v4.1-flash?` or a
  `close:` list), and says `provider has no model X` when the provider
  exists but lacks the model.
- **An empty message now means "continue" on every embedding surface,
  not just the terminal.** Embedders (the GUI via `--rpc`, editors via
  `--acp`) used to get an error back for an empty prompt, exactly the
  message a client sends after a cancelled turn to say "keep going".
  `AgentSession.prompt("")` (or whitespace) now runs a turn on the
  conversation exactly as it stands - no user message appended to the
  session or the scrollback, no `user` event row on the RPC stream, no
  `user_message_chunk` over ACP - and an empty `POST /prompt` body or
  `session/prompt` array means the same. An empty prompt on a fresh
  session with no conversation yet is an error (`no conversation to
  continue yet`), matching what the terminal's Enter-on-empty-line
  gesture (already in) does.
- **A system command run during a turn no longer ends the turn: the
  model is sent back in once the command has run.** A `:command`
  typed while the model was mid-loop in a tool batch (an `:!` shell
  escape, a mutating command) used to halt the turn at the next tool
  boundary, the drain ran the command, and nothing ever resumed the
  turn - the conversation sat on tool results the model never saw
  until the next prompt. The mid-loop yield is now flagged, and after
  the drain has run everything the queue held, the model gets its
  follow-up call and finishes the turn (a queued prompt still runs its
  own turn, an interrupt still stops for good, and a command that
  rewrites the conversation, like `:clear`, opts out by leaving a
  non-tool tail). Safe commands (`:tokens`, `:help`, ...) that run
  inline on the input thread the moment they are submitted no longer
  stop the turn at all: their queue entry waits for nothing, so
  `hasQueuedAutosend` no longer counts it.
- **Sandboxed ssh works as the user expects: aliases, keys, and
  known_hosts all found, every connection still allowlisted.** The
  fence runs the child as uid 65534, whose passwd home is `/`, so ssh's
  own defaults looked under `/.ssh` and each login died at host-key or
  auth even with the tunnel up. The PATH shim now hands ssh a config
  file that proxies through the wall (`wall connect %h %p`, same
  tunnel as git), carries a copy of `~/.ssh/config` with `~` rewritten
  to the absolute home, and falls back to the usual identity files and
  known_hosts; local names (mDNS, search domains) resolve at the proxy.
  `scp` and `sftp` are documented as the exception: OpenSSH 9.8+
  execs `/usr/bin/ssh` by absolute path, beyond any PATH shim or env,
  so they fail inside the fence - `rsync`, `ssh`, and git cover their
  use cases and are proxied.
- **Multiline bash commands banner their first lines, `+N lines` tail
  linked to the whole command, and `:cmd` shows it.** A multiline bash
  command used to render only its first line in the `$` banner with no
  signal anything followed. The banner now shows the first
  `banner_lines` lines (config `[settings]`, default 1) plus a linked
  `… +N lines · T<idx>.cmd ↗` tail row: the click opens the `T<idx>.cmd`
  dump the run wrote with the complete command. `:cmd [N]` prints the
  full command of bash tool call N (default last) in the transcript,
  `:cmd N edit` opens it in `$VISUAL`/`$EDITOR`.
- **Unknown config keys warn instead of erroring.** An unknown key in a
  known section prints a `file:line:` warning at startup and is
  ignored, so a config written by a newer 3code still boots; unknown
  sections stay fatal. Unknown `[shortcuts]` command names are dropped
  with the same warning so a bogus binding cannot shadow a real key.
- **Computer use is compiled out of release builds and undocumented.**
  Internal use only for now: `:computer`, `--computer`, and the
  `computer` config line are inert in a build without the internal
  compile flag, the manual section is gone, and the skill file is no
  longer materialized (existing copies are retired on upgrade).
  Test coverage is unchanged.
- **The sandbox ask covers `apply_patch` too.** The last file-tool gap:
  `apply_patch` carries its paths per-op inside the patch body, so the
  pre-emptive hook never saw them and gpt-oss profiles (its canonical
  mutation tool) were effectively bash-only. The gate now parses the
  ops up front and asks once per distinct `ask` rule root before any op
  executes (a patch touching three vault files is one question, nothing
  partial hits the disk), with the first op path under each root as the
  display target. A declined or timed-out root does not abort the patch:
  its ops fail their per-op policy denial while ops under granted roots
  proceed, and each decision lands in the tool result as its own
  `[sandbox ask: ...]` line. Unparseable patches and hard denies still
  never ask.
- **The sandbox ask covers the `read`/`write`/`patch` tools, not just
  bash.** An `ask` rule used to redeem only a failed bash command; a
  model `write` to an ask-protected path just denied. The file tools
  know their exact target, so they ask before running - `sandbox ask:
  ./vault/out.txt is ask-protected. [f] ./vault [d] ./ [n]o (60s)` -
  and on `f`/`d` the grant is written, the call runs under the widened
  policy, and the decision is recorded in the tool result (`[sandbox
  ask: user allowed ./vault; tool retried]`) exactly like the bash
  convention; `n`, a timeout, or a headless session keeps the plain
  denial. Hard denies still never ask. The ask gate also no longer
  races the editor: an answer key pressed while a turn is running used
  to land in the prompt draft about half the time, because only the
  gate's own poll window diverted keys; every input path now diverts
  while the gate is armed.
- **The sandbox ask answers on Windows consoles too.** The ask gate
  was posix-only (a hard `false` predicate); on Windows it now arms
  whenever the input thread owns a real console handle - ConPTY,
  Windows Terminal, and legacy conhost all qualify, mintty's pipes do
  not - and the input thread diverts the one-key answer on all three
  read paths (the VT readiness loop, which previously spun without
  re-checking the gate, the legacy blocking read, and bytes already
  buffered). Verified end-to-end on a real ConPTY session against the
  sandwall restricted-user backend: git-bash denial text is still
  `Permission denied`, root grants take effect through the ACL
  enforcement, and the full ask tty suite (bash and tool legs) passes;
  on hosts without the fence the suite's bash legs probe-and-skip (a
  sandboxed command cannot fail there), the tool legs run everywhere.
  Also un-broke the Windows cross-build under Nim 2.4: a `when`/`elif`
  in `fileLinkUrl` carried a runtime condition, which 2.2 tolerated and
  2.4 rejects.
- **`--ic:on` debug builds link.** Nim's IC backend emits the
  extern pre-declaration of a `{.volatile.}` global without the volatile
  qualifier, and the C compiler rejects the mismatched redeclaration.
  The two signal-handler flags in `signals.nim` are now plain
  `sig_atomic_t` globals accessed through `volatileLoad`/`volatileStore`,
  which produces the same volatile C accesses without a volatile-qualified
  variable, so incremental debug builds link.
- **The prompt draft save is key-press debounced, not interval-polled.**
  A dedicated flusher thread woke every 250ms to check a dirty flag; now
  the save is armed by the key presses that change the buffer and fired by
  the input thread's own no-key-waiting path, so it happens only after a
  sentence completes (`.`, `!`, `?`, or a line break) AND typing has been
  briefly quiet (750ms debounce). Steady typing and mid-sentence pauses
  write nothing; the unconditional final flush on shutdown still captures
  whatever was on the way out, and the crash-restore behavior is
  unchanged.
- **The mode file is the whole mode: kickoff turns are gone.** Goal
  mode (and cybernetic with it) had grown a second arming path
  beside the file: a `startGoalTurn` flag in the UI made every
  `:goal <text>` arm append a harness-autosent kickoff prompt and run
  a turn at once, and a `goal.md` already on disk when the session
  opened fired the same kickoff before the first prompt. Both are
  gone. Existence is the mode and the turn-end boundary in turns.nim
  is its only consumer: `:goal <text>` writes the file and answers
  with one receipt line (the mode's counts ride it for `:cyber`), a
  `goal.md` present at startup does nothing at all, and the first
  check runs at the end of the first turn — send any prompt, or an
  empty Enter (it runs a turn on the conversation as it stands), and
  the loop takes over from there. The kickoff message builders, the
  `◎` replay marker, and the `startGoalTurn` plumbing are deleted
  with it; discipline baselines (the mode-file snapshot and the
  change-log count) now bind at turn start instead of arm time, so
  the first check after an arm still judges that turn's own delta.
- **Goal verdicts read as a dim quote block, and the verifier is
  terser.** The check's scrollback item carried its verdict in a
  color flood - icon and prose alike saturated green or red. Now only
  the leading icon speaks the verdict (green `✓` satisfied, red `✗`
  anything else) while the prose sits in the dim tier behind a
  continuous vertical rule, wrapped rows keeping the rule aligned
  under the icon:

      ✓ | this is the
        | verdict text

  The judge preamble caps the reply at 40 words (was bullet points
  under a 200-word ceiling), so the block stays a quote, not a
  report. A satisfied goal now retires `goal.md` to `achieved.md`
  (was `goal-confirmed.md`) - the record's name says what happened.
- **`:btw` asks the model a side question about the conversation without
  it entering the context.** `:btw why did we pick the parser rewrite?`
  fires one meta-call over the live history (a dedicated aside system
  prompt, the conversation, the question as the final user message) and
  prints the answer to the terminal. Neither the question nor the answer
  is appended to the session's messages, so the next real turn — and
  the context window it pays for — is exactly the conversation from
  before the aside. Bare `:btw` is a usage hint; with no provider
  configured it fails like `:summarize` does.
- **DeepSeek vision: verified working, and `--good` now shows the eye.**
  `deepseek.deepseek-flash` (V4.1 Flash, native vision) delivers image
  content end to end — `@img.png` attaches, `read` on an image returns
  the receipt and rides the pixels on the follow-up user message, and
  the wire request carries the `image_url` block verbatim next to the
  family's own knobs (`thinking.type` + temperature 0.0 first-party,
  `reasoning_effort` on the hosted vLLM stacks, `reasoning_content`
  backfill on assistant history). Verified against a live local
  endpoint capturing the outgoing body; a new httpStub suite
  (`tests/stream/test_vision_wire.nim`) locks the invariant in, and
  fails the moment any family mutation flattens a content array.
  Text-only weights (`deepseek-v4-flash`, `v4-pro`, `v3.2`,
  `deepseek-chat`) keep refusing with the vision hint. To make the
  see/no-see split visible, `--good` / `3code good` now paints the
  same `(vision)` suffix the `:model` picker uses (the manual always
  said it marked them; the listing never did), and the manual's
  "Which models can see" names the DeepSeek ids that see.
- **`:sandbox allow|readonly|deny|ask` rewrites the existing rule for
  that target where it sits instead of stacking a new one at the
  end.** The policy is ordered last-match-wins, so appending a flipped
  rule silently moved it behind every later rule: flipping `deny /` to
  `ask /` that way would swallow the `allow /tmp` written after it.
  Now a rule command for a target the file already covers (paths match
  on their normalized absolute form, hosts on the host:port pair)
  replaces that rule in place and stacked duplicates for one target
  collapse into the first, while a new target still appends at the
  end; the order you wrote is the order that is enforced. Ask-gate
  grants keep appending on purpose, so an approved command's `allow`
  still wins over any later deny.
- **`:goal edit` creates the file it edits, and a pasted multi-line
  `:goal` arms instead of erroring.** `:goal edit` refused with
  "no goal active" when goal.md did not exist; now it creates the empty
  file and opens it in $VISUAL/$EDITOR — saving text arms straight from
  the editor, while leaving it empty (or removing it) is a clean no-op
  that leaves no file behind, and a live other harness mode still
  refuses the arm. Separately, a `:goal` whose first line ends at the
  verb (a pasted multi-line goal: `:goal`, blank line, then the text)
  died as "unknown command" because the command name was split on
  spaces and tabs only, so the newline and the next line's first word
  leaked into the name; the split now takes any whitespace, making the
  verb `:goal` and every following line the goal text. Same two fixes
  for `:cyber`.
- **Plugins can add subcommands and command-line options.** A plugin
  exporting `tc_register_cli` registers `3code <name>` subcommands
  (`tc_cli_command` runs them: verbatim args in, output and exit code
  out) and `--long`/`-s` options the main parser accepts and delivers
  as one JSON object via `tc_on_cli_options`, before any session work.
  Names the built-in CLI already owns are refused, `3code -h` lists
  the additions, and a leading bare word dispatches exactly like
  `provider` does. To know the surface before argv is parsed, plugins
  now load (init, `tc_register_cli`, `tc_register_tools`) right after
  the root check and a tolerant config read, earlier than their
  hooks fire; `--version`, the sandbox/ACP children and the skills
  directory stay untouched by a usage error. `:plugins` counts the
  registered commands.
- **Ctrl-Z suspends again on kitty-protocol terminals, and coming
  back from background repaints.** The shortcut-table refactor listed
  `suspend` as a command but never registered its handler on POSIX, so
  Ctrl-Z lived on only as a legacy fallback keymap entry — a path the
  kitty keyboard decoder (which the interactive app pushes at startup)
  never consults. On kitty, Ghostty, WezTerm and friends the key did
  nothing. The `suspend` command is registered in the command table
  again, and the kitty decoder now falls back to the same keymap the
  legacy control-byte path uses, so a binding can never again silently
  die on one encoding. Resume used to leave the shell's job-control
  output as the last thing on screen: the row-diffing painter skipped
  the post-resume repaint as a no-op because no editor state changed.
  A resume now invalidates the diff model (full repaint of the volatile
  block, like a resize) and sets the resize flag so the input poller
  repaints even when the resume was external (`kill -TSTP` from
  another terminal, then `fg`). A stale SIGCONT from such an external
  resume is drained instead of being left queued — it used to satisfy
  the next suspend's `sigwait` before the process had stopped, which
  looked like Ctrl-Z freezing.
- **`user_agent`: your build's User-Agent, your wording.** The
  `[settings] user_agent` template (`user-agent` spelling accepted)
  builds the User-Agent header 3code sends on every model request.
  Default `3code $version`; variables `$version` (the full build
  version, e.g. `0.9.2-main-a1b2c3d4a`), `$branch`, `$commit` /
  `$hash`, `$stage` (`-unstaged` when the build's sources differed
  from HEAD; each empty when not applicable), `$os`, `$arch`, `$$`
  for a literal `$`. Unknown `$names` pass through verbatim, and the
  setting round-trips through the config writer only when set. This
  replaces the fixed compiled-in string on every surface at once:
  streaming, non-streaming, the /models ping, the verifier, and the
  compactor.
- **Kimi K3.1 Pro runs on every provider that serves it.** Twenty-two
  known-good rows across fourteen hosts (kimi, kimicode, openrouter,
  novita, nanogpt, venice, cheaperinference, tencent, opencodego,
  vercel, volccode, aihubmix, kilo, commandcode), each carrying the
  wire id its catalog actually lists, dash-spelled and case-sensitive
  spellings included. K3.1 always thinks; the knob is top-level
  `reasoning_effort` low/high/max (default max), which `:reasoning`
  now sends on any host, and temperature is omitted because the
  serving side fixes it at 1.0. Native vision, spot-probed live with a
  real image on the hosts that took a key (novita, venice,
  cheaperinference): the rows are vision-capable, `@img.png` and `read
  img.png` work.
- **An empty prompt continues the ongoing session.** Press Enter with
  nothing typed and a turn runs on the conversation exactly as it stands:
  no user message is appended, no `❯` echo is painted, the `.3log` gains
  only the reply — the cheap way to say "keep going". The empty submit
  rides the same queued-event path as a text submit (so the controller
  always consumes it and the input thread never parks unconsumed), and a
  submit that races the turn boundary gets the same continuation from the
  post-turn drain. A fresh session with nothing to continue, and an empty
  Enter mid-turn, stay inert. On by default; `[settings]`
  `allow-empty-prompt = off` (`allow_empty_prompt` spelling accepted)
  restores the no-op and round-trips through the config writer.
- **The goal-mode check renders like scrollback, not a block of grey
  text.** The verifier's reply used to land as a dim, wrapped, unmarked
  tier — raw markdown asterisks and all — with the `VERDICT: ...`
  contract line on screen. It is now a first-class scrollback item: a
  `⌕` glyph leads the first row exactly where `●` leads a reply, and the
  prose goes through `renderAssistantContentBytes` itself (the one
  codepath for response rendering, via a swappable first-row bullet),
  so the check's markdown renders like any other response. The verdict
  line is stripped before display and its meaning is an icon row under
  the body — green `✓` satisfied, red `✗` not — which also replaces the
  `goal confirmed` receipt: the icon and color are the confirmation.
  Arming is quiet now too: `:goal <text>` answers with no response
  line, and the live kickoff commits no `auto: goal armed` receipt and
  no `◎` item — the echoed command already says it — while a session
  resumed from file still replays the kickoff prompt under its `◎`
  marker. The cybernetic mode shares every one of these paths and so
  inherits the same shapes.

- **A width change re-breaks the committed transcript above the
  prompt.** Committed rows are hard-wrapped at the width they were
  painted at, so a resize used to leave them to the terminal's own
  reflow, which breaks mid-word and strands stale tails. The engine now
  journals committed transcript content as it is written
  (`noteCommittedRows`, plus `noteNonMessageTail` for queued `:` command
  echoes and their bodies, which never enter the messages), and a
  width-only resize repaints that tail window re-wrapped at the new
  width: word-boundary breaks, every row within the new width (each row
  EL-terminated so a shorter row clears the stale tail of the wider row
  it replaces), every word present exactly once and in order - which the
  resize shakedown now asserts across 104/60/80 cols. The window is read
  only while the main thread is parked in the input wait, never while a
  modal wizard owns the screen; Windows stays frozen-rows because
  ConPTY's resize model already full-repaints.

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

- **A real SIGINT at an idle prompt now quits, like `:q`.**
  `installInterruptHook` replaces Nim's die-on-SIGINT handler with
  the turn-interrupt hook, so `kill -INT` from outside (a supervisor
  like mpx, or a wrapping script) while 3code sat idle was swallowed
  whole: the process lived on and the supervisor escalated to SIGKILL,
  which skips every terminal-restore path. The hook still means
  "cancel the turn" while a turn runs; the controller's prompt read
  consumes the flag afterwards so an interrupt that already cancelled
  its turn cannot also quit the prompt that turn returns to.

- **Modes: goal mode becomes entry #1 of a mode registry, and
  cybernetic mode (`:cyber`) runs a markdown plan.** A mode is a
  trigger file that arms a supervised loop, a `:` verb that writes
  it, retirement names, and per-mode continuation builders; the
  registry owns everything shared (arm validation, kickoff,
  feedback, cancel, the turn-boundary check), so goal mode is now
  just its first entry and a new mode is a descriptor, not a fork of
  the loop. Modes are mutually exclusive: a second mode's file on
  disk while one runs is a refused arming, receipted once right
  under the detection line. Cybernetic mode is the second entry:
  `cybernetic.md` carries a checkbox task list plus a `## Current
  state` section, and arming refuses anything else with a teaching
  error (`:cyber <text>` arms from a skeleton, bare `:cyber` is
  status, `:cyber edit` revises the live plan in $VISUAL/$EDITOR,
  `:cyber!`/`cancel` retires it). The kickoff orients on the first
  unchecked task by name; feedback continuations re-orient on the
  next one as boxes get ticked. Two mechanical duties run at every
  turn boundary: a plan that lost its format mid-run gets a
  restore-the-plan continuation and no side call, and
  work-happened-but-plan-unchanged gets the update-discipline note,
  which rides a verifier FEEDBACK or sends the agent back on its own.
  The verifier for plan modes also judges step truth: the preamble
  gains a clause that a checked box must match the evidence and the
  diff (newly checked boxes are claims to verify), and the prompt
  gains the plan delta (tasks ticked or added this turn) plus the
  plan's own Current state section. Context collapse no longer
  strands a supervised session: rollover injects a re-anchoring
  continuation (counts, next unchecked task, Current state quoted),
  receipted in scrollback.
- **Session change log: the harness records net per-path mutations
  and the verifier reads them.** Tool actions now land in a
  per-session change log, net per mutated path, git or no git; the
  verifier prompt carries it as the primary record of what the
  session did (the working-tree diff stays as the git-reported
  complement), and work-happened detection is content-aware
  instead of action-aware: the update-discipline note fires when
  the change log grew, not when any tool merely ran. A configured
  verifier (`:verifier`, decision or chat) rides the same mode-aware
  check - the System One state now carries the mode's full
  orientation (mode text, evidence, diff, structural feed, session
  change log) - so the verifier and mode features compose instead of
  colliding.
- **Verification-class models: goal mode can run its satisfaction check
  on a dedicated verifier (like jev), configurable and off by
  default.** Decision models - TypeSafe's Jev via OpenRouter is the
  curated one - answer typed questions with calibrated probabilities in
  a single forward pass instead of writing prose, which makes a check
  per turn end cheap enough to always run. `:verifier jev-latest`
  selects one, `:verifier off` returns to the exact previous behavior
  (the session model judges in a fresh side conversation), `:verifier
  list` shows what you can use. The check sends the same orientation
  (goal text, evidence digest, working-tree diff) as the `state` and
  asks two questions - is the goal satisfied, and what is the most
  important gap - with p(satisfied) >= 0.75 confirming the goal and
  anything else sending the agent back in with the gap as direction;
  the numbers land in scrollback as one dim line. Verifier models never
  appear in ordinary model lists (`:model` refuses them and points at
  `:verifier`; the wizard and `:provider new` skip them): they cannot
  run a turn, only judge one. Any ordinary model also works as a
  verifier. The selection persists as `[settings] verifier_model`
  (plus `verifier = "off"` only while disabled), the welcome block
  grows a `verifier` line naming the active verifier, and a verifier
  that stops resolving falls back to the session model with a visible
  note instead of a silent skip.
- **DeepSeek system prompt teaches the tools' real semantics (community t/9).**
  DeepSeek 4.1 Flash kept mangling `patch` calls - mismatched `search`
  blocks, invented failure stories about "collapsed lines", fallbacks to
  Python one-liners, loop-detector trips - even after 0.8.3 taught the
  harness every Frankenstein edit syntax it produced. A user rewrote the
  prompt's Tools section at the harness level and the flailing stopped.
  That rewrite now ships in the DeepSeek preamble, condensed to each fact
  once: `exit=N` markers, tail-truncated output, the `read` 250-line cap
  and 2KB line skip, first-match-only `patch` with unique context, the
  exact/indent/whitespace ladder `fuzzyReplaceFirst` really applies (and
  the note that names the strategy a non-exact match used), verbatim-
  from-disk `search` text, and the all-or-nothing edit transaction. Every
  claim is enforced code in `actions.nim`/`util.nim`; content and a
  9.9KB terseness bound are pinned by new setup tests (+1.2KB on the old
  preamble, not the +2.7KB of the verbatim forum version).
- **A `goal.md` on disk at startup now arms goal mode by itself.** Goal
  mode used to activate only at the first turn end: a `goal.md` written
  by hand (or by any other tool) sat inert until something - anything -
  ran a turn. The startup path now detects the file, loads it, and sends
  the same harness-autosent kickoff prompt `:goal <text>` produces, so
  work on the goal begins the moment the session opens, no keystroke
  needed. Fresh and resumed sessions alike; the kickoff keys off the
  session's project directory, the same authority as the turn-end
  satisfaction check.
- **Catalog sweep: live-checked known-good registry.** Every combo
  was re-verified against the provider's live `/models` list plus a
  one-token completion probe where a key allowed it, and the registry
  now mirrors what providers actually serve. New model versions from
  the OpenCode Zen catalog are known-good on every provider hosting
  them: MiniMax M3.1 Flash (minimax, OpenRouter free, zen free tiers,
  nano-gpt, tencent, venice), LongCat 2.5 Preview (longcat, nano-gpt,
  zen free tiers), Nemotron 3.5 Lightning and Super VL back on nvidia,
  DeepInfra, Nebius, Fireworks, Together, BaseTen, Venice, OpenRouter,
  nano-gpt and the zen free tiers, gpt-5.4-pro (openai, zen), and
  gpt-5.3-codex-spark (zen). The zen gateways also gained their current
  Claude line over the Anthropic-format `/messages` route (live-probed:
  the path speaks the Anthropic error envelope and takes `x-api-key`),
  qwen3.8-max, mistral-large-4, gpt-6-luna (zen Go), and free tiers of
  deepseek-v4.1-flash and glm-5.3-flash. Dead combos left the table
  after live 404/410 probes: OpenAI first-party gpt-oss-120b/20b and
  o1-mini, BaseTen's GLM-4.7/Kimi-K2.6/K2.7-Code/inkling/V4-Pro,
  Fireworks' dated v4 deepseek and minimax/kimi tiers, 13 retired
  Novita models, five deprecated OpenRouter qwen ids, OVH's qwen3-coder,
  SambaNova MiniMax-M2.7, nvidia kimi-k3 and deepseek-v4-flash-0731,
  deepseek vision-exp on novita and the zen gateways, aki's
  284b flash snapshot, nano-gpt's qwen3-coder-plus, deepinfra's
  unlisted Qwen3.8-2.4T-A95B and silently-rerouted GLM-5.1, and
  tencent's bare deepseek-v4-flash. Delisted-but-still-serving ids
  stayed after probing alive (anthropic's claude-haiku-4-5 alias,
  cheaperinference's dash-spelled gemini/qwen ids, all eleven flagged
  tensorx rows, venice glm-4.7-flash, greenpt qwen3-coder-30b).
  `harvest_models` compiles again: its `--sync` parser still expected
  the pre-vision 12-field tuples, so the sweep tool had been broken
  since the vision flag landed.
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
  patient-retry backoff, Ctrl+R cuts the wait short and resends, and
  the reset is part of the deal: the backoff curve starts over, so the
  next failure waits from the short end again instead of climbing a
  ladder the user already lost patience with. Ctrl+R also cancels and
  resends a request that has not shipped any output yet; once model
  output is streaming, or at the idle prompt, it does nothing. Bare
  `:retry` does the same from the command line; `:retry on`, `:retry
  off`, and `:retry list` manage the patient-retry setting itself.
- **`--rpc`: a headless REST surface for 3code-app.** `3code --rpc[=PORT]`
  serves a plain-text RPC on loopback - `/id`, `/session/new`,
  `/prompt`, `/cancel`, `/events` (25 s long-poll of TSV event rows),
  `/scrollback` - one session per process, stdout protocol-clean, the
  same early dispatch as `--acp` so no terminal is ever set up.
  Instances register under `~/.local/share/3code/rpc/<pid>` and a
  later start sweeps entries whose pid is gone, so a GUI can find
  live agents without stale hits.
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

- **Computer use (X11).** `:computer on` (or `--computer`, session-only,
  never persisted) lets a vision model see and drive the desktop:
  `screenshot()` captures the screen and attaches the image to the next
  message (same budgeted delivery as image reads; transcript:
  `· shot 1920x1080 -> 1280x720`), and a generated `shot` script
  (`shot click 640 360`, `drag`, `type`, `key`, `scroll`, `title`) drives
  mouse/keyboard through the ordinary bash tool — it takes
  delivered-raster coordinates and does the native mapping itself, so the
  model never does scale math; stale frames error loudly. Guardrails:
  3 captures per turn without an intervening action, capture streaks feed
  the flail detector, a one-time activation note (dmail pattern) teaches
  the loop, and the screenshot schema is only offered while armed +
  vision-capable + backend-probed (idle cost: one skills line,
  `computer-use.md`). Backend probes X11 (`import`/`maim`/`scrot` +
  `xdotool`); macOS/Wayland/Windows fail with a clear not-implemented
  error.

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
