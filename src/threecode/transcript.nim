## High-level transcript items for append-only terminal history.
##
## Controllers construct these semantic items and append them through the
## fat-prompt runtime. Formatters in display/tool modules can still build item
## bodies, but this module owns item markers, trimming, and item separators.

import std/[json, strutils]

import actions, display, fatprompt, session, types, util

export isEmptyReplyMsg

type
  TranscriptKind* = enum
    tiUserPrompt,
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
  var toolIdx = 0
  for i in start ..< messages.len:
    let m = messages[i]
    case m{"role"}.getStr
    of "user":
      let c = stripPreamble(m{"content"}.getStr("")).strip
      if c.len == 0: continue
      # No length truncation: the live path echoes the full submitted line
      # (wrapped at terminal width by `formatUserPromptItem`), so the replay
      # must too.
      stdout.write "\n"
      stdout.write formatItem(userPromptItem(c)) & "\n"
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
      # skips the assistant item entirely in that shape.
      if c.len > 0 or not hasTools:
        var bytes = formatItem(assistantItem(c))
        if receiptCap:
          bytes.attachReceipt(receiptBytes(tokenLineLabel(u, window, elapsed)), true)
        stdout.write "\n"
        stdout.write bytes & "\n"
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
      if isLast:
        result = u
      if hasTools:
        let tcs = m{"tool_calls"}
        let deferredReceipt =
          if not isLast and u.totalTokens > 0:
            receiptBytes(tokenLineLabel(u, window, elapsed))
          else: ""
        for j in 0 ..< tcs.len:
          let tc = tcs[j]
          inc toolIdx
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
    of "tool":
      # Result already rendered alongside the assistant's tool_call via
      # toolLog; nothing to do here.
      discard
    else: discard
  stdout.flushFile
