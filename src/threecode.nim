## Entry point and outer REPL loop.
##
## `main` parses CLI args, sets up the session, and runs the interactive loop.
## `turns.runTurns` is the inner driver: it calls the model, dispatches
## tool calls, updates the session, and handles compaction - repeating until
## the model emits no tool calls or the loop guard trips.
##
## Module graph overview::
##
##   threecode (entry)
##     ├── turns        turn lifecycle + API/tool orchestration
##     ├── api          HTTP + SSE streaming + spinner
##     ├── actions      tool_call JSON → Action → execute
##     ├── loop         mutation-saturation loop guard
##     ├── compact      supersede elision + LLM summarization
##     ├── session      .3log persistence (save + load)
##     ├── display      terminal rendering (markdown, token bar, replays)
##     ├── ui           REPL :commands + provider wizard
##     ├── config       config file parse + profile resolution
##     ├── prompts      KnownGoodCombos + per-family (prompt, tools)
##     ├── shell        shell command parsing for loop guard
##     ├── web          native web search + URL fetch
##     ├── update       background auto-update
##     ├── fatprompt    volatile prompt/token/ticker state and frame bytes
##     ├── util         string utils, ANSI palette, markdown helpers
##     ├── types        shared types + globals
##     └── minline      readline-style input

import std/[json, locks, os, parseopt, strformat, strutils, terminal, times]
import std/exitprocs
when defined(posix):
  import std/posix
import threecode/[types, util, prompts, shell, loop, session, compact,
                  config, actions, api, display, ui, update, fatprompt,
                  toolstream, turns, transcript]
import threecode/minline
export types, util, prompts, shell, loop, session, compact,
       config, actions, api, display, ui, fatprompt, toolstream, turns,
       transcript



proc usage() {.noreturn.} =
  stderr.writeLine """usage: 3code [options] [prompt...]
       3code good                   # list known-good provider/variant combos

  -m, --model PROVIDER[.MODEL]   pick model from config (overrides [settings])
  -r, --resume[=ID]    resume latest session from this directory (or by id)
  -i, --interactive    run prompt then continue interactively
  -l, --list[=all]     list sessions for this directory (or all) and exit
  -g, --good           list known-good provider/variant combos and exit
  -x, --experimental   allow combos outside the known-good list
  -D, --debug          colored debug trace to stderr
  -v, --version        print version
  -h, --help           this message

config: """ & configPath()
  quit ExitUsage


proc refuseRoot() =
  ## 3code runs arbitrary shell commands the model proposes — root
  ## blast radius is unacceptable. The install script also refuses, so
  ## a normal `curl | sh` user shouldn't ever see this; it's the safety
  ## net for `sudo 3code`, root containers, etc.
  when defined(posix):
    if geteuid() == 0 and getEnv("THREECODE_ALLOW_ROOT").len == 0:
      stderr.writeLine "3code: refusing to run as root. " &
        "Run as your normal user. (override: THREECODE_ALLOW_ROOT=1)"
      quit ExitUsage

proc setupTlsEnv() =
  ## macOS: stock LibreSSL at `/usr/lib/libssl.dylib` fails handshakes
  ## against most modern endpoints, so we ship Homebrew OpenSSL 3 dylibs
  ## alongside the binary (see `release.yml`). Prepend the binary's
  ## directory to DYLD_LIBRARY_PATH so `dlopen("libssl.dylib")` (from
  ## Nim's std/net openssl wrapper) hits ours first. dyld consults the
  ## env var on every dlopen, so updating it from inside the process
  ## before any TLS code runs is sufficient.
  ##
  ## Windows: DLLs are found next to the .exe by the app-directory
  ## rule, no path manipulation needed.
  ##
  ## CA bundle: bundled OpenSSL on both platforms has its OPENSSLDIR
  ## baked to a build-runner path that doesn't exist on user systems,
  ## so verifyMode=CVerifyPeer can't scan default locations. Code that
  ## opens a TLS context calls `bundledCaFile()` (in util.nim) to feed
  ## the bundled `cacert.pem` directly to `newContext(caFile = ...)`.
  ## Linux uses the system trust store and needs nothing here.
  when defined(macosx):
    let dir = parentDir(getAppFilename())
    let cur = getEnv("DYLD_LIBRARY_PATH")
    let newVal = if cur.len > 0: dir & ":" & cur else: dir
    putEnv("DYLD_LIBRARY_PATH", newVal)

proc commitUserPromptTranscript(line: string; restoreEditor = true) =
  ## Controller-owned transcript append for user prompt items. Formatters
  ## return trimmed item bodies; this proc owns the receipt/user separator and
  ## clears volatile footer state before the next turn starts.
  let receiptLabel =
    if restoreEditor and pendingHint.active:
      tokenLineLabel(pendingHint.usage, pendingHint.window, pendingHint.elapsed)
    else:
      ""
  var bytes = ""
  if receiptLabel.len > 0:
    bytes.add GreyFg
    bytes.add "  "
    bytes.add receiptLabel
    bytes.add Reset
    bytes.add "\n\n"
  elif not restoreEditor and pendingHint.active:
    bytes.add "\n"
  bytes.add formatUserPromptItem(line)
  proc clearSubmittedFooterState() =
    emitFatPromptEvent clearPendingHintEvent()
    emitFatPromptEvent clearBarEvent()
    emitFatPromptEvent clearTickerEvent()
  if not restoreEditor:
    while bytes.len > 0 and bytes[^1] in {'\r', '\n'}:
      bytes.setLen(bytes.len - 1)
    bytes.add "\r\n"
    commitTranscriptBytes(
      bytes,
      restoreEditor = false,
      beforeRepaint = clearSubmittedFooterState,
      reserveFooter = false,
      transcriptOwnsSpacing = true)
    receiptTouchesNextResponse = true
    return
  commitTranscriptBytes(
    bytes,
    restoreEditor,
    clearSubmittedFooterState,
    reserveFooter = restoreEditor)
  if not restoreEditor:
    receiptTouchesNextResponse = true

proc main() =
  setupTlsEnv()
  cleanupStaleBinaries()
  refuseRoot()
  # Internal flag for the detached background worker. Run silently and
  # exit before any other startup work (skill extraction, config load).
  let cl = commandLineParams()
  if cl.len == 1 and cl[0] == "--self-update-check":
    selfUpdateCheck()
    return
  installInterruptHook()
  materializeBuiltinSkills()
  var model = ""
  var args: seq[string]
  var pending = ""  # flag awaiting a space-separated value
  var resume = false
  var resumeId = ""
  var sessionOut = ""
  var forceInteractive = false
  var p = initOptParser(commandLineParams())
  for kind, k, v in p.getopt():
    case kind
    of cmdShortOption, cmdLongOption:
      case k
      of "v", "version": echo Version; return
      of "h", "help": usage()
      of "g", "good": printKnownGood(); return
      of "x", "experimental": experimentalEnabled = true
      of "D", "debug": debugEnabled = true
      of "i", "interactive": forceInteractive = true
      of "m", "model":
        if v != "": model = v
        else: pending = "model"
      of "s", "session":
        if v != "": sessionOut = v
        else: pending = "session"
      of "r", "resume":
        resume = true
        if v != "": resumeId = v
      of "l", "list":
        let showAll = v.toLowerAscii in ["all", "a"]
        let paths =
          if showAll: listSessionPaths()
          else: listSessionPathsForCwd(getCurrentDir())
        if paths.len == 0:
          stderr.writeLine (if showAll: "3code: no saved sessions"
                            else: "3code: no saved sessions for " &
                                  getCurrentDir() & "  (try --list=all)")
          quit ExitConfig
        printSessionList(paths, "", showAll)
        return
      else: die("unknown option: -" & (if k.len == 1: "" else: "-") & k, ExitUsage)
    of cmdArgument:
      if pending == "model":
        model = k
        pending = ""
      elif pending == "session":
        sessionOut = k
        pending = ""
      else:
        args.add k
    of cmdEnd: discard
  if pending != "":
    die("option --" & pending & " requires a value", ExitUsage)

  if args.len > 0:
    case args[0]
    of "good": printKnownGood(); return
    else: discard

  showUpdateNoticeMaybe()
  spawnBackgroundUpdateMaybe()

  let prompt = args.join(" ")
  var session: Session
  var messages: JsonNode

  if resume:
    let path = resolveSessionPath(resumeId, getCurrentDir())
    if path == "":
      if resumeId == "":
        die("no saved sessions for " & getCurrentDir(), ExitConfig)
      else:
        die("session not found: " & resumeId, ExitConfig)
    (session, messages) = loadSessionFile(path)
  else:
    messages = %* [{"role": "system", "content": DefaultSystemPrompt}]
    session.created = $now()
    session.cwd = getCurrentDir()
    session.savePath = if sessionOut != "": sessionOut else: newSessionPath()

  try:
    acquireSessionLock(session.savePath)
  except SessionLocked as e:
    die(e.msg, ExitConfig)
  addExitProc(releaseActiveSessionLock)

  if prompt != "" and not resume and not forceInteractive:
    let prof = loadProfile(model)
    if not gateExperimental(prof):
      explainExperimentalGate(prof)
      quit ExitConfig
    session.profileName = prof.name
    messages.add %*{"role": "user", "content": buildUserMessage(messages, prompt)}
    refreshSystemPrompt(messages, prof)
    try:
      runTurns(prof, messages, session)
    except ApiError as e:
      saveSession(session, messages)
      die(e.msg, ExitApi)
    if session.usage.totalTokens > 0:
      hintLn &"  · {humanTokens(session.usage.totalTokens)} total", resetStyle
    stderr.writeLine "session: " & sessionIdFromPath(session.savePath)
    return

  (activeCurrent, activeProviders) = loadStateOrEmpty(configPath())
  let wantedProfile =
    if model != "": model
    elif resume and session.profileName != "": session.profileName
    else: ""
  var prof = buildProfile(activeCurrent, activeProviders, wantedProfile)
  if wantedProfile == "" and not experimentalEnabled and prof.name != "" and
     not isKnownGood(prof):
    let fallback = firstKnownGoodCombo(activeProviders)
    if fallback != "":
      let alt = buildProfile(fallback, activeProviders, "")
      if alt.name != "":
        activeCurrent = alt.name
        prof = alt
  var editor = welcome(prof)
  # Ensure the cancel watcher's termios restore is registered as an exit
  # proc. The minline restoreTerminal exit proc handles cursor + colors;
  # this one restores stdin's termios if the cancel watcher put it in raw
  # mode and the process exits mid-stream.
  addExitProc(restoreCancelTermios)
  when defined(posix):
    # SIGTERM / SIGHUP: the default handler kills the process without
    # running exit procs, leaving the terminal broken. Install handlers
    # that restore terminal state first.
    proc termRestoreAndQuit(sig: cint) {.noconv.} =
      minline.restoreTerminal()
      restoreCancelTermios()
      # Re-raise with default handler so the exit code reflects the signal.
      signal(sig, SIG_DFL)
      discard posix.raise(sig)
    signal(SIGTERM, termRestoreAndQuit)
    signal(SIGHUP, termRestoreAndQuit)
  editor.completionCallback = proc(ed: minline.LineEditor): seq[string] =
    completionFor(ed.lineText)
  if prof.name == "":
    prof = bootstrapProvider(editor)
  session.profileName = prof.name
  inputEditor = addr(editor)
  inputMessages = addr(messages)
  inputSession = addr(session)
  inputProfile = addr(prof)
  setActiveCommandHook(proc(cmd: string) {.gcsafe.} =
    {.cast(gcsafe).}:
      let kind = classifyCommand(cmd)
      case kind
      of ckSafeImmediate:
        if inputMessages == nil or inputSession == nil or inputProfile == nil or
            inputEditor == nil:
          return
        var res = handleCommandResult(cmd, inputMessages[], inputSession[],
                                      inputProfile[], inputEditor[])
        if not res.recognized:
          res = CommandResult(recognized: true, ok: false, name: "command",
                              body: "unknown command: " & cmd.strip &
                                    "  (try :help)\n")
        let bytes =
          if res.plainBody:
            plainCommandBodyBytes(res.body)
          else:
            formatItem(commandItem(res.name, res.body, res.ok))
        commitTranscriptBytes(bytes, restoreEditor = true, reserveFooter = true,
                              transcriptOwnsSpacing = true)
      of ckMutating, ckModal:
        let msg = "cannot run " & cmd.strip & " while a turn is active"
        let bytes = formatItem(commandItem("command", msg & "\n", false))
        commitTranscriptBytes(bytes, restoreEditor = true, reserveFooter = true,
                              transcriptOwnsSpacing = true)
      else:
        let bytes = formatItem(commandItem("command",
          "unknown command: " & cmd.strip & "  (try :help)\n", false))
        commitTranscriptBytes(bytes, restoreEditor = true, reserveFooter = true,
                              transcriptOwnsSpacing = true)
  )

  proc handleBufferedAfterTurn(): bool =
    var cmdWasQuit = false
    var queued = ""
    var queuedRows = 0
    acquire inputStateLock
    try:
      cmdWasQuit = inputState.cmdWasQuit
      if inputState.autoSend:
        queued =
          if inputState.queuedText.len > 0: inputState.queuedText
          else: editor.line.text
        queuedRows = inputState.queuedEchoRows
        inputState.queuedText = ""
        inputState.autoSend = false
        inputState.queuedEchoRows = 0
    finally:
      release inputStateLock
    if cmdWasQuit:
      return true
    if queued.len > 0:
      if prof.name == "":
        editor.prefillText = queued
        return false
      messages.add %*{"role": "user",
                      "content": buildUserMessage(messages, queued)}
      refreshSystemPrompt(messages, prof)
      editor.echoRows = queuedRows
      commitUserPromptTranscript(queued, restoreEditor = false)
      editor.line = minline.Line(text: "", position: 0)
      editor.renderSuffix = ""
      editor.prefillText = ""
      editor.renderRow = 0
      editor.echoRows = 0
      runTurnsInteractive(prof, messages, session)
      return handleBufferedAfterTurn()
    false

  # Draw the initial chrome at the bottom of the welcome screen. On
  # resume with prior usage we paint bar+prompt carrying the last
  # response's tokens (typing-ready shape from `endTurn`). On resume
  # without usage we still paint the bar at zeros. On a fresh start
  # we paint *just* the prompt — the bar stays hidden until the first
  # model response brings real values to put in it. From the first
  # `paintBarPrompt` onward the bar+prompt are always visible.
  if resume:
    stdout.write "\n"
    stdout.styledWriteLine styleDim, &"● resumed {sessionIdFromPath(session.savePath)}", resetStyle
    let window = contextWindowFor(prof)
    let lastUsage = replaySessionTail(messages, session.toolLog,
                                      window, prof.family)
    if lastUsage.totalTokens > 0:
      # Same shape as `endTurn`: gap row + bar+prompt in typing-ready
      # state, carrying the last response's usage so
      # the bar replaces what would otherwise be the last receipt.
      # `pendingHint` is primed so the next user submit converts this
      # bar into the dim receipt for that response.
      stdout.write "\n"
      let label = tokenLineLabel(lastUsage, window)
      let tw = try: terminalWidth() except CatchableError: 0
      stdout.write barFooterBytes(label, tw)
      stdout.flushFile
      emitFatPromptEvent setBarEvent(label, hasGap = true)
      emitFatPromptEvent setPendingHintEvent(lastUsage, window, -1)
    else:
      paintInitialPrompt(prof)
    if prompt != "":
      messages.add %*{"role": "user", "content": buildUserMessage(messages, prompt)}
      refreshSystemPrompt(messages, prof)
      runTurnsInteractive(prof, messages, session)
      if handleBufferedAfterTurn(): return
  else:
    paintInitialPrompt(prof)
    if prompt != "":
      messages.add %*{"role": "user", "content": buildUserMessage(messages, prompt)}
      refreshSystemPrompt(messages, prof)
      runTurnsInteractive(prof, messages, session)
      if handleBufferedAfterTurn(): return
  while true:
    var done = false
    var line = readInput(editor, done)
    if done:
      echo ""
      break
    if line == "": continue
    let t = line.strip
    if t in ["exit", "quit", ":q", ":quit", ":exit"]: break
    let commandResult = handleCommandResult(line, messages, session, prof, editor)
    if commandResult.recognized:
      if commandResult.disposition == cdModal:
        editor.line = minline.Line(text: "", position: 0)
        editor.renderSuffix = ""
        editor.renderSuffixCursor = false
        editor.renderRow = 0
        editor.echoRows = 0
        releaseIdleSubmittedInput()
        continue
      var echo = userPromptItem(line)
      echo.attachSeparator = true
      let commandBytes =
        if commandResult.plainBody:
          plainCommandBodyBytes(commandResult.body)
        else:
          formatItem(commandItem(commandResult.name, commandResult.body,
                                commandResult.ok))
      let bytes = formatItem(echo) & commandBytes
      proc clearSubmittedCommandEditor() =
        editor.line = minline.Line(text: "", position: 0)
        editor.renderSuffix = ""
        editor.renderSuffixCursor = false
        editor.renderRow = 0
        editor.echoRows = 0
        if commandResult.clearFooter:
          emitFatPromptEvent clearPendingHintEvent()
          emitFatPromptEvent clearBarEvent()
      commitTranscriptBytes(
        bytes,
        restoreEditor = true,
        beforeRepaint = clearSubmittedCommandEditor,
        reserveFooter = true,
        transcriptOwnsSpacing = true)
      releaseIdleSubmittedInput()
      continue
    if prof.name == "":
      stdout.styledWriteLine fgMagenta,
        "  no provider configured. use :provider add", resetStyle
      continue
    messages.add %*{"role": "user", "content": buildUserMessage(messages, line)}
    refreshSystemPrompt(messages, prof)
    # User-submit transition: walk back to the previous turn's bar
    # row, repaint it dim (the receipt — skipped on the first turn),
    # echo the user's input as scroll-history content. Cursor lands
    # on the row directly after the last echo line, where callModel's
    # leading `\n` will set up the new spinner-footer scratch row.
    emitUserSubmit(line, editor.echoRows)
    editor.line = minline.Line(text: "", position: 0)
    editor.renderSuffix = ""
    editor.renderSuffixCursor = false
    editor.renderRow = 0
    editor.echoRows = 0
    runTurnsInteractive(prof, messages, session)
    if handleBufferedAfterTurn(): break

when isMainModule:
  main()
