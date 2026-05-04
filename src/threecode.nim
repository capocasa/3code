import std/[json, os, parseopt, strformat, strutils, terminal, times]
when defined(posix):
  import std/posix
import threecode/[types, util, prompts, shell, loop, session, compact,
                  config, actions, api, display, ui, update]
import threecode/minline
export types, util, prompts, shell, loop, session, compact,
       config, actions, api, display, ui

proc runTurns*(p: Profile, messages: var JsonNode, session: var Session) =
  interrupted = false
  resetLoopTracker(session.loop)
  # `beginTurn` hides the terminal cursor for the duration of the
  # turn (streaming + tool exec); the dim `❯ ` glyph remains on
  # screen as the visible-but-not-blinking caret. `endTurn` flips
  # the prompt back to bright cyan and shows the cursor again so
  # readline lands on a typing-ready row. The token receipt for the
  # turn that just completed is *not* rendered here — it lives in
  # `pendingHint` and is painted in place of the previous bar at
  # user-submit time by `emitUserSubmit`.
  beginTurn()
  defer: endTurn()
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
      withCleared:
        stdout.styledWriteLine styleDim, "  · interrupted", resetStyle
      interrupted = false
      return
    let window = contextWindowFor(p.model)
    var summarized = 0
    case decideContextAction(usage.promptTokens, window, messages.len)
    of caSummarize:
      summarized = summarizeHistory(messages, p)
      if summarized > 0:
        withCleared:
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
        withCleared:
          hintLn &"  · compacted {n} old tool result" &
            (if n == 1: "" else: "s") &
            &" (context at {humanTokens(usage.promptTokens)}/{humanTokens(window)} tokens)",
            resetStyle
        saveSession(session, messages)
    let content = msg{"content"}.getStr("")
    let streamedLive = contentStreamedLive
    contentStreamedLive = false
    let tcNode = msg{"tool_calls"}
    let toolCalls =
      if tcNode != nil and tcNode.kind == JArray: tcNode
      else: newJArray()
    if toolCalls.len > 0:
      # Each emit (blank row, assistant content, pending banner, tool
      # output, halt notice) is wrapped in its own `withCleared` so
      # bar+prompt are repainted directly below after the write. The
      # bar+prompt remain on screen for the entire tool exec — including
      # the seconds while runAction blocks on the bash command between
      # the pending banner and the timed result. (Wrapping the whole
      # block in one withCleared is wrong: it clears at start, repaints
      # at end, so bar/prompt are invisible while the command runs.)
      withCleared:
        stdout.write "\n"
        if content.strip.len > 0 and not streamedLive:
          renderAssistantContent(content)
          stdout.write "\n"
      var halt = false  # Strike-2 trip or budget cap: stop further tool calls this turn
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
        # Pre-exec: dim bullet + dim banner text — "in flight" signal.
        # After the call returns we move the cursor up and rewrite the
        # line via renderToolBanner so the bullet picks up a colour
        # (green success, dim error) and gains a duration suffix. Skill
        # loads skip the banner entirely; the model's own
        # "loaded skill: <name>" line is the only signal the user sees.
        # The withCleared wrap repaints bar+prompt directly below the
        # pending banner — they stay visible while runAction blocks.
        if not silent:
          withCleared:
            renderToolPending(bannerFor(act))
        let toolT0 = epochTime()
        if session.readCache == nil: session.readCache = newReadCache()
        var (r, code, diff) = runAction(act, session.readCache)
        if act.kind == akPlan and code == 0:
          session.plan = act.plan
        let toolElapsed = epochTime() - toolT0
        if r.strip.len == 0: r = "[no output]"
        session.toolLog.add ToolRecord(banner: bannerFor(act), output: r, code: code, kind: act.kind)
        if not silent:
          # Cursor parks at bar row after `withCleared` above; `\e[1A\r\e[2K`
          # walks up to the pending banner row and clears it so renderToolBanner
          # overwrites it with the timed final form.
          withCleared:
            stdout.write "\e[1A\r\e[2K"
            renderToolBanner(bannerFor(act), code, toolElapsed.int)
            printToolResult(act.kind, r, code, idx, diff)
        else:
          withCleared:
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
        # Strike 1 is a soft signal (mutation concentration on one path) —
        # no nudge is injected. Strike 2 halts the turn. The turn-call
        # budget (TurnCallBudget) is a separate backstop that also halts.
        if strike >= 2 and priorStrike < 2:
          halt = true
          if session.loop.recoveryCmd != "":
            toolContent &= "\n\n[repeat-guard] working-tree recovery detected (`" &
              session.loop.recoveryCmd &
              "`); further tool calls this turn are paused. The model's plan was likely based on the working tree as it was before this command — resume only if you've confirmed the new state is what you want."
          else:
            let fp = fingerprint(name, args)
            toolContent &= "\n\n[repeat-guard] mutation saturation (path=" & fp &
              "); further tool calls this turn are paused."
        elif session.loop.turnCalls >= TurnCallBudget and priorStrike < 2:
          halt = true
          toolContent &= "\n\n[repeat-guard] turn budget exceeded (" &
            $TurnCallBudget & " tool calls); further tool calls this turn are paused."
        messages.add %*{"role": "tool", "tool_call_id": id, "content": toolContent}
      saveSession(session, messages)
      if interrupted:
        withCleared:
          stdout.styledWriteLine styleDim, "  · interrupted", resetStyle
        interrupted = false
        return
      if halt:
        withCleared:
          if session.loop.recoveryCmd != "":
            stdout.styledWriteLine styleDim,
              &"  paused — `{session.loop.recoveryCmd}` wiped working-tree state",
              resetStyle
          elif session.loop.turnCalls >= TurnCallBudget:
            stdout.styledWriteLine styleDim,
              &"  paused — turn budget exceeded ({TurnCallBudget} calls)",
              resetStyle
          else:
            stdout.styledWriteLine styleDim, "  paused — looped", resetStyle
        return
      continue
    if content.strip.len > 0:
      if not streamedLive:
        withCleared:
          renderAssistantContent(content)
    else:
      withCleared:
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
    # User-triggered interrupts are not urgent — they pressed the
    # button. Render as dim grey hint, reserve magenta for actual
    # errors the user needs to read.
    if e.msg.startsWith("interrupted by user"):
      stdout.styledWriteLine styleDim, "  ", e.msg, resetStyle
    else:
      stdout.styledWriteLine fgMagenta, "  ", e.msg, resetStyle

proc usage() {.noreturn.} =
  stderr.writeLine """usage: 3code [options] [prompt...]
       3code good                   # list known-good provider/variant combos

  -m, --model PROVIDER[.MODEL]   pick model from config (overrides [settings])
  -r, --resume[=ID]    resume latest session from this directory (or by id)
  -l, --list[=all]     list sessions for this directory (or all) and exit
  -g, --good           list known-good provider/variant combos and exit
  -x, --experimental   allow combos outside the known-good list
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
  var p = initOptParser(commandLineParams())
  for kind, k, v in p.getopt():
    case kind
    of cmdShortOption, cmdLongOption:
      case k
      of "v", "version": echo Version; return
      of "h", "help": usage()
      of "g", "good": printKnownGood(); return
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
    let window = contextWindowFor(prof.model)
    let lastUsage = replaySessionTail(messages, session.toolLog,
                                      window, prof.family)
    if lastUsage.totalTokens > 0:
      # Same shape as `endTurn`: gap row + bar+prompt with bright cyan
      # (typing-ready) prompt, carrying the last response's usage so
      # the bar replaces what would otherwise be the last receipt.
      # `pendingHint` is primed so the next user submit converts this
      # bar into the dim receipt for that response.
      stdout.write "\n"
      let label = tokenLineLabel(lastUsage, window)
      stdout.write barFooterBytes(label, BrightPromptColor)
      stdout.flushFile
      currentBarLabel = label
      currentBarHasGap = true
      pendingHint = (active: true, usage: lastUsage,
                     window: window, elapsed: -1)
    else:
      paintInitialBar(prof)
    if prompt != "":
      messages.add %*{"role": "user", "content": buildUserMessage(messages, prompt)}
      refreshSystemPrompt(messages, prof)
      runTurnsInteractive(prof, messages, session)
  else:
    paintInitialPrompt(prof)
  while true:
    var done = false
    let line = readInput(editor, done)
    if done:
      echo ""
      break
    if line == "": continue
    let t = line.strip
    if t in ["exit", "quit", ":q", ":quit", ":exit"]: break
    if handleCommand(line, messages, session, prof, editor):
      # Slash command output advanced the cursor; the chrome at the
      # row where it stood before the user typed is now stale. Drop a
      # fresh copy at the new bottom so it stays glued to the cursor
      # flow. In prompt-only mode (pre-first-turn) the chrome is just
      # the prompt; otherwise it's bar+prompt.
      if currentBarLabel.len == 0:
        paintPromptOnly(BrightPromptColor)
      else:
        paintBarPrompt(currentBarLabel, BrightPromptColor)
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
    runTurnsInteractive(prof, messages, session)

when isMainModule:
  main()
