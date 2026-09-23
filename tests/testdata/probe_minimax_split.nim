## Systematic MiniMax split probe.
##
## Goal: figure out what makes MiniMax honor `reasoning_split: true`
## (returning thinking in `delta.reasoning_details`) vs ignore it
## (leaking thinking as `<think>...</think>` inside `delta.content`).
## We hold the body shape constant and vary only the prompt.
##
## For each prompt we record:
## - whether reasoning_content / reasoning_details / <think> appeared
## - byte counts of each
## - server-side IDs (trace, alb, mm) so we can spot different infra

import std/[json, strformat, strutils, tables, algorithm]
import streamhttp

const
  # Set via the MINIMAX_API_KEY env var; the literal is left out of
  # source so committing this file never carries a live credential.
  ApiKey = "sk-cp-replace-me"
  BaseUrl = "api.minimax.io"
  Model = "MiniMax-M3"

# Each tuple is (label, prompt). Label is the short tag in the output.
# We want a spread:
# - trivial math
# - trivial with "think" trigger word
# - short definition
# - creative
# - explanation (multi-sentence)
# - multi-step reasoning task
let probes: seq[tuple[label, prompt: string]] = @[
  ("trivial-math",    "What is 7 * 8? Reply with one line."),
  ("trivial-think",   "What is 7 * 8? Think step by step."),
  ("short-defn",      "Define gravity in one sentence."),
  ("creative",        "Write a haiku about recursion."),
  ("explain",         "Explain in 2 paragraphs how a hash table works."),
  ("choose-explain",  "Pick a number between 10 and 20 and explain your choice in 3 sentences."),
  ("multi-step",      "List the first 5 primes and show why each is prime."),
  ("trivial-factual", "What is the capital of France? One word."),
]

type
  Stats = object
    label: string
    prompt: string
    rcBytes: int     # total bytes across all deltas in `reasoning_content`
    rdBytes: int     # total bytes across all deltas in `reasoning_details[*].text`
    thinkBytes: int  # total bytes that appeared inside a <think>...</think> span in `content`
    visibleBytes: int
    rcDeltas: int
    rdDeltas: int
    thinkSpans: int  # how many distinct <think> spans we saw
    trace: string
    alb: string
    mm: string
    session: string

proc buildBody(prompt: string): string =
  let j = %*{
    "model": Model,
    "stream": true,
    "temperature": 0.2,
    "max_tokens": 8192,
    "messages": [{"role": "user", "content": prompt}],
    "chat_template_kwargs": {"enable_thinking": true},
    "reasoning_split": true
  }
  result = $j

proc collect(prompt: string, s: var Stats) =
  let body = buildBody(prompt)
  var conn = connectTls(BaseUrl, timeoutMs = 60_000)
  try:
    conn.setReadTimeoutMs(120_000)
    conn.sendRequest("POST", "/v1/chat/completions", BaseUrl,
      headers = @[("Authorization", "Bearer " & ApiKey),
                  ("Content-Type", "application/json"),
                  ("Accept", "text/event-stream")],
      body = body)
    let resp = conn.readResponseHead()
    if resp.status != 200:
      echo "[", s.label, "] HTTP ", resp.status, " — aborting"
      return
    s.trace = resp.headers.getOrDefault("trace-id", "?")
    s.alb  = resp.headers.getOrDefault("alb_request_id", "?")
    s.mm   = resp.headers.getOrDefault("x-mm-request-id", "?")
    s.session = resp.headers.getOrDefault("x-session-id", "?")

    var inThink = false
    var thinkOpen = "<think>"
    var thinkClose = "</think>"
    while true:
      var line = ""
      if not conn.readLine(line): break
      if not line.startsWith("data: "): continue
      let payload = line["data: ".len .. ^1]
      if payload.strip == "[DONE]": break
      let j = try: parseJson(payload) except CatchableError: nil
      if j == nil: continue
      let choices = j{"choices"}
      if choices == nil or choices.kind != JArray or choices.len == 0: continue
      let delta = choices[0]{"delta"}
      if delta == nil: continue

      let rc = delta{"reasoning_content"}.getStr("")
      if rc.len > 0:
        s.rcBytes += rc.len
        s.rcDeltas += 1
      let rd = delta{"reasoning_details"}
      if rd != nil and rd.kind == JArray:
        for d in rd:
          if d.kind == JObject:
            let t = d{"text"}.getStr("")
            if t.len > 0:
              s.rdBytes += t.len
              s.rdDeltas += 1

      let c = delta{"content"}.getStr("")
      if c.len > 0:
        # Walk the content chunk, split out <think>...</think> spans.
        var i = 0
        while i < c.len:
          if not inThink:
            let idx = c.find(thinkOpen, i)
            if idx < 0:
              s.visibleBytes += c.len - i
              break
            s.visibleBytes += idx - i
            i = idx + thinkOpen.len
            inThink = true
            s.thinkSpans += 1
          else:
            let idx = c.find(thinkClose, i)
            if idx < 0:
              s.thinkBytes += c.len - i
              break
            s.thinkBytes += idx - i
            i = idx + thinkClose.len
            inThink = false
  finally:
    close(conn)

echo "label             rcB  rdB  thkB visB  rcD rdD spans  trace                                 mm"
echo "---------------------------------------------------------------------------------------------"

var allStats: seq[Stats]
for (label, prompt) in probes:
  var s = Stats(label: label, prompt: prompt)
  collect(prompt, s)
  echo &"{s.label:<17} {s.rcBytes:>4} {s.rdBytes:>4} {s.thinkBytes:>4} {s.visibleBytes:>4}  " &
       &"{s.rcDeltas:>3} {s.rdDeltas:>3} {s.thinkSpans:>3}  {s.trace[0..<min(32,s.trace.len)]:<32}  {s.mm}"
  allStats.add s

echo ""
echo "=== summary ==="
for s in allStats:
  let split = s.rcBytes + s.rdBytes > 0
  let leak  = s.thinkBytes > 0
  let mode = if split and leak: "BOTH (suspect double-count)"
             elif split: "split (reasoning_details/reasoning_content)"
             elif leak:  "leak (<think> in content)"
             else:        "NONE (no thinking at all)"
  echo &"{s.label:<17}  {mode}"
