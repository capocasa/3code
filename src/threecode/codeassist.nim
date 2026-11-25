## Gemini-native wire translation for the `google` (AI Studio API key)
## and `geminicli` (OAuth subscription) providers.
##
## generativelanguage.googleapis.com speaks `generateContent` directly;
## cloudcode-pa.googleapis.com speaks the same
## `v1internal:{generateContent,streamGenerateContent}` methods with the
## request wrapped in `{model, project, request}`. This module builds the
## shared request body and translates both response directions so the
## rest of the pipeline (history, turn loop, tool dispatch, streamHttp's
## chunk parser) keeps seeing chat-style messages:
##
## - request: OpenAI `messages` -> Gemini `contents` + `systemInstruction`
##   + `tools[].functionDeclarations` + `generationConfig`; the API-key
##   `google` wire sends it as-is, Code Assist wraps it in its envelope.
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
## Gemini-only state (matches opencode-gemini-auth and LiteLLM).
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

func dataUriParts(uri: string): (string, string) =
  ## `data:image/png;base64,AAAA` -> (`image/png`, `AAAA`). Empty pair when
  ## the string is not a data URI (a url has no bytes to inline).
  if not uri.startsWith("data:"): return ("", "")
  let comma = uri.find(',')
  if comma < 0: return ("", "")
  var mime = uri[5 ..< comma]
  if mime.endsWith(";base64"):
    mime = mime[0 ..< mime.len - ";base64".len]
  (mime, uri[comma + 1 .. ^1])

func geminiChatModel*(name: string): bool =
  ## True for the chat-capable Gemini and Gemma models served by the
  ## native API. `/v1beta/models` also lists embeddings, TTS, live, image,
  ## video and decision models; they are `generateContent`-capable too, but
  ## a turn needs a chat model, so the model picker filters them out.
  let n = name.toLowerAscii
  if not (n.startsWith("gemini-") or n.startsWith("gemma-")): return false
  for marker in ["-image", "-tts", "-embedding", "-live", "-audio",
                 "-decision", "-robotics", "computer", "transcribe",
                 "-omni", "nano-banana"]:
    if marker in n: return false
  true

proc geminiRequest*(openAiBody: JsonNode): JsonNode =
  ## Translate a callModel chat-completions body into the Gemini-native
  ## `GenerateContentRequest`. `openAiBody` carries the already
  ## family-processed fields (tools, reasoning_effort, max_tokens,
  ## temperature when the user set one).
  var systemParts: seq[JsonNode]
  var contents = newJArray()
  # Gemini thinking models validate the thoughtSignature of every replayed
  # functionCall; the documented dummy bypasses the validator. Gemma has
  # no thought signatures, so the field is left off there.
  let wantsSignatures = not openAiBody{"model"}.getStr.toLowerAscii.startsWith("gemma")
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
      # A string content stays one text part; a content array carries
      # text blocks plus `image_url` blocks, whose data URI becomes an
      # inlineData part (Gemini has no URL-image block on this wire).
      let c = m{"content"}
      var parts = newJArray()
      if c != nil and c.kind == JArray:
        for b in c:
          if b.kind != JObject: continue
          case b{"type"}.getStr
          of "text":
            parts.add %*{"text": b{"text"}.getStr}
          of "image_url":
            let (mime, data) = dataUriParts(b{"image_url"}{"url"}.getStr(""))
            if mime.len > 0 and data.len > 0:
              parts.add %*{"inlineData": {"mimeType": mime, "data": data}}
          else: discard
      else:
        parts.add %*{"text": c.getStr}
      if parts.len > 0:
        contents.add %*{"role": "user", "parts": parts}
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
          if wantsSignatures:
            parts.add %*{"functionCall": {"name": name, "args": args},
                         "thoughtSignature": ThoughtSignatureBypass}
          else:
            parts.add %*{"functionCall": {"name": name, "args": args}}
      # An empty model turn (no text, no calls) has no parts to send;
      # Gemini rejects an empty parts array.
      if parts.len > 0:
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
    # `tool_choice: "none"` (the :btw aside) maps onto the native NONE
    # mode, which forbids a tool call without dropping the cached tool
    # roster from the prefix.
    let choice = openAiBody{"tool_choice"}.getStr("")
    inner["toolConfig"] = %*{
      "functionCallingConfig": {"mode": if choice == "none": "NONE"
                                          else: "AUTO"}}
  var gen = newJObject()
  let mt = openAiBody{"max_tokens"}
  if mt != nil and mt.kind == JInt and mt.getInt > 0:
    gen["maxOutputTokens"] = mt
  # A user-set `[params] temperature` rides through; the table value is
  # omitted for the gemini family (deprecated sampling knobs).
  if openAiBody{"temperature"} != nil:
    gen["temperature"] = openAiBody{"temperature"}
  # reasoning_effort maps onto the model's thinking surface: Gemini 3/4
  # take named levels (the native enum carries the same names, xhigh
  # included), while the 2.5 line thinks in token budgets (the compat
  # layer's documented map: minimal/low 1024, medium 8192, high 24576).
  # Older lines (2.0 and earlier) have no thinking surface; sending one
  # would 400, so the knob is dropped there.
  let effort = openAiBody{"reasoning_effort"}.getStr
  let modelId = openAiBody{"model"}.getStr.toLowerAscii
  if effort.len > 0 and modelId.startsWith("gemini-2.5"):
    let budget = case effort
      of "minimal", "low": 1024
      of "medium": 8192
      of "high": 24576
      else: 0
    if budget > 0:
      gen["thinkingConfig"] = %*{"thinkingBudget": budget}
  elif effort.len > 0 and not modelId.startsWith("gemini-2.0") and
       not modelId.startsWith("gemini-1."):
    gen["thinkingConfig"] = %*{"thinkingLevel": effort}
  if gen.len > 0:
    inner["generationConfig"] = gen
  inner

proc geminiBody*(openAiBody: JsonNode): string =
  ## The native `generateContent` body: `geminiRequest` serialized, no
  ## envelope (the model rides in the URL, the key in the header).
  $geminiRequest(openAiBody)

proc codeAssistBody*(p: Profile, openAiBody: JsonNode, project: string): string =
  ## The Code Assist request: the same Gemini-native request wrapped in
  ## the reverse-engineered `{model, project, request}` envelope.
  $(%*{"model": p.model, "project": project,
       "request": geminiRequest(openAiBody)})

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
