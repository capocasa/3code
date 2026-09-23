## Anthropic Messages wire translation for claude-family profiles.
##
## Anthropic's Messages endpoint (api.anthropic.com/v1/messages, other
## Anthropic-protocol deployments) is not OpenAI chat completions: the
## system prompt is a top-level field, tools carry `input_schema`, tool
## calls are assistant `tool_use` content blocks, tool results are
## user-turn `tool_result` blocks that must share one message per
## assistant turn, and streaming is semantic events (`message_start`,
## `content_block_delta`, `message_stop`) instead of `choices[0].delta`
## chunks.
##
## This module translates both directions so the rest of the pipeline
## (history, turn loop, tool dispatch, streamHttp's chunk parser) keeps
## seeing chat-style messages, exactly like codeassist.nim does for the
## Gemini-native wire:
##
## - request: OpenAI `messages` -> Anthropic `system` + alternating
##   `messages` with typed content blocks + `tools[].input_schema` +
##   `max_tokens` (required, not optional) + the thinking configuration
##   derived from the reasoning knob.
## - SSE response: each `data:` event becomes one or more OpenAI
##   `chat.completion.chunk` payloads before streamHttp's parse loop
##   sees them.
## - non-streaming: the Message object becomes an OpenAI
##   `chat.completion` object.
##
## Thinking vocabulary is generation-dependent (Anthropic's thinking
## docs): Claude 4.6+ and all 5.x models speak adaptive thinking
## (`thinking: {type: "adaptive"}` steered by `output_config.effort`,
## low/medium/high/xhigh/max); thinking is on by default for 5.x, and
## Fable/Mythos and Opus 5.5+ reject `{type: "disabled"}` outright, so
## the "off" knob maps to plain adaptive there. Claude 4.5 and earlier
## take the legacy manual mode (`{type: "enabled", budget_tokens}`),
## which 4.7+ rejects. The `:reasoning` knob maps onto whichever
## surface the model string says.
##
## Thinking replay: Anthropic wants the unmodified thinking blocks,
## signature included, passed back with the history, and (Fable 5.1 /
## Opus 5.5+) binds each block to the exact prefix that produced it: a
## dropped mid-sequence block invalidates every later one and 400s. So
## the claude family keeps thinking on every assistant turn (tbAllTurns)
## and this translation replays each block it recorded; blocks ride the
## internal history as a `reasoning_blocks` array on the assistant
## message (internal fields, stripped for OpenAI providers by
## `stripInternalFields`). Where blocks cannot be replayed exactly
## (interrupted stream, compaction, a resumed session), the request
## asks for `block_binding.prefix_mismatch_behavior: "drop_block"`
## under the thinking-binding beta header so the API drops the stale
## blocks instead of rejecting the turn. `display: "summarized"` keeps
## the reasoning ticker fed: the default display hides thinking text.
##
## Sampling: the 4.6+/5.x generations 400 on any non-default
## temperature/top_p/top_k, and older models reject them while thinking
## is on, so the claude family never sends a temperature at all.

import std/[json, sequtils, strutils]
import types

const
  AnthropicMessagesPath* = "/messages"
  AnthropicVersionHeader* = "2023-06-01"
  ThinkingBindingBeta* = "thinking-binding-controls-2026-08-01"
    ## Opt-in for `thinking.block_binding` (preserved-thinking mismatch
    ## behavior). Required whenever block_binding is sent; without it the
    ## field itself is a 400.
  ClaudeOAuthBeta* = "oauth-2025-04-20"
    ## Beta opt-in the Claude Code subscription token demands (see
    ## auth_anthropic.nim).
  ClaudeCodeSystem* = "You are Claude Code, Anthropic's official CLI for Claude."
    ## The subscription endpoint is scoped to the Claude Code client and
    ## rejects a system prompt that does not open with this line.

type
  AnthropicStreamState* = object
    ## Per-connection translation state for the SSE path. Token counts
    ## from `message_start` are held until `message_delta` completes
    ## them, so the final usage chunk carries full totals (streamHttp
    ## keeps the LAST usage chunk it sees). Thinking blocks accumulate
    ## per content-block index and close on `content_block_stop`, so a
    ## turn with several thinking blocks (5.x progress updates between
    ## tool calls) round-trips block-for-block.
    inputTokens*: int
    cacheReadTokens*: int
    cacheCreateTokens*: int
    outputTokens*: int
    sawStop*: bool
    openBlocks*: seq[(int, JsonNode)]

# ---------- model generation parsing ----------

type ClaudeGeneration* = enum
  cgAdaptive   ## 4.6-4.8: thinking.type "adaptive", off until set
  cgAdaptiveAlwaysOn  ## 5.x (incl. Fable/Mythos): thinking on by default
  cgManual     ## 4.5 and earlier: thinking.type "enabled" + budget

proc claudeGeneration*(model: string): ClaudeGeneration =
  ## `claude-sonnet-5` -> adaptive always-on; `claude-opus-4-8` /
  ## `claude-sonnet-4-6` -> adaptive; `claude-haiku-4-5` -> manual.
  ## Bare tier names without a number (`claude-opus`) resolve to the
  ## current generation.
  var nums: seq[int]
  for t in model.split('-'):
    if t.len > 0 and t.allIt(it in {'0'..'9'}):
      try: nums.add parseInt(t) except ValueError: discard
  if nums.len == 0: return cgAdaptiveAlwaysOn
  let major = nums[0]
  let minor = if nums.len > 1: nums[1] else: 0
  if major >= 5: cgAdaptiveAlwaysOn
  elif minor >= 6: cgAdaptive
  else: cgManual

proc rejectsThinkingDisabled*(model: string): bool =
  ## Fable/Mythos and Opus 5.5+ cannot turn thinking off ("disabled"
  ## 400s); an "off" knob maps to plain adaptive with no effort
  ## override instead. Future majors assumed to follow.
  let m = model.toLowerAscii
  if "fable" in m or "mythos" in m: return true
  if "opus" notin m: return false
  var nums: seq[int]
  for t in m.split('-'):
    if t.len > 0 and t.allIt(it in {'0'..'9'}):
      try: nums.add parseInt(t) except ValueError: discard
  if nums.len == 0: return true
  nums[0] >= 6 or (nums[0] == 5 and nums.len > 1 and nums[1] >= 5)

proc runsPrefixCheck*(model: string): bool =
  ## Models that bind thinking blocks to the conversation prefix and
  ## reject a stale block by default (Fable/Mythos 5.1+, Opus 5.5+).
  ## Only these need the drop_block safety net; earlier models never
  ## run the check.
  let m = model.toLowerAscii
  if "fable" in m or "mythos" in m: return true
  if "opus" notin m: return false
  var nums: seq[int]
  for t in m.split('-'):
    if t.len > 0 and t.allIt(it in {'0'..'9'}):
      try: nums.add parseInt(t) except ValueError: discard
  if nums.len == 0: return true
  nums[0] >= 6 or (nums[0] == 5 and nums.len > 1 and nums[1] >= 5)

proc thinkingConfig(model, effort: string): tuple[thinking: JsonNode, effortCfg: JsonNode] =
  ## (`thinking`, `output_config`) fields for the request, or (nil, nil)
  ## to omit both. Reads the OpenAI-shaped body's `reasoning_effort`
  ## value placed there by `applyClaudeReasoning`.
  let gen = claudeGeneration(model)
  if effort == "off" or effort == "":
    if effort == "off" and gen != cgManual and not rejectsThinkingDisabled(model):
      return (%*{"type": "disabled"}, nil)
    return (nil, nil)
  # display "summarized": 4.6+/5.x default to omitted thinking text; the
  # harness has a reasoning ticker, so ask for the summary.
  if gen == cgManual:
    let budget =
      case effort
      of "low": 2_048
      of "medium": 8_192
      else: 16_384
    return (%*{"type": "enabled", "display": "summarized",
               "budget_tokens": budget}, nil)
  var thinking = %*{"type": "adaptive", "display": "summarized"}
  if runsPrefixCheck(model):
    # Stale blocks (interrupted stream, compaction, resume) degrade to a
    # drop instead of a 400; requires the thinking-binding beta header.
    thinking["block_binding"] = %*{"prefix_mismatch_behavior": "drop_block"}
  (thinking, %*{"effort": effort})

proc budgetOf(thinking: JsonNode): int =
  if thinking != nil and thinking.kind == JObject:
    thinking{"budget_tokens"}.getInt(0)
  else:
    0

proc thinkingActive(thinking: JsonNode): bool =
  ## Thinking is off exactly when the config says "disabled" or is
  ## absent after a degrade; block replay follows this so a disabled
  ## request never carries thinking blocks.
  if thinking == nil or thinking.kind != JObject: return false
  thinking{"type"}.getStr != "disabled"

# ---------- request translation ----------

proc textBlocks(content: JsonNode): seq[JsonNode] =
  ## OpenAI message content (string, or an array of typed parts) to
  ## Anthropic text blocks. Non-text parts have no translation yet.
  result = @[]
  if content == nil: return
  case content.kind
  of JString:
    if content.getStr.len > 0:
      result.add %*{"type": "text", "text": content.getStr}
  of JArray:
    for part in content:
      let t = part{"text"}.getStr("")
      if t.len > 0: result.add %*{"type": "text", "text": t}
  else: discard

proc toolUseBlocks(m: JsonNode): seq[JsonNode] =
  ## `tool_calls` entries to `tool_use` blocks. Anthropic wants `input`
  ## as a JSON object, not the OpenAI arguments string.
  result = @[]
  let tcs = m{"tool_calls"}
  if tcs == nil or tcs.kind != JArray: return
  for tc in tcs:
    let fn = tc{"function"}
    if fn == nil: continue
    var input: JsonNode
    try: input = parseJson(fn{"arguments"}.getStr)
    except CatchableError: input = %*{"_raw": fn{"arguments"}.getStr}
    if input.kind != JObject: input = %*{"_value": input}
    result.add %*{"type": "tool_use", "id": tc{"id"}.getStr,
                  "name": fn{"name"}.getStr, "input": input}

proc thinkingBlocks(m: JsonNode): seq[JsonNode] =
  ## The recorded `reasoning_blocks` of an assistant message back to
  ## wire shape: thinking blocks carry (thinking, signature);
  ## redacted blocks carry their opaque `data` blob unchanged.
  result = @[]
  let blocks = m{"reasoning_blocks"}
  if blocks == nil or blocks.kind != JArray: return
  for b in blocks:
    if b.kind != JObject: continue
    if b{"thinking"} != nil:
      result.add %*{"type": "thinking", "thinking": b{"thinking"}.getStr,
                    "signature": b{"signature"}.getStr}
    elif b{"redacted"} != nil:
      result.add %*{"type": "redacted_thinking", "data": b{"redacted"}.getStr}

proc anthropicBody*(p: Profile, openAiBody: JsonNode): string =
  ## Translate a callModel chat-completions body into an Anthropic
  ## Messages request. `openAiBody` carries the already family-processed
  ## fields (tools, reasoning_effort, max_tokens, stream flag).
  let msgs = openAiBody{"messages"}

  # max_tokens is required by the Messages API; the OpenAI body always
  # carries one for known-good combos, default for hand-built pings.
  let maxTokens = block:
    let mt = openAiBody{"max_tokens"}
    if mt != nil and mt.kind == JInt and mt.getInt > 0: mt.getInt
    else: 8_192

  var (thinking, effortCfg) = thinkingConfig(p.model, openAiBody{"reasoning_effort"}.getStr)
  # Manual-mode budgets must leave room for the answer inside
  # max_tokens; if they cannot fit (a 1-token verify ping), degrade to
  # no thinking for this request instead of a guaranteed 400.
  if thinking != nil and budgetOf(thinking) > 0 and
     budgetOf(thinking) >= maxTokens - 1_023:
    thinking = nil

  # Thinking replay (see module doc): every recorded block rides back,
  # but only while this request's thinking is active.
  let replay = thinkingActive(thinking)

  # Manual mode also demands that the FINAL assistant turn of a
  # continued tool loop open with a thinking block; without a
  # replayable one, run the request with thinking off rather than fail.
  var lastAssistant = -1
  if msgs != nil and msgs.kind == JArray:
    for i in 0 ..< msgs.len:
      if msgs[i].kind == JObject and
         msgs[i]{"role"}.getStr == "assistant":
        lastAssistant = i
  if replay and thinking != nil and
     claudeGeneration(p.model) == cgManual and lastAssistant >= 0 and
     thinkingBlocks(msgs[lastAssistant]).len == 0 and
     toolUseBlocks(msgs[lastAssistant]).len > 0:
    thinking = nil

  var systemParts: seq[string]
  var outMsgs = newJArray()
  var openUserBlocks: seq[JsonNode] = @[]

  proc flushUser() =
    if openUserBlocks.len == 0: return
    outMsgs.add %*{"role": "user", "content": openUserBlocks}
    openUserBlocks = @[]

  if msgs != nil and msgs.kind == JArray:
    for i in 0 ..< msgs.len:
      let m = msgs[i]
      if m.kind != JObject: continue
      case m{"role"}.getStr
      of "system":
        systemParts.add m{"content"}.getStr
      of "user":
        for b in textBlocks(m{"content"}): openUserBlocks.add b
      of "tool":
        openUserBlocks.add %*{
          "type": "tool_result",
          "tool_use_id": m{"tool_call_id"}.getStr,
          "content": m{"content"}.getStr}
      of "assistant":
        flushUser()
        var blocks: seq[JsonNode] = @[]
        if replay:
          for b in thinkingBlocks(m): blocks.add b
        let content = m{"content"}.getStr
        if content.strip.len > 0 and
           not (content == EmptyReplyMsg and toolUseBlocks(m).len > 0):
          blocks.add %*{"type": "text", "text": content}
        for b in toolUseBlocks(m): blocks.add b
        if blocks.len == 0:
          blocks.add %*{"type": "text", "text": EmptyReplyMsg}
        # Consecutive assistant messages (interrupted turns) merge into
        # one turn; Anthropic requires alternating roles.
        if outMsgs.len > 0 and
           outMsgs[^1]{"role"}.getStr == "assistant":
          for b in blocks: outMsgs[^1]["content"].add b
        else:
          outMsgs.add %*{"role": "assistant", "content": blocks}
      else: discard
  flushUser()

  var body = %*{"model": p.model, "max_tokens": %maxTokens}
  if systemParts.len > 0:
    if providerOf(p) == "claudecode":
      # Claude Code line first (required), 3code preamble as a second block.
      body["system"] = %*[
        {"type": "text", "text": ClaudeCodeSystem},
        {"type": "text", "text": systemParts.join("\n\n")}]
    else:
      body["system"] = %systemParts.join("\n\n")
  if outMsgs.len > 0:
    body["messages"] = outMsgs
  let tools = openAiBody{"tools"}
  if tools != nil and tools.kind == JArray and tools.len > 0:
    var decls = newJArray()
    for t in tools:
      let fn = t{"function"}
      if fn == nil: continue
      let decl = %*{"name": fn{"name"}.getStr,
                    "description": fn{"description"}.getStr}
      let params = fn{"parameters"}
      if params != nil and params.kind == JObject:
        decl["input_schema"] = params
      decls.add decl
    if decls.len > 0:
      body["tools"] = decls
      body["tool_choice"] = %*{"type": "auto"}
  if openAiBody{"stream"}.getBool(false):
    body["stream"] = %true
  if thinking != nil:
    body["thinking"] = thinking
    if effortCfg != nil:
      body["output_config"] = effortCfg
  $body

# ---------- SSE translation ----------

proc usageChunk(st: AnthropicStreamState): JsonNode =
  ## Full-totals usage object in the OpenAI shape (see parseUsage).
  let prompt = st.inputTokens + st.cacheReadTokens + st.cacheCreateTokens
  %*{"usage": {
    "prompt_tokens": prompt,
    "completion_tokens": st.outputTokens,
    "total_tokens": prompt + st.outputTokens,
    "prompt_tokens_details": {
      "cached_tokens": st.cacheReadTokens + st.cacheCreateTokens}}}

proc stopReasonMap(r: string): string =
  case r
  of "end_turn", "stop_sequence", "pause_turn": "stop"
  of "tool_use": "tool_calls"
  of "max_tokens", "model_context_window_exceeded": "length"
  of "refusal": "content_filter"
  else: r.toLowerAscii

proc chunk(delta: JsonNode): string =
  $(%*{"choices": [%*{"index": 0, "delta": delta}]})

proc translateAnthropicEvent*(st: var AnthropicStreamState,
                              payload: string): seq[string] =
  ## One Anthropic SSE `data:` payload -> zero or more OpenAI chunk
  ## payloads (raw JSON strings for streamHttp's parser), plus a
  ## trailing "[DONE]" on `message_stop`. Unparseable events yield
  ## nothing. `event:` lines never reach this proc (streamHttp only
  ## feeds `data:` payloads); the event type rides inside the JSON.
  result = @[]
  let j = try: parseJson(payload) except CatchableError: return
  if j == nil or j.kind != JObject: return
  # Mid-stream error envelope passes through unchanged — streamHttp's
  # in-band error check reads the same top-level `error` shape.
  if j{"error"} != nil and j{"error"}.kind == JObject:
    result.add payload
    return
  case j{"type"}.getStr
  of "message_start":
    let u = j{"message"}{"usage"}
    if u != nil and u.kind == JObject:
      st.inputTokens = u{"input_tokens"}.getInt(0)
      st.cacheReadTokens = u{"cache_read_input_tokens"}.getInt(0)
      st.cacheCreateTokens = u{"cache_creation_input_tokens"}.getInt(0)
      result.add $usageChunk(st)
  of "content_block_start":
    let idx = j{"index"}.getInt(0)
    let cb = j{"content_block"}
    if cb == nil or cb.kind != JObject: return
    case cb{"type"}.getStr
    of "tool_use":
      result.add chunk(%*{"tool_calls": [%*{
        "index": idx,
        "id": cb{"id"}.getStr,
        "type": "function",
        "function": {"name": cb{"name"}.getStr, "arguments": ""}}]})
    of "thinking":
      st.openBlocks.add (idx, %*{"thinking": "", "signature": ""})
    of "redacted_thinking":
      st.openBlocks.add (idx, %*{"redacted": cb{"data"}.getStr})
    else: discard
  of "content_block_delta":
    let d = j{"delta"}
    if d == nil or d.kind != JObject: return
    let idx = j{"index"}.getInt(0)
    let text = d{"text_delta"}{"text"}.getStr("")
    if text.len > 0:
      result.add chunk(%*{"content": text})
    let think = d{"thinking_delta"}{"thinking"}.getStr("")
    if think.len > 0:
      result.add chunk(%*{"reasoning_content": think})
      for i, (bi, b) in st.openBlocks:
        if bi == idx and b{"thinking"} != nil:
          st.openBlocks[i][1]["thinking"] =
            %(b{"thinking"}.getStr & think)
    let sig = d{"signature_delta"}{"signature"}.getStr("")
    if sig.len > 0:
      for i, (bi, b) in st.openBlocks:
        if bi == idx and b{"signature"} != nil:
          st.openBlocks[i][1]["signature"] = %(b{"signature"}.getStr & sig)
    let frag = d{"input_json_delta"}{"partial_json"}.getStr("")
    if frag.len > 0:
      result.add chunk(%*{"tool_calls": [%*{
        "index": idx,
        "function": {"arguments": frag}}]})
  of "content_block_stop":
    let idx = j{"index"}.getInt(0)
    for i, (bi, b) in st.openBlocks:
      if bi != idx: continue
      # Closed thinking block: hand streamHttp the exact (text,
      # signature) pair (or the redacted blob) for history replay.
      result.add chunk(%*{"reasoning_block": b})
      st.openBlocks.delete(i)
      break
  of "message_delta":
    let d = j{"delta"}
    if d != nil and d.kind == JObject:
      let sr = d{"stop_reason"}.getStr("")
      if sr.len > 0:
        st.sawStop = true
        result.add $(%*{"choices": [%*{"index": 0, "delta": {},
          "finish_reason": stopReasonMap(sr)}]})
    let u = j{"usage"}
    if u != nil and u.kind == JObject:
      st.outputTokens = u{"output_tokens"}.getInt(0)
      var uc = usageChunk(st)
      let rt = u{"output_tokens_details"}{"thinking_tokens"}.getInt(0)
      if rt > 0:
        uc["usage"]["completion_tokens_details"] =
          %*{"reasoning_tokens": rt}
      result.add $uc
  of "message_stop":
    result.add "[DONE]"
  else: discard  # ping, content_block bookkeeping, future events

# ---------- non-streaming translation ----------

proc translateAnthropicResponse*(payload: string): JsonNode =
  ## Message object -> OpenAI chat.completion object for callHttp's
  ## `choices[0].message` path. Thinking blocks ride along as a
  ## `reasoning_blocks` array (see anthropicBody) so the built assistant
  ## message can replay them on later turns.
  let j = try: parseJson(payload) except CatchableError: return nil
  if j == nil or j.kind != JObject: return nil
  var content, reasoning = ""
  var blocks = newJArray()
  var toolCalls = newJArray()
  let contentArr = j{"content"}
  if contentArr != nil and contentArr.kind == JArray:
    for b in contentArr:
      if b.kind != JObject: continue
      case b{"type"}.getStr
      of "text": content &= b{"text"}.getStr("")
      of "thinking":
        reasoning &= b{"thinking"}.getStr("")
        blocks.add %*{"thinking": b{"thinking"}.getStr,
                      "signature": b{"signature"}.getStr}
      of "redacted_thinking":
        blocks.add %*{"redacted": b{"data"}.getStr}
      of "tool_use":
        let inp = b{"input"}
        toolCalls.add %*{
          "id": b{"id"}.getStr,
          "type": "function",
          "function": {"name": b{"name"}.getStr,
                       "arguments": if inp != nil: $inp else: "{}"}}
      else: discard
  var msg = %*{"role": "assistant", "content": content}
  if reasoning.len > 0:
    msg["reasoning_content"] = %reasoning
  if blocks.len > 0:
    msg["reasoning_blocks"] = blocks
  if toolCalls.len > 0:
    msg["tool_calls"] = toolCalls
  var choice = %*{"index": 0, "message": msg}
  let sr = j{"stop_reason"}.getStr("")
  if sr.len > 0:
    choice["finish_reason"] = %(stopReasonMap(sr))
  result = %*{"choices": [choice]}
  let u = j{"usage"}
  if u != nil and u.kind == JObject:
    let prompt = u{"input_tokens"}.getInt(0) +
                 u{"cache_read_input_tokens"}.getInt(0) +
                 u{"cache_creation_input_tokens"}.getInt(0)
    let output = u{"output_tokens"}.getInt(0)
    result["usage"] = %*{
      "prompt_tokens": prompt,
      "completion_tokens": output,
      "total_tokens": prompt + output,
      "prompt_tokens_details": {
        "cached_tokens": u{"cache_read_input_tokens"}.getInt(0) +
                         u{"cache_creation_input_tokens"}.getInt(0)},
      "completion_tokens_details": {
        "reasoning_tokens":
          u{"output_tokens_details"}{"thinking_tokens"}.getInt(0)}}
