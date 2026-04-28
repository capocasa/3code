import std/[json, os, parseopt, strformat, strutils, terminal, times]
import threecode/[types, util, prompts, shell, loop, session, compact,
                  config, actions, api, display, ui, update, web]
import threecode/minline
export types, util, prompts, shell, loop, session, compact,
       config, actions, api, display, ui

proc runTurns*(p: Profile, messages: var JsonNode, session: var Session) =
  interrupted = false
  resetLoopTracker(session.loop)
  while true:
    discard supersedeCompact(messages)
    var usage: Usage
    let msg = callModel(p, messages, usage, session.lastPromptTokens)
    session.usage.promptTokens += usage.promptTokens
    session.usage.completionTokens += usage.completionTokens
    session.usage.totalTokens += usage.totalTokens
    session.usage.cachedTokens += usage.cachedTokens
    session.lastPromptTokens = usage.promptTokens
    messages.add msg
    saveSession(session, messages)
    if interrupted:
      stdout.styledWriteLine styleDim, "  · interrupted", resetStyle
      interrupted = false
      return
    let window = contextWindowFor(p.model)
    var summarized = 0
    case decideContextAction(usage.promptTokens, window, messages.len)
    of caSummarize:
      summarized = summarizeHistory(messages, p)
      if summarized > 0:
        hintLn &"  · summarized {summarized} old message" &
          (if summarized == 1: "" else: "s") &
          &" (context at {humanTokens(usage.promptTokens)}/{humanTokens(window)} tokens)",
          resetStyle
        saveSession(session, messages)
    of caCompact, caNone: discard
    # Fall through: if summarization bailed, still try compaction on the
    # same turn. Summarization only runs once per turn regardless.
    if summarized == 0 and usage.promptTokens > 0 and
       usage.promptTokens.float > CompactThresholdFrac * window.float:
      let n = compactHistory(messages)
      if n > 0:
        hintLn &"  · compacted {n} old tool result" &
          (if n == 1: "" else: "s") &
          &" (context at {humanTokens(usage.promptTokens)}/{humanTokens(window)} tokens)",
          resetStyle
        saveSession(session, messages)
    stdout.write "\n"
    let content = msg{"content"}.getStr("")
    let streamedLive = contentStreamedLive
    contentStreamedLive = false
    let tcNode = msg{"tool_calls"}
    let toolCalls =
      if tcNode != nil and tcNode.kind == JArray: tcNode
      else: newJArray()
    if toolCalls.len > 0:
      if content.strip.len > 0 and not streamedLive:
        stdout.styledWrite fgWhite, styleBright, "● ", resetStyle
        let lines = content.splitLines
        var idx = 0
        for l in lines:
          let prefix = if idx == 0: "" else: "  "
          stdout.styledWrite fgWhite, styleDim, prefix & l & "\n", resetStyle
          inc idx
        stdout.write "\n"
        stdout.flushFile
      var halt = false  # Strike-2 trip: stop further tool calls this turn
      for tc in toolCalls:
        let id = tc{"id"}.getStr
        if interrupted or halt:
          # still emit a tool response so the assistant message's tool_calls
          # are all paired; the model sees the cancellation on the next turn.
          let stopMsg = if halt: "skipped — loop guard paused the turn"
                        else: "interrupted by user"
          messages.add %*{"role": "tool", "tool_call_id": id,
                          "content": stopMsg}
          continue
        let fn = tc{"function"}
        let name = if fn != nil and fn.kind == JObject: fn{"name"}.getStr else: ""
        let argsStr =
          if fn != nil and fn.kind == JObject: fn{"arguments"}.getStr("") else: ""
        let args =
          try: parseJson(if argsStr == "": "{}" else: argsStr)
          except CatchableError as e:
            stderr.writeLine "3code: tool_call " & name &
              " has malformed arguments JSON (" & e.msg & "): " & argsStr
            newJObject()
        let act = toolCallToAction(p.family, name, args)
        let idx = session.toolLog.len + 1
        let silent = isSkillRead(act)
        # Pre-exec: dim bullet + dim banner text — "in flight" signal. After
        # the call returns we overwrite the line so the bullet only picks up
        # a colour (green success, red error); the banner text itself stays
        # dim so the colour acts as a glance cue, not a shout. Skill loads
        # skip the banner entirely; the model's own "loaded skill: <name>"
        # line is the only signal the user sees.
        if not silent:
          stdout.styledWrite fgWhite, styleDim, "• ", bannerFor(act), resetStyle, "\n"
          stdout.flushFile
        let toolT0 = epochTime()
        if session.readCache == nil: session.readCache = newReadCache()
        var (r, code, diff) = runAction(act, session.readCache)
        let toolElapsed = epochTime() - toolT0
        if r.strip.len == 0: r = "[no output]"
        session.toolLog.add ToolRecord(banner: bannerFor(act), output: r, code: code, kind: act.kind)
        if not silent:
          stdout.write "\e[1A\r\e[2K"
          if code == 0:
            stdout.styledWrite fgGreen, "• ", resetStyle
          else:
            stdout.styledWrite fgWhite, styleDim, "• ", resetStyle
          stdout.styledWrite fgWhite, styleDim, bannerFor(act), resetStyle
          if toolElapsed >= 1:
            stdout.styledWrite fgWhite, styleDim, &"  ({toolElapsed.int}s)", resetStyle
          stdout.write "\n"
          stdout.flushFile
          printActionResult(act, r, code, idx, diff)
        else:
          printSkillLoaded(act)
        # Loop guard: fingerprint the call and decide whether to annotate the
        # tool result (Strike 1) or halt further tool calls (Strike 2). The
        # guard message is appended to the real tool result rather than
        # injected as a separate message — the assistant's tool_calls array
        # already pairs 1:1 with tool responses via tool_call_id, so slipping
        # in an extra message would break the pairing.
        let priorStrike = session.loop.strike
        let strike = trackCall(session.loop, name, args)
        var toolContent = r
        # Strike 1 used to append a "stop and reassess" nudge; dropped because
        # many legit compile-iterate sessions trip it without actually being
        # stuck. Only the Strike-2 halt survives — that one we want.
        if strike >= 2 and priorStrike < 2:
          halt = true
          if session.loop.recoveryCmd != "":
            toolContent &= "\n\n[repeat-guard] working-tree recovery detected (`" &
              session.loop.recoveryCmd &
              "`); further tool calls this turn are paused. The model's plan was likely based on the working tree as it was before this command — resume only if you've confirmed the new state is what you want."
          else:
            let fp = fingerprint(name, args)
            toolContent &= "\n\n[repeat-guard] second saturation (path=" & fp &
              "); further tool calls this turn are paused."
        messages.add %*{"role": "tool", "tool_call_id": id, "content": toolContent}
      saveSession(session, messages)
      if interrupted:
        stdout.styledWriteLine styleDim, "  · interrupted", resetStyle
        interrupted = false
        return
      if halt:
        if session.loop.recoveryCmd != "":
          stdout.styledWriteLine styleDim,
            &"  paused — `{session.loop.recoveryCmd}` wiped working-tree state",
            resetStyle
        else:
          stdout.styledWriteLine styleDim, "  paused — looped", resetStyle
        return
      continue
    if content.strip.len > 0:
      if not streamedLive:
        stdout.styledWrite fgWhite, styleBright, "● ", resetStyle
        let lines = content.splitLines
        var idx = 0
        for l in lines:
          let prefix = if idx == 0: "" else: "  "
          stdout.styledWrite fgWhite, styleDim, prefix & l & "\n", resetStyle
          inc idx
        stdout.write "\n"
        stdout.flushFile
    else:
      stdout.styledWriteLine styleDim,
        "  (empty reply — no content, no tool calls)", resetStyle
    break

proc runTurnsInteractive*(p: Profile, messages: var JsonNode, session: var Session) =
  if not gateExperimental(p):
    explainExperimentalGate(p)
    return
  try:
    runTurns(p, messages, session)
  except ApiError as e:
    saveSession(session, messages)
    stdout.styledWriteLine fgMagenta, "  ", e.msg, resetStyle

proc usage() {.noreturn.} =
  stderr.writeLine """usage: 3code [options] [prompt...]
       3code web <query...>         # DuckDuckGo search, plain-text results
       3code fetch <url>            # GET url, return readable text

  -m, --model PROVIDER[.MODEL]   pick model from config (overrides [settings])
  -r, --resume[=ID]    resume latest session from this directory (or by id)
  -l, --list[=all]     list sessions for this directory (or all) and exit
  -x, --experimental   allow combos outside the known-good list
  -v, --version        print version
  -h, --help           this message

config: """ & configPath()
  quit ExitUsage

proc runWeb(args: seq[string]) =
  if args.len == 0:
    die "web: missing query", ExitUsage
  let query = args.join(" ")
  let hits = try: webSearch(query)
             except CatchableError as e: die("web: " & e.msg, ExitApi)
  stdout.write formatHits(hits)
  if hits.len > 0: stdout.write "\n"

proc runFetch(args: seq[string]) =
  if args.len != 1:
    die "fetch: expected one url", ExitUsage
  let text = try: fetchUrl(args[0])
             except CatchableError as e: die("fetch: " & e.msg, ExitApi)
  stdout.write capText(text)
  stdout.write "\n"

proc main() =
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
  var p = initOptParser(commandLineParams())
  for kind, k, v in p.getopt():
    case kind
    of cmdShortOption, cmdLongOption:
      case k
      of "v", "version": echo Version; return
      of "h", "help": usage()
      of "x", "experimental": experimentalEnabled = true
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
    of "web": runWeb(args[1 .. ^1]); return
    of "fetch": runFetch(args[1 .. ^1]); return
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

  if prompt != "" and not resume:
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
  editor.completionCallback = proc(ed: minline.LineEditor): seq[string] =
    completionFor(ed.lineText)
  if prof.name == "":
    prof = bootstrapProvider(editor)
  session.profileName = prof.name
  if resume:
    hintLn &"  · resumed {sessionIdFromPath(session.savePath)}  " &
      &"({messages.len} msg" & (if messages.len == 1: "" else: "s") & ")",
      resetStyle
    stdout.write "\n"
    replaySessionTail(messages, session.toolLog, prof.family)
    stdout.write "\n"
    if prompt != "":
      messages.add %*{"role": "user", "content": buildUserMessage(messages, prompt)}
      refreshSystemPrompt(messages, prof)
      runTurnsInteractive(prof, messages, session)
  while true:
    var done = false
    let line = readInput(editor, done)
    if done:
      echo ""
      break
    if line == "": continue
    let t = line.strip
    if t in ["exit", "quit", ":q", ":quit", ":exit"]: break
    if handleCommand(line, messages, session, prof, editor): continue
    if prof.name == "":
      stdout.styledWriteLine fgMagenta,
        "  no provider configured. use :provider add", resetStyle
      continue
    messages.add %*{"role": "user", "content": buildUserMessage(messages, line)}
    refreshSystemPrompt(messages, prof)
    runTurnsInteractive(prof, messages, session)

when isMainModule:
  main()
