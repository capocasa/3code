
## Turn lifecycle orchestration.
##
## This module is the high-level place where model calls, tool calls,
## transcript commits and fat-prompt transitions meet.
## `api.nim` should stay transport/protocol focused; visual consequences of
## model/tool progress should flow through this layer.

import std/[json, os, strformat, strutils, terminal, times]
when defined(posix):
  import std/posix except Time
import types, util, prompts, session, compact, config, actions, api,
  display, fatprompt, streamexec, toolstream, transcript
import engine as termengine

proc trimTranscriptTail(bytes: var string) =
  while bytes.len > 0 and bytes[^1] in {'\r', '\n'}:
    bytes.setLen(bytes.len - 1)

proc emitTestFrameEvent() =
  when defined(posix):
    let fdText = getEnv("THREECODE_TEST_FRAME_FD")
    if fdText.len > 0:
      try:
        let fd = cint(parseInt(fdText))
        var ch = 'f'
        discard posix.write(fd, addr ch, 1)
        let ackText = getEnv("THREECODE_TEST_FRAME_ACK_FD")
        if ackText.len > 0:
          let ackFd = cint(parseInt(ackText))
          var ack: array[1, char]
          discard posix.read(ackFd, addr ack[0], 1)
      except CatchableError:
        discard

proc onTurnInterrupted*() =
  ## Single response to a user-triggered interrupt (Ctrl-C, ESC, or any
  ## other trigger wired to `requestTurnInterrupt`). Appends the notice to
  ## scrollback as an ordinary harness line and clears the interrupt flag.
  ##
  ## This is the only place that renders an interrupt message. Whether the
  ## interrupt was noticed mid-stream, after a tool call, or propagated up
  ## as an `ApiError` once the stream had already torn itself down, the
  ## response is identical.
  ##
  ## This proc appends ONLY the harness line; it does not repaint the idle
  ## prompt. The caller (`runTurns`) runs this before its deferred
  ## `endTurn`, so clearing the flag here makes that `endTurn` take the
  ## `repaintPrompt = not isInterrupted() = true` branch and own the single
  ## idle prompt paint. Repainting the prompt here as well would race that
  ## `endTurn` paint for the prompt row and leave a half-overwritten caret.
  var bytes = ansiForegroundColorCode(fgMagenta) &
    InterruptedByUserMsg & ansiResetCode & "\r\n"
  commitTranscriptBytes(bytes, restoreEditor = false)
  clearInterrupted()

proc stubToolCallResult(stub: JsonNode; onLine: proc(line: string) = nil):
    tuple[output: string, code: int, diff: string] =
  let stream = stub{"stream"}
  var streamedLines: seq[string]
  if stream != nil and stream.kind == JArray:
    for item in stream:
      let line = item.getStr("")
      streamedLines.add line
      if onLine != nil:
        onLine(line)
      emitTestFrameEvent()
  result.output = stub{"output"}.getStr("")
  if result.output.len == 0 and streamedLines.len > 0:
    result.output = streamedLines.join("\n") & "\n"
  result.code = stub{"code"}.getInt(stub{"exitCode"}.getInt(0))
  result.diff = stub{"diff"}.getStr("")

proc runBashWithViewport(act: Action; cache: ReadCache; stub: JsonNode;
                         idx: int; streamedOutputShown: ptr bool):
    tuple[output: string, code: int, diff: string] =
  var view = initStreamingView(StreamMaxLines, idx, bannerFor(act))
  let promptOwnsStdin = inputEditor != nil

  proc renderView() =
    view.setSymbol(nextCommandSymbol())
    termengine.renderToolViewport(
      view.viewportRows(),
      footerFrame(fatPromptState),
      inputThreadRunning,
      inputEditor)

  setToolStdinWatcherEnabled(not promptOwnsStdin)
  try:
    setCommandStatusActive(true)
    renderView()
    emitTestFrameEvent()
    if stub != nil and stub.kind == JObject:
      let stream = stub{"stream"}
      let finalCode = stub{"code"}.getInt(stub{"exitCode"}.getInt(0))
      var streamedLines: seq[string]
      if stream != nil and stream.kind == JArray:
        var lineIdx = 0
        for item in stream:
          let line = item.getStr("")
          streamedLines.add line
          if lineIdx == stream.len - 1 and finalCode > 0:
            view.setExitCode(finalCode)
          streamedOutputShown[] = true
          view.addLine(line)
          renderView()
          emitTestFrameEvent()
          inc lineIdx
      result.output = stub{"output"}.getStr("")
      if result.output.len == 0 and streamedLines.len > 0:
        result.output = streamedLines.join("\n") & "\n"
      result.code = finalCode
      result.diff = stub{"diff"}.getStr("")
      if streamedLines.len == 0 or finalCode <= 0:
        view.setExitCode(finalCode)
        renderView()
    else:
      let onLine = proc(line: string) =
        streamedOutputShown[] = true
        view.addLine(line)
        renderView()
      result = runActionStreaming(act, cache, onLine)
      setCommandStatusActive(false)
      view.setExitCode(result.code)
      renderView()
  finally:
    setCommandStatusActive(false)
    setToolStdinWatcherEnabled(true)
    # The normal path leaves the viewport in place so the controller's
    # `appendItem` can fold it into one synchronized scrollback commit (no
    # blank intermediate frame). Only on exception, where the append will not
    # run, clear the viewport here so a stale live viewport does not linger.
    if getCurrentException() != nil:
      termengine.clearToolViewport(
        footerFrame(fatPromptState),
        inputThreadRunning,
        inputEditor)

proc pendingReceiptBytes(): string =
  if not pendingHint.active:
    return ""
  let label = tokenLineLabel(pendingHint.usage, pendingHint.window,
                             pendingHint.elapsed)
  receiptBytes(label)

proc finishTranscriptItem(bytes: var string) =
  ## A transcript item owns its attached receipt and its following separator.
  ## The terminal append primitive must not trim or synthesize spacing for
  ## these controller-owned bytes.
  bytes.trimTranscriptTail()
  bytes.add "\r\n\r\n"

proc finishFinalTranscriptItem(bytes: var string) =
  ## Variant for the last item before the idle footer is reserved. The
  ## reserved footer frame opens with its own cleared gap/ticker row, which is
  ## the visible separator between content and the bar. Ending the bytes with a
  ## full `\r\n\r\n` separator here would leave that gap row as a second,
  ## redundant blank. End the line only and let the footer own the gap.
  bytes.trimTranscriptTail()
  bytes.add "\r\n"

proc clearSubmittedReceiptState() =
  let restingLabel =
    if pendingHint.active:
      contextLabel(pendingHint.usage.promptTokens, pendingHint.window)
    else:
      ""
  emitFatPromptEvent clearPendingHintEvent()
  emitFatPromptEvent clearTickerEvent()
  if restingLabel.len > 0:
    emitFatPromptEvent setBarEvent(restingLabel)

proc clearSubmittedTickerState() =
  emitFatPromptEvent clearTickerEvent()

proc commitAssistantItem(content: string; restoreEditor = true;
                         attachReceipt = true; finalBeforeIdle = false) =
  let afterCommit =
    if attachReceipt: clearSubmittedReceiptState
    else: clearSubmittedTickerState
  let reserveFooter = restoreEditor
  let collapseGap = reserveFooter and finalBeforeIdle
  if content.strip.len == 0:
    var bytes = GreyFg & "empty reply - no content, no tool calls" & Reset
    let receipt = if attachReceipt: pendingReceiptBytes() else: ""
    if attachReceipt and receipt.len > 0:
      bytes.add "\r\n"
      bytes.add receipt
    if collapseGap: bytes.finishFinalTranscriptItem()
    else: bytes.finishTranscriptItem()
    commitTranscriptBytes(
      bytes,
      restoreEditor,
      afterCommit,
      reserveFooter = reserveFooter,
      transcriptOwnsSpacing = collapseGap)
    return
  var bytes = captureStdoutWrites:
    renderAssistantContent(content)
  bytes.trimTranscriptTail()
  let receipt = if attachReceipt: pendingReceiptBytes() else: ""
  if attachReceipt and receipt.len > 0:
    bytes.add "\r\n"
    bytes.add receipt
  if collapseGap: bytes.finishFinalTranscriptItem()
  else: bytes.finishTranscriptItem()
  commitTranscriptBytes(
    bytes,
    restoreEditor,
    afterCommit,
    reserveFooter = reserveFooter,
    transcriptOwnsSpacing = collapseGap)

proc commitPendingReceiptAfterStream(restoreEditor = true) =
  ## Streaming assistant content is already in scrollback. Once usage arrives,
  ## append only the receipt and the following separator as ordinary history so
  ## the next transcript item starts after a real blank row.
  var bytes = pendingReceiptBytes()
  if bytes.len == 0:
    return
  let reserveFooter = restoreEditor
  if reserveFooter: bytes.finishFinalTranscriptItem()
  else: bytes.finishTranscriptItem()
  commitTranscriptBytes(
    bytes,
    restoreEditor,
    clearSubmittedReceiptState,
    reserveFooter = reserveFooter,
    transcriptOwnsSpacing = reserveFooter)

proc commitTranscriptItem(formatBody: proc(); restoreEditor = true;
                          prefixBoundary = false; receipt = "") =
  ## Commit one complete transcript item. ``prefixBoundary`` is used when the
  ## previous item already restored the live prompt; the controller still owns
  ## the inter-item blank row, so it emits that boundary before this marker
  ## instead of asking terminal cursor cleanup to preserve it implicitly.
  var bytes = captureStdoutWrites:
    formatBody()
  if receipt.len > 0:
    bytes.trimTranscriptTail()
    bytes.add "\r\n"
    bytes.add receipt
  bytes.finishTranscriptItem()
  if prefixBoundary:
    bytes = "\r\n" & bytes
  commitTranscriptBytes(
    bytes,
    restoreEditor)

proc runTurns*(p: Profile, messages: var JsonNode, session: var Session): bool =
  ## Returns true if the turn was interrupted by the user (Ctrl-C / ESC).
  ## Callers use this to skip end-of-turn side effects like desktop
  ## notifications: the user was at the keyboard to cancel, so alerting
  ## them that the turn finished would be noise.
  installApiStreamHooks()
  clearInterrupted()
  # `beginTurn` hides the terminal cursor for the duration of the
  # turn (streaming + tool exec); the `❯ ` glyph remains on screen as
  # the visible-but-not-blinking caret. `endTurn` shows the cursor again so
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
  # Empty-content auto-handling state (lives at turn scope so it survives
  # the `continue` that re-enters the loop for an escalation/steering retry).
  # "length" escalations reuse the same conversation and just bump max_tokens;
  # "stop"/unknown steering appends a nudge. Both are bounded so a hostile or
  # broken provider can't pin the turn in a retry loop. See the empty-handling
  # block below (after toolCalls is computed).
  var
    maxTokensOverride = 0          # > 0 replaces known-good max_tokens
    lengthEscalations = 0          # "length" retries so far this turn
    steerAttempts = 0              # "stop"/unknown steering retries
  const
    MaxLengthEscalations = 3
    MaxSteerAttempts = 1
  while true:
    var usage: Usage
    var msg: JsonNode
    try:
      msg = callModel(p, messages, usage, session.lastPromptTokens,
        maxTokensOverride)
    except ApiError as e:
      if isInterruptedMsg(e.msg):
        saveSession(session, messages)
        onTurnInterrupted()
        return true
      raise
    session.usage.promptTokens += usage.promptTokens
    session.usage.completionTokens += usage.completionTokens
    session.usage.totalTokens += usage.totalTokens
    session.usage.cachedTokens += usage.cachedTokens
    session.lastPromptTokens = usage.promptTokens
    if isInterrupted():
      saveSession(session, messages)
      onTurnInterrupted()
      return true
    let content = msg{"content"}.getStr("")
    let streamedLive = contentStreamedLive
    contentStreamedLive = false
    let tcNode = msg{"tool_calls"}
    let toolCalls =
      if tcNode != nil and tcNode.kind == JArray: tcNode
      else: newJArray()
    let finishReason = msg{"finish_reason"}.getStr("")
    if content.strip.len == 0 and toolCalls.len == 0:
      # Empty assistant turn. Branch on finish_reason rather than blindly
      # retrying (a bare resend reproduces the empty reply). This is a
      # conversational concern, kept out of callModel's transport retry block.
      let budgetStarved =
        finishReason == "length" or
        usage.completionTokens >= knownGoodGeneration(p).maxTokens or
        usage.reasoningTokens > 0
      if finishReason == "content_filter":
        # Terminal: the provider refused the content. Persist the empty turn
        # and surface the existing dead-end notice; no point retrying as-is.
        messages.add msg
        saveSession(session, messages)
        writeTranscriptWithFatPrompt:
          hintLn "empty reply - content filtered by provider", resetStyle
        endTurnAfterTranscriptAppend()
        turnEnded = true
        break
      if budgetStarved and lengthEscalations < MaxLengthEscalations:
        inc lengthEscalations
        let cur = knownGoodGeneration(p).maxTokens
        let window = contextWindowFor(p)
        let bumped = min(cur * 2, window)
        maxTokensOverride = max(maxTokensOverride, bumped)
        writeTranscriptWithFatPrompt:
          errLn "finished by length, retrying with ", humanTokens(maxTokensOverride), " token budget", resetStyle
        debugOut &"runTurns: empty length-retry {lengthEscalations}/{MaxLengthEscalations} max_tokens={maxTokensOverride}"
        continue
      if steerAttempts < MaxSteerAttempts:
        inc steerAttempts
        # Append the empty assistant turn (so the exchange stays paired) plus
        # a short steering user message asking for the final answer, then
        # retry the same callModel with the nudged history.
        messages.add msg
        messages.add %*{"role": "user",
          "content": "Please provide your final answer now."}
        saveSession(session, messages)
        writeTranscriptWithFatPrompt:
          hintLn "empty reply; re-prompting for a final answer", resetStyle
        debugOut &"runTurns: empty steer-retry {steerAttempts}/{MaxSteerAttempts}"
        continue
      # Exhausted auto-handling. Persist the empty turn and fall through to
      # the existing dead-end notice below (commitAssistantItem renders
      # "empty reply - no content, no tool calls").
    messages.add msg
    saveSession(session, messages)
    let window = contextWindowFor(p)
    case decideContextAction(usage.promptTokens, window, messages.len)
    of caSummarize:
      let summarized = summarizeHistory(messages, p)
      if summarized > 0:
        writeTranscriptWithFatPrompt:
          hintLn &"· summarized {summarized} message" &
            (if summarized == 1: "" else: "s") &
            &" (context at {humanTokens(usage.promptTokens)}/{humanTokens(window)} tokens)",
            resetStyle
        saveSession(session, messages)
    of caNone: discard
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
      # When the model emits both content and tool calls, the token receipt
      # belongs under the LAST tool of the turn, not under the prose. Attaching
      # it to the prose item here would render the receipt between the answer
      # and the tool calls it documents. Defer it instead.
      var deferredReceipt = pendingReceiptBytes()
      if content.strip.len > 0:
        # Streamed content is already in scrollback; non-streamed content is
        # committed here as a receipt-less item. Either way, the pending
        # receipt (captured above) caps the last tool below so the turn's
        # token usage lands in scrollback even when the model emits only
        # tool calls and no prose.
        if not streamedLive:
          commitAssistantItem(content, attachReceipt = false)
      # The last tool that will actually reach its commit is the one the
      # deferred receipt caps. Tools that are interrupted or have malformed
      # arguments skip their transcript commit, so the cap may fall to an
      # earlier tool or be left over for a trailing commit after the loop.
      var lastCommitIdx = -1
      for i in 0 ..< toolCalls.len:
        let tc = toolCalls[i]
        let fn = tc{"function"}
        let argsStr =
          if fn != nil and fn.kind == JObject: fn{"arguments"}.getStr("") else: ""
        block malformedCheck:
          if argsStr.len > 0:
            try: discard parseJson(argsStr)
            except CatchableError: break malformedCheck
          lastCommitIdx = i
      var queuedUser = false # User submitted while tools were running.
      var cleared = false  # akClear: rebuild and continue loop
      for i in 0 ..< toolCalls.len:
        let tc = toolCalls[i]
        let id = tc{"id"}.getStr
        if isInterrupted():
          # still emit a tool response so the assistant message's tool_calls
          # are all paired; the model sees the cancellation on the next turn.
          let stopMsg = InterruptedByUserMsg
          messages.add %*{"role": "tool", "tool_call_id": id,
                          "content": stopMsg}
          continue
        let fn = tc{"function"}
        let name = if fn != nil and fn.kind == JObject: fn{"name"}.getStr else: ""
        let argsStr =
          if fn != nil and fn.kind == JObject: fn{"arguments"}.getStr("") else: ""
        let (args, argsMalformed) =
          block:
            var a: JsonNode
            var bad = false
            try: a = parseJson(if argsStr == "": "{}" else: argsStr)
            except CatchableError as e:
              debugOut "tool_call " & name &
                " has malformed arguments JSON (" & e.msg & "): " & argsStr
              a = newJObject()
              bad = true
            (a, bad)
        let toolStub = tc{"stub"}
        let idx = session.toolLog.len + 1
        if argsMalformed:
          debugOut "tool done: " & name &
            " code=-1 (malformed args, skipping execution)"
          session.toolLog.add ToolRecord(
            banner: "! " & name & " (malformed args)",
            output: "malformed arguments: " & argsStr, code: -1, kind: akBash)
          messages.add %*{"role": "tool", "tool_call_id": id,
            "content": "ERROR: tool arguments arrived truncated or malformed (" &
              "got '" & argsStr & "'). Re-emit this tool call."}
          continue
        let act = toolCallToAction(p.family, name, args)
        let silent = isSkillRead(act)
        let hadToolBar = currentBarLabel.len > 0
        let toolT0 = epochTime()
        if session.readCache == nil: session.readCache = newReadCache()
        var streamedOutputShown = false
        # withBarTick is the RAII scope: the bar-tick thread is stopped on
        # any exit (normal, exception, return) — it can't be leaked by a
        # forgotten stopBarTick, the class of bug that froze the footer
        # with an ever-climbing seconds counter and a dead prompt.
        var r: string
        var code: int
        var diff: string
        withBarTick(currentBarLabel):
          try:
            (r, code, diff) =
              if act.kind == akBash:
                runBashWithViewport(
                  act, session.readCache, toolStub, idx, addr streamedOutputShown)
              else:
                if toolStub != nil and toolStub.kind == JObject:
                  stubToolCallResult(toolStub)
                else:
                  runAction(act, session.readCache)
          except CatchableError as e:
            r = "ERROR: tool execution failed: " & e.msg
            code = -1
            diff = ""
        if act.kind == akPlan and code == 0:
          session.plan = act.plan
        let toolElapsed = epochTime() - toolT0
        debugOut &"tool done: {act.kind} code={code} elapsed={toolElapsed:.2f}"

        session.toolLog.add ToolRecord(banner: bannerFor(act), output: r, code: code, kind: act.kind)
        let isReceiptCap = deferredReceipt.len > 0 and i == lastCommitIdx
        if not silent:
          appendItem(
            toolItem(act, r, code, idx, diff, toolElapsed.int),
            prefixBoundary = not hadToolBar,
            receipt = if isReceiptCap: deferredReceipt else: "")
        else:
          commitTranscriptItem(proc() =
            printSkillLoaded(act)
          , prefixBoundary = not hadToolBar,
            receipt = if isReceiptCap: deferredReceipt else: "")
        if isReceiptCap:
          deferredReceipt = ""
          emitFatPromptEvent clearPendingHintEvent()
        messages.add %*{"role": "tool", "tool_call_id": id, "content": r}
        if hasQueuedAutosend():
          # Let the current assistant tool batch finish so the tool-call
          # pairing stays faithful to what the model requested, then return
          # before the model-initiated follow-up call. The interactive loop
          # drains the queued user text and starts the next user turn.
          queuedUser = true
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
          session.readCache = nil
          session.plan.setLen 0
          emitFatPromptEvent clearPendingHintEvent()
          emitFatPromptEvent clearBarEvent()
          if session.savePath != "":
            # Drop the draft belonging to the cleared conversation before the
            # session path moves to a new id.
            clearDraft(session)
            releaseSessionLock(session.savePath)
            session.savePath = newSessionPath()
            session.created = $now()
            session.cwd = safeCwd()
            acquireSessionLock(session.savePath)
          saveSession(session, messages)
          cleared = true
          break
      # The deferred receipt was captured before the loop, but a tool can
      # skip its commit at runtime (interrupt, akClear wiping the hint). If it
      # was never spliced onto a tool item, commit it as a trailing item so
      # the turn's token usage still lands in scrollback rather than silently
      # evaporating with the bar.
      if deferredReceipt.len > 0:
        commitPendingReceiptAfterStream()
        deferredReceipt = ""
      if cleared:
        emitFatPromptEvent clearPendingHintEvent()
        continue
      saveSession(session, messages)
      if isInterrupted():
        onTurnInterrupted()
        return true
      if queuedUser:
        endTurn(repaintPrompt = false)
        turnEnded = true
        return
      debugOut "runTurns: loop continue"
      continue
    let queuedBeforeFinalRender = hasQueuedAutosend()
    discard stopBarTick()
    stopSpinner(clearLiveFooter = false)
    if streamedLive:
      commitPendingReceiptAfterStream(restoreEditor = not queuedBeforeFinalRender)
    else:
      if not queuedBeforeFinalRender:
        stopTurnInputForFinalRender()
      commitAssistantItem(
        content,
        restoreEditor = not queuedBeforeFinalRender,
        finalBeforeIdle = not queuedBeforeFinalRender)
    if queuedBeforeFinalRender or hasQueuedAutosend():
      stopTurnInputForFinalRender()
      turnEnded = true
      return false
    if streamedLive:
      stopTurnInputForFinalRender()
    endTurnAfterTranscriptAppend()
    turnEnded = true
    break
  result = false

proc runTurnsInteractive*(p: Profile, messages: var JsonNode,
    session: var Session): bool =
  ## Returns true if the turn was interrupted by the user. See `runTurns`.
  if not gateExperimental(p):
    explainExperimentalGate(p)
    return false
  try:
    return runTurns(p, messages, session)
  except ApiError as e:
    saveSession(session, messages)
    if isInterruptedMsg(e.msg):
      # Safety net: `callModel`'s interrupt raises are caught inside
      # `runTurns` so `onTurnInterrupted` lands before the deferred
      # `endTurn`. If an interrupt ApiError nonetheless escapes `runTurns`,
      # the deferred `endTurn` already ran with the flag still set
      # (`repaintPrompt = false`), so repaint the idle prompt here after
      # appending the harness line.
      onTurnInterrupted()
      endTurn(repaintPrompt = true)
      return true
    else:
      stdout.styledWriteLine fgMagenta, e.msg, resetStyle
      return false
  except OSError as e:
    # The working directory was removed out from under us (e.g. the
    # user `rm -rf`'d it in another shell). There is nothing useful
    # to keep doing, so save what we have and exit cleanly. `quit`
    # runs the registered exit procs, which restore terminal state.
    saveSession(session, messages)
    stdout.styledWriteLine fgMagenta, "  ",
      "working directory gone: ", e.msg, resetStyle
    quit()
