## High-level transcript items for append-only terminal history.
##
## Controllers construct these semantic items and append them through the
## fat-prompt runtime. Formatters in display/tool modules can still build item
## bodies, but this module owns item markers, trimming, and item separators.

import std/[json, strutils, tables]

import actions, display, fatprompt, goal, session, types, util, images
import engine as termengine

export isEmptyReplyMsg

type
  TranscriptKind* = enum
    tiUserPrompt,
    tiAgentPrompt,
    tiAssistant,
    tiTool

  TranscriptItem* = object
    kind*: TranscriptKind
    marker*: string
    body*: string
    attachSeparator*: bool

proc trimTranscriptTail*(bytes: var string) =
  while bytes.len > 0 and bytes[^1] in {'\r', '\n'}:
    bytes.setLen(bytes.len - 1)

proc normalizeLines(body: string): seq[string] =
  let text = body.strip(chars = {'\r', '\n'})
  if text.len == 0:
    return @[]
  text.replace("\r\n", "\n").replace("\r", "\n").splitLines

proc finishItem(bytes: var string; attachSeparator: bool) =
  ## Trim trailing whitespace before the write (append-only-safe). The
  ## inter-item separator is owned by `appendTranscript`; items carry no
  ## trailing separator. (`attachSeparator` is retained on the item type for
  ## construction-call compatibility but no longer appends anything.)
  bytes.trimTranscriptTail()

proc plainCommandBodyBytes*(body: string): string =
  ## Format captured command output as a flush-left transcript body: each
  ## line on its own row, no title marker, no indent, ANSI styling preserved.
  ## Command bodies already emit flush-left, so this is normalization only
  ## (collapse \r\n/\r to \r\n, trim the trailing separator owned by
  ## `appendTranscript`).
  for line in normalizeLines(body):
    result.add line & "\r\n"
  result.finishItem(true)

proc userPromptItem*(line: string): TranscriptItem =
  TranscriptItem(kind: tiUserPrompt, marker: "❯", body: line,
                 attachSeparator: false)

proc agentPromptItem*(line: string): TranscriptItem =
  TranscriptItem(kind: tiAgentPrompt, marker: "»", body: line,
                 attachSeparator: false)

proc goalPromptItem*(line: string): TranscriptItem =
  ## The goal kickoff: same harness-voice tier as a steer but a target
  ## marker, so the goal text reads as the session's aim, not another
  ## autosend.
  TranscriptItem(kind: tiAgentPrompt, marker: "◎", body: line,
                 attachSeparator: false)

proc assistantItem*(content: string): TranscriptItem =
  TranscriptItem(kind: tiAssistant, marker: "●", body: content,
                 attachSeparator: true)

proc toolItem*(act: Action; res: string; code, idx: int; diff = "";
               elapsedS = -1): TranscriptItem =
  TranscriptItem(kind: tiTool,
                 body: toolTranscriptBytes(act, res, code, idx, diff, elapsedS),
                 attachSeparator: true)

proc emptyAssistantBytes*(attachReceipt: bool; receipt = ""): string =
  ## The shared empty-reply rendering. Live (`commitAssistantItem`) and
  ## replay (`formatItem`) both render through this, and the saved-session
  ## marker text is the same constant (`EmptyReplyMsg`), so the three
  ## surfaces can't drift apart.
  result.add GreyFg & EmptyReplyMsg & Reset
  if attachReceipt and receipt.len > 0:
    result.add "\r\n"
    result.add receipt

proc formatItem*(item: TranscriptItem): string =
  case item.kind
  of tiUserPrompt:
    result = formatUserPromptItem(item.body)
  of tiAgentPrompt:
    result = formatAgentPromptItem(item.body, item.marker)
  of tiAssistant:
    if item.body.strip.len == 0:
      result = emptyAssistantBytes(false)
    else:
      result = renderAssistantContentBytes(item.body)
  of tiTool:
    result = item.body
  result.finishItem(item.attachSeparator)

proc attachReceipt*(bytes: var string; receipt: string; attachSeparator: bool) =
  ## Splice a token receipt row flush below an item body (a single `\r\n`
  ## joins them, no blank between). The inter-item separator after the whole
  ## item is owned by `appendTranscript`, so nothing trailing is appended here.
  if receipt.len == 0:
    return
  bytes.trimTranscriptTail()
  bytes.add "\r\n"
  bytes.add receipt

proc appendItem*(item: TranscriptItem; restoreEditor = true;
                 beforeRepaint: proc() = nil; reserveFooter = true;
                 receipt = "") =
  var bytes = formatItem(item)
  if receipt.len > 0:
    bytes.attachReceipt(receipt, item.attachSeparator)
  commitTranscriptBytes(
    bytes,
    restoreEditor,
    beforeRepaint,
    reserveFooter = reserveFooter)

proc replaySessionTail*(messages: JsonNode, toolLog: seq[ToolRecord],
                       window: int, family: string): Usage =
  ## Replay the whole conversation into scrollback so a resumed session drops
  ## the user back into the full prior context, reachable by scrolling up.
  ## The session file is already bounded by compaction to roughly one context
  ## window, so replaying it in full stays manageable. Renders through the
  ## same TranscriptItem formatters the live path uses (`formatItem`,
  ## `toolItem`, `attachReceipt`); usage is read from each assistant
  ## message's inline `usage` field (legacy sessions saved before the inline
  ## format simply skip the receipt). The last assistant's inline receipt is
  ## suppressed and its usage is returned instead: the caller paints the
  ## live token bar with it, so the resumed shape matches the post-`endTurn`
  ## typing-ready state.
  if messages == nil or messages.kind != JArray or messages.len == 0: return
  # Start at the first non-system message: the `case` below discards the
  # system message anyway, but skipping it keeps the leading separator clean.
  var start = 0
  while start < messages.len and messages[start]{"role"}.getStr == "system":
    inc start
  if start >= messages.len: return
  var lastAssistant = -1
  for i in countdown(messages.len - 1, start):
    if messages[i]{"role"}.getStr == "assistant":
      lastAssistant = i
      break
  # Every replayed item gets the same one-blank leading separator a live
  # commit writes (`writeTranscriptItem` always prepends "\r\n"): the first
  # item included, so a resumed screen shows the same hint/blank/echo shape
  # a fresh session does instead of starting flush under the "● resumed"
  # banner.
  # Flail-noted calls executed, so they replay as their tool banner PLUS
  # the `»` note item (`flailNote` field, keyed by tool_call_id).
  # Note-only pairings (an abort batch's unexecuted remainder,
  # `agentSent`) replay as the `»` item alone, never a tool banner. Both
  # kinds share the consecutive-duplicate collapse: an abort batch pairs
  # the same note onto every remaining call, exactly like the single live
  # commit.
  var agentNotes = initTable[string, string]()
  var flailNotes = initTable[string, string]()
  for m in messages:
    if m.kind != JObject or m{"role"}.getStr != "tool": continue
    if m{"agentSent"}.getBool(false):
      agentNotes[m{"tool_call_id"}.getStr] = m{"content"}.getStr("")
    let fn = m{"flailNote"}.getStr("")
    if fn.len > 0:
      flailNotes[m{"tool_call_id"}.getStr] = fn
  var lastAgentNote = ""
  var toolIdx = 0
  for i in start ..< messages.len:
    let m = messages[i]
    case m{"role"}.getStr
    of "user":
      let raw = m{"content"}
      # Image-bearing user messages: a user @attach echoes with the same
      # `[image attached]` marker the live path painted (array content has
      # no string to getStr); the harness-made follow-ups that ride image
      # reads and screenshots (`attached: ... (image read)` /
      # `(screenshot)`) rendered nothing live — their tool rows already
      # carry the `· read img` / `· shot` banners — so they stay invisible
      # here too. Replay/live parity is the contract.
      if raw != nil and raw.kind == JArray:
        let text = userTextBlocks(raw).strip
        if text.startsWith("attached: ") and
            ("(image read)" in text or "(screenshot)" in text):
          continue
        let c = stripPreamble(text).strip & " [image attached]"
        let bytes = formatItem(userPromptItem(c))
        stdout.write "\n"
        stdout.write bytes & "\n"
        termengine.noteCommittedRows(bytes)
        continue
      # The one-time computer-use activation note entered the conversation
      # silently live (the :computer response covered the terminal); replay
      # keeps it invisible for parity with the live path.
      if m{"content"}.getStr("").startsWith("[computer use on]"):
        continue
      let c = stripPreamble(m{"content"}.getStr("")).strip
      if c.len == 0: continue
      # A harness-autosent steer renders as the `»` agent-prompt item the
      # live path committed, never as a user `❯` echo; the goal kickoff
      # keeps its `◎` target marker instead.
      let item =
        if m{"agentSent"}.getBool(false):
          if c.startsWith(GoalKickoffPrefix): goalPromptItem(c)
          else: agentPromptItem(c)
        else: userPromptItem(c)
      # No length truncation: the live path echoes the full submitted line
      # (wrapped at terminal width by `formatUserPromptItem`), so the replay
      # must too.
      let bytes = formatItem(item)
      stdout.write "\n"
      stdout.write bytes & "\n"
      termengine.noteCommittedRows(bytes)
    of "assistant":
      var c = m{"content"}.getStr("").strip
      # Sessions saved by `renderSession` persist a tool-less empty reply as
      # the marker text (`EmptyReplyMsg`); rendering that as prose would show
      # a white "empty reply" line with a `●` bullet instead of the grey
      # fallback the live path paints. Map the marker back to empty so the
      # `tiAssistant` fallback below renders it identically to live.
      if isEmptyReplyMsg(c): c = ""
      let u = usageFromJson(m{"usage"})
      # The live receipt carries the turn timer; it round-trips through
      # the .3log `tokens` record, so replay can render it identically.
      let elapsed = m{"usage"}{"elapsed"}.getInt(-1)
      let isLast = i == lastAssistant
      let hasTools =
        block:
          let tcs = m{"tool_calls"}
          tcs != nil and tcs.kind == JArray and tcs.len > 0
      # The turn's token receipt lands under the LAST tool of the turn,
      # not under the prose (the live path defers it via `deferredReceipt`
      # so it never renders between the answer and the tools it documents).
      # A turn without tools keeps the receipt under the prose.
      let receiptCap = not isLast and u.totalTokens > 0 and not hasTools
      # An empty reply paired with tool calls renders nothing live (the
      # empty-reply fallback is only for tool-less replies), so the replay
      # skips the assistant item entirely in that shape. Same for an empty
      # turn the steer autosend recovered: live commits only the `»` steer
      # item below (no grey fallback, no receipt, no reason line), and the
      # steer user message always directly follows the assistant it nudges.
      let steerFollows =
        i + 1 < messages.len and
        messages[i + 1].kind == JObject and
        messages[i + 1]{"role"}.getStr == "user" and
        messages[i + 1]{"agentSent"}.getBool(false)
      if c.len > 0 or (not hasTools and not steerFollows):
        var bytes = formatItem(assistantItem(c))
        if receiptCap:
          bytes.attachReceipt(receiptBytes(tokenLineLabel(u, window, elapsed)), true)
        stdout.write "\n"
        stdout.write bytes & "\n"
        termengine.noteCommittedRows(bytes)
        # A tool-less empty reply persisted with the provider's explanation
        # (`finish_reason`) gets the same explanatory line the live retry
        # loop painted (`empty reply: <reason>. ...`), so a resumed session
        # shows why the turn was empty instead of the bare fallback. The
        # reason rides on the item, not the separator, so it joins flush.
        if c.len == 0:
          let fr = m{"finish_reason"}.getStr("").strip
          if fr.len > 0:
            var reason = errLnS("empty reply: " & fr)
            reason.trimTranscriptTail()
            stdout.write reason & "\n"
            termengine.noteCommittedRows(reason, separator = false)
      if isLast:
        result = u
      if hasTools:
        let tcs = m{"tool_calls"}
        # Dedupe scope is one batch: an abort batch pairs its note onto
        # every remaining call, but a later turn may legitimately send the
        # same note text again.
        lastAgentNote = ""
        let deferredReceipt =
          if not isLast and u.totalTokens > 0:
            receiptBytes(tokenLineLabel(u, window, elapsed))
          else: ""
        for j in 0 ..< tcs.len:
          let tc = tcs[j]
          inc toolIdx
          let agentNote = agentNotes.getOrDefault(tc{"id"}.getStr, "")
          if agentNote.len > 0:
            if agentNote != lastAgentNote:
              lastAgentNote = agentNote
              var bytes = formatItem(agentPromptItem(agentNote))
              if deferredReceipt.len > 0 and j == tcs.len - 1:
                bytes.attachReceipt(deferredReceipt, true)
              stdout.write "\n"
              stdout.write bytes & "\n"
              termengine.noteCommittedRows(bytes)
            continue
          var code = 0
          var output = ""
          var kind = akBash
          var plan: seq[PlanItem] = @[]
          var act: Action
          var haveAct = false
          if toolIdx <= toolLog.len:
            let rec = toolLog[toolIdx - 1]
            code = rec.code
            output = rec.output
            kind = rec.kind
            plan = rec.plan
          # Rebuild the Action from the persisted tool_call args so the
          # shared `toolItem(act, ...)` renders exactly what live rendered:
          # the banner (`bannerFor`), the write tool's body-as-diff, and the
          # patch header all derive from the Action, and the stored banner
          # alone loses the body (a replayed `w` item rendered banner-only).
          block rebuildAction:
            let fn = tc{"function"}
            if fn == nil or fn.kind != JObject: break rebuildAction
            let name = fn{"name"}.getStr("?")
            let argsStr = fn{"arguments"}.getStr("")
            let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                       except CatchableError: newJObject()
            act = toolCallToAction(family, name, args)
            haveAct = true
            kind = act.kind
            # A plan round-trip can lose its items in the persisted args
            # (empty `items` array) while toolLog kept them; the stored
            # plan wins when the rebuilt one came back empty.
            if act.kind == akPlan and act.plan.len == 0 and plan.len > 0:
              act.plan = plan
            else:
              plan = act.plan
            if toolIdx > toolLog.len:
              code = 0
              output = ""
          var bytes: string
          if haveAct:
            # A skill read renders live as the single suppressed marker, not
            # a tool transcript (`isSkillRead` in the turn loop); the replay
            # must render the same marker so a scrolled-back skill load
            # looks identical after resume.
            if isSkillRead(act):
              bytes = skillLoadedBytes(act)
              bytes.trimTranscriptTail()
            else:
              let diff =
                if act.kind == akWrite and code == 0: act.body else: ""
              var item = toolItem(act, output, code, toolIdx, diff)
              bytes = formatItem(item)
              # The deferred receipt caps the LAST tool of the turn, flush
              # below the item, exactly where the live path attached it.
              if deferredReceipt.len > 0 and j == tcs.len - 1:
                bytes.attachReceipt(deferredReceipt, true)
          else:
            # tool_call payload unreadable (malformed/legacy session): fall
            # back to the stored banner + shared per-kind renderer.
            var banner = ""
            if toolIdx <= toolLog.len: banner = toolLog[toolIdx - 1].banner
            if banner.len == 0: banner = "?"
            bytes = toolTranscriptBytes(banner, kind, output, code, toolIdx)
            bytes.trimTranscriptTail()
          stdout.write "\n"
          stdout.write bytes & "\n"
          termengine.noteCommittedRows(bytes)
          # The flail-noted call's `»` warning rides below its tool item,
          # the same position the live commit wrote it.
          let flailNote = flailNotes.getOrDefault(tc{"id"}.getStr, "")
          if flailNote.len > 0 and flailNote != lastAgentNote:
            lastAgentNote = flailNote
            let noteBytes = formatItem(agentPromptItem(flailNote))
            stdout.write "\n"
            stdout.write noteBytes & "\n"
            termengine.noteCommittedRows(noteBytes)
    of "tool":
      # Result already rendered alongside the assistant's tool_call via
      # toolLog; nothing to do here.
      discard
    else: discard
  stdout.flushFile

proc renderTailRows*(messages: JsonNode; toolLog: seq[ToolRecord];
                     window: int; family: string;
                     journal: seq[termengine.TailJournalRecord];
                     width, budget: int): seq[string] =
  ## The rebreak window's content: the committed transcript tail re-rendered
  ## at the CURRENT terminal width (the formatters read the live width; the
  ## `width` argument is advisory), newest content last, at most `budget`
  ## rows, the topmost unit head-truncated because its head already lives in
  ## scrollback above the window. Items render through the exact replay walk
  ## above (`replaySessionTail`): replay/live parity is the contract, so a
  ## re-broken window matches what a resume would have painted. Journal
  ## records — committed scrollback the messages cannot re-render — merge in
  ## by their messages-length anchor and keep the wraps they were committed
  ## with; only their content must survive a resize.
  if messages == nil or messages.kind != JArray or budget <= 0: return
  var start = 0
  while start < messages.len and messages[start]{"role"}.getStr == "system":
    inc start
  if start >= messages.len: return
  var lastAssistant = -1
  for i in countdown(messages.len - 1, start):
    if messages[i]{"role"}.getStr == "assistant":
      lastAssistant = i
      break
  var agentNotes = initTable[string, string]()
  var flailNotes = initTable[string, string]()
  for m in messages:
    if m.kind != JObject or m{"role"}.getStr != "tool": continue
    if m{"agentSent"}.getBool(false):
      agentNotes[m{"tool_call_id"}.getStr] = m{"content"}.getStr("")
    let fn = m{"flailNote"}.getStr("")
    if fn.len > 0:
      flailNotes[m{"tool_call_id"}.getStr] = fn
  var lastAgentNote = ""
  var toolIdx = 0
  type TailUnit = tuple[anchor: int, rows: seq[string]]
  proc itemRows(bytes: string): seq[string] =
    var rows: seq[string] = @[]
    for row in bytes.split("\r\n"):
      rows.add row
    while rows.len > 0 and rows[^1].len == 0:
      rows.setLen(rows.len - 1)
    rows
  var units: seq[TailUnit] = @[]
  template emit(anchor: int, bytes: string) =
    let rows = itemRows(bytes)
    if rows.len > 0:
      units.add (anchor, rows)
  for i in start ..< messages.len:
    let m = messages[i]
    let anchor = i + 1
    case m{"role"}.getStr
    of "user":
      let raw = m{"content"}
      if raw != nil and raw.kind == JArray:
        let text = userTextBlocks(raw).strip
        if text.startsWith("attached: ") and "(image read)" in text:
          continue
        let c = stripPreamble(text).strip & " [image attached]"
        emit anchor, formatItem(userPromptItem(c))
        continue
      let c = stripPreamble(m{"content"}.getStr("")).strip
      if c.len == 0: continue
      let item =
        if m{"agentSent"}.getBool(false):
          if c.startsWith(GoalKickoffPrefix): goalPromptItem(c)
          else: agentPromptItem(c)
        else: userPromptItem(c)
      emit anchor, formatItem(item)
    of "assistant":
      var c = m{"content"}.getStr("").strip
      if isEmptyReplyMsg(c): c = ""
      let u = usageFromJson(m{"usage"})
      let elapsed = m{"usage"}{"elapsed"}.getInt(-1)
      let isLast = i == lastAssistant
      let hasTools =
        block:
          let tcs = m{"tool_calls"}
          tcs != nil and tcs.kind == JArray and tcs.len > 0
      let receiptCap = not isLast and u.totalTokens > 0 and not hasTools
      let steerFollows =
        i + 1 < messages.len and
        messages[i + 1].kind == JObject and
        messages[i + 1]{"role"}.getStr == "user" and
        messages[i + 1]{"agentSent"}.getBool(false)
      if c.len > 0 or (not hasTools and not steerFollows):
        var bytes = formatItem(assistantItem(c))
        if receiptCap:
          bytes.attachReceipt(
            receiptBytes(tokenLineLabel(u, window, elapsed)), true)
        emit anchor, bytes
        if c.len == 0:
          let fr = m{"finish_reason"}.getStr("").strip
          if fr.len > 0:
            var reason = errLnS("empty reply: " & fr)
            reason.trimTranscriptTail()
            emit anchor, reason
      if hasTools:
        let tcs = m{"tool_calls"}
        lastAgentNote = ""
        let deferredReceipt =
          if not isLast and u.totalTokens > 0:
            receiptBytes(tokenLineLabel(u, window, elapsed))
          else: ""
        for j in 0 ..< tcs.len:
          let tc = tcs[j]
          inc toolIdx
          let agentNote = agentNotes.getOrDefault(tc{"id"}.getStr, "")
          if agentNote.len > 0:
            if agentNote != lastAgentNote:
              lastAgentNote = agentNote
              var bytes = formatItem(agentPromptItem(agentNote))
              if deferredReceipt.len > 0 and j == tcs.len - 1:
                bytes.attachReceipt(deferredReceipt, true)
              emit anchor, bytes
            continue
          var code = 0
          var output = ""
          var kind = akBash
          var plan: seq[PlanItem] = @[]
          var act: Action
          var haveAct = false
          if toolIdx <= toolLog.len:
            let rec = toolLog[toolIdx - 1]
            code = rec.code
            output = rec.output
            kind = rec.kind
            plan = rec.plan
          block rebuildAction:
            let fn = tc{"function"}
            if fn == nil or fn.kind != JObject: break rebuildAction
            let name = fn{"name"}.getStr("?")
            let argsStr = fn{"arguments"}.getStr("")
            let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                       except CatchableError: newJObject()
            act = toolCallToAction(family, name, args)
            haveAct = true
            kind = act.kind
            if act.kind == akPlan and act.plan.len == 0 and plan.len > 0:
              act.plan = plan
            else:
              plan = act.plan
            if toolIdx > toolLog.len:
              code = 0
              output = ""
          var bytes: string
          if haveAct:
            if isSkillRead(act):
              bytes = skillLoadedBytes(act)
              bytes.trimTranscriptTail()
            else:
              let diff =
                if act.kind == akWrite and code == 0: act.body else: ""
              var item = toolItem(act, output, code, toolIdx, diff)
              bytes = formatItem(item)
              if deferredReceipt.len > 0 and j == tcs.len - 1:
                bytes.attachReceipt(deferredReceipt, true)
          else:
            var banner = ""
            if toolIdx <= toolLog.len: banner = toolLog[toolIdx - 1].banner
            if banner.len == 0: banner = "?"
            bytes = toolTranscriptBytes(banner, kind, output, code, toolIdx)
            bytes.trimTranscriptTail()
          emit anchor, bytes
          let flailNote = flailNotes.getOrDefault(tc{"id"}.getStr, "")
          if flailNote.len > 0 and flailNote != lastAgentNote:
            lastAgentNote = flailNote
            emit anchor, formatItem(agentPromptItem(flailNote))
    of "tool":
      discard
    else: discard
  # Merge the journal and cut to the budget, newest first. The newest unit
  # sits directly above the volatile block, whose own top row is the gap —
  # it costs no separator; every older unit costs the one blank separator
  # row a live commit writes between items.
  var picked: seq[seq[string]] = @[]
  var used = 0
  var iu = units.len - 1
  var jr = journal.len - 1
  while iu >= 0 or jr >= 0:
    var rows: seq[string]
    if jr >= 0 and (iu < 0 or
        journal[jr].atMessagesLen >= units[iu].anchor):
      rows = journal[jr].rows
      dec jr
    else:
      rows = units[iu].rows
      dec iu
    if rows.len == 0: continue
    let sep = if picked.len == 0: 0 else: 1
    if used + sep + rows.len <= budget:
      if sep == 1: picked.add @[""]
      picked.add rows
      used += sep + rows.len
      continue
    # The topmost unit does not fit whole: head-truncate it (its head
    # already lives in scrollback above the window) and stop.
    let keep = budget - used - sep
    if keep > 0:
      if sep == 1: picked.add @[""]
      picked.add rows[rows.len - keep .. ^1]
    break
  for rows in picked:
    for row in rows:
      result.add row
