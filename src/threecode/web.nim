## Web helpers: fetch a URL and return readable text, or run a DuckDuckGo
## search and return a compact list of hits. Both are exposed as `3code fetch`
## and `3code web` subcommands so the agent can invoke them from a bash block.
##
## No external binaries, no scripting runtimes — pure Nim httpclient + a
## hand-rolled HTML-to-text pass.

import std/[httpclient, strutils, uri, unicode, tables]
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

# ---------- DuckDuckGo search ----------

proc innerText(html: string, afterTagOpen: int, closeTag: string): string =
  # Slice from just after the opening tag to the matching closing tag, then
  # strip inner markup (DDG wraps query terms in <b>...</b>).
  let close = html.find(closeTag, afterTagOpen)
  let raw = if close < 0: html[afterTagOpen .. ^1]
            else: html[afterTagOpen ..< close]
  stripHtml(raw).replace("\n", " ").strip

proc parseDdgUrl(href: string): string =
  # href looks like "//duckduckgo.com/l/?uddg=<encoded>&rut=..." (with &amp;)
  let h = href.replace("&amp;", "&")
  let key = "uddg="
  let k = h.find(key)
  if k < 0:
    return (if h.startsWith("//"): "https:" & h else: h)
  let rest = h[k + key.len .. ^1]
  let amp = rest.find('&')
  let enc = if amp < 0: rest else: rest[0 ..< amp]
  try: decodeUrl(enc) except CatchableError: enc

proc parseSearchHits*(html: string): seq[SearchHit] =
  ## Extract result__a titles/urls and result__snippet text from DDG HTML.
  var i = 0
  while result.len < SearchResultCap:
    let aMark = html.find("class=\"result__a\"", i)
    if aMark < 0: break
    # find href attribute on this anchor (scan backwards to '<a' then forward)
    let tagStart = html.rfind('<', 0, aMark)
    if tagStart < 0: break
    let tagEnd = html.find('>', aMark)
    if tagEnd < 0: break
    let tag = html[tagStart .. tagEnd]
    var hit: SearchHit
    let hrefKey = "href=\""
    let hk = tag.find(hrefKey)
    if hk >= 0:
      let he = tag.find('"', hk + hrefKey.len)
      if he > 0:
        hit.url = parseDdgUrl(tag[hk + hrefKey.len ..< he])
    hit.title = innerText(html, tagEnd + 1, "</a>")
    # look for a snippet after this anchor, before the next result__a
    let nextA = html.find("class=\"result__a\"", tagEnd)
    let snipMark = html.find("class=\"result__snippet\"", tagEnd)
    if snipMark > 0 and (nextA < 0 or snipMark < nextA):
      let snipTagEnd = html.find('>', snipMark)
      if snipTagEnd > 0:
        hit.snippet = innerText(html, snipTagEnd + 1, "</a>")
    if hit.title.len > 0 or hit.url.len > 0:
      result.add hit
    i = tagEnd + 1

proc webSearch*(query: string): seq[SearchHit] =
  let client = newClient()
  defer: client.close()
  let url = "https://html.duckduckgo.com/html/?q=" & encodeUrl(query)
  let resp = client.get(url)
  if resp.code.int div 100 != 2:
    raise newException(IOError, "HTTP " & $resp.code & " searching")
  parseSearchHits(resp.body)

proc formatHits*(hits: seq[SearchHit]): string =
  if hits.len == 0: return "no results"
  var buf = ""
  for i, h in hits:
    buf.add $(i + 1) & ". " & h.title & "\n"
    if h.url.len > 0: buf.add "   " & h.url & "\n"
    if h.snippet.len > 0: buf.add "   " & h.snippet & "\n"
    buf.add "\n"
  buf.strip
