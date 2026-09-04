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
## them. `prompt`/`command` on one session are not thread-safe; serialize
## calls (one worker thread per session is the intended shape).

import std/[json, os, strutils, tables, times]
import types, util, prompts, session, config, actions, api, display, ui,
       auth_xai, auth_openai, sandbox, minline, transcript, turns
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
    closed: bool

  AgentError* = object of CatchableError
    ## Initialization failures (no config, unknown model, locks held).
    ## Turn-level failures are returned by `prompt` via aevError instead.

  TurnJob = ref object
    ## createThread argument for `promptAsync`. The session and the prompt
    ## text travel in one heap box because thread procs can't capture.
    s: AgentSession
    text: string

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
    if s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '[':
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

proc resolveSessionProfile*(wanted, resumeProfile: string): Profile =
  ## Resolve the effective profile the same way the CLI does: explicit
  ## model > resumed session's profile > config current, with the
  ## known-good fallback when the resolved combo isn't curated and
  ## `--experimental` wasn't given. A fallback also updates `activeCurrent`
  ## so later lookups (`:provider`, status lines) agree with the session.
  ## Empty Profile when nothing resolves (first run, unknown model);
  ## callers decide how to surface that (CLI: provider wizard; library:
  ## AgentError).
  result = buildProfile(activeCurrent, activeProviders, wanted)
  if wanted.len == 0 and not experimentalEnabled and result.name.len > 0 and
     not isKnownGood(result):
    let fallback = firstKnownGoodCombo(activeProviders)
    if fallback.len > 0:
      let alt = buildProfile(fallback, activeProviders, "")
      if alt.name.len > 0:
        activeCurrent = alt.name
        result = alt

proc initAgentSession*(opts: AgentOptions): AgentSession =
  ## Create or resume a session and install the headless plumbing.
  ## Raises `AgentError` when no usable provider is configured, the model
  ## doesn't resolve, or the directory/session locks are held by a live
  ## 3code process.
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

  var colorKeys: Table[string, string]
  (activeCurrent, activeProviders, colorKeys) = loadStateOrEmpty(configPath())
  if sandboxEnabled:
    sandbox.current = sandbox.loadPolicy(cwd)
    sandbox.active = true
    sandbox.procboxExe = sandbox.findProcbox()
    if not sandbox.backendWorks(sandbox.procboxExe):
      sandbox.procboxExe = ""

  var s = AgentSession()
  s.editor = minline.initEditor(historyFile = "")

  if opts.resume or opts.resumeId.len > 0:
    let path = resolveSessionPath(opts.resumeId, cwd)
    if path.len == 0:
      raise newException(AgentError,
        if opts.resumeId.len > 0: "session not found: " & opts.resumeId
        else: "no saved sessions for " & cwd)
    (s.state, s.messages) = loadSessionFile(path)
  else:
    s.messages = %* [{"role": "system", "content": DefaultSystemPrompt}]
    s.state = Session(created: $now(), cwd: cwd,
      savePath: if opts.sessionPath.len > 0: opts.sessionPath
                else: newSessionPath())

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
  # claiming the directory. Lock failures roll back in reverse order.
  try:
    acquireDirLock(s.state.cwd, s.state.savePath)
  except DirLocked as e:
    raise newException(AgentError, e.msg)
  try:
    acquireSessionLock(s.state.savePath)
  except SessionLocked as e:
    releaseDirLock(s.state.cwd)
    raise newException(AgentError, e.msg)

  # Headless plumbing last, so a raised init leaves the terminal path
  # untouched.
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
  s

proc close*(s: AgentSession) =
  ## Persist the session, release locks, and restore the terminal-facing
  ## hooks so the process can go back to CLI use (or init a new session).
  if s.closed: return
  s.closed = true
  try: saveSession(s.state, s.messages) except CatchableError: discard
  releaseActiveSessionLock()
  releaseActiveDirLock()
  termengine.headlessTranscriptHook = nil
  termengine.engineOutputEnabled = true
  fatruntime.installApiStreamHooks()

# ---------- prompts and commands ----------

proc prompt*(s: AgentSession; text: string): string =
  ## Blocking interface: submit a user prompt, run the full turn loop
  ## (model calls + tool calls until the model stops calling tools), and
  ## return the final assistant text. Events stream to `onEvent` as they
  ## happen. Raises `AgentError` on turn failure; the session stays valid
  ## and saved.
  s.messages.add %*{"role": "user",
                    "content": buildUserMessage(s.messages, text)}
  refreshSystemPrompt(s.messages, s.profile)
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
      return stripCheckpointMarkers(m{"content"}.getStr(""))
  ""

proc promptThread(job: TurnJob) {.thread.} =
  {.cast(gcsafe).}:
    try:
      discard job.s.prompt(job.text)
    except CatchableError as e:
      job.s.emit(AgentEvent(kind: aevError, text: e.msg))

proc promptAsync*(s: AgentSession; text: string): Thread[TurnJob] =
  ## Threaded interface: run `prompt` on a library-managed worker thread
  ## and return it; events (including aevDone/aevError) arrive on
  ## `onEvent` from that thread. `joinThread(result)` to wait for the
  ## turn. Only one turn per session at a time.
  createThread(result, promptThread, TurnJob(s: s, text: text))

proc command*(s: AgentSession; cmd: string): string =
  ## Run a colon command (`:tokens`, `:model ...`, `:sandbox show`, ...)
  ## exactly as the REPL would and return its plain-text body. Modal
  ## commands that need an interactive terminal (`:provider add/edit`)
  ## return an error string. `:quit` raises `AgentError` — quitting is
  ## the embedder's `close`.
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
  ## Short "provider.model" label for display.
  s.profile.name

proc usage*(s: AgentSession): Usage =
  ## Cumulative token usage for the session.
  s.state.usage
