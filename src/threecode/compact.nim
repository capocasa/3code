## Context management: when the conversation approaches the model's context
## window, older turns are collapsed into a single synthetic recap via a
## meta-call to the same model (with a dedicated terse system prompt). That
## recap replaces everything except the system prompt and the last
## `SummarizeKeepRecent` messages. Summarization is lossy and expensive, so
## it runs at most once per turn, only when the context crosses the
## threshold.

import std/[httpclient, json, strutils]
import util
import types
import prompts

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
  elif "qwen" in m: 128_000
  elif "claude" in m: 200_000
  elif "gpt-5" in m: 400_000
  elif "gpt-4" in m: 128_000
  elif "o1" in m or "o3" in m or "o4" in m: 200_000
  elif "deepseek" in m: 128_000
  elif "gemini" in m: 1_000_000
  elif "llama" in m: 128_000
  elif "glm-5.2" in m: 1_000_000
  elif "glm" in m: 200_000
  elif "mistral" in m or "mixtral" in m: 128_000
  elif "minimax-m3" in m: 1_000_000
  elif "minimax" in m: 204_800
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
  let body = %*{
    "model": p.model,
    "messages": payload,
    "max_tokens": SummarizeMaxTokens,
    "stream": false
  }
  var status = 0
  var respBody = ""
  try:
    let client = newHttpClient(timeout = 120_000, userAgent = "3code",
                               sslContext = bundledSslContext())
    defer: client.close()
    client.headers["Authorization"] = "Bearer " & p.key
    client.headers["Content-Type"] = "application/json"
    let resp = client.request(p.url & "/chat/completions",
                              httpMethod = HttpPost, body = sanitizeUtf8($body))
    status = resp.code.int
    respBody = resp.body
  except CatchableError as e:
    stderr.writeLine "3code: summarize: " & e.msg
    return ""
  if status != 200:
    stderr.writeLine "3code: summarize: api " & $status
    return ""
  let j = try: parseJson(respBody)
          except CatchableError as e:
            stderr.writeLine "3code: summarize: " & e.msg
            return ""
  if "error" in j:
    stderr.writeLine "3code: summarize: " & $j["error"]
    return ""
  let choices = j{"choices"}
  if choices == nil or choices.kind != JArray or choices.len == 0: return ""
  let msg = choices[0]{"message"}
  if msg == nil or msg.kind != JObject: return ""
  msg{"content"}.getStr("")

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
