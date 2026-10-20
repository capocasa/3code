
## Turn lifecycle orchestration.
##
## This module is the high-level place where model calls, tool calls,
## transcript commits and fat-prompt transitions meet.
## `api.nim` should stay transport/protocol focused; visual consequences of
## model/tool progress should flow through this layer.

import std/[algorithm, json, os, sequtils, sets, strformat, strutils, tables,
  terminal, times]
when defined(posix):
  import std/posix except Time
import types, util, prompts, session, compact, config, actions, api, plugins,
  display, fatprompt, streamexec, toolstream, transcript, images
import sandbox
import tabtitle
import goal
import engine as termengine

const
  FlailMaxEscalations* = 3   ## three recovery attempts, fourth flagged call aborts
  FlailWindowSize* = 8       ## how many recent call fingerprints to remember
  FlailSpacedThreshold* = 3  ## failing repeats of one call at any spacing flag on this occurrence
  FlailStreakMin* = 9        ## ring size: the last N same-tool calls decide the streak signal
  FlailStreakArm* = 12       ## same-tool run length before the streak signal is even considered
  FlailStreakJaccard* = 0.5  ## avg pairwise token overlap the ring must reach to flag
  FlailStreakNearDup* = 0.8  ## pairwise Jaccard at which two ring calls count as near-duplicates
  FlailStreakCluster* = 4    ## near-duplicates forming a tight repeat cluster flag on their own
  FlailStreakStale* = 4      ## consecutive results adding no new output line before the streak can flag
  FlailSeenLinesMax* = 4096  ## per-run output-line memory cap; past it the epoch restarts empty

type
  FlailVerdict* = enum
    fvOk        ## not a loop; plain run
    fvEscalate  ## loop: run the tool anyway, note rides on the result
    fvAbort     ## still looping after all escalations: run this call,
                ## then abort the turn

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
    ## 4. Stuck streak: the last `FlailStreakMin` calls to the same tool are
    ##    mostly the same call, and the run is at least `FlailStreakArm` long.
    ##    Mostly-same means either ring-wide overlap (average pairwise token
    ##    Jaccard >= `FlailStreakJaccard`) or a tight cluster of
    ##    `FlailStreakCluster` near-duplicates. Sharing one keyword is
    ##    deliberately not enough: recorded sessions show varied work on one
    ##    project or host shares boilerplate tokens across every call. A call
    ##    sharing no distinctive token with the ring's consensus is a subject
    ##    change, not a cosmetic variant, and empties the ring: an
    ##    uninterrupted run of near-duplicates is required to build one.
    ##
    ## Recovery uses a graduated ladder of injected messages, because field
    ## reports on GLM 5.x loops (zai-org/GLM-5#116) show a plain "be careful"
    ## warning does not break the loop: the model's thinking is already
    ## careful, it is the emission channel that is stuck. What works is
    ## forcing a change in the *shape* of the call, so the middle rung of
    ## the ladder demands exactly that before the final warning.
    ##
    ## Each escalation fires once per model batch: models that emit many
    ## tool calls in one response get one nudge per response, never a
    ## whole ladder inside a single batch. A flagged call in a later batch
    ## after the last escalation aborts the turn. A genuinely novel call
    ## resets the ladder.
    window*: seq[string]      ## recent fingerprints, oldest first, <= FlailWindowSize
    escalations*: int
    lastNoProgress*: bool     ## did the previous executed call report no change?
    progress*: Table[string, bool]  ## last result per fingerprint; false = no change
    streakName*: string       ## tool name of the current same-tool run
    streakLen*: int           ## length of the current same-tool run
    streakTokens*: seq[HashSet[string]]  ## ring of per-call distinctive tokens
    staleStreak*: int         ## consecutive executed streak calls that added no new output line
    seenLines*: HashSet[string]  ## output lines (normalized) already delivered in this run
    flaggedInBatch*: bool     ## a loop already fired in this model batch (one rung per batch)

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
      let node = parseJson(argsStr)
      # `read` of an image ignores offset/limit (the budget encoder
      # delivers the same bytes whatever window was asked for), so those
      # args don't change the work: key the fingerprint on the path alone
      # and a run of reads varying only the window compares as the same
      # call, which the ordinary repeat signals flag.
      if "read" in name.toLowerAscii:
        let p = node{"path"}.getStr("")
        if p.len > 0 and isImagePath(p):
          canonical = canonicalJson(%*{"path": p})
        else:
          canonical = canonicalJson(node)
      else:
        canonical = canonicalJson(node)
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
  ## Strip a leading `cd <dir> &&` or `ssh [user@]host` remote-exec prefix,
  ## split into tokens, trim punctuation, normalize digits to '#', keep
  ## tokens of length >= 6.
  ## The ssh strip matters because a remote session bakes the host and the
  ## remote working directory into every command; without it the host token
  ## is the one thing a whole run of ssh calls shares and the streak signal
  ## reads connection boilerplate as a probing theme.
  for _ in 0 ..< 4:
    var stripped = false
    s = s.strip(leading = true, trailing = false)
    if s.startsWith("cd "):
      let rest = s[3 ..^ 1]
      let sp = rest.find(" && ")
      if sp > 0:
        s = rest[sp + 4 ..^ 1]
        stripped = true
    if s.startsWith("ssh "):
      let rest = s[4 ..^ 1]
      let sp = rest.find(' ')
      s = if sp > 0: rest[sp + 1 ..^ 1] else: ""
      while s.len > 0 and s[0] in {' ', '\'', '"'}: s = s[1 ..^ 1]
      stripped = true
    if not stripped: break
  for tok in s.splitWhitespace():
    var t = tok
    while t.len > 0 and not (t[0].isAlphanumeric or t[0] == '_'):
      t = t[1 ..^ 1]
    while t.len > 0 and not (t[^1].isAlphanumeric or t[^1] == '_'):
      t = t[0 ..< t.len - 1]
    if t.len < 6: continue
    var norm = ""
    var letters = 0
    for ch in t:
      if ch.isDigit: norm.add '#'
      else:
        norm.add ch
        if ch.isAlphaAscii: inc letters
    # Addresses are not intent. A token that is mostly digits and
    # punctuation (line ranges, versions, pids: `40,140p`, `2.2.10`)
    # normalizes to `##,###p`-shaped filler, and filler made four
    # *different* sed ranges over one file read as one near-duplicate
    # cluster (20260921 stefani session). Tokens need real words.
    if letters < 3: continue
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
  ## call). A leading `cd <dir> &&` or `ssh [user@]host` prefix is stripped
  ## from each value so a persistent working directory or connection target
  ## cannot masquerade as the theme.
  ## Digits are normalized away so counters do not mask similarity, and
  ## tokens that carry almost no letters (line ranges, versions, pids)
  ## are dropped outright as addresses rather than intent; tokens shorter
  ## than 6 chars are dropped because short tokens are usually flags,
  ## paths' common words or shell keywords.
  try:
    collectValues(parseJson(argsStr), result)
  except CatchableError:
    var s = argsStr
    tokenify(s, result)

proc streakRingStuck(ring: seq[HashSet[string]]): bool =
  ## True when the ring is mostly the same call, in either of two shapes:
  ## ring-wide overlap (average pairwise token Jaccard >=
  ## `FlailStreakJaccard`, the emission-stuck loop where every call is a
  ## cosmetic variant of the last) or a tight cluster (`FlailStreakCluster`
  ## calls each >= `FlailStreakNearDup` similar to a common member, the doom
  ## loop that hammers one near-identical probe amid other variation).
  ##
  ## Sets with fewer than two distinctive tokens never count as similar:
  ## one shared token is the *subject* of a probe (the file being read)
  ## and says nothing about intent, yet two such sets compare at Jaccard
  ## 1.0. Counting them made a healthy file-inspection run (tail, sed,
  ## wc over one transcript, 20260921 stefani session) read as a tight
  ## near-duplicate cluster. Sparse pairs contribute 0 to the average
  ## and never form near-duplicates; a true repeat of a sparse call is
  ## still caught by the fingerprint signals, which don't need tokens.
  if ring.len < 2: return false
  var total = 0.0
  var pairs = 0
  var cluster = 1
  for i in 0 ..< ring.len:
    var near = 0
    for j in 0 ..< ring.len:
      if j == i: continue
      let sparse = ring[i].len < 2 or ring[j].len < 2
      let u = (ring[i] + ring[j]).len
      let jac = if sparse or u == 0: 0.0
                else: (ring[i] * ring[j]).len.float / u.float
      if jac >= FlailStreakNearDup: inc near
      if j > i:
        total += jac
        inc pairs
    if near + 1 > cluster: cluster = near + 1
  total / pairs.float >= FlailStreakJaccard or cluster >= FlailStreakCluster

proc ringConsensus(ring: seq[HashSet[string]]): HashSet[string] =
  ## Tokens carried by at least half the ring members: the subject the
  ## current streak is about. Half rather than all so one deviation inside
  ## a doom loop cannot erase the theme the ring is judged on, and
  ## narration tokens (prose `#` comments baked into commands) cannot
  ## extend the subject: a comment mentioning "version" on a `git
  ## describe` call does not make that call about the pytest ring it
  ## interrupted (20260930 astropy session).
  var counts: CountTable[string]
  for s in ring:
    for t in s: counts.inc(t)
  for t, n in counts:
    if 2 * n >= ring.len: result.incl t

proc countInWindow(det: FlailDetector, fp: string): int =
  for w in det.window:
    if w == fp: inc result

proc normalizeOutLine(line: string): string =
  ## One output line reduced for the staleness memory: whitespace collapsed,
  ## digits normalized, so counters, timings, pids and progress lines that
  ## differ only in numbers compare equal (a doom loop re-running one command
  ## reads stale even when its output carries fresh numbers).
  for ch in line.strip():
    if ch.isDigit: result.add '#'
    elif ch in Whitespace:
      if result.len == 0 or result[^1] != ' ': result.add ' '
    else:
      result.add ch

proc noteResult*(det: var FlailDetector, name, argsStr: string, madeChange: bool,
                 output = "") =
  ## Record whether the just-executed call actually changed anything. Called
  ## after execution with the tool's own verdict (exit code 0 vs failure)
  ## and its full output. Read-only tools pass madeChange=true so they never
  ## arm the no-progress signal. The per-fingerprint record powers the
  ## spaced-repeat signal: a call that failed before and keeps coming
  ## back inside the window is a stuck cycle even when other calls
  ## interleave. The output feeds the streak signal's staleness arm:
  ## consecutive results that add no new line are a run going nowhere.
  det.lastNoProgress = isMutating(name) and not madeChange
  let fp = fingerprint(name, argsStr)
  let isRepeat = fp in det.progress  # sampled before recording this sighting
  det.progress[fp] = madeChange

  # Staleness memory for the streak signal. A NOVEL call is fresh by
  # definition: it asks a question this run has not asked (a new window,
  # a new file, a new flag) and whatever comes back - matches, a repeated
  # line shape from another window, or nothing at all - is new information
  # about that question. Only a REPEATED call can re-deliver: same
  # question, same answer (20261007T100839 mistral session, second
  # incident: a fixed grep walked over successive windows armed the
  # stale streak through no-match windows (empty output) and windows
  # whose whole yield was a header shape an earlier window had already
  # shown; every call probed a new window). A repeat is fresh only when
  # its output adds a line this run has not delivered before.
  var fresh = not isRepeat
  for line in output.splitLines():
    let n = normalizeOutLine(line)
    if n.len == 0: continue
    if n notin det.seenLines:
      fresh = true
      det.seenLines.incl n
  if det.seenLines.len > FlailSeenLinesMax:
    det.seenLines.clear()
  if fresh:
    det.staleStreak = 0
  else:
    inc det.staleStreak

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
  # tool empties the ring; so does a subject change: a call sharing no
  # distinctive token with the ring's consensus is genuinely different
  # work, not a cosmetic variant of the ring's theme, and the ring
  # restarts empty (20260930 astropy session: pytest retries cycling
  # capture tails interleaved with version-file reads read as one
  # near-duplicate cluster because the varying tails fall under the token
  # minimum). Restarting, not disarming: the ring refills from the next
  # same-theme call, so an uninterrupted doom loop still fires, only
  # delayed while genuinely different work keeps interrupting it. Calls
  # with no distinctive tokens at all are inert: they neither fill nor
  # purge, so a doom loop sprinkling `ls` between probes cannot dodge the
  # signal that way. The ring only starts filling at FlailStreakArm calls
  # into the run, so a healthy burst of same-tool iteration (compile,
  # read, tweak, test) shorter than that never arms the signal at all.
  let toks = distinctiveTokens(argsStr)
  if det.streakName != name:
    det.streakName = name
    det.streakLen = 0
    det.streakTokens = @[]
    det.staleStreak = 0
    det.seenLines.clear()
  inc det.streakLen
  if det.streakLen >= FlailStreakArm:
    if toks.len > 0:
      if det.streakTokens.len > 0 and
          (ringConsensus(det.streakTokens) * toks).len == 0:
        det.streakTokens = @[]
      else:
        det.streakTokens.add toks
        if det.streakTokens.len > FlailStreakMin:
          det.streakTokens.delete 0
  # The staleness arm: token shape alone cannot tell a scan from a loop,
  # because a fixed query walked over successive windows of one subject
  # tokenizes every call identically. Results can: a scan delivers a new
  # window's lines every call, a loop re-delivers what the model has
  # already seen. Only a run whose last FlailStreakStale results added no
  # new output line may flag (20261007T100839 mistral session).
  let stuckStreak = det.streakTokens.len == FlailStreakMin and
    det.staleStreak >= FlailStreakStale and
    streakRingStuck(det.streakTokens)

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
  # 4. Stuck streak: the last FlailStreakMin calls were all to the same
  #    tool and are mostly the same call (ring-wide overlap or a tight
  #    near-duplicate cluster, see streakRingStuck), the same-tool run
  #    is at least FlailStreakArm long, and the last FlailStreakStale
  #    results added no new output line. Catches emission-stuck loops
  #    whose calls are cosmetic variants of each other; the arm gate
  #    keeps short healthy bursts of same-command-prefix iteration out,
  #    and the staleness arm keeps systematic scans out - one fixed query
  #    walked over successive windows of a file tokenizes every call
  #    identically but delivers fresh lines each time, which is progress,
  #    not a loop.
  let knownFailing = not det.progress.getOrDefault(fp, true)
  let isLoop = consecutive or (det.lastNoProgress and seen >= 1) or
    (knownFailing and seen >= FlailSpacedThreshold - 1) or stuckStreak
  if not isLoop:
    # Genuinely new or harmless: a clearly novel call resets the ladder -
    # unless a flag already fired in this batch, where the novel call was
    # emitted before the model could have seen any note and the ladder
    # must stay frozen until the next batch.
    if seen == 0 and not det.flaggedInBatch:
      det.escalations = 0
    return fvOk

  if det.flaggedInBatch:
    # A loop already fired in this model batch: the model emitted several
    # tool calls in one response (mistral emits up to a dozen) and has not
    # seen any note yet. The recovery ladder is one rung per response -
    # three ESCALATEs and an ABORT inside a single batch would sentence the
    # whole batch before the first nudge could land (20261007T100839
    # mistral session, second incident: calls #266-277 burned every rung
    # in one response). Reuse the current rung; the caller resets the flag
    # when the next batch starts.
    return fvEscalate

  # Flagged as a loop.
  det.flaggedInBatch = true
  if det.escalations < FlailMaxEscalations:
    inc det.escalations
    return fvEscalate
  fvAbort

proc flailEscalationMessage*(step: int): string =
  ## The tool-role note prepended to the repeated call's result. The call
  ## still executes, so the model gets both the warning and the real
  ## output and can judge its own response.
  ## Three graduated recovery attempts before the abort: step 1 names the
  ## loop and demands a strategy change; step 2 forces the only recovery
  ## known to work on GLM 5.x emission-stuck loops (reply in prose first,
  ## then a structurally different call, per zai-org/GLM-5#116); step 3 is
  ## the final warning. Deliberately short: this is the only token cost of
  ## the whole mechanism.
  ##
  ## No fake role prefix ("SYSTEM:") on the wire: the tool-result slot is
  ## already where every provider expects harness-authored text, and no API
  ## defines an in-content role label. The same text is what the user sees
  ## under the bold `»` marker, so it stays plain imperative prose.
  ##
  ## Steps 1-2 never invite the model to stop and ask the user: these
  ## messages persist in context for the rest of the session, and GLM
  ## generalizes "tell the user what is blocking you" into a habit of
  ## checking in instead of acting (field reports, Sep 2026). The
  ## user-handoff instruction lives only in the step-3 final warning.
  if step == 1:
    "Loop detected: these tool calls are not making progress. Change " &
    "strategy now: a different input, a different tool, or a smaller step."
  elif step == 2:
    "You repeated the same call after a warning; the next one would come " &
    "out identical. Do not repeat it. Reply first in plain prose, no tool " &
    "call: one sentence stating the hypothesis your next attempt will " &
    "test. If you continue, make a structurally different call: different " &
    "arguments, flags, or tool."
  else:
    "Final warning: one more repeated call and this turn is aborted. Stop " &
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
  tabtitle.settleTabTitle(false)
  commitTurnEndNotice(errLnS(InterruptedByUserMsg))
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

proc runBashWithViewport*(act: Action; cache: ReadCache; stub: JsonNode;
                          idx: int; streamedOutputShown: ptr bool):
    tuple[output: string, code: int, diff: string] =
  ## Also the engine behind `:! CMD`: the live bash viewport (banner,
  ## streamed lines, bar-tick clock) is the same one a model-run bash
  ## call paints, and the caller's transcript commit folds it into one
  ## scrollback item afterwards.
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
      # Sandbox ask gate: a failed command that smells like an EACCES
      # from the sandbox, whose denied target is covered by an `ask`
      # rule (not a hard deny), can be redeemed by the user once. The
      # question rides the tool viewport; the answer is a single key
      # diverted from the input thread (fatprompt requestAskKey). On
      # f/d the ask rule's root (or its parent directory) is appended
      # to the active policy file as `allow` and the command is
      # retried once; on n, an undecided key, or a timeout the denial
      # stands and the result goes back to the model unretried.
      block askGate:
        if result.code == 0: break askGate
        if not sandboxEnabled or not sandbox.active: break askGate
        if "Permission denied" notin result.output and
            "Operation not permitted" notin result.output:
          break askGate
        if not askGateAvailable(): break askGate
        let deniedPath = sandbox.deniedAskPath(act.body, result.output)
        if deniedPath.len == 0: break askGate
        # Narrow offer = the ask rule root (a file grant under an ask
        # DIRECTORY cannot pierce the Linux mount mask, so the root is
        # the narrowest grant that takes effect); broad offer = the
        # root's parent directory, one level up.
        let rootPath = sandbox.askRuleRoot(deniedPath)
        if rootPath.len == 0: break askGate
        let broadPath = parentDir(rootPath)
        view.addLine("sandbox ask: " & sandbox.askPathDisplay(deniedPath) &
          " is ask-protected.  [f] " & sandbox.askPathDisplay(rootPath) &
          "  [d] " & sandbox.askPathDisplay(broadPath) &
          "  [n]o  (" & $(askTimeoutMs() div 1000) & "s)")
        renderView()
        let key = requestAskKey()
        var marker = ""
          # The model-visible record of the decision, appended to the
          # tool output after any retry (each side sees what was decided
          # and whether a retry happened).
        if key == 'f' or key == 'd':
          let target = if key == 'd': broadPath else: rootPath
          if sandbox.grantAskAllow(target):
            view.addLine("· allowed " & sandbox.askPathDisplay(target) &
              " - retrying")
            renderView()
            result = runActionStreaming(act, cache, onLine)
            marker = "user allowed " & sandbox.askPathDisplay(target) &
              "; command retried"
          else:
            view.addLine("· policy update failed; not retried")
            renderView()
            marker = "policy update failed; not retried"
        else:
          let why =
            if key == '\0': "no answer before timeout"
            else: "declined by user"
          view.addLine("· " & why & "; not retried")
          renderView()
          marker = why & "; not retried"
        if result.output.len > 0 and not result.output.endsWith("\n"):
          result.output.add "\n"
        result.output.add "[sandbox ask: " & marker & "]"
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

proc cutVisibleContent(content: string): string =
  ## What of an assistant reply would actually paint: complete marker lines
  ## stripped plus a truncated trailing marker cut (a stream that ends
  ## mid-`[checkpoint` held that tail back, so every end-of-turn commit,
  ## emptiness check, notification, and reply-text extraction must treat it
  ## as bookkeeping, not prose).
  cutPartialTrailingMarker(stripCheckpointMarkers(content))

proc commitAssistantItem(content: string; restoreEditor = true;
                         attachReceipt = true) =
  # Emptiness is judged on the visible content, not the raw string: a
  # reply whose only text is checkpoint bookkeeping paints nothing, so it
  # must take the same empty-reply fallback as a bare empty reply. The
  # truncated trailing marker counts as bookkeeping too (the stream held
  # it back, so the commit must not paint it).
  let afterCommit =
    if attachReceipt: clearSubmittedReceiptState
    else: clearSubmittedTickerState
  if cutVisibleContent(content).strip.len == 0:
    let receipt = if attachReceipt: pendingReceiptBytes() else: ""
    var bytes = emptyAssistantBytes(attachReceipt, receipt)
    bytes.finishTranscriptItem()
    commitTranscriptBytes(bytes, restoreEditor, afterCommit)
    return
  var bytes = renderAssistantContentBytes(cutVisibleContent(content))
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

proc turnFinishedBody*(messages: JsonNode): string =
  ## The desktop-notification body for a finished turn. Same visibility
  ## rules as the transcript: checkpoint markers are harness bookkeeping,
  ## and an empty-reply marker renders as nothing, so neither belongs in
  ## a notification. "" means "send no notification".
  if messages.len == 0: return ""
  let last = messages[^1]
  if last.kind != JObject or last{"role"}.getStr != "assistant": return ""
  let body = last{"content"}.getStr
  if isEmptyReplyMsg(body.strip): return ""
  cutPartialTrailingMarker(stripCheckpointMarkers(body))

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

var pluginTurnCount = 0

func pluginToolBanner*(name, argsJson: string): string =
  ## Banner text for a plugin-registered tool: the tool name plus a
  ## squeezed one-line preview of its JSON arguments.
  var flat = argsJson.replace("{", "").replace("}", "")
    .replace("\"", "").replace("\n", " ")
  var outp: string
  var prevSpace = false
  for ch in flat:
    if ch in {' ', '\t', '\n'}:
      if not prevSpace and outp.len > 0: outp.add ' '
      prevSpace = true
    else:
      outp.add ch
      prevSpace = false
  if outp.len > 48: outp = outp[0 ..< 48] & "…"
  name & (if outp.len > 0: " " & outp else: "")

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
  inc pluginTurnCount
  pluginOnTurnStart(pluginTurnCount, session.lastPromptTokens)
  var turnT0 = epochTime()
  defer:
    pluginOnTurnEnd(pluginTurnCount, session.lastPromptTokens,
      session.usage.completionTokens, session.usage.reasoningTokens,
      ((epochTime() - turnT0) * 1000).int, isInterrupted(),
      session.savePath)
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
    loopSteers = 0                 # reasoning-loop cut re-prompts this turn
    emptyRetries = 0               # bare empty-reply resends after smart-handling
    flailDet: FlailDetector        # identical-consecutive-tool-call guard
    nextCheckpoint = 0             # id of the marker on the next assistant message
    summarizedOn400 = false       # opaque-400 recovery fired this turn (one-shot)
    rolloverDue = false           # a context collapse happened; the mode's
                                  # handoff waits for tool pairing to settle
  # A context collapse is a context clear for a mode with a rollover
  # duty: the fresh context re-anchors at the mode file. Receipted like
  # every harness act. Deferred past the tool loop when the collapsing
  # reply carries unanswered tool_calls (a user message between an
  # assistant's calls and their results orphans the pairing).
  template injectRollover() =
    let m = activeMode(session.cwd)
    if not noMode(m) and m.rolloverNote != nil:
      let body = readModeText(m, session.cwd)
      let note = m.rolloverNote(body)
      messages.add note
      let counts = m.taskCounts(body)
      commitTranscriptBytes(
        receiptBytes("auto: " & m.name & " rollover - plan at " &
          m.fileName &
          (if counts.len > 0: " (" & counts & ")" else: "")), true)
      commitTranscriptBytes(
        formatItem(agentPromptItem(note{"content"}.getStr)), true)
      saveSession(session, messages)
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
    MaxLoopSteers = 2
    EmptyReplySteerMsg = "Your last reply came back empty. Answer now, " &
                        "or continue with a tool call."
    ReasoningLoopSteerMsg = "Your last reply was cut because your reasoning " &
                        "kept repeating itself. Answer now, or continue with " &
                        "a tool call."
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
      # Opaque 400 recovery (issue #48): a gateway can reject a request
      # for being byte-large while the token count is still far under the
      # context window, so the proactive summarize never fires and the
      # same history would 400 again on every resend. Zen's reply is a bare
      # `inference_failed` with no overflow wording, so there is nothing
      # to classify; the only signal is 400 + a history big enough to
      # shrink. Collapse it once and retry; a 400 that survives a fresh
      # summarize is a real request defect, so the guard is one-shot per
      # turn.
      if e of HttpError and cast[ref HttpError](e).code == 400 and
          not summarizedOn400 and messages.len >= SummarizeKeepRecent + 4:
        summarizedOn400 = true
        # Prefer a real recap; if the summarizer meta-call fails too (its
        # payload is clipped to fit, but an even tighter envelope or a
        # broken route kills it anyway), drop the middle locally rather
        # than leave the session permanently dead.
        let summarized = summarizeHistory(messages, wire)
        let collapsed =
          if summarized > 0: summarized
          else: applySummary(messages, OverflowFallbackSummary)
        if collapsed > 0:
          saveSession(session, messages)
          commitTranscriptBytes(
            hintLnS("· request rejected as too large; collapsed " &
              $collapsed & " message" &
              (if collapsed == 1: "" else: "s") &
              (if summarized > 0: " into a recap" else: " without a recap") &
              ", retrying"), true)
          # The failed call's reply was never appended, so pairing is
          # settled: the handoff rides the retry directly.
          injectRollover()
          continue
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
      commitTurnEndNotice(errLnS(e.msg))
      endTurnAfterTranscriptAppend(failed = true)
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
    # Emptiness is judged on what would paint (markers stripped, truncated
    # marker tail cut): a kimi marker-echo loop that exhausts the output
    # budget mid-tag is an empty reply to the user (field shape: hundreds
    # of `[checkpoint N]` lines, stream cut at a bare `[`), so it must take
    # the empty-reply recovery, not commit as a one-character reply.
    let replyIsEmpty = cutVisibleContent(content).strip.len == 0
    if replyIsEmpty and toolCalls.len == 0:
      # Empty assistant turn. Try the targeted recoveries first (reasoning
      # loop steer, escalate the budget on "length", steer on
      # "stop"/unknown), then fall back to a bare resend. A hostile or
      # broken provider can't pin the turn: each path has its own ceiling,
      # and the final resend loop is bounded by MaxEmptyRetries. This is a
      # conversational concern, kept out of callModel's transport retry
      # block.
      if finishReason == ReasoningLoopFinish and loopSteers < MaxLoopSteers:
        # The stream guard cut the model out of a thinking repetition loop
        # (see api.nim). Budget escalation is the wrong medicine - the
        # model is stuck, not starved - and a bare resend would just re-cut,
        # so steer with a note that names the failure, then give up cleanly
        # once the steers are spent (below).
        inc loopSteers
        messages.add msg
        messages.add %*{"role": "user", "content": ReasoningLoopSteerMsg,
                        "agentSent": true}
        saveSession(session, messages)
        commitTranscriptBytes(
          formatItem(agentPromptItem(ReasoningLoopSteerMsg)), true)
        incEmptyRetryLevel()
        if emptyReplyWait():
          saveSession(session, messages)
          onTurnInterrupted()
          turnEnded = true
          return true
        debugOut &"runTurns: reasoning-loop steer-retry {loopSteers}/{MaxLoopSteers}"
        continue
      if finishReason == ReasoningLoopFinish:
        # Still looping after MaxLoopSteers re-prompts: the model cannot
        # leave the loop on its own. Commit the empty turn and end with a
        # notice instead of feeding the bare-resend loop a cut every time.
        messages.add msg
        saveSession(session, messages)
        commitTurnEndNotice(
          errLnS("reasoning loop - giving up after " & $MaxLoopSteers &
            " re-prompts"))
        endTurnAfterTranscriptAppend(failed = true)
        turnEnded = true
        break
      let budgetStarved =
        finishReason == "length" or
        usage.completionTokens >= knownGoodGeneration(wire).maxTokens or
        usage.reasoningTokens > 0
      if budgetStarved and lengthEscalations < MaxLengthEscalations:
        inc lengthEscalations
        # A forced-thinking model that spent the whole budget on reasoning
        # and returned nothing will usually do it again at 2x the budget:
        # the thinking scales with effort, not with headroom. Demote the
        # effort first (one rung down the model's own ladder; verified
        # against Z.ai: effort high starves 400-token budgets that effort
        # low finishes in 1k) and only raise the budget once effort is
        # already at the floor or the family has no graded knob. The
        # ladder must be the model's own supported set, stepped down one
        # entry at a time: a hardcoded high -> low sent Mistral (none/high
        # only) a value its API rejects with 400, turning the recovery
        # into a dead turn. Budget bumps are also clamped by the model's
        # real output cap (131k on GLM-5.3), so a starved turn at the cap
        # would otherwise just re-derive the same override and burn
        # identical retries.
        var demoted = false
        block demote:
          let ladder = defaultReasoningsFor(providerOf(wire), wire.model,
            wire.family)
          let idx = ladder.find(wire.reasoning)
          if idx <= 0: break demote
          wire.reasoning = ladder[idx - 1]
          demoted = true
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
        # a short steering user message that names the observed problem and
        # leaves the tool path open (an empty reply is not always a finished
        # model demanding a final answer), then retry with the nudged history.
        messages.add msg
        messages.add %*{"role": "user", "content": EmptyReplySteerMsg,
                        "agentSent": true}
        saveSession(session, messages)
        commitTranscriptBytes(
          formatItem(agentPromptItem(EmptyReplySteerMsg)), true)
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
      commitTurnEndNotice(
        errLnS("empty reply - giving up after " & $MaxEmptyRetries &
          " retries"))
      endTurnAfterTranscriptAppend(failed = true)
      turnEnded = true
      break
    if dmailEnabled:
      tagCheckpoint(msg, nextCheckpoint)
      inc nextCheckpoint
    messages.add msg
    saveSession(session, messages)
    let window = contextWindowFor(p)
    var action = decideContextAction(usage.promptTokens, window, messages.len)
    # Zen byte-envelope guard: the token threshold above cannot predict a
    # request-size rejection (bytes and tokens are different axes), so for
    # the gateways known to enforce one, the exact body size just sent
    # drives the same collapse proactively — before any route can 400 it.
    var byteGuard = false
    if action == caNone and providerOf(p) in ["opencode", "opencodego"] and
        lastRequestBodyBytes >= SummarizeByteGuardBytes:
      action = caSummarize
      byteGuard = true
    # Tesseracted message-count guard: the gateway (hosted Kolibri-1)
    # rejects a request with more than 80 `messages` entries with an
    # opaque 400, far under the token window, so like the byte guard
    # this fires the same collapse on the axis the route actually
    # validates. Self-hosted kolibri carries no such cap and stays
    # unguarded. See MaxMessagesTesseracted for the cap and headroom.
    var msgGuard = false
    var msgGuardCount = 0
    if action == caNone and providerOf(p) == "tesseracted" and
        messages.len >= MaxMessagesTesseracted:
      action = caSummarize
      msgGuard = true
      msgGuardCount = messages.len
    case action
    of caSummarize:
      let summarized = summarizeHistory(messages, p)
      if summarized > 0:
        commitTranscriptBytes(
          hintLnS(&"· summarized {summarized} message" &
            (if summarized == 1: "" else: "s") &
            (if byteGuard:
               &" (request body {humanBytes(lastRequestBodyBytes)}; gateway byte guard)"
             elif msgGuard:
               &" ({msgGuardCount} messages; tesseracted message-count guard)"
             else:
               &" (context at {humanTokens(usage.promptTokens)}/{humanTokens(window)} tokens)")), true)
        saveSession(session, messages)
        # This reply's tool_calls may still be unanswered: defer the
        # handoff to the point just after their results land, or inject
        # now when there are none.
        if toolCalls.len > 0: rolloverDue = true
        else: injectRollover()
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
        if not streamedLive and
           not (toolCalls.len > 0 and
                cutVisibleContent(content).strip.len == 0):
          # The second guard keeps live in sync with replay: an empty or
          # marker-only text paired with tool calls renders nothing (the
          # grey empty-reply fallback is for the final tool-less reply),
          # so it must not commit a fallback row the replay suppresses.
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
      var flailAbortNote = ""  # the abort note sent to the model
      # One escalation rung per model response: the model cannot have
      # reacted to a note it has not seen yet, so flags later in this same
      # batch reuse the current rung instead of advancing the ladder.
      flailDet.flaggedInBatch = false
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
        var argsStr =
          if fn != nil and fn.kind == JObject: fn{"arguments"}.getStr("") else: ""
        # Plugin pre-gate BEFORE the flail fingerprint: a rewrite is
        # fingerprinted in its rewritten form (no free flail evasion), a
        # veto skips execution with the pairing intact, a takeover
        # supplies the whole result, a wrap sandwiches the original run.
        let pre = pluginOnToolPre(name, argsStr, id, p.family)
        argsStr = pre.args
        if pre.kind == tpkVeto:
          session.toolLog.add ToolRecord(
            banner: "! " & name & " (vetoed)",
            output: pre.note, code: -1, kind: akError)
          messages.add %*{"role": "tool", "tool_call_id": id,
                          "content": pre.note, "agentSent": true}
          commitTranscriptBytes(
            formatItem(agentPromptItem(pre.note)), true)
          continue
        # Loop verdicts never skip execution: the result is real data for
        # the model to judge, and the scrollback shows exactly what was
        # tried. The note rides on top of the tool result content, shows
        # as a `»` agent-prompt item, and `flailNote` on the tool message
        # lets the resumed replay render both the tool banner and the
        # note instead of burying the note in the output.
        var flailNote = ""
        case flailDet.observeCall(name, argsStr)
        of fvOk: discard
        of fvEscalate:
          flailNote = flailEscalationMessage(flailDet.escalations)
          debugOut &"flail: repeat of {name}, escalation " &
            "{flailDet.escalations}/{FlailMaxEscalations}; executing anyway"
        of fvAbort:
          # Still looping after all recovery attempts. This call executes
          # too; once its result is paired the turn stops and control
          # returns to the user. The abort note's live rendering is the
          # turn-end notice, not a per-call `»` item.
          debugOut &"flail: repeat of {name} after " &
            "{FlailMaxEscalations} escalations; aborting turn"
          flailAbortNote =
            "Turn aborted: the same tool call was repeated after three " &
            "warnings; you did not change course."
          flailNote = flailAbortNote
          flailAbort = true
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
        let act =
          if pluginsHaveTool(name):
            Action(kind: akPlugin, path: name, body: pluginToolBanner(name, argsStr))
          else:
            toolCallToAction(p.family, name, args)
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
              if pre.kind == tpkTakeover:
                (pre.note, pre.code, "")
              elif act.kind == akPlugin:
                let pr = pluginToolExec(name, argsStr)
                (pr.output, pr.code, "")
              elif act.kind == akBash:
                runBashWithViewport(
                  act, session.readCache, toolStub, idx, addr streamedOutputShown)
              else:
                if toolStub != nil and toolStub.kind == JObject:
                  stubToolCallResult(toolStub)
                else:
                  runAction(act, session.readCache, p.vision,
                            sessionImageDir(session.savePath))
          except CatchableError as e:
            r = "ERROR: tool execution failed: " & e.msg
            code = -1
            diff = ""
        if pre.kind == tpkWrap:
          r = pre.note & "\n" & r &
              (if pre.post.len > 0: "\n" & pre.post else: "")
        if act.kind == akPlan and code == 0:
          session.plan = act.plan
        let toolElapsed = epochTime() - toolT0
        debugOut &"tool done: {act.kind} code={code} elapsed={toolElapsed:.2f}"
        pluginOnToolResult(name, argsStr, r, code,
                           (toolElapsed * 1000).int, diff)

        # Feed the no-progress signal: a failed call (code != 0) is
        # recorded per fingerprint, so a spaced re-try of that exact call
        # counts toward a loop; an immediately retried failed mutation
        # counts heaviest. Successful calls never arm the signal, so
        # legitimate polling is untouched. Uses the tool's own exit
        # verdict, so it costs nothing extra at runtime.
        flailDet.noteResult(name, argsStr, madeChange = code == 0, output = r)

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
        if flailNote.len > 0 and not flailAbort:
          commitTranscriptBytes(formatItem(agentPromptItem(flailNote)), true)
        var toolMsg = %*{"role": "tool", "tool_call_id": id, "content": r}
        if flailNote.len > 0:
          toolMsg["content"] = %(flailNote & "\n\n" & r)
          toolMsg["flailNote"] = %flailNote
        messages.add toolMsg
        if flailAbort:
          # Pair any remaining tool_calls in this batch too: the
          # assistant message carries them all and an unpaired id breaks
          # strict providers on the next request.
          for j in i + 1 ..< toolCalls.len:
            messages.add %*{"role": "tool",
              "tool_call_id": toolCalls[j]{"id"}.getStr,
              "content": flailAbortNote, "agentSent": true}
          break
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
          rebuilt.add %*{"role": "system", "content": DefaultSystemPrompt}
          rebuilt.add %*{"role": "user", "content": freshMsg}
          messages.elems.setLen 0
          for m in rebuilt: messages.add m
          # Fresh promptState for the rebuilt conversation: resolve the new
          # system prompt and stamp identity/skills so the persisted header
          # describes the new message, not the old one.
          session.promptState = PromptState()
          refreshSystemPrompt(messages, p, session.promptState)
          session.toolLog.setLen 0
          session.usage = Usage()
          session.lastPromptTokens = 0
          session.readCache = nil
          session.plan.setLen 0
          flailDet = FlailDetector()  # fresh conversation, fresh ladder
          emitFatPromptEvent clearPendingHintEvent()
          emitFatPromptEvent clearBarEvent()
          # The wiped conversation's numbers are meaningless to the rebuilt
          # one: drop the resting label so a later usage-less turn end does
          # not resurrect a bar with stale context numbers.
          emitFatPromptEvent setRestingLabelEvent("")
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
        commitTurnEndNotice(formatItem(agentPromptItem(flailAbortNote)))
        endTurnAfterTranscriptAppend(failed = true)
        turnEnded = true
        return false
      # Image reads this batch ride a follow-up user message: image
      # blocks in tool results are not portable across OpenAI-compat
      # providers, user-message blocks are. Capped at MaxImagesPerTurn so
      # a model that reads a gallery cannot attach it all in one turn.
      if session.readCache != nil and session.readCache.images.len > 0:
        var imgs = session.readCache.images
        session.readCache.images.setLen 0
        var extraNote = ""
        if imgs.len > MaxImagesPerTurn:
          let rest = imgs[MaxImagesPerTurn ..^ 1].mapIt(it.name)
          extraNote = &"\n[{rest.len} image read(s) not attached: " &
            rest.join(", ") & "]"
          imgs.setLen MaxImagesPerTurn
        let names = imgs.mapIt(it.name).join(", ")
        messages.add imageUserMessage(
          &"attached: {names} (image read){extraNote}", imgs)
      saveSession(session, messages)
      if rolloverDue:
        # The deferred handoff: tool pairing has settled, the fresh
        # context re-anchors before the next model call.
        rolloverDue = false
        injectRollover()
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
    # Streamed prose is already in scrollback; committing it again would
    # duplicate it, so the commit only tops the stream up with the receipt.
    # A reply whose visible text is empty (marker-only, kimi dmail tag)
    # painted nothing at all, so it must still go through the assistant-item
    # commit: streaming used to skip it, leaving a bare receipt floating in
    # scrollback and no empty-reply notice.
    let displayEmpty = cutVisibleContent(content).strip.len == 0
    discard stopBarTick()
    stopSpinner(clearLiveFooter = false)
    # The editor keeps whatever draft the user is typing through the final
    # commit even when the queue will drain next: the queued items live in
    # the event queue now, not in the editor, so there is nothing to tear
    # down here. The drain's own transition consumes the chrome.
    if streamedLive and not displayEmpty:
      commitPendingReceiptAfterStream(restoreEditor = true)
    else:
      if not queuedBeforeFinalRender and not streamedLive:
        stopTurnInputForFinalRender()
      commitAssistantItem(
        content,
        restoreEditor = true)
    if queuedBeforeFinalRender or hasQueuedAutosend():
      stopTurnInputForFinalRender()
      turnEnded = true
      return false
    # Harness-mode end-call boundary — the only hook. The turn's final
    # model call completed, the reply is committed, nothing is queued,
    # and the harness is about to hand the prompt back. The armed mode's
    # trigger file in the project root keeps the session on its goal: a
    # fresh-context side-call verifier (same model, own message list, no
    # tools) judges the mode's text against harness-built evidence from
    # this turn plus the check-time working-tree diff. FEEDBACK sends the
    # agent back in with the verifier's words; SATISFIED retires the file
    # and idles normally. No session-start check, no per-tool-call
    # checks. Interrupt is the pause lever: it skips the check and ends
    # the turn; on resume the file is still there, so the mode is still
    # on.
    # The mode file is a project-root artifact: activation keys off the
    # session's project dir, not the process cwd. Embedders (library,
    # ACP) run sessions against their own cwd while the process may sit
    # anywhere — e.g. a test harness parked in a repo that happens to
    # carry a goal.md must not arm goal mode for every session it runs,
    # and the end-of-turn verifier call it would fire is a real API call.
    let mode = activeMode(session.cwd)
    if not noMode(mode):
      if isInterrupted():
        onTurnInterrupted()
        turnEnded = true
        return true
      if not session.goalNotified:
        session.goalNotified = true
        commitTranscriptBytes(
          receiptBytes(mode.name & " mode: " & mode.fileName &
            " detected (interrupt to pause, " & mode.verb & "! to cancel)"),
          true)
        # A second mode's file on disk while one mode runs is a refused
        # arming: say so once, right under the detection receipt.
        let other = conflictingMode(mode, session.cwd)
        if not noMode(other):
          commitTranscriptBytes(
            receiptBytes(modeConflictLabel(mode, other)), true)
      # Verifier steps land in scrollback as they happen: same commit
      # path as the receipts around them, one dim indented tier below
      # the agent's items so the check can never read as agent work.
      goalStepHook = proc (step: GoalStep) =
        commitTranscriptBytes(goalStepBytes(step), true)
      defer: goalStepHook = nil
      let modeText = readModeText(mode, session.cwd)
      # Duty 1, structure guard: a plan that lost its format mid-run
      # gets a mechanical restore-continuation and no side call (there
      # is no task list to judge). The mode stays latched.
      let guard = mode.structureGuard(modeText)
      if guard.len > 0:
        session.modeSnapshot = modeText
        commitTranscriptBytes(
          receiptBytes(mode.name & " check: plan structure lost"), true)
        messages.add harnessNote(guard)
        saveSession(session, messages)
        commitTranscriptBytes(
          receiptBytes("auto: " & mode.name & " check - continuing toward " &
            mode.fileName), true)
        commitTranscriptBytes(formatItem(agentPromptItem(guard)), true)
        debugOut "runTurns: " & mode.name & " structure lost, continuing"
        continue
      let check = runGoalCheck(p, mode, modeText, buildGoalEvidence(messages),
                               session.modeSnapshot)
      # The side call ran the bar/spinner hooks again; its usage is not
      # this turn's and must not leak into the next receipt.
      emitFatPromptEvent clearPendingHintEvent()
      if isInterrupted():
        onTurnInterrupted()
        turnEnded = true
        return true
      # Duty 2, update discipline: work happened but the mode file is
      # byte-identical to its turn-start snapshot -> the mechanical
      # note. It rides with a verifier FEEDBACK or, when the check
      # could not produce one, sends the agent back on its own.
      let note = mode.updateNote(turnHadToolActions(messages),
                                 session.modeSnapshot, modeText)
      session.modeSnapshot = modeText
      template sendBack(content: string; why: string) =
        messages.add mode.feedbackMessage(modeText, content)
        saveSession(session, messages)
        commitTranscriptBytes(
          receiptBytes("auto: " & mode.name & " check - continuing toward " &
            mode.fileName), true)
        commitTranscriptBytes(formatItem(agentPromptItem(content)), true)
        debugOut "runTurns: " & why
      if not check.ok:
        # Verifier call failed (network, provider): note it in the
        # receipt, retry at the next boundary. The mode file is
        # untouched, so the mode is still on; the discipline note still
        # sends the agent back.
        debugOut mode.name & " check failed: " & check.err
        # First line only: an ApiError msg can span lines, a receipt is one.
        let why = check.err.strip.splitLines[0]
        commitTranscriptBytes(
          receiptBytes(
            (if why.len > 0: mode.name & " check unavailable (" & why & ")"
             else: mode.name & " check unavailable") & ", retrying next turn"),
          true)
        if note.len > 0:
          sendBack(note, mode.name & " update discipline (check unavailable)")
          continue
      elif check.verdict.kind == gvkSatisfied:
        if completeMode(mode, session.cwd):
          session.goalNotified = false
          session.modeSnapshot = ""
          commitTranscriptBytes(
            receiptBytes(mode.name & " confirmed (" & mode.fileName &
              " renamed to " & mode.confirmedName & ")"), true)
        else:
          commitTranscriptBytes(
            errLnS(mode.name & " satisfied but " & mode.fileName &
              " could not be renamed to " & mode.confirmedName), true)
      elif check.verdict.kind == gvkFeedback:
        commitTranscriptBytes(
          receiptBytes(mode.name & " check: feedback"), true)
        var fb = check.verdict.feedback
        if note.len > 0: fb.add "\n\nAlso: " & note
        sendBack(fb, mode.name & " check feedback, continuing")
        continue
      else:
        commitTranscriptBytes(
          receiptBytes(mode.name &
            " check returned no verdict, retrying next turn"),
          true)
        if note.len > 0:
          sendBack(note, mode.name & " update discipline (no verdict)")
          continue
    else:
      session.goalNotified = false
      session.modeSnapshot = ""
    if streamedLive:
      stopTurnInputForFinalRender()
    endTurnAfterTranscriptAppend()
    turnEnded = true
    break
  result = false

proc runTurnsInteractive*(p: Profile, messages: var JsonNode,
    session: var Session): bool =
  ## Returns true if the turn was interrupted by the user. See `runTurns`.
  # The catalog gates ad-hoc picks (`-m`, `:model`, `:provider` all check
  # `gateExperimental` themselves before anything is set). A profile that
  # is still the config's `[settings] current` - or a directory-sticky
  # current - is the user's explicit word and runs ungated; refusing it
  # would make a hand-edited config unusable without a flag.
  if not gateExperimental(p) and p.name != activeCurrent:
    explainExperimentalGate(p)
    # The controller already ran `emitUserSubmit`, which parks the input
    # thread (`inputIdleLinePending`) until the turn starts. A normal turn
    # unparks via `beginTurn`; this bail-out never reaches it, so unpark
    # here or the editor wedges until kill -9. Same idiom as the
    # `no provider configured` bail-out in the REPL loop.
    releaseIdleSubmittedInput()
    return false
  if privateMode and not privateAllowed(p):
    stdout.styledWriteLine fgMagenta, privateGateText(p), resetStyle
    emitTestFrameEvent()
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
