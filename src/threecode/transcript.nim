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
  var firstItem = true
  var toolIdx = 0
  for i in start ..< messages.len:
    let m = messages[i]
    case m{"role"}.getStr
    of "user":
      let c = stripPreamble(m{"content"}.getStr("")).strip
      if c.len == 0: continue
      let shown = if c.len > 400: c[0 ..< 400] & " ..." else: c
      if not firstItem:
        stdout.write "\n"
      stdout.write formatItem(userPromptItem(shown)) & "\n"
      firstItem = false
    of "assistant":
      var c = m{"content"}.getStr("").strip
      # Sessions saved by `renderSession` persist a tool-less empty reply as
      # the marker text (`EmptyReplyMsg`); rendering that as prose would show
      # a white "empty reply" line with a `●` bullet instead of the grey
      # fallback the live path paints. Map the marker back to empty so the
      # `tiAssistant` fallback below renders it identically to live.
      if isEmptyReplyMsg(c): c = ""
      let u = usageFromJson(m{"usage"})
      let isLast = i == lastAssistant
      let hasTools =
        block:
          let tcs = m{"tool_calls"}
          tcs != nil and tcs.kind == JArray and tcs.len > 0
      # An empty reply paired with tool calls renders nothing live (the
      # empty-reply fallback is only for tool-less replies), so the replay
      # skips the assistant item entirely in that shape.
      if c.len > 0 or not hasTools:
        var bytes = formatItem(assistantItem(c))
        if not isLast and u.totalTokens > 0:
          bytes.attachReceipt(receiptBytes(tokenLineLabel(u, window)), true)
        if not firstItem:
          stdout.write "\n"
        stdout.write bytes & "\n"
        firstItem = false
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
        for tc in tcs:
          inc toolIdx
          var banner = ""
          var code = 0
          var output = ""
          var kind = akBash
          var plan: seq[PlanItem] = @[]
          if toolIdx <= toolLog.len:
            let rec = toolLog[toolIdx - 1]
            banner = rec.banner
            code = rec.code
            output = rec.output
            kind = rec.kind
            plan = rec.plan
          else:
            let fn = tc{"function"}
            let name = if fn != nil: fn{"name"}.getStr else: "?"
            let argsStr = if fn != nil: fn{"arguments"}.getStr("") else: ""
            let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                       except CatchableError: newJObject()
            let act = toolCallToAction(family, name, args)
            banner = bannerFor(act)
            kind = act.kind
            plan = act.plan
          # Plan and clear items come straight from the shared formatters so
          # a replayed item looks byte-identical to how it rendered live.
          # Other kinds keep the stored banner (or the `bannerFor` fallback
          # when toolLog was not saved) and render the body through the
          # shared per-kind renderer.
          var bytes: string
          if kind == akPlan:
            bytes = formatItem(toolItem(Action(kind: akPlan, plan: plan),
              output, code, toolIdx))
          elif kind == akClear:
            bytes = formatItem(toolItem(Action(kind: akClear),
              output, code, toolIdx))
          else:
            bytes = toolTranscriptBytes(banner, kind, output, code, toolIdx)
            bytes.trimTranscriptTail()
          if not firstItem:
            stdout.write "\n"
          stdout.write bytes & "\n"
          firstItem = false
    of "tool":
      # Result already rendered alongside the assistant's tool_call via
      # toolLog; nothing to do here.
      discard
    else: discard
  stdout.flushFile
