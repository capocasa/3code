## Google Cloud Code Assist wire translation for the `geminicli`
## provider (OAuth tokens from auth_google).
##
## cloudcode-pa.googleapis.com speaks Gemini-native
## `v1internal:{generateContent,streamGenerateContent}` with the request
## wrapped in `{model, project, request}` — not OpenAI chat completions.
## This module translates both directions so the rest of the pipeline
## (history, turn loop, tool dispatch, streamHttp's chunk parser) keeps
## seeing chat-style messages:
##
## - request: OpenAI `messages` -> Gemini `contents` + `systemInstruction`
##   + `tools[].functionDeclarations` + `generationConfig`, wrapped in
##   the Code Assist envelope.
## - SSE response: each `data:` event (a GenerateContentResponse) is
##   translated to one or more OpenAI `chat.completion.chunk` payloads
##   before streamHttp's parse loop sees them.
## - non-streaming: the GenerateContentResponse becomes an OpenAI
##   `chat.completion` object.
##
## Thought signatures: Gemini 3 wants the `thoughtSignature` of every
## functionCall echoed back on the next turn, but accepts the documented
## bypass `skip_thought_signature_validator`. We always send the bypass
## and never echo, which keeps the OpenAI-shaped history free of
## Gemini-only state (matches opencode-gemini-auth).
##
## The envelope shape (`{model, project, request}`) is undocumented;
## it is reverse-engineered from gemini-cli, opencode-gemini-auth, and
## CLIProxyAPI, same as every third-party consumer.

import std/[json, strutils, times]
import types

const
  ThoughtSignatureBypass = "skip_thought_signature_validator"
  CodeAssistStreamPath* = "/v1internal:streamGenerateContent?alt=sse"
  CodeAssistGeneratePath* = "/v1internal:generateContent"

proc argsJson(fc: JsonNode): string =
  ## Gemini functionCall.args is already an object; OpenAI wants a JSON
  ## string in `function.arguments`. Empty/missing -> "{}".
  let a = fc{"args"}
  if a == nil or a.kind == JNull: "{}" else: $a

proc sanitizeSchema(n: JsonNode) =
  ## Gemini's functionDeclaration parameters speak a subset of JSON
  ## Schema (OpenAPI 3-flavored): no `additionalProperties`, no `$schema`.
  ## Recurse and strip the unsupported keys.
  if n == nil: return
  case n.kind
  of JObject:
    for k in ["additionalProperties", "$schema"]:
      if n.hasKey(k): n.delete(k)
    for _, v in n: sanitizeSchema(v)
  of JArray:
    for v in n: sanitizeSchema(v)
  else: discard

proc codeAssistBody*(p: Profile, openAiBody: JsonNode, project: string): string =
  ## Translate a callModel chat-completions body into the wrapped Code
  ## Assist request. `openAiBody` carries the already family-processed
  ## fields (tools, reasoning_effort, max_tokens, stream flag).
  var systemParts: seq[JsonNode]
  var contents = newJArray()
  # tool_call_id -> function name, so `role: tool` messages become
  # functionResponse parts with the name Gemini requires.
  var callNames: seq[(string, string)]
  for m in openAiBody{"messages"}:
    if m.kind != JObject: continue
    let role = m{"role"}.getStr
    case role
    of "system":
      systemParts.add %*{"text": m{"content"}.getStr}
    of "user":
      contents.add %*{"role": "user",
                      "parts": [%*{"text": m{"content"}.getStr}]}
    of "assistant":
      var parts = newJArray()
      let c = m{"content"}.getStr
      if c.len > 0:
        parts.add %*{"text": c}
      let tcs = m{"tool_calls"}
      if tcs != nil and tcs.kind == JArray:
        for tc in tcs:
          let fn = tc{"function"}
          let name = fn{"name"}.getStr
          callNames.add (tc{"id"}.getStr, name)
          var args: JsonNode
          try: args = parseJson(fn{"arguments"}.getStr)
          except CatchableError: args = %*{"_raw": fn{"arguments"}.getStr}
          if args.kind != JObject: args = %*{"_value": args}
          parts.add %*{"functionCall": {"name": name, "args": args},
                       "thoughtSignature": ThoughtSignatureBypass}
      contents.add %*{"role": "model", "parts": parts}
    of "tool":
      let id = m{"tool_call_id"}.getStr
      var name = ""
      for (cid, cn) in callNames:
        if cid == id: name = cn
      # repairToolCallPairing guarantees pairing upstream; a missing name
      # here means a hand-built message, degrade to the id.
      if name == "": name = id
      contents.add %*{"role": "user", "parts": [
        {"functionResponse": {
          "name": name,
          "response": {"output": m{"content"}.getStr}}}]}
    else: discard
  var inner = newJObject()
  if systemParts.len > 0:
    inner["systemInstruction"] = %*{"role": "user", "parts": systemParts}
  inner["contents"] = contents
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
        let pcopy = copy(params)
        sanitizeSchema(pcopy)
        decl["parameters"] = pcopy
      decls.add decl
    inner["tools"] = %*[{"functionDeclarations": decls}]
    inner["toolConfig"] = %*{
      "functionCallingConfig": {"mode": "AUTO"}}
  var gen = newJObject()
  let mt = openAiBody{"max_tokens"}
  if mt != nil and mt.kind == JInt and mt.getInt > 0:
    gen["maxOutputTokens"] = mt
  # reasoning_effort (minimal/low/medium/high) maps 1:1 onto Gemini 3
  # thinking levels; the OpenAI-compat endpoint documents the same map.
  let effort = openAiBody{"reasoning_effort"}.getStr
  if effort.len > 0:
    gen["thinkingConfig"] = %*{"thinkingLevel": effort}
  if gen.len > 0:
    inner["generationConfig"] = gen
  $(%*{"model": p.model, "project": project, "request": inner})

type
  CodeAssistStreamState* = object
    ## Per-connection translation state for the SSE path.
    ## `nextToolIndex` numbers tool calls across events (one Gemini
    ## event can carry several functionCalls); `sawFinish` gates the
    ## synthetic `[DONE]` the parser needs to accept the stream.
    nextToolIndex*: int
    sawFinish*: bool

proc translateEvent*(st: var CodeAssistStreamState,
                     payload: string): seq[string] =
  ## One Gemini SSE `data:` payload -> zero or more OpenAI chunk payloads
  ## (as raw JSON strings, ready to hand to streamHttp's parser), plus a
  ## trailing "[DONE]" once a finishReason arrives. Unparseable events
  ## yield nothing (the caller's malformed-line handling stays unused for
  ## Gemini events; debug logging happens there).
  result = @[]
  let j = try: parseJson(payload) except CatchableError: return
  # Mid-stream Google error envelope: {"error": {...}} passes through
  # unchanged — streamHttp's in-band error check reads the same shape.
  let errNode = j{"error"}
  if errNode != nil and errNode.kind == JObject:
    result.add payload
    return
  let resp = if j{"response"} != nil and j{"response"}.kind == JObject: j["response"]
             else: j
  let cands = resp{"candidates"}
  var chunks = newJArray()
  if cands != nil and cands.kind == JArray and cands.len > 0:
    let cand = cands[0]
    let delta = newJObject()
    let parts = cand{"content"}{"parts"}
    if parts != nil and parts.kind == JArray:
      var text = ""
      for part in parts:
        if part.kind != JObject: continue
        # Thought parts ({"text": ..., "thought": true}) are internal
        # reasoning; the OpenAI surface exposes them on
        # `reasoning_content`, same as DeepSeek/Kimi streams.
        let t = part{"text"}.getStr("")
        if t.len > 0:
          if part{"thought"}.getBool(false):
            delta["reasoning_content"] = %(delta{"reasoning_content"}.getStr("") & t)
          else:
            text &= t
        let fc = part{"functionCall"}
        if fc != nil and fc.kind == JObject:
          let idx = st.nextToolIndex
          inc st.nextToolIndex
          var tcs = delta{"tool_calls"}
          if tcs == nil or tcs.kind != JArray:
            tcs = newJArray()
          tcs.add %*{
            "index": idx,
            "id": "call_" & $idx & "_" & $epochTime().int64,
            "type": "function",
            "function": {
              "name": fc{"name"}.getStr,
              "arguments": argsJson(fc)}}
          delta["tool_calls"] = tcs
      if text.len > 0:
        delta["content"] = %text
    let fr = cand{"finishReason"}.getStr("")
    var chunk = %*{"choices": [%*{"index": 0, "delta": delta}]}
    if fr.len > 0:
      st.sawFinish = true
      # Gemini finishReasons: STOP, MAX_TOKENS, SAFETY, RECITATION, ...
      # Map onto the OpenAI vocabulary the turn loop branches on.
      let mapped =
        case fr
        of "MAX_TOKENS": "length"
        of "STOP": "stop"
        else: fr.toLowerAscii
      chunk["choices"][0]["finish_reason"] = %mapped
    if delta.len > 0 or fr.len > 0:
      result.add $chunk
  let um = resp{"usageMetadata"}
  if um != nil and um.kind == JObject:
    result.add $(%*{"usage": {
      "prompt_tokens": um{"promptTokenCount"}.getInt(0),
      "completion_tokens": um{"candidatesTokenCount"}.getInt(0) +
                           um{"thoughtsTokenCount"}.getInt(0),
      "total_tokens": um{"totalTokenCount"}.getInt(0),
      "prompt_tokens_details": {
        "cached_tokens": um{"cachedContentTokenCount"}.getInt(0)},
      "completion_tokens_details": {
        "reasoning_tokens": um{"thoughtsTokenCount"}.getInt(0)}}})
  if st.sawFinish:
    result.add "[DONE]"
    st.sawFinish = false  # one [DONE] per stream; later events re-arm

proc translateResponse*(payload: string): JsonNode =
  ## Non-streaming GenerateContentResponse -> OpenAI chat.completion
  ## object for callHttp's `choices[0].message` path.
  let j = try: parseJson(payload) except CatchableError: return nil
  let resp = if j{"response"} != nil and j{"response"}.kind == JObject: j["response"]
             else: j
  var content, reasoning = ""
  var toolCalls = newJArray()
  var finish = ""
  let cands = resp{"candidates"}
  if cands != nil and cands.kind == JArray and cands.len > 0:
    let cand = cands[0]
    let parts = cand{"content"}{"parts"}
    if parts != nil and parts.kind == JArray:
      for part in parts:
        if part.kind != JObject: continue
        let t = part{"text"}.getStr("")
        if t.len > 0:
          if part{"thought"}.getBool(false): reasoning &= t
          else: content &= t
        let fc = part{"functionCall"}
        if fc != nil and fc.kind == JObject:
          toolCalls.add %*{
            "id": "call_" & $toolCalls.len & "_" & $epochTime().int64,
            "type": "function",
            "function": {"name": fc{"name"}.getStr,
                         "arguments": argsJson(fc)}}
    let fr = cand{"finishReason"}.getStr("")
    finish = case fr
      of "MAX_TOKENS": "length"
      of "STOP": "stop"
      else: fr.toLowerAscii
  var msg = %*{"role": "assistant", "content": content}
  if reasoning.len > 0:
    msg["reasoning_content"] = %reasoning
  if toolCalls.len > 0:
    msg["tool_calls"] = toolCalls
  var choice = %*{"index": 0, "message": msg}
  if finish.len > 0:
    choice["finish_reason"] = %finish
  result = %*{"choices": [choice]}
  let um = resp{"usageMetadata"}
  if um != nil and um.kind == JObject:
    result["usage"] = %*{
      "prompt_tokens": um{"promptTokenCount"}.getInt(0),
      "completion_tokens": um{"candidatesTokenCount"}.getInt(0) +
                           um{"thoughtsTokenCount"}.getInt(0),
      "total_tokens": um{"totalTokenCount"}.getInt(0)}
