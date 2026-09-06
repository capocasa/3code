
## Turn lifecycle orchestration.
##
## This module is the high-level place where model calls, tool calls,
## transcript commits and fat-prompt transitions meet.
## `api.nim` should stay transport/protocol focused; visual consequences of
## model/tool progress should flow through this layer.

import std/[algorithm, json, os, sets, strformat, strutils, tables, terminal, times]
when defined(posix):
  import std/posix except Time
import types, util, prompts, session, compact, config, actions, api,
  display, fatprompt, streamexec, toolstream, transcript
import engine as termengine

const
  FlailMaxEscalations* = 3   ## three recovery attempts, fourth flagged call aborts
  FlailWindowSize* = 8       ## how many recent call fingerprints to remember
  FlailSpacedThreshold* = 3  ## failing repeats of one call at any spacing flag on this occurrence
  FlailStreakMin* = 9        ## same-tool calls in a row all carrying one distinctive token flag here
  FlailStreakArm* = 12       ## same-tool run length before the streak signal is even considered

type
  FlailVerdict* = enum
    fvOk        ## not a loop; run the tool
    fvEscalate  ## loop: inject an escalation message, skip the tool
    fvAbort     ## still looping after all escalations: abort the turn

  FlailDetector* = object
    ## Detects agentic doom loops cheaply, in the harness, spending zero
    ## tokens on detection. Four complementary signals over a bounded window
    ## of recent calls:
    ##
    ## 1. Repetition: a fingerprint (name + args) recurring within the last
    ##    `FlailWindowSize` calls catches A-B-A-B cycles, not just identical
    ##    back-to-back calls. Repeats of the *identical consecutive* call
    ##    escalate fastest; spaced repeats need more occurrences.
    ## 2. No progress: a call that failed before (recorded per fingerprint
    ##    via `noteResult`) and keeps recurring in the window is a stuck
    ##    cycle even when other calls interleave; an immediately retried
    ##    no-op mutation counts heaviest. Calls whose results succeed are
    ##    only judged on identical-consecutive repetition, so a
    ##    legitimately idempotent poll (re-check output that changes) is
    ##    never falsely flagged.
    ## 4. Stuck streak: `FlailStreakMin` consecutive calls to the same tool
    ##    sharing one distinctive argument token. Every call in the
    ##    recorded doom loop was a novel, successful fingerprint; only this
    ##    signal sees it. Only armed once the same-tool run reaches
    ##    `FlailStreakArm`: models legitimately iterate 9-11 variants of one
    ##    command prefix (fixed binary and flags, varying tail) while
    ##    debugging, and the shared-prefix tokens that survive trimming the
    ##    `cd <dir> &&` boilerplate would flag that healthy work.
    ##
    ## Recovery uses a graduated ladder of injected messages, because field
    ## reports on GLM 5.x loops (zai-org/GLM-5#116) show a plain "be careful"
    ## warning does not break the loop: the model's thinking is already
    ## careful, it is the emission channel that is stuck. What works is
    ## forcing a change in the *shape* of the call, so the middle rung of
    ## the ladder demands exactly that before the final warning.
    ##
    ## Each escalation fires once; a flagged call after the last escalation
    ## aborts the turn. A genuinely novel call resets the ladder.
    window*: seq[string]      ## recent fingerprints, oldest first, <= FlailWindowSize
    escalations*: int
    lastNoProgress*: bool     ## did the previous executed call report no change?
    progress*: Table[string, bool]  ## last result per fingerprint; false = no change
    streakName*: string       ## tool name of the current same-tool run
    streakLen*: int           ## length of the current same-tool run
    streakTokens*: seq[HashSet[string]]  ## ring of per-call distinctive tokens

proc canonicalJson(node: JsonNode): string =
  ## Stable serialization with sorted object keys, so key-order variants of
  ## the same call fingerprint identically. Models re-emitting "the same
  ## call" from memory often reshuffle keys; raw-string comparison would
  ## treat those as different calls and miss the loop.
  case node.kind
  of JObject:
    var keys: seq[string]
    for k in node.fields.keys: keys.add k
    keys.sort
    result = "{"
    for i, k in keys:
      if i > 0: result.add ","
      result.add escapeJson(k)
      result.add ":"
      result.add canonicalJson(node.fields[k])
    result.add "}"
  of JArray:
    result = "["
    for i, e in node.elems:
      if i > 0: result.add ","
      result.add canonicalJson(e)
    result.add "]"
  else:
    result = $node

proc fingerprint(name, argsStr: string): string =
  var canonical = argsStr
  if argsStr.len > 0:
    try:
      canonical = canonicalJson(parseJson(argsStr))
    except CatchableError:
      discard
  name & "\x1f" & canonical

proc isMutating(name: string): bool =
  ## Only mutating tools participate in the no-progress signal. Name match is
  ## on the wire tool name (what the model emitted), kept loose so it works
  ## across providers' naming.
  let n = name.toLowerAscii
  n in ["write", "patch", "edit", "apply_patch", "applypatch", "write_file",
        "edit_file", "str_replace", "str_replace_editor", "create_file"]

proc tokenify(s: var string, outSet: var HashSet[string]) =
  ## Strip a leading `cd <dir> &&`, split into tokens, trim punctuation,
  ## normalize digits to '#', keep tokens of length >= 6.
  if s.startsWith("cd "):
    let rest = s[3 ..^ 1]
    let sp = rest.find(" && ")
    if sp > 0: s = rest[sp + 4 ..^ 1]
  for tok in s.splitWhitespace():
    var t = tok
    while t.len > 0 and not (t[0].isAlphanumeric or t[0] == '_'):
      t = t[1 ..^ 1]
    while t.len > 0 and not (t[^1].isAlphanumeric or t[^1] == '_'):
      t = t[0 ..< t.len - 1]
    if t.len < 6: continue
    var norm = ""
    for ch in t:
      if ch.isDigit: norm.add '#'
      else: norm.add ch
    outSet.incl norm

proc collectValues(node: JsonNode, outSet: var HashSet[string]) =
  case node.kind
  of JObject:
    for v in node.fields.values: collectValues(v, outSet)
  of JArray:
    for e in node.elems: collectValues(e, outSet)
  of JString:
    var s = node.str
    tokenify(s, outSet)
  else:
    discard

proc distinctiveTokens(argsStr: string): HashSet[string] =
  ## Tokens likely to carry the *intent* of a call, as opposed to shell
  ## grammar, cwd boilerplate, argument-key names or universal flags.
  ## Used only by the streak signal: a long run of same-tool calls all
  ## carrying one distinctive token is probing the same thing over and
  ## over. Only JSON string *values* are tokenized (the keys - command,
  ## path, search - would otherwise be the persistent "theme" of every
  ## call). A leading `cd <dir> &&` is stripped from each value so a
  ## persistent working directory cannot masquerade as the theme.
  ## Digits are normalized away so counters, line numbers and pids do not
  ## mask similarity; tokens shorter than 6 chars are dropped because
  ## short tokens are usually flags, paths' common words or shell keywords.
  try:
    collectValues(parseJson(argsStr), result)
  except CatchableError:
    var s = argsStr
    tokenify(s, result)

proc countInWindow(det: FlailDetector, fp: string): int =
  for w in det.window:
    if w == fp: inc result

proc noteResult*(det: var FlailDetector, name, argsStr: string, madeChange: bool) =
  ## Record whether the just-executed call actually changed anything. Called
  ## after execution with the tool's own verdict (exit code 0 vs failure).
  ## Read-only tools pass madeChange=true so they never arm the no-progress
  ## signal. The per-fingerprint record powers the spaced-repeat signal: a
  ## call that failed before and keeps coming back inside the window is a
  ## stuck cycle even when other calls interleave.
  det.lastNoProgress = isMutating(name) and not madeChange
  det.progress[fingerprint(name, argsStr)] = madeChange

proc observeCall*(det: var FlailDetector, name, argsStr: string): FlailVerdict =
  ## Record one tool call and decide what to do with it. Called once per
  ## tool call before execution; `argsStr` is the raw arguments JSON so
  ## key-order variants of the same call compare equal only when the model
  ## emits them identically (good enough for a loop detector).
  let fp = fingerprint(name, argsStr)
  let seen = det.countInWindow(fp)
  let consecutive = det.window.len > 0 and det.window[^1] == fp

  # Streak signal state: a ring of the last FlailStreakMin same-tool
  # calls and the distinctive tokens each carried. A switch to a different
  # tool empties the ring. The signal fires when the full ring shares at
  # least one token: every recent call to this tool is probing the same
  # thing. A sliding window (not a shrinking run intersection) so one
  # healthy deviation inside a doom loop does not permanently disarm it.
  # The ring only starts filling at FlailStreakArm calls into the run, so
  # a healthy burst of same-tool iteration (compile, read, tweak, test)
  # shorter than that never arms the signal at all.
  let toks = distinctiveTokens(argsStr)
  if det.streakName != name:
    det.streakName = name
    det.streakLen = 0
    det.streakTokens = @[]
  inc det.streakLen
  if det.streakLen >= FlailStreakArm:
    det.streakTokens.add toks
    if det.streakTokens.len > FlailStreakMin:
      det.streakTokens.delete 0
  var stuckStreak = false
  if det.streakTokens.len == FlailStreakMin:
    var common = det.streakTokens[0]
    for s in det.streakTokens[1 ..^ 1]:
      common = common * s
    stuckStreak = common.len > 0

  # Push onto the bounded window.
  det.window.add fp
  if det.window.len > FlailWindowSize:
    det.window.delete 0

  # Flag this call as a loop on any of four signals:
  #
  # 1. Identical consecutive repeat: the model re-emitted the exact call it
  #    just made. Strongest signal; flags on the first repeat. This is the
  #    classic GLM identical-call loop and the cheap MTP-duplication case.
  # 2. No-progress re-try: the previous mutating call made no change
  #    (`lastNoProgress`) AND the model is re-trying a call it already made
  #    in this window.
  # 3. Spaced failing repeat: this exact call failed before (per-fingerprint
  #    record from `noteResult`) and this is at least its third sighting in
  #    the window. Catches A-B-A-B cycles of *failing* calls that signal 1
  #    misses because the calls interleave. A spaced cycle of *successful*
  #    calls (re-run a test, re-check output) is legitimate polling and is
  #    never flagged; progress distinguishes a stuck loop from a poll.
  # 4. Stuck streak: the last FlailStreakMin calls were all to the same tool
  #    and all carry one distinctive argument token, and the same-tool run
  #    is at least FlailStreakArm long. Catches the recorded GLM doom loop
  #    where every call was a novel fingerprint (cosmetic pipeline
  #    variations of one grep), succeeded (exit 0), and never repeated
  #    exactly, so signals 1-3 all stayed quiet while the model spent 25
  #    calls re-probing one fact; the arm gate keeps short healthy bursts
  #    of same-command-prefix iteration out.
  let knownFailing = not det.progress.getOrDefault(fp, true)
  let isLoop = consecutive or (det.lastNoProgress and seen >= 1) or
    (knownFailing and seen >= FlailSpacedThreshold - 1) or stuckStreak
  if not isLoop:
    # Genuinely new or harmless: a clearly novel call resets the ladder.
    if seen == 0:
      det.escalations = 0
    return fvOk

  # Flagged as a loop.
  if det.escalations < FlailMaxEscalations:
    inc det.escalations
    return fvEscalate
  fvAbort

proc flailEscalationMessage*(step: int): string =
  ## The tool-role message injected in place of the repeated tool result.
  ## Three graduated recovery attempts before the abort: step 1 names the
  ## loop and demands a strategy change; step 2 forces the only recovery
  ## known to work on GLM 5.x emission-stuck loops (reply in prose first,
  ## then a structurally different call, per zai-org/GLM-5#116); step 3 is
  ## the final warning. Deliberately short: this is the only token cost of
  ## the whole mechanism.
  ##
  ## Steps 1-2 never invite the model to stop and ask the user: these
  ## messages persist in context for the rest of the session, and GLM
  ## generalizes "tell the user what is blocking you" into a habit of
  ## checking in instead of acting (field reports, Sep 2026). The
  ## user-handoff instruction lives only in the step-3 final warning.
  if step == 1:
    "SYSTEM: Loop detected: you are repeating tool calls that are not making " &
    "progress. Repeating them will not help. Change strategy now: use a " &
    "different input, a different tool, or a smaller step, and continue " &
    "the task."
  elif step == 2:
    "SYSTEM: You repeated the same call after a loop warning. Telling " &
    "yourself to be careful does not fix this: the next call would likely " &
    "come out identical again. Do not emit that call. First reply in plain " &
    "prose with no tool call: one sentence stating the hypothesis your next " &
    "attempt will test. Then, if you continue, use " &
    "a structurally different call (different arguments, flags, or tool), " &
    "not the same one with cosmetic edits."
  else:
    "SYSTEM: Final warning: you are still repeating non-progress tool calls " &
    "after two warnings. One more repeat and this turn is aborted. Stop " &
    "calling tools and tell the user what is blocking you."

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
  ## other trigger wired to `requestTurnInterrupt`). Same scrollback
  ## contract as `apiRetryNotice`: one ordinary harness line, no leading
  ## bullet, written through `writeTranscriptWithFatPrompt` so the fat
  ## prompt's editor is preserved in place across this line.
  ##
  ## This is the only place that renders an interrupt message. Whether the
  ## interrupt was noticed mid-stream, after a tool call, or propagated up
  ## as an `ApiError` once the stream had already torn itself down, the
  ## response is identical.
  ##
  ## The spinner or bar-tick thread may still be running when this fires.
  ## Stop them with `clearLiveFooter = false` so the freshly-painted
  ## editor row below is not overwritten, then commit the harness line
  ## through `writeTranscriptWithFatPrompt` (the same primitive
  ## `apiRetryNotice` and the normal turn-end path use). Callers in
  ## `runTurns` skip their deferred `endTurn` afterwards — the editor
  ## paint here owns the final prompt position. Because `endTurn` is
  ## skipped, `stopTurnInputForFinalRender` (which it normally calls) is
  ## skipped too, so reset `inputTurnActive` here: otherwise the input
  ## thread keeps believing a turn is in progress and routes every later
  ## Ctrl-D to the interrupt branch instead of the quit branch.
  stopTurnInputForFinalRender()
  stopSpinner(clearLiveFooter = false)
  discard stopBarTick()
  commitTranscriptBytes(errLnS(InterruptedByUserMsg), true)
  emitTestFrameEvent()
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
    # Push a snapshot of the viewport's raw inputs into the shared model;
    # the GUI thread owns the viewport+footer composite during amBarTick
    # and re-wraps it at the live terminal width each tick (so a resize
    # between output lines re-wraps instead of replaying stale rows). The
    # GUI thread owns the rotating command symbol too, so don't set it
    # here. In test mode, request one paint and wait for the ack so the
    # harness captures each streamed line as a discrete frame (the frame
    # event fires after this returns). In normal mode the 80ms cadence
    # paints the rows.
    setAnimViewport(view.banner, view.buf, view.exitCode, view.idx,
                    view.maxLines)
    requestViewportPaint()

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
    # The GUI thread still owns the composite, so clear via the model + a
    # paint request rather than rendering directly.
    if getCurrentException() != nil:
      clearAnimViewport()
      requestViewportPaint()

proc pendingReceiptBytes(): string =
  if not pendingHint.active:
    return ""
  let label = tokenLineLabel(pendingHint.usage, pendingHint.window,
                             pendingHint.elapsed)
  receiptBytes(label)

proc finishTranscriptItem(bytes: var string) =
  ## Trim trailing whitespace before the write (append-only-safe). The
  ## inter-item separator is owned by `appendTranscript`, which prepends
  ## `\r\n\r\n` before every item after the first; items carry no trailing
  ## separator.
  bytes.trimTranscriptTail()

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
                         attachReceipt = true) =
  let afterCommit =
    if attachReceipt: clearSubmittedReceiptState
    else: clearSubmittedTickerState
  if content.strip.len == 0:
    let receipt = if attachReceipt: pendingReceiptBytes() else: ""
    var bytes = emptyAssistantBytes(attachReceipt, receipt)
    bytes.finishTranscriptItem()
    commitTranscriptBytes(bytes, restoreEditor, afterCommit)
    return
  var bytes = renderAssistantContentBytes(content)
  bytes.trimTranscriptTail()
  let receipt = if attachReceipt: pendingReceiptBytes() else: ""
  if attachReceipt and receipt.len > 0:
    bytes.add "\r\n"
    bytes.add receipt
  bytes.finishTranscriptItem()
  commitTranscriptBytes(bytes, restoreEditor, afterCommit)

proc commitPendingReceiptAfterStream(restoreEditor = true;
                                    flushWithPrevious = true) =
  ## Streaming assistant content is already in scrollback. Once usage arrives,
  ## append only the receipt. With `flushWithPrevious` it joins the streamed
  ## answer it caps with no separator blank (design.md: "no blank line
  ## between the last output of the API call and its token receipt"); the
  ## all-tools-skipped fallback passes false because nothing of this call's
  ## output may be directly above it.
  var bytes = pendingReceiptBytes()
  if bytes.len == 0:
    return
  bytes.finishTranscriptItem()
  commitTranscriptBytes(bytes, restoreEditor, clearSubmittedReceiptState,
                        flushWithPrevious = flushWithPrevious)

proc commitTranscriptItem(formatBody: proc(): string; restoreEditor = true;
                          receipt = "") =
  var bytes = formatBody()
  if receipt.len > 0:
    bytes.trimTranscriptTail()
    bytes.add "\r\n"
    bytes.add receipt
  bytes.finishTranscriptItem()
  commitTranscriptBytes(bytes, restoreEditor)

proc tagCheckpoint*(msg: JsonNode, id: int) =
  ## Prefix an assistant message's content with a `[checkpoint N]` marker
  ## so a dmail-capable model can name a revert target. Only tagged for
  ## profiles whose tool schema includes `dmail`; every other family
  ## passes messages through untouched (no wire diff, no test churn).
  ## Skips nil content (tool-call-only messages) so the wire shape of the
  ## string-vs-null content field is preserved.
  if msg.kind != JObject: return
  let content = msg{"content"}
  if content == nil or content.kind != JString: return
  content.str = "[checkpoint " & $id & "]\n" & content.str

proc revertHistory*(messages: var JsonNode, checkpoint: int): bool =
  ## Truncate `messages` just before the assistant message whose content
  ## carries the `[checkpoint N]` marker. Orphaned tool results at the new
  ## tail are dropped too (the summarizer walks back from tool messages
  ## for the same reason; their assistant owner may sit before the
  ## checkpoint). Returns false when no marker matches; the caller leaves
  ## the conversation untouched.
  if messages == nil or messages.kind != JArray: return false
  let marker = "[checkpoint " & $checkpoint & "]"
  var cut = -1
  for i in countdown(messages.len - 1, 1):
    let m = messages[i]
    if m.kind != JObject or m{"role"}.getStr != "assistant": continue
    let content = m{"content"}
    if content != nil and content.kind == JString and
       content.str.startsWith(marker):
      cut = i
      break
  if cut < 0: return false
  # Everything before the tagged message survives as-is: any tool result
  # in there has its assistant owner right before it, also kept. (This is
  # different from the summarizer's walk-back, which keeps a TAIL and
  # must not start it on a tool message; here we keep a PREFIX.)
  messages.elems.setLen(cut)
  true

proc runTurns*(p: Profile, messages: var JsonNode, session: var Session): bool =
  ## Returns true if the turn was interrupted by the user (Ctrl-C / ESC).
  ## Callers use this to skip end-of-turn side effects like desktop
  ## notifications: the user was at the keyboard to cancel, so alerting
  ## them that the turn finished would be noise.
  ## Headless (library) sessions installed their own hooks at session init;
  ## reinstalling the terminal set would clobber them (and paint on a tty
  ## that isn't there), so only the terminal path re-installs here.
  if termengine.engineOutputEnabled:
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
    wire = p                      # mutable copy: length-retries demote reasoning
                                  # effort here instead of only raising the budget
    maxTokensOverride = 0          # > 0 replaces known-good max_tokens
    lengthEscalations = 0          # "length" retries so far this turn
    steerAttempts = 0              # "stop"/unknown steering retries
    emptyRetries = 0               # bare empty-reply resends after smart-handling
    flailDet: FlailDetector        # identical-consecutive-tool-call guard
    nextCheckpoint = 0             # id of the marker on the next assistant message
  # dmail is offered only when the active profile's tool schema includes
  # it (kimi family); the marker tagging below keys off the same flag.
  var dmailEnabled = false
  if p.family == "kimi":
    let tools = setup(p).tools
    if tools != nil and tools.kind == JArray:
      for t in tools:
        if t{"function"}{"name"}.getStr == "dmail":
          dmailEnabled = true
          break
  const
    MaxLengthEscalations = 3
    MaxSteerAttempts = 1
    MaxEmptyRetries = 12
  decayEmptyRetryLevel(epochTime())
  # Publish the conversation id for the OpenCode Zen/Go session header
  # (stable across turns → routing/token-cache affinity). Recomputed every
  # turn because :clear/akClear rotate savePath mid-conversation. A session
  # with no savePath mints a one-shot id so the whole turn (tool-call loop,
  # retries) shares one header value.
  let sid = sessionIdFromPath(session.savePath)
  conversationId = if sid != "": sid else: oneShotSessionId()
  while true:
    var usage: Usage
    var msg: JsonNode
    try:
      msg = callModel(wire, messages, usage, session.lastPromptTokens,
        maxTokensOverride)
    except ApiError as e:
      if isInterruptedMsg(e.msg):
        saveSession(session, messages)
        onTurnInterrupted()
        # onTurnInterrupted already stopped the spinner/bar-tick and
        # repainted the editor via writeTranscriptWithFatPrompt; the
        # deferred endTurn would erase that and reset the cursor to col 0.
        turnEnded = true
        return true
      # Transport retry budget exhausted (or another fatal callModel error).
      # `callModel` already stopped the spinner, but the deferred `endTurn`
      # below still owns the prompt repaint, and the outer catch path used
      # to `stdout.styledWriteLine` the error after that repaint — which
      # stranded the caret one row above the prompt on the stale spinner
      # row and made the next keystroke land in scrollback. Render the
      # error through the transcript primitive (same as the empty-content
      # branches above) so the prompt lands in the right place and the
      # error is part of the same scrollback block as the rest of the
      # turn. `endTurnAfterTranscriptAppend` finalizes the turn without
      # rewriting the prompt.
      saveSession(session, messages)
      commitTranscriptBytes(errLnS(e.msg), true)
      endTurnAfterTranscriptAppend()
      turnEnded = true
      return false
    session.usage.promptTokens += usage.promptTokens
    session.usage.completionTokens += usage.completionTokens
    session.usage.totalTokens += usage.totalTokens
    session.usage.cachedTokens += usage.cachedTokens
    session.lastPromptTokens = usage.promptTokens
    if isInterrupted():
      saveSession(session, messages)
      onTurnInterrupted()
      # onTurnInterrupted already stopped the spinner/bar-tick and
      # repainted the editor via writeTranscriptWithFatPrompt; the
      # deferred endTurn would erase that and reset the cursor to col 0.
      turnEnded = true
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
      # Empty assistant turn. Try the targeted recoveries first (escalate the
      # budget on "length", steer on "stop"/unknown), then fall back to a
      # bare resend. A hostile or broken provider can't pin the turn: each
      # path has its own ceiling, and the final resend loop is bounded by
      # MaxEmptyRetries. This is a conversational concern, kept out of
      # callModel's transport retry block.
      let budgetStarved =
        finishReason == "length" or
        usage.completionTokens >= knownGoodGeneration(wire).maxTokens or
        usage.reasoningTokens > 0
      if budgetStarved and lengthEscalations < MaxLengthEscalations:
        inc lengthEscalations
        # A forced-thinking model that spent the whole budget on reasoning
        # and returned nothing will usually do it again at 2x the budget:
        # the thinking scales with effort, not with headroom. Demote the
        # effort first (high -> low; verified against Z.ai: effort high
        # starves 400-token budgets that effort low finishes in 1k) and
        # only raise the budget once effort is already at the floor or
        # the family has no graded knob. Budget bumps are also clamped
        # by the model's real output cap (131k on GLM-5.3), so a starved
        # turn at the cap would otherwise just re-derive the same
        # override and burn identical retries.
        var demoted = false
        if wire.reasoning == "max":
          wire.reasoning = "high"; demoted = true
        elif wire.reasoning == "high":
          wire.reasoning = "low"; demoted = true
        if not demoted:
          let cur =
            if maxTokensOverride > 0: maxTokensOverride
            else: knownGoodGeneration(wire).maxTokens
          let bumped = min(cur * 2, maxOutputTokensFor(wire))
          maxTokensOverride = max(maxTokensOverride, bumped)
        let backoff = emptyReplyBackoffS()
        commitTranscriptBytes(
          errLnS((if demoted: "finished by length, retrying with lower " &
            "reasoning effort" else: "finished by length, retrying with " &
            humanTokens(maxTokensOverride) & " token budget") & " in " &
            $backoff & "s"), true)
        incEmptyRetryLevel()
        if emptyReplyWait():
          saveSession(session, messages)
          onTurnInterrupted()
          turnEnded = true
          return true
        debugOut &"runTurns: empty length-retry {lengthEscalations}/{MaxLengthEscalations} max_tokens={maxTokensOverride} reasoning={wire.reasoning}"
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
        let backoff = emptyReplyBackoffS()
        commitTranscriptBytes(
          errLnS("empty reply; re-prompting for a final answer in " &
            $backoff & "s"), true)
        incEmptyRetryLevel()
        if emptyReplyWait():
          saveSession(session, messages)
          onTurnInterrupted()
          turnEnded = true
          return true
        debugOut &"runTurns: empty steer-retry {steerAttempts}/{MaxSteerAttempts}"
        continue
      # Smart-handling exhausted (or never applicable). Retry the bare call,
      # surfacing whatever signal the reply carried as the reason. Bounded so
      # a permanently-empty provider gives up rather than looping forever.
      if emptyRetries < MaxEmptyRetries:
        inc emptyRetries
        let reason =
          if finishReason.len > 0: finishReason
          elif usage.reasoningTokens > 0: "reasoning only"
          else: "no content, no tool calls"
        let backoff = emptyReplyBackoffS()
        commitTranscriptBytes(
          errLnS("empty reply: " & reason & ". retrying " &
            $emptyRetries & "/" & $MaxEmptyRetries & " in " & $backoff & "s"), true)
        incEmptyRetryLevel()
        if emptyReplyWait():
          saveSession(session, messages)
          onTurnInterrupted()
          turnEnded = true
          return true
        debugOut &"runTurns: empty resend {emptyRetries}/{MaxEmptyRetries} finishReason={finishReason}"
        continue
      # All retries exhausted. Persist the empty turn and surface a final
      # notice so the user knows the model gave nothing back.
      messages.add msg
      saveSession(session, messages)
      commitTranscriptBytes(
        errLnS("empty reply - giving up after " & $MaxEmptyRetries &
          " retries"), true)
      endTurnAfterTranscriptAppend()
      turnEnded = true
      break
    if dmailEnabled:
      tagCheckpoint(msg, nextCheckpoint)
      inc nextCheckpoint
    messages.add msg
    saveSession(session, messages)
    let window = contextWindowFor(p)
    case decideContextAction(usage.promptTokens, window, messages.len)
    of caSummarize:
      let summarized = summarizeHistory(messages, p)
      if summarized > 0:
        commitTranscriptBytes(
          hintLnS(&"· summarized {summarized} message" &
            (if summarized == 1: "" else: "s") &
            &" (context at {humanTokens(usage.promptTokens)}/{humanTokens(window)} tokens)"), true)
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
      var dmailRevert = false  # akDMail: history truncated, continue loop
      var flailAbort = false  # flail detector fired past all escalations
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
        case flailDet.observeCall(name, argsStr)
        of fvOk: discard
        of fvEscalate:
          # The model re-emitted the exact same call it just made. Skip
          # execution, pair the tool_call with the escalation notice (so
          # the request/response pairing stays intact), and surface a
          # harness line so the user sees the intervention.
          let note = flailEscalationMessage(flailDet.escalations)
          debugOut &"flail: identical repeat of {name}, escalation {flailDet.escalations}/{FlailMaxEscalations}"
          session.toolLog.add ToolRecord(
            banner: "! " & name & " (flailing)",
            output: note, code: -1, kind: akError)
          messages.add %*{"role": "tool", "tool_call_id": id,
                          "content": note}
          commitTranscriptBytes(
            errLnS(if flailDet.escalations == 1:
                     "flailing detected (repeated tool call); hinting the model"
                   elif flailDet.escalations < FlailMaxEscalations:
                     "still flailing; demanding a different approach from the model"
                   else:
                     "still flailing; final warning to the model"), true)
          continue
        of fvAbort:
          # Still looping after all recovery attempts. Pair the tool_call,
          # then stop the turn and hand control back to the user with a
          # visible warning.
          debugOut &"flail: repeat of {name} after {FlailMaxEscalations} escalations; aborting turn"
          let note =
            "SYSTEM: Turn aborted: the same tool call was repeated after " &
            "three warnings. The model is stuck in a loop."
          session.toolLog.add ToolRecord(
            banner: "! " & name & " (flail abort)",
            output: note, code: -1, kind: akError)
          messages.add %*{"role": "tool", "tool_call_id": id,
                          "content": note}
          # Pair any remaining tool_calls in this batch too: the
          # assistant message carries them all and an unpaired id breaks
          # strict providers on the next request.
          for j in i + 1 ..< toolCalls.len:
            messages.add %*{"role": "tool",
              "tool_call_id": toolCalls[j]{"id"}.getStr,
              "content": note}
          flailAbort = true
          break
        let (args, argsMalformed, parseErr) =
          block:
            var a: JsonNode
            var bad = false
            var err = ""
            try: a = parseJson(if argsStr == "": "{}" else: argsStr)
            except CatchableError as e:
              debugOut "tool_call " & name &
                " has malformed arguments JSON (" & e.msg & "): " & argsStr
              a = newJObject()
              bad = true
              err = e.msg
            (a, bad, err)
        let toolStub = tc{"stub"}
        let idx = session.toolLog.len + 1
        if argsMalformed:
          debugOut "tool done: " & name &
            " code=-1 (malformed args, skipping execution)"
          session.toolLog.add ToolRecord(
            banner: "! " & name & " (malformed args)",
            output: "malformed arguments: " & argsStr, code: -1, kind: akBash)
          messages.add %*{"role": "tool", "tool_call_id": id,
            "content": "ERROR: tool arguments arrived truncated or malformed: " &
              parseErr & ". Re-emit this tool call."}
          continue
        let act = toolCallToAction(p.family, name, args)
        let silent = isSkillRead(act)
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

        # Feed the no-progress signal: a failed call (code != 0) is
        # recorded per fingerprint, so a spaced re-try of that exact call
        # counts toward a loop; an immediately retried failed mutation
        # counts heaviest. Successful calls never arm the signal, so
        # legitimate polling is untouched. Uses the tool's own exit
        # verdict, so it costs nothing extra at runtime.
        flailDet.noteResult(name, argsStr, madeChange = code == 0)

        session.toolLog.add ToolRecord(banner: bannerFor(act), output: r,
          code: code, kind: act.kind, plan: act.plan)
        let isReceiptCap = deferredReceipt.len > 0 and i == lastCommitIdx
        if not silent:
          appendItem(
            toolItem(act, r, code, idx, diff, toolElapsed.int),
            receipt = if isReceiptCap: deferredReceipt else: "")
        else:
          commitTranscriptItem(proc(): string =
            skillLoadedBytes(act)
          , receipt = if isReceiptCap: deferredReceipt else: "")
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
        if act.kind == akDMail:
          # Model-initiated context pruning: pair the tool_call, then
          # truncate the conversation to just before the assistant message
          # carrying the requested `[checkpoint N]` marker and append the
          # dmail as a user message. Everything after the marker
          # (including the assistant message that requested this dmail
          # and the tool result just paired) is discarded; the filesystem
          # is NOT reverted. An invalid checkpoint keeps the conversation
          # untouched and reports back in the tool result instead.
          let cp = try: parseInt(act.path) except CatchableError: -1
          let ok = dmailEnabled and cp >= 0 and
                   revertHistory(messages, cp)
          if ok:
            messages.add %*{"role": "user", "content":
              "[dmail from your future self] " & act.body}
            saveSession(session, messages)
            dmailRevert = true
            commitTranscriptBytes(
              hintLnS("· dmail to checkpoint " & $cp & " (" &
                humanTokens(session.lastPromptTokens) & " prompt tokens folded)"),
              true)
            break
          else:
            messages.add %*{"role": "tool", "tool_call_id": id,
              "content": "ERROR: checkpoint " & act.path &
                " not found. Checkpoints are the `[checkpoint N]` markers " &
                "on your assistant messages; pick one of those."}
            continue
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
          flailDet = FlailDetector()  # fresh conversation, fresh ladder
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
            updateActiveDirLockSession(session.savePath)
          saveSession(session, messages)
          cleared = true
          break
      # The deferred receipt was captured before the loop, but a tool can
      # skip its commit at runtime (interrupt, akClear wiping the hint). If it
      # was never spliced onto a tool item, commit it as a trailing item so
      # the turn's token usage still lands in scrollback rather than silently
      # evaporating with the bar.
      if deferredReceipt.len > 0:
        commitPendingReceiptAfterStream(flushWithPrevious = streamedLive)
        deferredReceipt = ""
      if cleared:
        emitFatPromptEvent clearPendingHintEvent()
        continue
      if dmailRevert:
        continue
      if flailAbort:
        saveSession(session, messages)
        commitTranscriptBytes(
          errLnS("turn aborted: the model kept repeating the same tool " &
            "call after three warnings. It appears stuck; please rephrase, " &
            "give it a hint, or take over."), true)
        endTurnAfterTranscriptAppend()
        turnEnded = true
        return false
      saveSession(session, messages)
      if isInterrupted():
        onTurnInterrupted()
        # Same contract as the callModel interrupt paths above:
        # onTurnInterrupted already stopped the spinner/bar-tick and
        # repainted the editor via the transcript commit; the deferred
        # endTurn would erase that repaint and park the caret at col 0.
        turnEnded = true
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
        restoreEditor = not queuedBeforeFinalRender)
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
    # The controller already ran `emitUserSubmit`, which parks the input
    # thread (`inputIdleLinePending`) until the turn starts. A normal turn
    # unparks via `beginTurn`; this bail-out never reaches it, so unpark
    # here or the editor wedges until kill -9. Same idiom as the
    # `no provider configured` bail-out in the REPL loop.
    releaseIdleSubmittedInput()
    return false
  try:
    return runTurns(p, messages, session)
  except ApiError as e:
    saveSession(session, messages)
    if isInterruptedMsg(e.msg):
      # Safety net: `callModel`'s interrupt raises are normally caught inside
      # `runTurns` so `onTurnInterrupted` lands before the deferred
      # `endTurn` and its callers set `turnEnded = true` to skip that
      # `endTurn`. If an interrupt ApiError nonetheless escapes `runTurns`,
      # the deferred `endTurn` already ran with the flag still set
      # (`repaintPrompt = false`), so `onTurnInterrupted` owns the prompt
      # repaint here.
      onTurnInterrupted()
      return true
    # Safety net for ApiErrors that escape `runTurns` other than from the
    # callModel retry-exhaustion path (which is handled inside the loop
    # and never reaches here). By the time we get here, `runTurns`'s
    # deferred `endTurn` has already repainted the prompt; writing the
    # error to stdout would walk past the prompt and strand the caret on
    # the error line, so route through stderr (the existing channel for
    # transient post-prompt feedback) instead.
    stderr.writeLine e.msg
    return false
  except IOError as e:
    # stdout (or another fd we write to) became unwritable mid-turn:
    # closed pipe, ssh disconnect, terminal hang-up, broken tty. The
    # runTurns deferred `finishTurn` has already repainted the prompt
    # (or tried to — if stdout is gone, the editor is gone with it),
    # and the session was already saved at the end of the last tool
    # batch / assistant commit, so we don't re-save here (a second
    # saveDraft-style write can race with a stale .tmp left behind by
    # the previous saveSession and surface its own IOError). Surface
    # the error on stderr (the only fd we can trust at this point)
    # and return so the REPL loop decides whether to keep going.
    # Without this catch the unhandled IOError propagates all the way
    # out and the process dies silently, which is the user-visible
    # "3code just exits during a turn" bug.
    stderr.writeLine "3code: output stream broken (" & e.msg &
      "); turn ended, session saved. If you ran 3code from a pipe " &
      "or a now-closed terminal, reattach before sending more prompts."
    return false
  except OSError as e:
    # The working directory was removed out from under us (e.g. the
    # user `rm -rf`'d it in another shell). There is nothing useful
    # to keep doing, so save what we have and exit cleanly. `quit`
    # runs the registered exit procs, which restore terminal state.
    try: saveSession(session, messages) except CatchableError: discard
    commitTranscriptBytes(errLnS("working directory gone: " & e.msg), true)
    quit()
  except CatchableError as e:
    # Last-resort safety net: anything else that escapes `runTurns`
    # (JsonError, ValueError, KeyError, IOError subtypes, library
    # defects wrapped as CatchableError, etc.). The session was saved
    # on the last tool-batch / assistant-commit boundary inside
    # runTurns, so we don't re-save here either. In debug builds we
    # re-raise so the developer sees the full stack via Nim's
    # unhandled-exception printer. In release builds we render a
    # one-line notice plus the stack trace to stderr and quit cleanly
    # so the user isn't left staring at a dead prompt after a crash
    # that would otherwise vanish silently.
    when not defined(release):
      raise
    let trace = e.getStackTrace()
    stderr.writeLine "3code: internal error during turn: " & e.msg
    if trace.len > 0:
      stderr.writeLine trace
    stderr.writeLine "3code: session saved at " & session.savePath &
      ". Please open an issue with the lines above."
    quit()
