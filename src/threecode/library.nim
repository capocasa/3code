## Library API: embed 3code in another program.
##
## This module is the headless frontend. It runs the same agent loop the
## CLI runs (same `runTurns`, same tools, same sandbox, same `.3log`
## sessions) with the terminal replaced by plain return values and
## callbacks. A web server, GUI, or batch script drives a session with
## three procs:
##
## ```nim
## let s = initAgentSession(AgentOptions(model: "deepinfra.deepseek-v3.2"))
## let reply = s.prompt("what does this project do?")     # blocking
## echo s.command(":tokens")                              # colon commands
## s.close()
## ```
##
## For streaming, set `onEvent` before prompting:
##
## ```nim
## s.onEvent = proc(ev: AgentEvent) =
##   case ev.kind
##   of aevDelta: stdout.write ev.text
##   of aevToolLine: stderr.writeLine ev.text
##   else: discard
## discard s.prompt("run the tests")
## ```
##
## Everything is blocking; the library manages its own threads internally.
## One live `AgentSession` per process: stream hooks, the interrupt flag,
## and the config/sandbox globals are process-wide, and `close` restores
## them. The lifecycle is enforced: a closed session refuses
## `prompt`/`promptAsync`/`command` with a stable `AgentError`, a session
## with a turn in flight refuses a second turn and `command` alike (one
## reservation covers blocking and async submissions), and `close` is
## idempotent but refuses while a turn runs — `interrupt`, join the
## worker, then close. Still serialize `prompt`/`command` from one worker
## thread per session; initialization rejects a second open session
## before changing globals.

import std/[json, locks, os, strutils, tables, times, atomics]
import types, util, prompts, session, config, actions, api, display, ui, plugins,
       auth_xai, auth_openai, auth_google, sandbox, minline, transcript, turns
import dirsettings
import fatprompt as fatruntime
import engine as termengine

type
  AgentEventKind* = enum
    aevDelta       ## streaming assistant text chunk (`text`)
    aevReasoning   ## streaming reasoning trace (`text`)
    aevTool        ## committed tool result / transcript line (`text`,
                   ## `toolCode` carries the exit code, -1 when n/a)
    aevRetry       ## provider retry notice (`text`)
    aevNotice      ## harness notice: steering, compaction, usage (`text`)
    aevDone        ## model call finished (`usage`, `elapsed`)
    aevError       ## turn failed (`text`)

  AgentEvent* = object
    kind*: AgentEventKind
    text*: string
    usage*: Usage
    elapsed*: int
    toolCode*: int

  AgentOptions* = object
    ## Everything the CLI takes from flags and config, as fields. Empty
    ## `model` resolves the config default; empty `cwd` uses the process
    ## cwd; empty `sessionPath` picks a fresh timestamped path (or the
    ## resolved resume target).
    model*: string        ## PROVIDER[.MODEL], overrides config default
    cwd*: string          ## working dir for tools and the sandbox policy
    resumeId*: string     ## session id (or "" with `resume` for latest)
    resume*: bool         ## resume the latest session for `cwd`
    sessionPath*: string  ## explicit .3log path for a new session
    experimental*: bool   ## allow combos outside the known-good list
    debug*: bool          ## colored debug trace to stderr

  AgentSession* = ref object
    profile*: Profile
    messages*: JsonNode
    state*: Session
    onEvent*: proc(ev: AgentEvent) {.closure.}
    editor: minline.LineEditor  # dummy; only fills handleCommandResult's sig
    life: SessionLife
    gate: Lock
    worker: Thread[TurnJob]
    workerStarted: bool

  SessionLife = enum
    ## Explicit lifecycle behind every public entry point: closed/closing
    ## sessions refuse work, a running session refuses competing work.
    slIdle      ## open and idle: turns and commands are admitted
    slRunning   ## a turn is in flight
    slClosing   ## terminal: close cleanup is running
    slClosed    ## terminal: unusable; every entry point refuses

  TurnJob = ref object
    ## createThread argument for `promptAsync`. The session and the prompt
    ## text travel in one heap box because thread procs can't capture.
    s: AgentSession
    text: string

  AgentError* = object of CatchableError
    ## Initialization failures (no config, unknown model, locks held),
    ## closed/busy session rejections, and turn-level failures when the
    ## call is blocking (async turns return them via aevError instead).

const
  # Stable rejection messages: closed/busy sessions fail with the same
  # text every time, so embedders can branch on them.
  busyTurnMsg = "a turn is already running"
  closedSessionMsg = "session is closed"
  closeBusyMsg =
    "cannot close: a turn is in flight (interrupt and join the worker first)"
  closeClosingMsg = "close already in progress"

var agentSessionOwned: Atomic[bool]

# ---------- ANSI stripping ----------
#
# Transcript items arrive styled for the terminal. The library surface is
# plain text, so committed items are stripped here. Operates on raw bytes:
# a multi-byte UTF-8 sequence never contains a 0x1b byte, so a byte scan
# can't split a codepoint.

proc stripAnsi(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == ']':
      # OSC (e.g. an OSC 8 hyperlink): swallow through BEL or ST so the
      # invisible URI doesn't leak into the plain-text surface.
      i += 2
      while i < s.len and s[i] != '\x07' and s[i] != '\x1b':
        inc i
      if i < s.len and s[i] == '\x07':
        inc i
      elif i < s.len and s[i] == '\x1b' and i + 1 < s.len and
          s[i + 1] == '\\':
        inc i, 2
    elif s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '[':
      i += 2
      while i < s.len and s[i] notin {'m', 'K', 'J', 'H', 'A', 'B', 'C', 'D',
                                      'G', 'f', 'h', 'l', 'q', 's', 'u'}:
        inc i
      inc i  # skip the terminator
    else:
      result.add s[i]
      inc i

proc normalizeItem(bytes: string): string =
  ## One transcript item as plain text: ANSI stripped, \r\n -> \n, trimmed.
  stripAnsi(bytes).replace("\r\n", "\n").replace('\r', '\n').strip

proc emit(s: AgentSession; ev: AgentEvent) =
  if s.onEvent != nil:
    s.onEvent(ev)

# ---------- init / close ----------

proc combinedSubscriptionTokenFor(provider: string): string =
  ## Single resolver installed as `config.subscriptionTokenForImpl`:
  ## xAI (supergrok) first, then ChatGPT (chatgpt). Each module vends ""
  ## for names it does not own.
  result = auth_xai.subscriptionTokenFor(provider)
  if result == "":
    result = auth_openai.subscriptionTokenFor(provider)
  if result == "":
    result = auth_google.subscriptionTokenFor(provider)

proc resolveSessionProfile*(wanted, resumeProfile: string): Profile =
  ## Resolve the effective profile the same way the CLI does: explicit
  ## model > resumed session's profile > config current. An explicit
  ## config current is the user's word and runs as-is; known-good
  ## curation gates interactive `:provider`/`:model` picks
  ## (`gateExperimental`), not what the config file says. Empty Profile
  ## when nothing resolves (first run, unknown model); callers decide
  ## how to surface that (CLI: provider wizard; library: AgentError).
  result = buildProfile(activeCurrent, activeProviders, wanted)

proc beginTurn(s: AgentSession) =
  ## Claim the turn slot (idle -> running). Raises `AgentError` when the
  ## session is closed or a turn is already in flight. The gate is never
  ## held while the turn itself runs, so user callbacks fire unlocked.
  withLock s.gate:
    case s.life
    of slIdle: s.life = slRunning
    of slRunning: raise newException(AgentError, busyTurnMsg)
    of slClosing, slClosed: raise newException(AgentError, closedSessionMsg)

proc endTurn(s: AgentSession) =
  withLock s.gate:
    if s.life == slRunning: s.life = slIdle

proc requireOpen(s: AgentSession) =
  ## Guard for entry points and reads that must describe a live session.
  withLock s.gate:
    if s.life in {slClosing, slClosed}:
      raise newException(AgentError, closedSessionMsg)

proc initAgentSession*(opts: AgentOptions): AgentSession =
  ## Create or resume a session and install the headless plumbing.
  ## Raises `AgentError` when no usable provider is configured, the model
  ## doesn't resolve, or the directory/session locks are held by a live
  ## 3code process. Every resource acquired on the way (reservation
  ## file, locks, headless hooks, the per-process slot) is rolled back
  ## when a later step fails, so a failed init leaves nothing claimed.
  if agentSessionOwned.exchange(true):
    raise newException(AgentError, "only one AgentSession may be open per process")
  var initialized = false
  var reservation = ""
  var dirLockHeld = false
  var sessionLockHeld = false
  var headlessInstalled = false
  defer:
    if not initialized:
      if reservation.len > 0:
        try: removeFile(reservation)
        except OSError: discard
      if sessionLockHeld: releaseActiveSessionLock()
      if dirLockHeld: releaseActiveDirLock()
      if headlessInstalled:
        termengine.headlessTranscriptHook = nil
        termengine.engineOutputEnabled = true
        fatruntime.installApiStreamHooks()
      agentSessionOwned.store(false)
  experimentalEnabled = opts.experimental
  debugEnabled = opts.debug
  let cwd = if opts.cwd.len > 0: opts.cwd else: safeCwd()

  materializeBuiltinSkills()

  # Config first (it reads `[settings] sandbox = off`), then the
  # sandbox: same single-file policy as the CLI. Paths resolve
  # against the session cwd so the policy follows the project.
  subscriptionTokenForImpl = combinedSubscriptionTokenFor
  extraHeadersImpl = chatgptExtraHeaders
  api.bearerHook = subscriptionBearer
  api.extraHeadersHook = extraHeadersFor

  # Plugins load BEFORE the full config parse, exactly like the CLI:
  # a tolerant pre-parse supplies the [plugins] gates (disable, lib),
  # then tc_register_config defaults are in the table by the time the
  # real parse below applies them. In a CLI/headless run the load
  # already happened at argv time and both calls are no-ops.
  discard tryLoadStateOrEmpty(configPath())
  pluginsDiscoverAndLoad()

  var colorKeys: Table[string, string]
  (activeCurrent, activeProviders, colorKeys) = loadStateOrEmpty(configPath())
  # Directory-specific overlay (`.3code/config` in the session dir or
  # any parent, nearest wins) — applied after the full parse so the
  # user config's own switches cannot undo it. Sandbox-off here must
  # land before the `if sandboxEnabled` arm below.
  dirsettings.applyDirConfig(cwd)
  # Per-directory sticky current, same resolution as the CLI main: this
  # directory's last `:provider` / `:model` wins when it still resolves.
  block:
    let dirCurrent = loadDirCurrent(cwd)
    if dirCurrent != "" and
       buildProfile(dirCurrent, activeProviders, "").name.len > 0:
      activeCurrent = dirCurrent
      # The overlay is not a switch: mark it so config writes know this
      # instance never authored its current and must not hoist it into
      # the user config (see config.dirStickyCurrent).
      dirStickyCurrent = dirCurrent
  if sandboxEnabled:
    sandbox.arm(cwd)

  var s = AgentSession()
  initLock(s.gate)
  s.editor = minline.initEditor(historyFile = "")

  if opts.resume or opts.resumeId.len > 0:
    let path = resolveSessionPath(opts.resumeId, cwd)
    if path.len == 0:
      raise newException(AgentError,
        if opts.resumeId.len > 0: "session not found: " & opts.resumeId
        else: "no saved sessions for " & cwd)
    (s.state, s.messages) = loadSessionFile(path)
  else:
    if opts.sessionPath.len == 0: reservation = newSessionPath()
    s.messages = %* [{"role": "system", "content": DefaultSystemPrompt}]
    s.state = Session(created: $now(), cwd: cwd,
      savePath: if opts.sessionPath.len > 0: opts.sessionPath
                else: reservation)

  let wanted =
    if opts.model.len > 0: opts.model
    elif (opts.resume or opts.resumeId.len > 0) and
         s.state.profileName.len > 0: s.state.profileName
    else: ""
  let prof = resolveSessionProfile(wanted, s.state.profileName)
  if prof.name.len == 0:
    raise newException(AgentError,
      "no provider configured. Create one with the 3code CLI (:provider add) " &
      "or pass a model in AgentOptions.")
  s.profile = prof
  s.state.profileName = prof.name

  # Locks after profile resolution: a config error must fail fast without
  # claiming the directory. A failed acquisition (or any later failure)
  # rolls back through the defer above.
  try:
    acquireDirLock(s.state.cwd, s.state.savePath)
    dirLockHeld = true
  except DirLocked as e:
    raise newException(AgentError, e.msg)
  try:
    acquireSessionLock(s.state.savePath)
    sessionLockHeld = true
  except SessionLocked as e:
    raise newException(AgentError, e.msg)

  # An embedding that turned on private mode continues the resumed
  # conversation in the private transcript directory, same as the CLI's
  # `-p --resume`. After the locks, mirroring the CLI's placement:
  # adopting swaps the session lock itself.
  discard adoptPrivateTranscriptDir(s.state)

  # Headless plumbing last, so a raised init leaves the terminal path
  # untouched.
  termengine.engineOutputEnabled = false
  termengine.headlessTranscriptHook = proc(bytes: string) =
    let text = normalizeItem(bytes)
    if text.len == 0: return
    s.emit(AgentEvent(kind: aevTool, text: text, toolCode: -1))
  headlessInstalled = true
  fatruntime.installApiHeadlessHooks(fatruntime.HeadlessStreamHooks(
    contentDelta: proc(chunk: string) =
      s.emit(AgentEvent(kind: aevDelta, text: chunk)),
    reasoningDelta: proc(text: string) =
      s.emit(AgentEvent(kind: aevReasoning, text: text)),
    contentFinished: nil,  # turn-end reply arrives via the transcript hook
    finalUsage: proc(usage: Usage; elapsed: int) =
      s.emit(AgentEvent(kind: aevDone, usage: usage, elapsed: elapsed)),
    retryNotice: proc(msg: string) =
      s.emit(AgentEvent(kind: aevRetry, text: msg))))
  # Plugins: for the CLI they load before argv is parsed (their CLI
  # surface must exist first); here at session init, before the first
  # prompt. The session event fires with the final profile.
  pluginsDiscoverAndLoad()
  pluginOnSessionStart(s.state.savePath, s.state.cwd, s.profile.name,
                       s.profile.model, opts.resume or opts.resumeId.len > 0,
                       s.messages.len)
  initialized = true
  s

proc close*(s: AgentSession) =
  ## Persist the session, release locks, and restore the terminal-facing
  ## hooks so the process can go back to CLI use (or init a new session).
  ##
  ## Lifecycle: an idle session closes; a session with a turn in flight
  ## refuses with `AgentError` - close never blocks on, or self-joins, a
  ## running turn. The embedder's shutdown order is `interrupt`, join the
  ## `promptAsync` worker, then `close`; a close called from an event or
  ## plugin callback therefore always lands on a running/closing session
  ## and raises the same stable error. Repeated close after the terminal
  ## state is a no-op: an old handle's second close cannot clear a newer
  ## session's hooks or locks.
  ##
  ## Cleanup is mandatory even when parts of it fail: the final save is
  ## attempted, every lock this process owns is released, the headless
  ## hooks are restored, plugin teardown completes, and the per-process
  ## session slot is freed even when the save or shutdown raised - the
  ## terminal state is marked last. Only then is a persistence failure
  ## reported on stderr: it never skips ownership release or keeps the
  ## slot reserved.
  block:
    withLock s.gate:
      case s.life
      of slClosed: return
      of slIdle: s.life = slClosing
      of slRunning: raise newException(AgentError, closeBusyMsg)
      of slClosing: raise newException(AgentError, closeClosingMsg)
  var saveErr: ref SessionSaveError = nil
  try: saveSession(s.state, s.messages)
  except SessionSaveError as e: saveErr = e
  releaseActiveSessionLock()
  releaseActiveDirLock()
  termengine.headlessTranscriptHook = nil
  termengine.engineOutputEnabled = true
  fatruntime.installApiStreamHooks()
  pluginsShutdown()
  agentSessionOwned.store(false)
  withLock s.gate:
    s.life = slClosed
  if saveErr != nil: reportSaveFailure(saveErr)

# ---------- prompts and commands ----------

proc runTurnBlocking(s: AgentSession; text: string): string =
  ## One admitted turn, without the lifecycle reservation: the shared
  ## body of `prompt` and the `promptAsync` worker (which reserves
  ## before spawning, so the body must not reserve again).
  if text.strip.len == 0:
    if s.messages.len <= 1:
      raise newException(AgentError,
        "empty prompt: no conversation to continue yet")
  else:
    var promptText = text
    pluginOnPrompt(promptText, s.state.savePath, s.profile.name, s.profile.model)
    s.messages.add %*{"role": "user",
                      "content": buildUserMessage(s.messages, promptText,
                        s.state.cwd, s.profile.vision,
                        sessionImageDir(s.state.savePath))}
    refreshSystemPrompt(s.messages, s.profile, s.state.promptState)
    clearDraft(s.state)
  let interrupted = runTurnsInteractive(s.profile, s.messages, s.state)
  saveSession(s.state, s.messages)
  if interrupted:
    raise newException(AgentError, InterruptedByUserMsg)
  # The final assistant text is the last assistant message's content.
  # Tool turns end with the model's closing reply; an empty reply
  # surfaces as "" (runTurns already emitted its notices). Dmail
  # checkpoint markers stay in the stored content but are harness
  # bookkeeping, not reply text, so they are stripped here like the
  # terminal path strips them at paint time.
  for i in countdown(s.messages.len - 1, 0):
    let m = s.messages[i]
    if m.kind == JObject and m{"role"}.getStr == "assistant":
      return cutPartialTrailingMarker(stripCheckpointMarkers(m{"content"}.getStr("")))
  ""

proc prompt*(s: AgentSession; text: string): string =
  ## Blocking interface: submit a user prompt, run the full turn loop
  ## (model calls + tool calls until the model stops calling tools), and
  ## return the final assistant text. An empty (or whitespace-only) text
  ## continues the session instead: a turn runs on the messages exactly
  ## as they stand, appending no user message, the embedder's way to say
  ## "keep going" (e.g. after a cancelled turn). Events stream to `onEvent`
  ## as they happen. Raises `AgentError` on turn failure, on a closed
  ## session, or when a turn is already running (async vs blocking alike:
  ## the reservation is taken before any model/tool/file work), or on an
  ## empty prompt with no conversation to continue yet; a rejected call
  ## touches no hooks, files, model state, or tools, and the session
  ## stays valid and saved after a failed turn. Raises
  ## `SessionSaveError` when persisting the turn fails: the in-memory
  ## conversation is intact, and the on-disk transcript keeps its
  ## previous content unless the error reports `committed`.
  beginTurn(s)
  try:
    result = runTurnBlocking(s, text)
  finally:
    endTurn(s)

proc promptThread(job: TurnJob) {.thread.} =
  {.cast(gcsafe).}:
    try:
      discard runTurnBlocking(job.s, job.text)
    except CatchableError as e:
      job.s.emit(AgentEvent(kind: aevError, text: e.msg))
    finally:
      endTurn(job.s)

proc promptAsync*(s: AgentSession; text: string) =
  ## Threaded interface: run the turn on a library-managed worker thread;
  ## events (including aevDone/aevError) arrive on `onEvent` from that
  ## thread. `joinTurn(s)` waits for the worker. Only one turn per
  ## session at a time: the reservation is taken here, before the worker
  ## spawns, so two concurrent `promptAsync` calls cannot both enter,
  ## and a failed thread creation releases it. Raises `AgentError` on a
  ## closed or busy session.
  ##
  ## The thread record lives in the session: `createThread` hands the
  ## worker a pointer to its argument slot, so a handle in the caller's
  ## frame would be read after that frame is gone (the old
  ## return-a-Thread API was exactly that race). The slot lives as long
  ## as the session; a later `promptAsync` joins the previous worker
  ## before reusing it.
  beginTurn(s)
  try:
    if s.workerStarted: joinThread(s.worker)
    s.workerStarted = true
    createThread(s.worker, promptThread, TurnJob(s: s, text: text))
  except CatchableError as e:
    endTurn(s)
    raise e

proc joinTurn*(s: AgentSession) =
  ## Wait for a `promptAsync` worker to finish (instant when none ever
  ## started or it already ran). Part of the shutdown order:
  ## `interrupt`, `joinTurn`, then `close`. The driving thread's call:
  ## serialize with `promptAsync` like every other session call.
  if s.workerStarted:
    joinThread(s.worker)
    s.workerStarted = false

proc command*(s: AgentSession; cmd: string): string =
  ## Run a colon command (`:tokens`, `:model ...`, `:sandbox show`, ...)
  ## exactly as the REPL would and return its plain-text body. Modal
  ## commands that need an interactive terminal (`:provider add/edit`)
  ## return an error string. `:quit` raises `AgentError` — quitting is
  ## the embedder's `close`. Raises `AgentError` on a closed session or
  ## while a turn is running (commands mutate the conversation, so they
  ## are never admitted mid-turn).
  withLock s.gate:
    case s.life
    of slIdle: discard
    of slRunning: raise newException(AgentError, busyTurnMsg)
    of slClosing, slClosed: raise newException(AgentError, closedSessionMsg)
  case classifyCommand(cmd)
  of ckModal:
    return "command requires an interactive terminal: " & cmd.strip
  of ckQuit:
    raise newException(AgentError, "use close() to end a session")
  else: discard
  let res = handleCommandResult(cmd, s.messages, s.state, s.profile, s.editor)
  if not res.recognized:
    return "unknown command: " & cmd.strip & "  (try :help)"
  normalizeItem(res.body)

proc interrupt*(s: AgentSession) =
  ## Cancel the in-flight turn (same mechanism as Ctrl-C in the CLI).
  ## The running `prompt` call returns by raising `AgentError` with the
  ## interrupted message. Process-wide: every live session observes it.
  requestTurnInterrupt("library-interrupt")

proc profileLabel*(s: AgentSession): string =
  ## Short "provider.model" label for display. Raises `AgentError` on a
  ## closed session: a dead handle does not describe anything.
  requireOpen(s)
  s.profile.name

proc usage*(s: AgentSession): Usage =
  ## Cumulative token usage for the session. Raises `AgentError` on a
  ## closed session.
  requireOpen(s)
  s.state.usage
