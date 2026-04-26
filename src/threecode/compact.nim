import std/[httpclient, json, strutils, tables]
import types

const
  CompactThresholdFrac* = 0.8
  CompactKeepRecent* = 10
  CompactedMarker* = "[compacted — tool output elided; use :show to view]"
  SupersededMarker* = "[superseded — later action on same path elided this]"

proc contextWindowFor*(model: string): int =
  ## Heuristic: substring match on well-known model slugs. Cheap, and no
  ## known collisions exist in practice. Update if a provider ships a
  ## colliding model name.
  let m = model.toLowerAscii
  if "kimi-k2" in m: 128_000
  elif "qwen3-coder" in m or "qwen3_coder" in m: 262_144
  elif "qwen" in m: 128_000
  elif "claude" in m: 200_000
  elif "gpt-5" in m: 400_000
  elif "gpt-4" in m: 128_000
  elif "o1" in m or "o3" in m or "o4" in m: 200_000
  elif "deepseek" in m: 128_000
  elif "gemini" in m: 1_000_000
  elif "llama" in m: 128_000
  elif "glm" in m: 128_000
  elif "mistral" in m or "mixtral" in m: 128_000
  else: 128_000

proc compactHistory*(messages: JsonNode, keepRecent = CompactKeepRecent): int =
  ## Replace `content` of old `tool` messages with a short marker. Returns
  ## the number of messages compacted. System prompt (index 0) and the last
  ## `keepRecent` messages are left untouched.
  if messages == nil or messages.kind != JArray: return 0
  if messages.len <= keepRecent + 1: return 0
  let cutoff = messages.len - keepRecent
  for i in 1 ..< cutoff:
    let m = messages[i]
    if m.kind != JObject: continue
    if m{"role"}.getStr != "tool": continue
    let c = m{"content"}.getStr("")
    if c.len <= CompactedMarker.len + 32: continue
    if c.startsWith("[compacted"): continue
    m["content"] = %CompactedMarker
    inc result

proc supersedeCompact*(messages: JsonNode, keepRecent = 2): int =
  ## Lossless-ish elision for write-happy models: when a `write` or `patch`
  ## to path P lands later in the conversation, earlier tool-call bodies
  ## and read results targeting P are replaced with a short marker. Same
  ## goes for an earlier `read(P)` superseded by any later read or write.
  ## The very last `keepRecent` messages are left alone so the model still
  ## sees the result of its most recent actions.
  if messages == nil or messages.kind != JArray or messages.len < 3: return 0
  # Map tool_call_id → (path, tool name, assistant msg index, tool_call index)
  var idInfo = initTable[string, (string, string, int)]()
  # path → highest message index of any later write or patch; reads only
  # invalidate earlier reads of the same path, not writes.
  var lastMut = initTable[string, int]()   # write or patch
  var lastRead = initTable[string, int]()
  for i in 0 ..< messages.len:
    let m = messages[i]
    if m.kind != JObject: continue
    if m{"role"}.getStr != "assistant": continue
    let tcs = m{"tool_calls"}
    if tcs == nil or tcs.kind != JArray: continue
    for tc in tcs:
      let id = tc{"id"}.getStr
      let fn = tc{"function"}
      if fn == nil or fn.kind != JObject: continue
      let name = fn{"name"}.getStr
      let argsStr = fn{"arguments"}.getStr("")
      let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                 except CatchableError: continue
      let path = args{"path"}.getStr
      if path == "": continue
      idInfo[id] = (path, name, i)
      case name
      of "write", "patch": lastMut[path] = i
      of "read": lastRead[path] = i
      else: discard
  let protectFrom = max(0, messages.len - keepRecent)
  for i in 0 ..< messages.len:
    if i >= protectFrom: break
    let m = messages[i]
    if m.kind != JObject: continue
    case m{"role"}.getStr
    of "tool":
      let id = m{"tool_call_id"}.getStr
      if id notin idInfo: continue
      let (path, name, _) = idInfo[id]
      let mut = lastMut.getOrDefault(path, -1)
      let rd = lastRead.getOrDefault(path, -1)
      var superseded = false
      case name
      of "read":
        if mut > i or rd > i: superseded = true
      of "write", "patch":
        if mut > i: superseded = true   # superseded by a later edit
      else: discard
      if superseded:
        let c = m{"content"}.getStr("")
        if c.len > SupersededMarker.len + 32 and
           not c.startsWith("[superseded") and
           not c.startsWith("[compacted") and
           "[repeat-guard]" notin c:
          m["content"] = %SupersededMarker
          inc result
    of "assistant":
      let tcs = m{"tool_calls"}
      if tcs == nil or tcs.kind != JArray: continue
      for tc in tcs:
        let id = tc{"id"}.getStr
        if id notin idInfo: continue
        let (path, name, callIdx) = idInfo[id]
        let mut = lastMut.getOrDefault(path, -1)
        if name notin ["write", "patch"]: continue
        if mut <= callIdx: continue  # still the latest edit on this path
        let fn = tc["function"]
        let argsStr = fn{"arguments"}.getStr("")
        var args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                   except CatchableError: continue
        var changed = false
        if name == "write":
          let b = args{"body"}.getStr("")
          if b.len > 64 and "elided" notin b:
            args["body"] = %"[body elided — a later write to this path replaced this one; the current file matches the latest write, not this earlier body]"
            changed = true
        elif name == "patch":
          let edits = args{"edits"}
          if edits != nil and edits.kind == JArray and edits.len > 0:
            var bulk = 0
            var alreadyElided = false
            for e in edits:
              bulk += ($e).len
              if e.kind == JObject and "elided" in e{"search"}.getStr(""):
                alreadyElided = true
            if bulk > 128 and not alreadyElided:
              args["edits"] = %*[{"search": "[edits elided — superseded]",
                                   "replace": "[edits elided — superseded]"}]
              changed = true
        if changed:
          fn["arguments"] = %( $args )
          inc result
    else: discard

const
  SummarizeKeepRecent* = 8
  SummarizeThresholdFrac* = 0.8
  SummarizeMaxTokens* = 500
  SummaryPrefix* = "Earlier in this session: "
  SummarizerSystemPrompt* = """You are summarizing an earlier coding session for later recall. Compress the messages below into one paragraph covering: files read/written, commands run and outcomes, current state (tests green? uncommitted changes? what decision was reached?). Omit everything that's been superseded. No filler."""

proc applySummary*(messages: JsonNode, summary: string,
                  keepRecent = SummarizeKeepRecent): int =
  ## Rewrites `messages` in place to `[system, synthetic_user_summary,
  ## ...last keepRecent]` and returns the number of messages collapsed (i.e.
  ## removed from the middle). Returns 0 without touching `messages` if the
  ## prerequisites are not met: array shape, a system message at index 0,
  ## and at least `keepRecent + 4` messages to justify the call.
  if messages == nil or messages.kind != JArray: return 0
  if messages.len < keepRecent + 4: return 0
  if messages[0].kind != JObject: return 0
  if messages[0]{"role"}.getStr != "system": return 0
  if summary.strip.len == 0: return 0
  let system = messages[0]
  let tailStart = messages.len - keepRecent
  var tail = newSeq[JsonNode](keepRecent)
  for i in 0 ..< keepRecent:
    tail[i] = messages[tailStart + i]
  let collapsed = tailStart - 1  # messages dropped from the middle
  let synthetic = %*{"role": "user",
                     "content": SummaryPrefix & summary.strip}
  let rebuilt = newJArray()
  rebuilt.add system
  rebuilt.add synthetic
  for m in tail: rebuilt.add m
  # Replace `messages` contents in place so callers holding the ref see it.
  # elems is a public exported field on JArray; this is the canonical
  # way to clear a JArray while keeping ref identity for callers.
  messages.elems.setLen 0
  for m in rebuilt: messages.add m
  collapsed

proc callSummarizer(p: Profile, messages: JsonNode): string =
  ## Fires a single meta-call to the model with a dedicated summarizer
  ## system prompt and no tools. Returns "" on any failure.
  if p.name == "" or p.url == "" or p.key == "" or p.model == "": return ""
  # Build a trimmed payload: the summarizer prompt + every non-system
  # message from the live conversation. Tool_call messages are allowed —
  # most OpenAI-compatible providers accept them in chat completions even
  # without a tools parameter as long as the tool/assistant pairing is
  # intact.
  let payload = newJArray()
  payload.add %*{"role": "system", "content": SummarizerSystemPrompt}
  if messages != nil and messages.kind == JArray:
    for i in 0 ..< messages.len:
      let m = messages[i]
      if i == 0 and m.kind == JObject and m{"role"}.getStr == "system":
        continue
      payload.add m
  let client = newHttpClient(timeout = 120_000)
  defer: client.close()
  client.headers = newHttpHeaders({
    "Authorization": "Bearer " & p.key,
    "Content-Type": "application/json"
  })
  let body = %*{
    "model": p.modelPrefix & p.model,
    "messages": payload,
    "max_tokens": SummarizeMaxTokens,
    "stream": false
  }
  try:
    let r = client.request(p.url & "/chat/completions", HttpPost, $body)
    if r.code != Http200:
      stderr.writeLine "3code: summarize: api " & $r.code
      return ""
    let j = parseJson(r.body)
    if "error" in j:
      stderr.writeLine "3code: summarize: " & $j["error"]
      return ""
    let choices = j{"choices"}
    if choices == nil or choices.kind != JArray or choices.len == 0: return ""
    let msg = choices[0]{"message"}
    if msg == nil or msg.kind != JObject: return ""
    msg{"content"}.getStr("")
  except CatchableError as e:
    stderr.writeLine "3code: summarize: " & e.msg
    ""

type
  ContextAction* = enum
    caNone,         ## within budget, nothing to do
    caSummarize,    ## over threshold and enough history to make it worthwhile
    caCompact       ## over threshold but too little history to summarize

proc decideContextAction*(promptTokens, windowTokens, msgCount: int,
                         keepRecent = SummarizeKeepRecent,
                         threshold = SummarizeThresholdFrac): ContextAction =
  ## Pure policy helper. Given a fresh usage reading and the current message
  ## count, decide whether to summarize, compact, or leave things alone.
  ## Summarization comes first (big lossy win); compaction is the fallback
  ## when there aren't enough messages to summarize usefully.
  if promptTokens <= 0 or windowTokens <= 0: return caNone
  if promptTokens.float <= threshold * windowTokens.float: return caNone
  if msgCount >= keepRecent + 4: caSummarize else: caCompact

proc summarizeHistory*(messages: JsonNode, p: Profile,
                      keepRecent = SummarizeKeepRecent): int =
  ## Collapse old turns into one synthetic user recap via a meta-model call.
  ## Returns the number of messages dropped; 0 if we bailed (too few
  ## messages, missing system prompt, empty profile, or the summarizer
  ## call failed). On failure `messages` is left untouched.
  if messages == nil or messages.kind != JArray: return 0
  if messages.len < keepRecent + 4: return 0
  if messages[0].kind != JObject or messages[0]{"role"}.getStr != "system":
    return 0
  if p.name == "": return 0
  let summary = callSummarizer(p, messages)
  if summary.strip.len == 0: return 0
  applySummary(messages, summary, keepRecent)
