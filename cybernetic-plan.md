# Cybernetic plan: 3code as a library API

## Context

3code (`~/p/3code/lib`) is a Nim coding-agent CLI. Goal: make it usable as
an embeddable API so other frontends (web server, GUI) can drive the same
agent. Requirements from the user:

- Easy-to-initialize session object; CLI config passed as convenient params
  (or param tuples).
- Two reply interfaces: **blocking** and **callback**. No async.
- Library may manage its own threads (it already does). No
  bring-your-own-thread needed unless trivially free.
- Prompts and colon-commands are procs taking the session as first param.
- Full functionality retained: sandbox, tool calls, filesystem, resume.
- CLI refactored to call the same API; behavior unchanged ("don't break
  anything").

### Architecture map (verified by reading)

- `src/threecode.nim` (659 lines): `main()` does CLI parse, session
  create/resume, sandbox init, locks, config load, profile resolve, welcome,
  then the REPL loop calling `runTurnsInteractive` and `handleCommandResult`.
  Heavily terminal-coupled via global pointers `inputEditor/inputMessages/
  inputSession/inputProfile`, `addExitProc(cleanup)`, signal handlers.
- `src/threecode/turns.nim`: `runTurns(p, messages, session)` is the
  headless-safe turn driver. All visuals flow through two seams:
  (a) `apiStreamHooks` (api.nim) and (b) fatprompt procs.
- `src/threecode/fatprompt/runtime.nim` (2341 lines): owns the input
  thread, GUI spinner/bar-tick thread, and transcript commits.
  `installApiStreamHooks()` wires api.nim to terminal rendering.
  `beginTurn()` calls `ensureInputThreadStarted()` — terminal-coupled.
- `src/threecode/engine.nim` (704 lines): every byte to stdout goes through
  `defaultEngine` + global wrapper procs (`syncWrite`, `writeRaw`,
  `renderFooter`, `renderToolViewport`, `renderLiveContent`,
  `appendTranscript`, `endTurn`, `prepareAssistantContentStart`,
  `repaintLiveContent`, `clearToolViewport`, `clearLiveContent`,
  `beginEditorRedraw`, `finishEditorRedraw`). Global wrappers delegate to
  `defaultEngine` methods. **Single choke point for all terminal output.**
- `src/threecode/ui.nim`: `handleCommandResult(cmd, messages, session,
  prof, editor: var minline.LineEditor)` — editor only touched for
  completion callbacks (provider wizard) and `echoRows` (line 1015).
  Modal commands (`:provider add/edit`) need the input thread.
- `src/threecode/session.nim`: `Session` object (usage, toolLog, savePath,
  profileName, created, cwd, plan, readCache) + `.3log` persistence
  (`saveSession`, `loadSessionFile`, `resolveSessionPath`, `newSessionPath`).
- Config: `loadStateOrEmpty(configPath())` -> (current, providers,
  colorKeys); `buildProfile(current, providers, wanted)`.
- Tests: `tests/stub_helpers.nim` builds a `providerStub` binary with a
  stub provider (`testdata/stub/provider.nim`) + stub http
  (`testdata/stub/http.nim`). Full REPL can run against stubs with no
  network. `tests/api/*` run callModel/turns paths already.

### Design (chosen)

New module `src/threecode/library.nim` (name avoids clash with existing
`api.nim` = HTTP transport; `session.nim` = .3log persistence).

```nim
type
  AgentEventKind* = enum
    aevDelta, aevReasoning, aevToolStart, aevToolLine, aevToolDone,
    aevRetry, aevNotice, aevDone, aevError
  AgentEvent* = object
    kind*: AgentEventKind
    text*: string          # delta chunk / tool banner / notice / error msg
    usage*: Usage          # aevDone only
    toolCode*: int         # aevToolDone only
  AgentSession* = ref object
    profile*: Profile
    messages*: JsonNode
    state*: Session        # existing .3log session record
    onEvent*: proc(ev: AgentEvent) {.closure.}   # callback interface
    # internal: previous hook state for save/restore
  AgentOptions* = object
    model*, cwd*, resumeId*, sessionPath*: string
    experimental*, debug*: bool
```

Procs (session first param):

- `initAgentSession(opts: AgentOptions): AgentSession` — load config,
  resolve profile, create/resume .3log, init sandbox, acquire locks,
  install headless hooks. No terminal, no input thread, no wizard.
- `prompt*(s: AgentSession, text: string): string` — blocking: run turn(s),
  return final assistant text. Events also fire to `onEvent` if set.
- `command*(s: AgentSession, cmd: string): string` — run `:cmd`, return
  plain body. Modal commands return an error string.
- `close*(s: AgentSession)` — save session, release locks, restore hooks.

Headless plumbing:

1. `engine.nim`: add `var engineOutputEnabled* = true`; global wrappers
   no-op when false. Terminal state vars stay consistent because mutations
   still run; only stdout writes are skipped. Cheap alternative: keep
   engine untouched and install hooks that never paint. Decision: gate in
   the thin global wrappers of engine.nim + termio.syncWrite/writeRaw.
2. `fatprompt/runtime.nim`: add `installApiHeadlessHooks(cb)` exporting a
   proc that wires `apiStreamHooks` to an `onEvent` callback; and a
   `headlessTranscriptHook` capturing `commitTranscriptBytes` text
   (ANSI-stripped) into events/notices. Save/restore around each
   `runTurns` call since hooks are global and CLI may share the process
   (tests). Actually: AgentSession supports multiple sessions sequentially
   in one process; hooks installed at init, restored at close. Concurrency
   of multiple live sessions is explicitly out of scope (documented).
3. `beginTurn` coupling: headless path must not start the input thread.
   `ensureInputThreadStarted` is called inside `beginTurn`. Gate:
   `if engineOutputEnabled: ensureInputThreadStarted()` — or better,
   headless runTurns never calls fatprompt beginTurn? No — beginTurn also
   sets input state flags. Simplest: gate the thread start and caret hide
   on `engineOutputEnabled`.
4. Commands: dummy editor. `handleCommandResult` needs
   `var minline.LineEditor`; AgentSession holds a private dummy
   (`minline.initEditor(historyFile = "")`) used only for the signature.
   Modal commands (`:provider add/edit`) return "requires interactive
   terminal". `:quit` family returns recognized quit signal.
5. Interrupt: `requestTurnInterrupt()` already exists (global flag);
   expose `interrupt*(s)` proc that sets it — works because the flag is
   global, documented as process-wide for now.
6. CLI refactor: `threecode.nim main()` keeps its existing terminal path
   (it IS the terminal frontend). It does NOT have to route through
   library.nim for rendering (that would be a rewrite of the fat prompt).
   What the CLI shares: session/config/profile/bootstrap logic. Extract
   the reusable setup from main into library.nim procs used by both:
   `setupSandbox(cwd)`, `loadConfigAndProfile(model, resumeProfile)`.
   This satisfies "the command line calls the API" at the session level
   without destabilizing the terminal rendering. (Documented decision;
   full REPL-through-API is a later, riskier step the user did not ask
   to force.)

### Testing

New `tests/api/test_library.nim`: build against providerStub defines,
init a session with stub provider, run `prompt` (blocking) and assert
reply text + tool execution happened; run `command(":tokens")` and assert
body; resume a saved session. Also callback interface: collect events,
assert aevDone arrives with usage. Wire into nimble test (testament
discovers tests/api/*.nim automatically — verify).

## Current state

Steps 1-6 done and committed. What exists now:

- `src/threecode/library.nim`: AgentOptions/AgentSession/AgentEvent,
  initAgentSession, close, prompt (blocking), promptAsync (threaded),
  command, interrupt, profileLabel, usage, resolveSessionProfile.
- engine.nim: `engineOutputEnabled` gates every global paint wrapper;
  `headlessTranscriptHook` receives committed transcript bytes.
- fatprompt/runtime.nim: `HeadlessStreamHooks` + `installApiHeadlessHooks`;
  `beginTurn` and `ensureGuiStarted` skip threads when output disabled.
- turns.nim `runTurns`: only re-installs terminal hooks when output enabled
  (headless hooks survive across turns).
- threecode.nim main(): profile resolution goes through the shared
  `resolveSessionProfile` (incl. activeCurrent sync on known-good fallback).
- tests/api/test_library.nim: matrix plain + `-d:providerStub`; covers
  blocking prompt with a bash tool call, deltas/done/tool events, :tokens,
  modal refusal, close+resume, unknown-model error. Both variants PASS.

Key discoveries recorded for later steps:
- The stub provider's response index is process-global; tests pad files.
- With a nil onEvent, the final reply arrives via the transcript hook and
  `prompt` returns it (contentFinished returns "not streamed" in that case).
- The GUI spinner thread is a pure animation in headless mode and is gated
  off; embedders get tool lines as aevTool events instead of a live viewport.

Step 7 done: README library section committed; full `nimble test`
suite run clean (62 PASS, 0 failures, exit 0) covering tty, stream, api,
config, shell, core. Final diff reviewed: 6 focused commits, +766/-120.
All steps [x]; the library API is complete and the CLI is unbroken.

## Steps

- [x] 1. Engine output gate: add `engineOutputEnabled*` to engine.nim,
  guard every global wrapper + `defaultEngine` stdout paths (or guard
  inside the object procs' write sites). Build; run tests/core/test_sync_frames
  + test_display to confirm terminal path unchanged.
- [x] 2. Headless hooks in fatprompt/runtime.nim: `installApiHeadlessHooks`
  (deltas, usage, retry -> callback), headless transcript capture hook in
  `commitTranscriptBytes`, gate `ensureInputThreadStarted` + caret hide in
  `beginTurn` on `engineOutputEnabled`. Build + full quick test pass.
- [x] 3. library.nim: types (AgentOptions, AgentSession, AgentEvent),
  `initAgentSession` (config load, profile resolve, sandbox init, locks,
  session create/resume — reusing config/session/sandbox procs, mirroring
  main() lines ~330-400 without terminal calls), `close`.
- [x] 4. library.nim: `prompt` (blocking; appends user msg, refreshes
  system prompt, runTurns, returns last assistant text) + `command`
  (classify via `classifyCommand`; reject ckModal/ckQuit with message;
  run `handleCommandResult` with dummy editor; return plainBody) +
  `interrupt`.
- [x] 5. tests/api/test_library.nim: stub-provider test covering init,
  blocking prompt with a tool call, callback events, command, resume,
  close. Green locally.
- [x] 6. CLI dedup: extract shared setup (sandbox init, config+profile
  resolution incl. known-good fallback) from threecode.nim main into
  library.nim; main calls it. Behavior identical; build + run cli_args
  tests.
- [x] 7. Docs: README section on library use with a minimal Nim example
  (web-server-shaped). `nimble test` full suite green. Final review of
  complete diff.
