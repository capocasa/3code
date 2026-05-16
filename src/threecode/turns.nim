
## Turn lifecycle orchestration.
##
## This module is the high-level place where model calls, tool calls,
## transcript commits, fat-prompt transitions, and loop-guard decisions meet.
## `api.nim` should stay transport/protocol focused; visual consequences of
## model/tool progress should flow through this layer.

import std/[json, locks, os, strformat, strutils, terminal, times]
import types, util, prompts, loop, session, compact, config, actions, api,
  display, fatprompt, streamexec, toolstream
import terminal as termui

proc trimTranscriptTail(bytes: var string) =
  while bytes.len > 0 and bytes[^1] in {'\r', '\n'}:
    bytes.setLen(bytes.len - 1)

proc pendingReceiptBytes(): string =
  if not pendingHint.active:
    return ""
  let label = tokenLineLabel(pendingHint.usage, pendingHint.window,
                             pendingHint.elapsed)
  if label.len == 0:
    return ""
  CyanFg & "  " & label & Reset

proc finishTranscriptItem(bytes: var string) =
  ## A transcript item owns its attached receipt and its following separator.
  ## The terminal append primitive must not trim or synthesize spacing for
  ## these controller-owned bytes.
  bytes.trimTranscriptTail()
  bytes.add "\r\n\r\n"

proc clearSubmittedFooterState() =
  emitFatPromptEvent clearPendingHintEvent()
  emitFatPromptEvent clearBarEvent()

proc commitAssistantItem(content: string; restoreEditor = true) =
  if content.strip.len == 0:
    var bytes = GreyFg & "  (empty reply — no content, no tool calls)" & Reset
    let receipt = pendingReceiptBytes()
    if receipt.len > 0:
      bytes.add "\r\n"
      bytes.add receipt
    bytes.finishTranscriptItem()
    commitTranscriptBytes(
      bytes,
      restoreEditor,
      clearSubmittedFooterState,
      transcriptOwnsSpacing = true)
    return
  var bytes = captureStdoutWrites:
    renderAssistantContent(content)
  bytes.trimTranscriptTail()
  let receipt = pendingReceiptBytes()
  if receipt.len > 0:
    bytes.add "\r\n"
    bytes.add receipt
  bytes.finishTranscriptItem()
  commitTranscriptBytes(
    bytes,
    restoreEditor,
    clearSubmittedFooterState,
    transcriptOwnsSpacing = true)

proc commitPendingReceiptAfterStream(restoreEditor = true) =
  ## Streaming assistant content is already in scrollback. Once usage arrives,
  ## append only the receipt and the following separator as ordinary history so
  ## the next transcript item starts after a real blank row.
  var bytes = pendingReceiptBytes()
  if bytes.len == 0:
    return
  bytes.finishTranscriptItem()
  commitTranscriptBytes(
    bytes,
    restoreEditor,
    clearSubmittedFooterState,
    transcriptOwnsSpacing = true)

proc commitTranscriptItem(formatBody: proc(); restoreEditor = true;
                          prefixBoundary = false) =
  ## Commit one complete transcript item. ``prefixBoundary`` is used when the
  ## previous item already restored the live prompt; the controller still owns
  ## the inter-item blank row, so it emits that boundary before this marker
  ## instead of asking terminal cursor cleanup to preserve it implicitly.
  var bytes = captureStdoutWrites:
    formatBody()
  bytes.finishTranscriptItem()
  if prefixBoundary:
    bytes = "\r\n" & bytes
  commitTranscriptBytes(
    bytes,
    restoreEditor,
    transcriptOwnsSpacing = true)

proc runTurns*(p: Profile, messages: var JsonNode, session: var Session) =
  installApiStreamHooks()
  clearInterrupted()
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
  var turnEnded = false
  template finishTurn() =
    if not turnEnded:
      endTurn(repaintPrompt = not isInterrupted())
      turnEnded = true
  defer: finishTurn()
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
    if isInterrupted():
      writeTranscriptWithFatPrompt:
        stdout.styledWriteLine styleDim, "  · interrupted", resetStyle
      clearInterrupted()
      return
    let window = contextWindowFor(p.model)
    var summarized = 0
    case decideContextAction(usage.promptTokens, window, messages.len)
    of caSummarize:
      summarized = summarizeHistory(messages, p)
      if summarized > 0:
        writeTranscriptWithFatPrompt:
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
        writeTranscriptWithFatPrompt:
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
      debugOut $toolCalls.len & " tool calls"
      # Each emit (blank row, assistant content, pending banner, tool
      # output, halt notice) is wrapped in `writeTranscriptWithFatPrompt` so
      # bar+prompt are repainted directly below after the write. The
      # bar+prompt remain on screen for the entire tool exec — including
      # the seconds while runAction blocks on the bash command between
      # the pending banner and the timed result. (Wrapping the whole
      # block in one transcript write is wrong: it clears at start, repaints
      # at end, so bar/prompt are invisible while the command runs.)
      if content.strip.len > 0:
        if streamedLive:
          commitPendingReceiptAfterStream()
        else:
          commitAssistantItem(content)
      var halt = false  # Strike-2 trip or budget cap: stop further tool calls this turn
      var queuedUser = false # User submitted while tools were running.
      var cleared = false  # akClear: rebuild and continue loop
      for tc in toolCalls:
        let id = tc{"id"}.getStr
        if isInterrupted() or halt:
          # still emit a tool response so the assistant message's tool_calls
          # are all paired; the model sees the cancellation on the next turn.
          let stopMsg =
            if halt: "skipped — loop guard paused the turn"
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
            debugOut "tool_call " & name &
              " has malformed arguments JSON (" & e.msg & "): " & argsStr
            newJObject()
        let act = toolCallToAction(p.family, name, args)
        let idx = session.toolLog.len + 1
        let silent = isSkillRead(act)
        let hadToolBar = currentBarLabel.len > 0
        if hadToolBar:
          startBarTick(currentBarLabel)
        let toolT0 = epochTime()
        if session.readCache == nil: session.readCache = newReadCache()
        # try/finally guarantees `stopBarTick` runs even if `runAction`
        # raises. Without this, an unhandled exception in a non-bash
        # action leaves the bar-tick thread painting the bottom row
        # with an ever-growing seconds counter and no spinner glyph —
        # the symptom users see is a frozen-looking bar with an
        # incrementing timer and a Ctrl-C that does nothing because
        # the main thread has already unwound past the tool block.
        var r: string
        var code: int
        var diff: string
        try:
          (r, code, diff) =
            if act.kind == akBash:
              if liveEditorFooterAnchored():
                let promptOwnsStdin = inputEditor != nil
                setToolStdinWatcherEnabled(not promptOwnsStdin)
                var result: typeof(runActionStreaming(act, session.readCache))
                try:
                  result = runActionStreaming(act, session.readCache,
                    proc(line: string) = discard)
                finally:
                  setToolStdinWatcherEnabled(true)
                result
              else:
                discard stopBarTick()
                let termH = try: terminalHeight() except CatchableError: 24
                let overlay = toolOverlayGeometry(termH, StreamMaxLines)
                var sv = initStreamingView(StreamMaxLines, idx,
                  overlay.top, overlay.height, overlay.footerTop)
                let promptOwnsStdin = inputEditor != nil
                setToolStdinWatcherEnabled(not promptOwnsStdin)
                var result: typeof(runActionStreaming(act, session.readCache))
                try:
                  result = runActionStreaming(act, session.readCache,
                    proc(line: string) =
                      sv.addLine(line))
                finally:
                  setToolStdinWatcherEnabled(true)
                  sv.erase()
                  repaintBarPrompt()
                result
            else:
              runAction(act, session.readCache)
        finally:
          if hadToolBar:
            discard stopBarTick()
        if act.kind == akPlan and code == 0:
          session.plan = act.plan
        let toolElapsed = epochTime() - toolT0
        debugOut &"tool done: {act.kind} code={code} elapsed={toolElapsed:.2f}"

        session.toolLog.add ToolRecord(banner: bannerFor(act), output: r, code: code, kind: act.kind)
        if not silent:
          commitTranscriptItem(proc() =
            renderToolBanner(bannerFor(act), act.kind, code, toolElapsed.int)
            printToolResult(act.kind, r, code, idx, diff)
          , prefixBoundary = not hadToolBar)
        else:
          commitTranscriptItem(proc() =
            printSkillLoaded(act)
          , prefixBoundary = not hadToolBar)
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
            toolContent &= "\n\n⊘ [repeat-guard] working-tree recovery (`" &
              session.loop.recoveryCmd &
              "`); further tool calls paused. The model's plan was likely based on the working tree as it was before this command — resume only if you've confirmed the new state is what you want."
          else:
            let fp = fingerprint(name, args)
            toolContent &= "\n\n⊘ [repeat-guard] mutation saturation (" & fp &
              "); further tool calls paused."
        elif session.loop.turnCalls >= TurnCallBudget and priorStrike < 2:
          halt = true
          toolContent &= "\n\n⊘ [repeat-guard] turn budget exceeded (" &
            $TurnCallBudget & " tracked calls); further tool calls paused."
        messages.add %*{"role": "tool", "tool_call_id": id, "content": toolContent}
        acquire inputStateLock
        try:
          if inputState.autoSend:
            # Let the current assistant tool batch finish so the tool-call
            # pairing stays faithful to what the model requested, then return
            # before the model-initiated follow-up call. The interactive loop
            # drains the queued user text and starts the next user turn.
            queuedUser = true
        finally:
          release inputStateLock
        if act.kind == akClear:
          # Rebuild: fresh system prompt + synthetic user message, then
          # continue the loop so the model processes the prompt.
          let freshMsg = act.body
          let rebuilt = newJArray()
          rebuilt.add %*{"role": "system", "content": buildSystemPrompt(p)}
          rebuilt.add %*{"role": "user", "content": freshMsg}
          messages.elems.setLen 0
          for m in rebuilt: messages.add m
          session.toolLog.setLen 0
          session.usage = Usage()
          session.lastPromptTokens = 0
          session.loop = initLoopTracker()
          session.readCache = nil
          session.plan.setLen 0
          emitFatPromptEvent clearPendingHintEvent()
          emitFatPromptEvent clearBarEvent()
          if session.savePath != "":
            session.savePath = newSessionPath()
            session.created = $now()
            session.cwd = getCurrentDir()
          writeTranscriptWithFatPrompt:
            stdout.write OffWhiteFg
            for line in freshMsg.strip.splitLines:
              stdout.write "  "
              stdout.write line
              stdout.write "\n"
            stdout.write Reset
          saveSession(session, messages)
          cleared = true
          break
      if cleared:
        emitFatPromptEvent clearPendingHintEvent()
        continue
      saveSession(session, messages)
      if isInterrupted():
        writeTranscriptWithFatPrompt:
          stdout.styledWriteLine styleDim, "  · interrupted", resetStyle
        clearInterrupted()
        return
      if queuedUser:
        endTurn(repaintPrompt = false)
        turnEnded = true
        return
      if halt:
        writeTranscriptWithFatPrompt:
          if session.loop.recoveryCmd != "":
            errLn "⊘  working-tree recovery: `",
              session.loop.recoveryCmd, "` wiped state"
          elif session.loop.turnCalls >= TurnCallBudget:
            errLn &"⊘  turn budget exceeded ({TurnCallBudget} tracked calls)"
          else:
            errLn "⊘  mutation saturation"
        return
      debugOut "runTurns: loop continue"
      continue
    let queuedBeforeFinalRender = hasQueuedAutosend()
    if streamedLive:
      commitPendingReceiptAfterStream(restoreEditor = not queuedBeforeFinalRender)
    else:
      commitAssistantItem(content, restoreEditor = not queuedBeforeFinalRender)
    if queuedBeforeFinalRender or hasQueuedAutosend():
      promoteQueuedAutosendFromEditor()
      stopTurnInputForFinalRender()
      turnEnded = true
      return
    finishTurn()
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
      stderr.writeLine e.msg
    else:
      stdout.styledWriteLine fgMagenta, "  ", e.msg, resetStyle
