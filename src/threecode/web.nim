## Web helpers: fetch a URL and return readable text, or run an Exa
## search and return a compact list of hits. Exposed to the agent as native
## `web_search` and `web_fetch` tool calls (dispatched in actions.nim).
##
## No external binaries, no scripting runtimes, pure Nim httpclient + a
## hand-rolled HTML-to-text pass. The search backend is Exa's hosted MCP
## endpoint (keyless by default); it speaks a single stateless JSON-RPC
## call whose reply is one SSE frame.

import std/[httpclient, json, strutils, uri, unicode, tables]
import util

const UserAgent = "Mozilla/5.0 (X11; Linux x86_64) 3code/web"
const DefaultFetchCap = 20_000
const SearchResultCap = 10

type
  SearchHit* = object
    title*, url*, snippet*: string

proc newClient(): HttpClient =
  result = newHttpClient(timeout = 20_000, userAgent = UserAgent,
                         sslContext = bundledSslContext())
  result.headers = newHttpHeaders({
    "Accept": "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9"
  })

# ---------- HTML entity decoding ----------

const NamedEntities = {
  "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
  "nbsp": " ", "copy": "©", "reg": "®", "trade": "™",
  "hellip": "…", "mdash": "—", "ndash": "–",
  "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
  "laquo": "«", "raquo": "»", "middot": "·", "bull": "•",
  "deg": "°", "plusmn": "±", "times": "×", "divide": "÷",
  "euro": "€", "pound": "£", "yen": "¥", "cent": "¢"
}.toTable

proc decodeEntities*(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '&':
      let semi = s.find(';', i + 1)
      if semi > 0 and semi - i <= 10:
        let body = s[i+1 ..< semi]
        if body.len > 1 and body[0] == '#':
          try:
            let code =
              if body[1] in {'x', 'X'}: parseHexInt(body[2 .. ^1])
              else: parseInt(body[1 .. ^1])
            if code > 0 and code <= 0x10FFFF:
              result.add $Rune(code)
              i = semi + 1
              continue
          except ValueError: discard
        elif body in NamedEntities:
          result.add NamedEntities[body]
          i = semi + 1
          continue
      result.add s[i]
      inc i
    else:
      result.add s[i]
      inc i

# ---------- HTML to plain text ----------

const BlockTags = [
  "br", "p", "div", "li", "tr", "hr", "h1", "h2", "h3", "h4", "h5", "h6",
  "ul", "ol", "pre", "blockquote", "article", "section", "header", "footer",
  "nav", "aside", "main", "table", "thead", "tbody", "dt", "dd", "dl", "form"
]

proc stripHtml*(html: string): string =
  var raw = newStringOfCap(html.len)
  var i = 0
  while i < html.len:
    let c = html[i]
    if c == '<':
      if i + 3 < html.len and html[i+1] == '!' and html[i+2] == '-' and html[i+3] == '-':
        let k = html.find("-->", i + 4)
        i = if k < 0: html.len else: k + 3
        continue
      let j = html.find('>', i + 1)
      if j < 0:
        break
      var nameStart = i + 1
      if nameStart < j and html[nameStart] == '/': inc nameStart
      var nameEnd = nameStart
      while nameEnd < j and html[nameEnd] notin {' ', '\t', '\n', '/', '>'}:
        inc nameEnd
      let name = html[nameStart ..< nameEnd].toLowerAscii
      if name == "script" or name == "style":
        let close = "</" & name
        let k = html.find(close, j + 1)
        if k < 0:
          i = html.len
        else:
          let m = html.find('>', k)
          i = if m < 0: html.len else: m + 1
        continue
      if name in BlockTags:
        if raw.len > 0 and raw[^1] != '\n':
          raw.add '\n'
      i = j + 1
    else:
      raw.add c
      inc i
  let decoded = decodeEntities(raw)
  # per-line horizontal whitespace collapse + blank-line collapse
  var lines: seq[string]
  for ln in decoded.splitLines:
    var buf = newStringOfCap(ln.len)
    var prevSpace = false
    for ch in ln:
      if ch in {' ', '\t'}:
        if buf.len > 0 and not prevSpace:
          buf.add ' '
        prevSpace = true
      else:
        buf.add ch
        prevSpace = false
    lines.add buf.strip
  var out2: seq[string]
  var prevBlank = false
  for ln in lines:
    let blank = ln.len == 0
    if blank and prevBlank: continue
    out2.add ln
    prevBlank = blank
  result = out2.join("\n").strip

# ---------- Fetch ----------

proc fetchUrl*(url: string): string =
  let client = newClient()
  defer: client.close()
  let resp = client.get(url)
  if resp.code.int div 100 != 2:
    raise newException(IOError, "HTTP " & $resp.code & " fetching " & url)
  let ctype = resp.headers.getOrDefault("content-type").toString.toLowerAscii
  if "html" in ctype or "xml" in ctype:
    stripHtml(resp.body)
  elif ctype.startsWith("text/") or ctype.startsWith("application/json") or
       ctype.startsWith("application/javascript") or ctype == "":
    resp.body
  else:
    raise newException(IOError, "unsupported content-type: " & ctype)

proc capText*(s: string, cap = DefaultFetchCap): string =
  if s.len <= cap: return s
  let half = cap div 2
  s[0 ..< half] & "\n... [truncated " & $(s.len - cap) & " chars] ...\n" & s[^half .. ^1]

# ---------- Exa search ----------

proc extractSseData*(body: string): string =
  ## Return the substring after the first `data: ` line of an SSE stream.
  ## If there is no `data:` line, return the body unchanged (defensive
  ## against a future plain-JSON response).
  for ln in body.splitLines:
    if ln.startsWith("data: "):
      return ln[6 .. ^1]
    if ln.startsWith("data:"):
      return ln[5 .. ^1]
  body

proc parseExaText*(text: string): seq[SearchHit] =
  ## Exa returns `result.content[0].text` as a block of records separated by
  ## `\n---\n`. Each record begins with `Title: <t>` and `URL: <u>` lines,
  ## optionally has `Published:` / `Author:` lines, and then a `Highlights:`
  ## header followed by the body. We only rely on the `Title:` / `URL:` /
  ## `Highlights:` prefixes and the `---` separators.
  let records = text.split("\n---\n")
  for rec in records:
    if result.len >= SearchResultCap: break
    var hit: SearchHit
    var seenHigh = false
    var bodyLines: seq[string]
    for ln in rec.splitLines:
      if ln.startsWith("Title: "):
        hit.title = ln[7 .. ^1].strip
      elif ln.startsWith("URL: "):
        hit.url = ln[5 .. ^1].strip
      elif ln.strip == "Highlights:":
        seenHigh = true
      elif seenHigh:
        if ln.strip.len > 0: bodyLines.add ln.strip
    if hit.title.len == 0 and hit.url.len == 0: continue
    if bodyLines.len > 0:
      hit.snippet = bodyLines.join(" ")
    result.add hit

proc webSearch*(query: string; key = ""): seq[SearchHit] =
  ## POST a single JSON-RPC `tools/call` for `web_search_exa` to Exa's hosted
  ## MCP endpoint. Keyless by default; pass `key` to use a paid tier (it goes
  ## on the URL as `exaApiKey`). Raises `IOError` on non-2xx so callers
  ## wrapping us in `except CatchableError` keep working.
  let base =
    if key.len > 0:
      "https://mcp.exa.ai/mcp?exaApiKey=" & encodeUrl(key)
    else:
      "https://mcp.exa.ai/mcp"
  let body = $(%*{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "web_search_exa",
      "arguments": {
        "query": query,
        "numResults": SearchResultCap,
        "type": "auto"
      }
    }
  })
  let client = newHttpClient(timeout = 30_000, userAgent = UserAgent,
                             sslContext = bundledSslContext())
  defer: client.close()
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream"
  })
  let resp = client.post(base, body)
  if resp.code.int div 100 != 2:
    raise newException(IOError, "HTTP " & $resp.code & " searching")
  let data = extractSseData(resp.body)
  let j = try: parseJson(data) except CatchableError: nil
  if j == nil: return
  let txt = j{"result"}{"content"}{0}{"text"}.getStr("")
  if txt.len == 0: return
  parseExaText(txt)

proc formatHits*(hits: seq[SearchHit]): string =
  if hits.len == 0: return "no results"
  var buf = ""
  for i, h in hits:
    buf.add $(i + 1) & ". " & h.title & "\n"
    if h.url.len > 0: buf.add "   " & h.url & "\n"
    if h.snippet.len > 0: buf.add "   " & h.snippet & "\n"
    buf.add "\n"
  buf.strip
