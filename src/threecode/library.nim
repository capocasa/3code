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
## them. A session moves through an explicit lifecycle — idle, running
## (one turn in flight), closing, closed — and every public call gates on
## it: `prompt`/`promptAsync`/`command` on a closed session raise
## `AgentError` before touching hooks, files, model state, or tools, and
## a second concurrent submission is refused with the same error instead
## of racing through the conversation. `close` refuses while a turn runs
## (interrupt and join it first) and stays safe to repeat; a failed save
## is raised only after locks, hooks, and plugins are fully released.
## Initialization rejects a second open session before changing globals
## and rolls back every resource it acquired when it fails.

import std/[json, os, strutils, tables, times, atomics, locks]
import types, util, prompts, session, config, actions, api, compact, display,
       ui, plugins, auth_xai, auth_openai, auth_google, sandbox, minline,
       transcript, turns, goal
import btwthread
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

  SessionPhase = enum
    ## Lifecycle gate behind every public call. `spIdle` admits turns and
    ## commands; `spRunning` holds the one turn slot; `spClosing`/`spClosed`
    ## are terminal. The lock is never held while user callbacks or the
    ## turn itself run — only across the check-and-set.
    spIdle,
    spRunning,
    spClosing,
    spClosed

  AgentSession* = ref object
    profile*: Profile
    messages*: JsonNode
    state*: Session
    onEvent*: proc(ev: AgentEvent) {.closure.}
    editor: minline.LineEditor  # dummy; only fills handleCommandResult's sig
    lifeLock: Lock
    phase: SessionPhase
    turnWorker: Thread[TurnJob]
    turnWorkerActive: bool
    ## The async turn's worker slot. It must live in the session: Nim's
    ## thread wrapper keeps a pointer to the Thread object it was handed,
    ## so a handle built in `promptAsync`'s stack frame would leave the
    ## worker reading a dead stack frame (the pre-fix async crash).
    ## `promptAsync` returns a `TurnHandle` that joins this slot.

  AgentError* = object of CatchableError
    ## Initialization failures (no config, unknown model, locks held),
    ## closed/busy session rejections, and turn-level failures raised to
    ## the blocking caller.

  TurnJob = ref object
    ## createThread argument for `promptAsync`. The session and the prompt
    ## text travel in one heap box because thread procs can't capture.
    s: AgentSession
    text: string

  TurnHandle* = object
    ## What `promptAsync` returns: pass it to `joinTurn` to wait for the
    ## turn. Deliberately not a `Thread`: a Thread handed to Nim's wrapper
    ## must outlive the spawn frame, and one returned by value moves out
    ## of it.
    join: proc () {.closure.}

var agentSessionOwned: Atomic[bool]

const
  busyTurnMsg = "session busy: a turn is already in flight"
    ## Stable text for every refusal of a second concurrent submission,
    ## including a close that lands mid-turn.

proc phaseFault(s: AgentSession): string =
  ## Why the session cannot accept work right now ("" = it can).
  case s.phase
  of spIdle: ""
  of spRunning: busyTurnMsg
  of spClosing: "session close already in progress"
  of spClosed: "session is closed"

proc admitTurn(s: AgentSession) =
  ## Reserve the one turn slot, atomically against other threads and the
  ## worker. Raises `AgentError` without side effects when the session is
  ## closed, closing, or already running a turn.
  withLock s.lifeLock:
    let fault = phaseFault(s)
    if fault.len > 0:
      raise newException(AgentError, fault)
    s.phase = spRunning

proc releaseTurn(s: AgentSession) =
  ## Give the turn slot back. Runs on the caller's thread or the worker's;
  ## on every success/failure path of a turn.
  withLock s.lifeLock:
    if s.phase == spRunning: s.phase = spIdle

proc requireIdle(s: AgentSession) =
  ## Gate for non-turn operations (`command`) that mutate the conversation
  ## and so must not interleave with a running turn.
  withLock s.lifeLock:
    let fault = phaseFault(s)
    if fault.len > 0:
      raise newException(AgentError, fault)

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
  ## (`gateExperimental`), not what the config file says. A resumed
  ## session's profile that no longer resolves (its provider or model
  ## left the config since) falls through to the config current, the
  ## same way `:resume` keeps what is running. When nothing requested
  ## resolves, the last rung takes another model on the current
  ## provider, then another provider, and aligns `activeCurrent` so
  ## `currentProvider()`, `:model` and completion all agree with the
  ## profile actually running. An explicit model that does not resolve
  ## is the exception: it stays empty so the caller reports it instead
  ## of silently switching. Empty Profile only when no configured
  ## provider is usable; callers decide how to surface that (CLI:
  ## first-run wizard when there is no config file, else a warning;
  ## library: AgentError).
  result = buildProfile(activeCurrent, selectableProviders(), wanted)
  if result.name.len == 0 and wanted != "" and wanted == resumeProfile:
    result = buildProfile(activeCurrent, selectableProviders(), "")
  if result.name.len == 0 and wanted != "" and wanted != resumeProfile:
    return Profile()
  if result.name.len == 0:
    result = firstUsableProfile(activeCurrent, selectableProviders())
    if result.name.len > 0:
      activeCurrent = result.name

proc requireLive(s: AgentSession) =
  ## Guard for reads that describe a live session: safe mid-turn, refused
  ## once the session is closing or closed.
  withLock s.lifeLock:
    if s.phase in {spClosing, spClosed}:
      raise newException(AgentError, phaseFault(s))

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
  var locksHeld = false
  var hooksInstalled = false
  defer:
    # Rollback for every failure after the ownership claim: give back
    # exactly what this init acquired, in a fixed order, and leave the
    # globals usable for the next attempt. Nothing here may raise.
    if not initialized:
      if hooksInstalled:
        termengine.headlessTranscriptHook = nil
        termengine.engineOutputEnabled = true
        try: fatruntime.installApiStreamHooks()
        except CatchableError: discard
      if locksHeld:
        try: releaseActiveSessionLock()
        except CatchableError: discard
        try: releaseActiveDirLock()
        except CatchableError: discard
      if reservation.len > 0:
        try: removeFile(reservation)
        except OSError: discard
      agentSessionOwned.store(false)
  experimentalEnabled = opts.experimental
  debugEnabled = opts.debug
  let cwd = if opts.cwd.len > 0: opts.cwd else: safeCwd()
  # Project-local config discovery against the session cwd (the CLI
  # main does the same against the process cwd before dispatching
  # here). A `-C` in effect skips the walk.
  projectLayer = discoverProjectConfig(cwd)

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
  discard tryLoadStackOrEmpty()
  pluginsDiscoverAndLoad()

  var colorKeys: Table[string, string]
  (activeCurrent, activeProviders, colorKeys) = loadStackOrEmpty()
  # Directory-specific overlay (`.3code/config` in the session dir or
  # any parent, nearest wins) — applied after the full parse so the
  # user config's own values land first. Every [settings] key cascades
  # (compiled default < user config < nearest store); the security
  # switches only tighten under project stores, so whatever the arm
  # below sees is the user's choice or stricter.
  applyDirSettingsOverlay(cwd)
  # Default-provider ladder, same as the CLI main: the directory store
  # cascade first (this directory's or the nearest ancestor's
  # `:provider` / `:model` pick, when it still resolves), then the
  # config `current`, then the most-used ledger, then the first
  # [provider] section (inside buildProfile); selectableProviders()
  # keeps a limitproviders whitelist ahead of every rung — unless the
  # project layer pinned `current`: the repo pin owns selection, and
  # the per-directory sticky must not defeat it on every later start.
  if not (projectLayer != "" and currentOriginLayer == projectLayer):
    activeCurrent = resolveDefaultCurrent(cwd, activeCurrent,
                                          selectableProviders())
  if sandboxEnabled:
    sandbox.arm(cwd)

  var s = AgentSession()
  initLock(s.lifeLock)
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
  bumpProviderUsage(prof.name)
  s.profile = prof
  s.state.profileName = prof.name

  # Locks after profile resolution: a config error must fail fast without
  # claiming the directory. A failed acquisition (or any later failure)
  # rolls back through the defer above.
  try:
    acquireDirLock(s.state.cwd, s.state.savePath)
  except DirLocked as e:
    raise newException(AgentError, e.msg)
  try:
    acquireSessionLock(s.state.savePath)
  except SessionLocked as e:
    releaseDirLock(s.state.cwd)
    raise newException(AgentError, e.msg)
  # From here the rollback defer releases the locks this init holds.
  locksHeld = true

  # An embedding that turned on private mode continues the resumed
  # conversation in the private transcript directory, same as the CLI's
  # `-p --resume`. After the locks, mirroring the CLI's placement:
  # adopting swaps the session lock itself.
  discard adoptPrivateTranscriptDir(s.state)

  # Headless plumbing last, so a raised init leaves the terminal path
  # untouched. Once installed, the rollback defer restores it.
  hooksInstalled = true
  termengine.engineOutputEnabled = false
  termengine.headlessTranscriptHook = proc(bytes: string) =
    let text = normalizeItem(bytes)
    if text.len == 0: return
    s.emit(AgentEvent(kind: aevTool, text: text, toolCode: -1))
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
  ## Refused with `AgentError` while a turn runs or a close is already in
  ## progress - interrupt and join the worker first - and safe to repeat
  ## after actual closure. Cleanup is mandatory and ordered: the final
  ## save is attempted, every lock this process owns is released, the
  ## headless hooks are restored, plugin teardown completes, and the
  ## per-process session slot is freed even when the save raised - the
  ## terminal state is marked last. Only then is a persistence failure
  ## reported on stderr: it never skips ownership release or keeps the
  ## slot reserved.
  withLock s.lifeLock:
    case s.phase
    of spClosed: return
    of spClosing:
      raise newException(AgentError, "session close already in progress")
    of spRunning:
      raise newException(AgentError, "close refused: " & busyTurnMsg)
    of spIdle: s.phase = spClosing
  var saveErr: ref SessionSaveError = nil
  try: saveSession(s.state, s.messages)
  except SessionSaveError as e: saveErr = e
  try: releaseActiveSessionLock() except CatchableError: discard
  try: releaseActiveDirLock() except CatchableError: discard
  try:
    termengine.headlessTranscriptHook = nil
    termengine.engineOutputEnabled = true
    fatruntime.installApiStreamHooks()
  except CatchableError: discard
  try: pluginsShutdown() except CatchableError: discard
  # Last: a new init must not start while teardown is still running.
  agentSessionOwned.store(false)
  withLock s.lifeLock: s.phase = spClosed
  if saveErr != nil: reportSaveFailure(saveErr)

# ---------- prompts and commands ----------

proc promptBody(s: AgentSession; text: string): string =
  ## Turn implementation shared by `prompt` and the `promptAsync` worker.
  ## The caller holds the turn reservation; this proc neither admits nor
  ## releases it, so the two entry points never double-book the slot.
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
                        sessionImageDir(s.state.savePath),
                        lastBash = lastBashInclude(s.state.toolLog),
                        lastPrompt = s.state.lastPrompt)}
    if text.strip.len > 0:
      s.state.lastPrompt = text
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
  ## as they happen. Raises `AgentError` on turn failure, on an empty
  ## prompt with no conversation to continue yet, and on a closed session
  ## or an already-running turn (before any model or tool call); the turn
  ## slot is released on every path, so the session stays valid.
  admitTurn(s)
  try:
    result = promptBody(s, text)
  finally:
    releaseTurn(s)

proc promptThread(job: TurnJob) {.thread.} =
  {.cast(gcsafe).}:
    # The slot was reserved by `promptAsync` before the spawn; the worker
    # releases it when the shared turn body returns or raises.
    try:
      discard promptBody(job.s, job.text)
    except CatchableError as e:
      job.s.emit(AgentEvent(kind: aevError, text: e.msg))
    finally:
      releaseTurn(job.s)

proc promptAsync*(s: AgentSession; text: string): TurnHandle =
  ## Threaded interface: run the turn on a library-managed worker thread;
  ## events (including aevDone/aevError) arrive on `onEvent` from that
  ## thread. `joinTurn(result)` waits for the turn and is safe to skip:
  ## the next admission joins a finished worker itself. Only one turn per
  ## session at a time: the slot is reserved here, before the spawn, and
  ## a second call raises `AgentError` instead of entering (as does a
  ## blocking `prompt` from another thread). A failed spawn releases the
  ## slot before re-raising.
  admitTurn(s)
  if s.turnWorkerActive:
    joinThread(s.turnWorker)
    s.turnWorkerActive = false
  try:
    createThread(s.turnWorker, promptThread, TurnJob(s: s, text: text))
  except CatchableError:
    releaseTurn(s)
    raise
  s.turnWorkerActive = true
  result.join = proc () =
    joinThread(s.turnWorker)
    s.turnWorkerActive = false

proc joinTurn*(h: TurnHandle) =
  ## Wait for the async turn started by `promptAsync`. Safe to repeat and
  ## safe to skip: the next `promptAsync` joins a finished worker itself.
  if h.join != nil: h.join()

proc command*(s: AgentSession; cmd: string): string =
  ## Run a colon command (`:tokens`, `:model ...`, `:sandbox show`, ...)
  ## exactly as the REPL would and return its plain-text body. Modal
  ## commands that need an interactive terminal (`:provider add/edit`)
  ## return an error string. `:quit` raises `AgentError` — quitting is
  ## the embedder's `close`. Raises `AgentError` on a closed session or
  ## while a turn is running (commands mutate the conversation).
  requireIdle(s)
  case classifyCommand(cmd)
  of ckModal:
    return "command requires an interactive terminal: " & cmd.strip
  of ckQuit:
    raise newException(AgentError, "use close() to end a session")
  else: discard
  let res = handleCommandResult(cmd, s.messages, s.state, s.profile, s.editor)
  if not res.recognized:
    return "unknown command: " & cmd.strip & "  (try :help)"
  result = normalizeItem(res.body)
  if res.startGoalTurn and not noMode(res.armMode):
    # The REPL controller appends the kickoff message and runs the
    # kickoff turn the moment a mode-verb arm yields; this API is the
    # controller here, so the arm does the same before it returns. A
    # transcript mode IS its kickoff message - skipping this would
    # validate the arm and then drop it on the floor.
    s.state.goalNotified = true
    s.state.modeSnapshot =
      if res.armMode.transcript: res.armText
      else: readModeText(res.armMode, s.state.cwd, s.messages)
    if s.state.readCache != nil:
      s.state.changeCountStart = s.state.readCache.changes.len
    s.messages.add res.armMode.kickoffMessage(
      if res.armMode.transcript: res.armText
      else: readModeText(res.armMode, s.state.cwd, s.messages))
    saveSession(s.state, s.messages)
    result = normalizeItem(promptBody(s, ""))
  # A `:clear <text>` arm: the clear ran in the handler, the text now
  # runs as the next ordinary prompt on the fresh context and its reply
  # is the command's answer.
  if res.ok and res.followPrompt.len > 0:
    result = normalizeItem(promptBody(s, res.followPrompt))
  # A `:btw` fires on a worker thread (the REPL command never blocks);
  # this API is synchronous by contract, so the answer is joined and
  # folded into the returned body instead of being dropped, under the
  # `?` question line the REPL commits in place of the echoed command.
  # Its tokens are ledgered and summed onto the bar exactly as the REPL's
  # delivery path does. The command only posts the question (it may run on
  # a thread that does not own the history, in the REPL); this API is the
  # owner and no turn is running here, so it fires the question itself.
  for question in takePostedBtw():
    discard startBtw(question, s.messages, s.profile)
  if btwJobsLive() > 0:
    if res.btwQuestion != "":
      # The `?` question line above the answers (the REPL's item shape).
      result = BtwQuestionIcon & " " & res.btwQuestion
    var replies: seq[BtwReply]
    waitBtw(replies)
    for r in replies:
      if r.cancelled:
        result.add "\n\nbtw: " & InterruptedByUserMsg
        continue
      if r.answer.strip.len == 0:
        result.add "\n\nbtw: no answer (the side-question call failed)"
        continue
      accountSideCallUsage(s.state, s.messages, r.usage,
                           contextWindowFor(s.profile))
      result.add "\n\n" & normalizeItem(btwAnswerBytes(r.answer))

proc interrupt*(s: AgentSession) =
  ## Cancel the in-flight turn (same mechanism as Ctrl-C in the CLI).
  ## The running `prompt` call returns by raising `AgentError` with the
  ## interrupted message. Process-wide: every live session observes it.
  requestTurnInterrupt("library-interrupt")

proc profileLabel*(s: AgentSession): string =
  ## Short "provider.model" label for display. Raises `AgentError` on a
  ## closed session: a dead handle does not describe anything.
  requireLive(s)
  s.profile.name

proc usage*(s: AgentSession): Usage =
  ## Cumulative token usage for the session. Raises `AgentError` on a
  ## closed session; safe to read mid-turn, the copy is taken under the
  ## lifecycle lock.
  requireLive(s)
  withLock s.lifeLock:
    result = s.state.usage
