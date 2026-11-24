## Context management: when the conversation approaches the model's context
## window, older turns are collapsed into a single synthetic recap via a
## meta-call to the same model (with a dedicated terse system prompt). That
## recap replaces everything except the system prompt and the last
## `SummarizeKeepRecent` messages. Summarization is lossy and expensive, so
## it runs at most once per turn, only when the context crosses the
## threshold.
##
## The same meta-call machinery powers `:btw`: a side question about the
## conversation answered in one shot over the live history, whose answer
## never enters the context.

import std/[httpclient, json, strutils]
import plugins
import util
import types
import prompts
import images
# applyReasoning lives here; under providerStub the stub serves the
# meta-call itself (see stubNextSummarizerReply). api imports nothing
# from compact, so this stays acyclic.
import api

proc contextWindowFor*(model: string): int =
  ## Heuristic fallback for models off the known-good table
  ## (experimental, or a provider/model pair we haven't curated).
  ## Substring match on well-known slugs; no known collisions in
  ## practice. Known-good pairs should go through `contextWindowFor(p)`
  ## instead, which consults `KnownGoodCombos` for the exact window.
  let m = model.toLowerAscii
  if m == "stub-model": 12_000
  elif "kimi-k2" in m: 262_144
  elif "qwen3-coder" in m or "qwen3_coder" in m: 262_144
  elif "qwen4" in m: 1_000_000
  elif "qwen" in m: 128_000
  elif "claude" in m: 200_000
  elif "gpt-6" in m: 1_050_000
  elif "gpt-5" in m: 400_000
  elif "gpt-4" in m: 128_000
  elif "o1" in m or "o3" in m or "o4" in m: 200_000
  elif "deepseek" in m: 128_000
  elif "gemini" in m: 1_000_000
  elif "llama" in m: 128_000
  elif "glm-5.2" in m or "glm-5.3" in m or "glm-5.4" in m: 1_000_000
  elif "omen-alpha" in m: 500_000
  elif "glm" in m: 200_000
  elif "mistral-large-4" in m: 524_288
  elif "mistral" in m or "mixtral" in m: 262_144
  elif "minimax-m3" in m: 1_000_000
  elif "space-bunny" in m: 1_000_000
  elif "minimax" in m: 204_800
  elif "hy3" in m or "hunyuan" in m: 262_144
  else: 128_000

proc contextWindowFor*(p: Profile): int =
  ## Known-good-aware context window. A curated (provider, model) pair
  ## returns its exact advertised window; everything else falls back to
  ## the substring heuristic in the `model: string` overload. The table
  ## is the source of truth because provider curation (which GLM build a
  ## provider actually serves) matters as much as the family.
  let kg = knownGoodContextWindow(p)
  if kg > 0: return kg
  contextWindowFor(p.model)

const
  SummarizeKeepRecent* = 8
  SummarizeThresholdFrac* = 0.8
  SummarizeMaxTokens* = 500
  SummaryPrefix* = "Earlier in this session: "
  SummarizerSystemPrompt* = """You are summarizing an earlier coding session for later recall. Compress the messages below into one paragraph covering: files read/written, commands run and outcomes, current state (tests green? uncommitted changes? what decision was reached?). Omit everything that's been superseded. No filler."""
  SummarizerPayloadCap = 768 * 1024
    ## Gateways reject oversized request bodies with an opaque 400 while
    ## the token count is still far under the context window (Zen does at
    ## roughly a megabyte; issue #48). The summarizer meta-call must fit
    ## that same envelope even when the conversation it summarizes does
    ## not, so oversized message text is clipped to a per-message budget
    ## derived from this cap.
  SummarizeTailCapBytes* = 512 * 1024
    ## Ceiling on the serialized size of what a collapse RETAINS. A reply
    ## that batches thousands of tool calls (a degenerate loop burning the
    ## whole output budget on near-identical calls) leaves a tool-result
    ## run that pairing keeps intact, and keepRecent alone cannot shrink
    ## it: the collapse then saves megabytes, the retry 400s exactly like
    ## the call it recovers from, and the session is bricked. The tail is
    ## shed head-first until the rebuild fits, comfortably under the
    ## tightest request envelope observed on any route.
  SummarizeByteGuardBytes* = 1_000_000
    ## Proactive request-size ceiling for the Zen-family gateways
    ## (opencode/opencodego). Their byte envelope is undocumented and
    ## route-variable — observed between roughly one and two MB
    ## (anomalyco/opencode#35013, capocasa/3code#48) — so the guard sits
    ## under the tightest observed envelope and fires while every known
    ## route would still accept the request. Other providers are not
    ## guarded: several accept multi-MB bodies and would get pointless
    ## lossy summarization.
  MaxMessagesTesseracted* = 72
    ## Proactive message-count ceiling for the tesseracted gateway
    ## (hosted Kolibri-1). Tesseracted caps the conversation history at
    ## 80 messages — a gateway envelope, not model or vLLM behavior: the
    ## aleph-alpha-inference plugin carries no request validation, and
    ## self-hosted vLLM serves unbounded message counts — and rejects a
    ## longer `messages` array with an opaque 400, "Provide between 1 and
    ## 80 messages" (observed 2026-10-08 on a session killed at 82
    ## messages while the token count sat at 12% of the window, so the
    ## token threshold cannot predict it; message count and token count
    ## are different axes). The catalog (llmtr.com) also lists 60k-char
    ## and 32k-token history caps, but the same session pushed ~150KB /
    ## 38k-token requests through, so only the count axis is guarded. The
    ## guard sits 8 under the cap: it fires after a reply is appended,
    ## and the tool results of that reply land after the check, so one
    ## parallel batch can still push the next request past 80 — the
    ## reactive one-shot 400 recovery catches that burst; everything else
    ## collapses before the route can 400 it.
  OverflowFallbackSummary* = "Earlier turns were dropped without a recap " &
    "because the provider rejected the conversation as too large and the " &
    "summarizer call failed as well; the recent messages below are " &
    "everything that remains."

proc clipSummarizerPayload(payload: JsonNode) =
  ## Shrink `payload` in place until its serialized size fits
  ## `SummarizerPayloadCap`, halving the per-message budget as needed.
  ## Only message text is clipped; roles, ids and tool-call wrappers stay
  ## intact so provider-side pairing validation still passes.
  if payload == nil or payload.kind != JArray or payload.len == 0: return
  var perMsg = max(256, SummarizerPayloadCap div payload.len)
  while len($payload) > SummarizerPayloadCap:
    for m in payload:
      if m.kind != JObject: continue
      for field in ["content", "reasoning_content"]:
        let c = m{field}
        if c != nil and c.kind == JString and c.getStr.len > perMsg:
          let s = c.getStr
          m[field] = %(utf8ByteCut(s, perMsg div 2) &
            "\n... [clipped for size] ...\n" &
            utf8ByteCutEnd(s, perMsg div 2))
    if perMsg <= 256: break
    perMsg = perMsg div 2

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
  var tailStart = messages.len - keepRecent
  # Never start the retained suffix on a `role:tool` message: that orphans
  # the result from its assistant `tool_calls` and Kimi/Moonshot 400 with
  # `tool_call_id is not found`. Walk back to the owning assistant.
  while tailStart > 1 and messages[tailStart]{"role"}.getStr == "tool":
    dec tailStart
  var tail = newSeq[JsonNode]()
  for i in tailStart ..< messages.len:
    tail.add messages[i]
  let synthetic = %*{"role": "user",
                     "content": SummaryPrefix & summary.strip}
  # Shed the oldest tail entries until the rebuild fits SummarizeTailCapBytes.
  # The pairing snap-back above keeps a whole tool-result run with its
  # owning assistant; when that run is the oversized part, shedding from
  # the tail head is the only way down. repairToolCallPairing below makes
  # the survivor legal again: orphan results drop, unanswered calls get
  # synthetic results.
  var dropped = tailStart - 1  # messages dropped from the middle
  let fixedBytes = len($system) + len($synthetic)
  var sizes = newSeq[int](tail.len)
  var tailBytes = 0
  for i, m in tail:
    sizes[i] = len($m)
    tailBytes += sizes[i]
  var head = 0
  while tail.len - head > 1 and tailBytes + fixedBytes > SummarizeTailCapBytes:
    tailBytes -= sizes[head]
    inc head
    inc dropped
  let rebuilt = newJArray()
  rebuilt.add system
  rebuilt.add synthetic
  for i in head ..< tail.len: rebuilt.add tail[i]
  let collapsed = dropped
  # Drop any leftover leading tool results and pair unanswered tool_calls.
  let paired = repairToolCallPairing(rebuilt)
  rebuilt.elems.setLen 0
  for m in paired: rebuilt.add m
  # Replace `messages` contents in place so callers holding the ref see it.
  # elems is a public exported field on JArray; this is the canonical
  # way to clear a JArray while keeping ref identity for callers.
  messages.elems.setLen 0
  for m in rebuilt: messages.add m
  collapsed

proc collapseForSummary*(payload: JsonNode): JsonNode =
  ## Field-by-field copy of the summarizer payload in which user image
  ## blocks collapse to their `[image WxH]` text stand-in: the bytes
  ## already live in the earlier history the summary replaces, and a
  ## meta-call must not carry megabyte blobs. A copy because the live
  ## history's JsonNode refs are shared with the payload entries.
  result = newJArray()
  for m in payload:
    if m.kind == JObject:
      var c = newJObject()
      for k, v in m.pairs: c[k] = v
      if c{"role"}.getStr == "user" and c{"content"}.kind == JArray:
        c["content"] = %userTextContent(c)
      result.add c
    else:
      result.add m

const
  # Forced-thinking models spend this budget on reasoning before the
  # first answer token, so it is headroom, not just answer length.
  BtwMaxTokens* = 8192
  BtwTrailingPrefix* = """Side question ("btw"), asked out of band: the answer is shown to the developer only and never becomes part of this conversation. Tool calls are disabled for this request — answer in plain prose, brief and direct, no filler, no follow-up questions.

Question: """
    ## Frames the question in the aside's trailing user message. The
    ## prose-only contract lives here (not in a dedicated system prompt)
    ## because the aside's system message is the conversation's own, kept
    ## byte-identical so the provider's prompt cache survives the aside.

type
  MetaRequest* = object
    ## One meta-call reduced to plain strings: everything the wire step
    ## needs and nothing that carries a GC'd ref across a thread. Built on
    ## the caller's thread (where the live history is readable); the POST
    ## itself may then run anywhere — the synchronous summarizer path runs
    ## it inline, `:btw` hands it to a worker (see btwthread.nim).
    endpoint*: string
    body*: string          ## serialized request body
    authKey*: string
    sessionHeader*: string  ## x-opencode-session value; "" sends none
    responses*: bool       ## parse shape: output[] (Responses) vs choices[]
  MetaReply* = tuple[answer: string, usage: Usage]
  MetaAttempt* = object
    ## One wire attempt of a meta-request, failures itemized so a caller
    ## with its own retry policy (the `:btw` worker) can classify them
    ## exactly like the main transport does (`retryCategory`).
    reply*: MetaReply    ## parsed answer + usage; "" on any failure
    status*: int         ## HTTP status; 0 when no response arrived
    errBody*: string     ## the provider's error body, "" when none
    retryAfter*: string  ## the Retry-After header value, "" when absent
    err*: string         ## 3code's own failure description, "" on a 200

proc asideWireCacheAffinity(p: Profile, body: JsonNode, roster: JsonNode) =
  ## The aside's cache-side body fields, mirroring the main call so both
  ## land on one prompt-cache prefix: the profile's tool roster rides
  ## UNCHANGED (tool definitions are prefix content — omitting them would
  ## re-bill the whole history as fresh input), `tool_choice: "none"`
  ## is what forbids the model to call any of them (its answer is prose,
  ## never a tool run of its own), and the conversation's cache key pins
  ## the shard the main call warmed (gh #58).
  if roster != nil and roster.kind == JArray and roster.len > 0:
    body["tools"] = roster
    body["tool_choice"] = %"none"
  if responsesApi(p) and conversationId != "":
    body["prompt_cache_key"] = %conversationId

proc buildMetaRequest*(p: Profile, messages: JsonNode, systemPrompt: string,
                       trailingUser: string, maxTokens: int,
                       keepCachePrefix = false): MetaRequest =
  ## Assembles the payload and wire shape of a single non-streaming
  ## meta-call with a dedicated system prompt and no tools, over the live
  ## history plus an optional trailing user message. `messages` is
  ## read-only here: the payload is a copy, so the build leaves the live
  ## conversation untouched. Returns `endpoint == ""` when the profile is
  ## not usable (no provider/model configured).
  ##
  ## `keepCachePrefix` is the `:btw` shape: instead of a meta system
  ## prompt over a flattened history, the payload rides the live history
  ## through the SAME wire transforms as the main call (`repair`,
  ## `stripInternalFields`, the think-back knob), keeps its system
  ## message and image blocks, and carries the profile's tool roster
  ## with `tool_choice: "none"` (plus the Responses prompt_cache_key).
  ## A provider's prompt cache keys on the tools + messages prefix, so
  ## anything but byte-identical fields would re-bill the whole history
  ## as fresh input; with them, an aside costs the trailing question
  ## alone. `systemPrompt` is unused in this mode.
  if p.name == "" or p.url == "" or p.key == "" or p.model == "": return
  var payload = newJArray()
  if keepCachePrefix:
    # The aside's context IS the conversation's wire copy — same
    # transforms as callModel, so the bytes match the main request's
    # cached prefix through the last message. Works on copies only: the
    # live history is never touched from here.
    if messages != nil and messages.kind == JArray:
      payload = repairToolCallPairing(stripInternalFields(messages))
      stripThinkBack(knownGoodThinkBack(p), payload)
  else:
    # Build a trimmed payload: the meta prompt + every non-system message
    # from the live conversation (+ the trailing question). Tool_call
    # messages are allowed — most OpenAI-compatible providers accept them
    # in chat completions even without a tools parameter as long as the
    # tool/assistant pairing is intact.
    payload.add %*{"role": "system", "content": systemPrompt}
    if messages != nil and messages.kind == JArray:
      for i in 0 ..< messages.len:
        let m = messages[i]
        if i == 0 and m.kind == JObject and m{"role"}.getStr == "system":
          continue
        payload.add m
  if trailingUser.len > 0:
    payload.add %*{"role": "user", "content": trailingUser}
  # Copy before mutation: `messages` is the live history; payload entries
  # share its JsonNode refs, so the clip below and the field deletes must
  # never hit it. (Top-level field copies are enough: clipping replaces
  # the content node on the copy.) For keepCachePrefix the image blocks
  # ride verbatim — the main request bills them into its cached prefix —
  # while the summarizer's copy collapses them to their `[image WxH]`
  # text stand-in: the bytes already live in the earlier history the
  # summary replaces, and a meta-call must not carry megabyte blobs.
  var payload2 = newJArray()
  for m in payload:
    if m.kind == JObject:
      var c = newJObject()
      for k, v in m.pairs: c[k] = v
      if not keepCachePrefix and c{"role"}.getStr == "user" and
         c{"content"}.kind == JArray:
        c["content"] = %userTextContent(c)
      payload2.add c
    else:
      payload2.add m
  payload = payload2
  let useResponses = responsesApi(p)
  # The summarizer payload is one synthetic call over the raw history, so
  # there is no active tool loop to preserve: tbCurrentTurn strips here
  # just like tbNone. Same wire-safety as callModel: strict providers
  # reject unknown fields on replayed assistant messages (fireworks et
  # al.); Responses (first-party openai) rejects `reasoning_content`
  # outright. keepCachePrefix payloads had the knob applied via
  # stripThinkBack already — the main path's exact policy.
  if not keepCachePrefix and (knownGoodThinkBack(p) != tbAllTurns or useResponses):
    for m in payload:
      if m.kind == JObject and m{"role"}.getStr == "assistant" and
         m.contains("reasoning_content"):
        m.delete("reasoning_content")
  # Last, after the field hygiene above: clip oversized text so the
  # meta-call itself fits the gateway's request envelope. Without this a
  # byte-large history made BOTH the main call and this rescue call 400,
  # which is why a stuck session could not even be summarized manually.
  clipSummarizerPayload(payload)
  var body: JsonNode
  # Same pro-slug translation as the main turn path (api.nim): the
  # first-party /responses endpoint has no gpt-5.6/6 `-pro` model ids.
  # The chatgpt twin keeps its slug (the Codex backend serves it
  # natively); compact posts to p.url directly either way.
  let proBase = if providerOf(p) == "openai" and '/' notin p.model:
                  proModeWire(p.model)
                else: ""
  if useResponses:
    # Responses API (first-party openai): same role/content messages in
    # `input` (system is accepted), `max_output_tokens` budget, summary
    # text extracted from output[] in `runMetaRequest`.
    body = %*{
      "model": (if proBase != "": proBase else: p.model),
      "input": payload,
      "max_output_tokens": maxTokens,
      "stream": false
    }
    if keepCachePrefix:
      asideWireCacheAffinity(p, body, responsesTools(activeTools(p)))
    # Same reasoning-effort shape responsesBody sends on the main path.
    if p.reasoning.len > 0:
      body["reasoning"] = %*{"effort": %p.reasoning}
    result.endpoint = p.url & "/responses"
  else:
    body = %*{
      "model": p.model,
      "messages": payload,
      maxTokensField(p): maxTokens,
      "stream": false
    }
    if keepCachePrefix:
      asideWireCacheAffinity(p, body, activeTools(p))
    # Same per-family reasoning wire mapping the main turn sends. Without
    # it a forced-thinking model (GLM-5.3 et al.) burns the meta-call's
    # whole token budget on reasoning and returns an empty answer.
    applyReasoning(p, body)
    result.endpoint = p.url & "/chat/completions"
  result.responses = useResponses
  result.body = $body
  result.authKey = p.key
  # Same Zen/Go contract as the main transport: the summarizer is a
  # mid-conversation call, so it rides the conversation's session id
  # (runTurns published it); without one it mints a per-call id.
  if providerOf(p) in ["opencode", "opencodego"]:
    result.sessionHeader =
      if conversationId != "": conversationId else: oneShotSessionId()

proc metaRequestAttempt*(req: ptr MetaRequest; label: string): MetaAttempt

proc runMetaRequest*(req: ptr MetaRequest; label: string): MetaReply =
  ## One attempt of a prebuilt meta-request, answer only: the
  ## single-shot callers (the summarizer, `askBtw`). Failures come back
  ## as ("", zeroed usage) with the reason on stderr under `label`.
  metaRequestAttempt(req, label).reply

proc metaRequestAttempt*(req: ptr MetaRequest; label: string): MetaAttempt =
  ## Fires one prebuilt meta-request and parses the reply. Every input is
  ## read through `req` (never copied into a ref the caller owns), every
  ## allocation it makes dies on the calling thread, so this runs safely
  ## on a worker. A failed attempt reports why (`status`, `errBody`,
  ## `err`) for the caller's retry policy and goes to stderr under
  ## `label`; a 200 with an unparsable or error body reports `err`.
  when defined(providerStub):
    # Test stub: the canned-response queue serves the meta-call itself;
    # the payload is re-parsed from the serialized body ("messages" for
    # chat completions, "input" for Responses). The stub hands back the
    # entry's usage with the answer so an aside's spend is accountable.
    var stubUsage: Usage
    let b = parseJson(req.body)
    let payload = if b{"messages"} != nil: b{"messages"} else: b{"input"}
    let answer = stubNextSummarizerReply(payload, stubUsage)
    return MetaAttempt(reply: (answer, stubUsage), status: 200)
  var status = 0
  var respBody = ""
  var retryAfter = ""
  try:
    let client = newHttpClient(timeout = 120_000,
                               userAgent = modelUserAgent(),
                               sslContext = bundledSslContext())
    defer: client.close()
    client.headers["Authorization"] = "Bearer " & req.authKey
    client.headers["Content-Type"] = "application/json"
    if req.sessionHeader.len > 0:
      client.headers["x-opencode-session"] = req.sessionHeader
    let resp = guardedHttp(client.request(req.endpoint, httpMethod = HttpPost,
                               body = sanitizeUtf8(req.body)),
                           IOError, "fetching " & req.endpoint)
    status = resp.code.int
    respBody = resp.body
    retryAfter = resp.headers.getOrDefault("Retry-After")
  except CatchableError as e:
    stderr.writeLine "3code: " & label & ": " & e.msg
    return MetaAttempt(status: 0, err: e.msg)
  if status != 200:
    stderr.writeLine "3code: " & label & ": api " & $status
    return MetaAttempt(status: status, errBody: respBody,
                       retryAfter: retryAfter, err: "api " & $status)
  let j = try: parseJson(respBody)
          except CatchableError as e:
            stderr.writeLine "3code: " & label & ": " & e.msg
            return MetaAttempt(status: status, errBody: respBody, err: e.msg)
  if "error" in j:
    stderr.writeLine "3code: " & label & ": " & $j["error"]
    return MetaAttempt(status: status, errBody: respBody,
                       err: $j["error"])
  result.status = status
  if j{"usage"} != nil:
    result.reply.usage =
      if req.responses: responsesUsage(j{"usage"}) else: parseUsage(j{"usage"})
  if req.responses:
    let output = j{"output"}
    if output == nil or output.kind != JArray: return
    for item in output:
      if item{"type"}.getStr != "message": continue
      let parts = item{"content"}
      if parts == nil or parts.kind != JArray: continue
      for c in parts:
        if c{"type"}.getStr == "output_text":
          result.reply.answer &= c{"text"}.getStr("")
    return
  let choices = j{"choices"}
  if choices == nil or choices.kind != JArray or choices.len == 0: return
  let msg = choices[0]{"message"}
  if msg == nil or msg.kind != JObject: return
  result.reply.answer = msg{"content"}.getStr("")

proc metaCallOnce(p: Profile, messages: JsonNode, systemPrompt: string,
                  trailingUser: string, maxTokens: int,
                  label: string): string =
  ## Synchronous one-shot meta-call (the summarizer path): build on this
  ## thread, run inline. Returns "" on any failure.
  let req = buildMetaRequest(p, messages, systemPrompt, trailingUser,
                             maxTokens)
  if req.endpoint == "": return ""
  runMetaRequest(addr req, label).answer

type
  ContextAction* = enum
    caNone,         ## within budget, nothing to do
    caSummarize     ## over threshold and enough history to make it worthwhile

proc decideContextAction*(promptTokens, windowTokens, msgCount: int,
                         keepRecent = SummarizeKeepRecent,
                         threshold = SummarizeThresholdFrac): ContextAction =
  ## Pure policy helper. Given a fresh usage reading and the current message
  ## count, decide whether to run the lossy summarizer or do nothing.
  if promptTokens <= 0 or windowTokens <= 0: return caNone
  if promptTokens.float <= threshold * windowTokens.float: return caNone
  if msgCount >= keepRecent + 4: caSummarize else: caNone

proc callSummarizer(p: Profile, messages: JsonNode): string =
  metaCallOnce(p, messages, SummarizerSystemPrompt, "", SummarizeMaxTokens,
               "summarize")

proc buildBtwRequest*(p: Profile, messages: JsonNode,
                      question: string): MetaRequest =
  ## The `:btw` aside's request, shared by the async worker (btwthread)
  ## and the synchronous askBtw. The context is the live history
  ## VERBATIM — byte-for-byte the main turn's wire prefix, tools roster
  ## included, `tool_choice: "none"` instead of the turn's "auto" — so
  ## the model answers from the conversation it already knows at
  ## cached-input prices, and it cannot spend the answer on a tool run
  ## of its own (the tool calls it sees are history; none may be its
  ## reply). The question rides as a trailing user message: appended,
  ## never merged into the shared history.
  buildMetaRequest(p, messages, "", BtwTrailingPrefix & question,
                   BtwMaxTokens, keepCachePrefix = true)

proc askBtw*(question: string, messages: JsonNode, p: Profile): MetaReply =
  ## Side-channel question about the conversation: one meta-call with the
  ## live history as read-only context and the question as the final user
  ## message. The answer (and the call's usage) comes back for display
  ## only — callers must not append it (or the question) to `messages`.
  ## `answer` is "" on any failure; `usage` is zeroed with it.
  let req = buildBtwRequest(p, messages, question)
  if req.endpoint == "": return ("", Usage())
  runMetaRequest(addr req, "btw")

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
  let before = messages.len
  let dropped = applySummary(messages, summary, keepRecent)
  pluginOnCompact(before, messages.len, summary)
  dropped
