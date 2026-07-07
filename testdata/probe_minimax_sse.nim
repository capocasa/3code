## One-shot SSE probe for the MiniMax OpenAI-compatible endpoint.
## Sends the same body shape 3code sends (reasoning_split: true +
## chat_template_kwargs.enable_thinking: true) and prints every raw
## SSE data line so we can see what the model actually returns.
##
## Usage:
##   nim c -r -d:ssl testdata/probe_minimax_sse.nim

import std/[json, strformat, strutils, tables]
import streamhttp

const
  # Set via the MINIMAX_API_KEY env var; the literal is left out of
  # source so committing this file never carries a live credential.
  ApiKey = "sk-cp-replace-me"
  BaseUrl = "api.minimax.io"
  Model = "MiniMax-M3"

let tasks = @[
  "What is 7 * 8? Reply with one line.",
  "Pick a number between 10 and 20 and explain your choice in 3 sentences."
]

proc buildBody(prompt: string): string =
  ## Mirror of what applyMinimaxReasoning produces for the M3 family.
  let j = %*{
    "model": Model,
    "stream": true,
    "temperature": 0.2,
    "max_tokens": 8192,
    "messages": [
      {"role": "user", "content": prompt}
    ],
    "chat_template_kwargs": {"enable_thinking": true},
    "reasoning_split": true
  }
  result = $j

proc dump(conn: StreamConn) =
  while true:
    var line = ""
    if not conn.readLine(line): break
    if line.len == 0: continue
    if line.startsWith("data: "):
      let payload = line["data: ".len .. ^1]
      if payload.strip == "[DONE]":
        echo "[DONE]"
        break
      let j = try: parseJson(payload) except CatchableError: nil
      if j == nil:
        echo "RAW: ", payload
        continue
      let choices = j{"choices"}
      if choices == nil or choices.kind != JArray or choices.len == 0:
        echo "META: ", j
        continue
      let delta = choices[0]{"delta"}
      if delta == nil:
        echo "FINISH: ", choices[0]
        continue
      var bits: seq[string]
      if "content" in delta and delta["content"].getStr.len > 0:
        bits.add "content=\"" & delta["content"].getStr & "\""
      if "reasoning_content" in delta and delta["reasoning_content"].getStr.len > 0:
        bits.add "reasoning_content=\"" & delta["reasoning_content"].getStr & "\""
      if "reasoning" in delta and delta["reasoning"].getStr.len > 0:
        bits.add "reasoning=\"" & delta["reasoning"].getStr & "\""
      if "reasoning_details" in delta:
        bits.add "reasoning_details=" & $delta["reasoning_details"]
      if "finish_reason" in choices[0] and choices[0]["finish_reason"].kind == JString and
         choices[0]["finish_reason"].getStr.len > 0:
        bits.add "finish_reason=\"" & choices[0]["finish_reason"].getStr & "\""
      if bits.len == 0:
        bits.add "(empty delta)"
      echo bits.join(" | ")
    elif line.startsWith("event:"):
      echo "EVENT: ", line
    elif line.startsWith(":"):
      discard
    elif line.strip.len == 0:
      discard
    else:
      echo "META-LINE: ", line

proc runProbe(prompt: string) =
  echo "\n##### PROBE: ", prompt, " #####"
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
    echo "HTTP ", resp.status
    for k, v in tables.pairs(resp.headers): echo "  ", k, ": ", v
    if resp.status >= 400:
      var errBody = ""
      while true:
        var ln = ""
        if not conn.readLine(ln): break
        if ln.len == 0: break
        errBody.add ln & "\n"
      echo "ERROR BODY: ", errBody
      return
    dump(conn)
  finally:
    close(conn)

for task in tasks:
  runProbe(task)

echo "\n[probe done]"
