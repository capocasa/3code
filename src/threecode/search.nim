## Full-text search over saved `.3log` transcripts.
##
## The scan is grep-shaped: read the file, lowercase it once, blank out
## header lines (they are 3log formatting, not content; otherwise every
## session matches its own role names and cwd path), and count substring
## occurrences through libc `memmem` (Nim's `strutils.find` routes there
## on the C backend). No record tree is ever built.
##
## Matching is ASCII-case-insensitive and whitespace-agnostic: a phrase
## term matches with any run of one or more whitespace characters between
## its words, so line breaks and arbitrary indentation never break it.
## Offsets stay in raw-file coordinates the whole way, which is what makes
## snippets a cheap re-walk of the lines a match spans.
##
## Results rank by total term frequency, ties broken newest-first (callers
## pass paths newest-first and the scan order is kept).

import std/[algorithm, strutils]

const WsChars = {' ', '\t', '\r', '\x0b', '\x0c'}
  ## Horizontal whitespace that can separate phrase words. '\n' is added
  ## locally where line geometry allows it.

let SessionWord = "session"  # `let`, not `const`: equalMem needs its address

type
  SearchHit* = object
    path*: string
    cwd*: string   ## cwd recorded in the newest `session` header, "" if none
    name*: string  ## `:rename` label (the session record's body), "" if none
    score*: int    ## total occurrences of all terms
    pos*: int      ## first match start, in raw-file byte coordinates
    mlen*: int     ## raw bytes from match start to the end of its last word
    order*: int    ## scan index; ties in score keep newest-first

func lineIsHeader(s: int32): bool = s < 0

func lineOff(s: int32): int =
  if s < 0: -int(s) - 1 else: int(s)

proc appendCollapsed*(buf: var string, line: string) =
  ## Append `line` to `buf` with every whitespace run collapsed to one
  ## space, seam-aware against `buf`'s last byte. Snippet display only;
  ## the hot path never collapses anything.
  var prevSpace = buf.len > 0 and buf[^1] in WsChars
  for c in line:
    if c in WsChars:
      if not prevSpace:
        buf.add ' '
        prevSpace = true
    else:
      buf.add c
      prevSpace = false

proc normalizeTerm*(s: string): string =
  ## Lowercase + whitespace-collapse a search term. A phrase given as one
  ## argument ("like this", `foo\ bar`) becomes `like this`, which the
  ## matcher treats as words separated by any whitespace run.
  var buf: string
  appendCollapsed(buf, s.toLowerAscii)
  if buf.len > 0 and buf[^1] == ' ': buf.setLen buf.len - 1
  if buf.len > 0 and buf[0] == ' ': buf = buf[1 .. ^1]
  buf

type
  FileMap* = object
    low*: string        ## lowered raw text, header lines blanked to spaces
    lineStart*: seq[int32] ## per line: start offset, negated-1 for headers
    cwd*: string
    name*: string  ## the `session` record's body (the `:rename` label),
                   ## taken from the raw text before blanking

proc mapString*(text: string): FileMap =
  ## One lowered copy plus per-line geometry. Header lines (column-0
  ## non-whitespace: roles with their args, `~~` terminators) are blanked
  ## so they can never match; `cwd` is pulled from the newest `session`
  ## header before blanking (last one wins, like `previewSession`), and
  ## the `:rename` name from the body line right under that header — it
  ## stays searchable content, the copy is only for the hit list.
  result.low = text.toLowerAscii
  var off = 0
  # Set right after a `session` header: the name rides that record's body,
  # so the immediately following indented line IS the name (an immediate
  # blank or another header cancels the want). Searched like any content,
  # but surfaced next to the id in the hit list.
  var wantName = false
  while off <= result.low.len:
    var lineEnd = result.low.len
    let nl = result.low.find('\n', off)
    if nl >= 0: lineEnd = nl
    let lineLen = lineEnd - off
    if lineLen > 0 and result.low[off] notin {' ', '\t'}:
      result.lineStart.add -int32(off + 1)
      wantName = false
      if lineLen >= 7 and (lineLen == 7 or result.low[off + 7] == ' ') and
          equalMem(addr result.low[off], unsafeAddr SessionWord[0], 7):
        for part in text[off ..< lineEnd].split(' '):
          if part.len > 4 and part.startsWith("cwd="):
            result.cwd = part[4 .. ^1]
        wantName = true
      for i in off ..< lineEnd: result.low[i] = ' '
    else:
      result.lineStart.add int32(off)
      if wantName:
        wantName = false
        if lineLen > 0: result.name = text[off ..< lineEnd].strip
    if nl < 0: break
    off = nl + 1

proc mapFile*(path: string): FileMap =
  ## `mapString` over a file on disk; unreadable files map to empty.
  let raw = try: readFile(path) except CatchableError: return
  mapString(raw)

proc phraseLen*(low: string, words: seq[string], at: int): int =
  ## Length of a phrase match starting at `at` (where `words[0]` already
  ## sits), or -1. Between words: at least one whitespace char, then skip
  ## the whole run. Blanked header lines are spaces, so a phrase may
  ## legitimately match across a record boundary.
  const allWs = WsChars + {'\n'}
  var p = at + words[0].len
  for w in words[1 .. ^1]:
    if p >= low.len or low[p] notin allWs: return -1
    while p < low.len and low[p] in allWs: inc p
    if p + w.len > low.len: return -1
    if not equalMem(addr low[p], unsafeAddr w[0], w.len): return -1
    inc p, w.len
  p - at

proc countTerm*(low: string, words: seq[string]): tuple[count, first, firstLen: int] =
  ## Non-overlapping occurrences of one term. Single words are plain
  ## memmem; phrases verify candidate first-word hits in place.
  result.first = -1
  let w0 = words[0]
  var i = 0
  while i <= low.len:
    let at = low.find(w0, i)
    if at < 0: break
    var l = w0.len
    if words.len > 1:
      l = phraseLen(low, words, at)
      if l < 0:
        i = at + 1
        continue
    inc result.count
    if result.first < 0:
      result.first = at
      result.firstLen = l
    i = at + l
    if i >= low.len: break

proc searchSessions*(paths: seq[string], terms: seq[string]): seq[SearchHit] =
  ## Every session under `paths` (expected newest-first) containing any
  ## term, ranked by total term frequency, ties newest-first. `terms` must
  ## already be normalized (`normalizeTerm`); empty terms are ignored.
  var parsed: seq[seq[string]]
  for t in terms:
    if t.len > 0: parsed.add t.split(' ')
  var order = 0
  for p in paths:
    inc order
    let m = mapFile(p)
    if m.low.len == 0: continue
    var hit = SearchHit(path: p, cwd: m.cwd, name: m.name, order: order)
    for words in parsed:
      let (n, first, firstLen) = countTerm(m.low, words)
      if n == 0: continue
      hit.score += n
      if hit.mlen == 0 or first < hit.pos:
        hit.pos = first
        hit.mlen = firstLen
    if hit.score > 0: result.add hit
  proc cmpHits(a, b: SearchHit): int =
    if a.score != b.score: b.score - a.score
    else: a.order - b.order
  if result.len > 1: result.sort(cmpHits)

proc hitSnippet*(h: SearchHit, width: int): string =
  ## Display snippet around the hit's first match, 3log formatting
  ## stripped. Re-reads the file and walks only the lines the match
  ## spans; undisplayed hits never pay for this.
  let raw = try: readFile(h.path) except CatchableError: return ""
  if h.pos >= raw.len: return ""
  var lineStart: seq[int32]
  var off = 0
  while off <= raw.len:
    var lineEnd = raw.len
    let nl = raw.find('\n', off)
    if nl >= 0: lineEnd = nl
    if lineEnd - off > 0 and raw[off] notin {' ', '\t'}:
      lineStart.add -int32(off + 1)
    else:
      lineStart.add int32(off)
    if nl < 0: break
    off = nl + 1
  let endPos = min(h.pos + h.mlen - 1, raw.len - 1)
  var first = -1
  var last = -1
  for i, s in lineStart:
    if lineOff(s) <= h.pos: first = i
    else: break
  for i in first ..< lineStart.len:
    if i < 0: continue
    if lineOff(lineStart[i]) <= endPos: last = i
    else: break
  if first < 0 or last < 0: return ""
  # Join the span's body lines into display text; count the collapsed
  # prefix of the match line byte-for-byte with the same rule so the
  # snippet window centers on the match itself.
  var ctx: string
  var ctxOff = -1
  for i in first .. last:
    let s = lineOff(lineStart[i])
    var e = raw.len
    let nl = raw.find('\n', s)
    if nl >= 0: e = nl
    let content =
      if e - s >= 2 and raw[s] == ' ' and raw[s + 1] == ' ': raw[s + 2 ..< e]
      else: raw[s ..< e]
    if lineIsHeader(lineStart[i]): continue
    if i == first and h.pos >= s:
      let dedent = if content.len < e - s: 2 else: 0
      let upto = min(h.pos - s - dedent, content.len)
      var prevSpace = ctx.len > 0 and ctx[^1] in WsChars
      for j in 0 ..< upto:
        let c = content[j]
        if c in WsChars:
          if not prevSpace:
            ctx.add ' '
            prevSpace = true
        else:
          ctx.add c
          prevSpace = false
      ctxOff = ctx.len
      appendCollapsed(ctx, content[upto .. ^1])
    else:
      appendCollapsed(ctx, content)
  if ctx.len > 0 and ctx[^1] == ' ': ctx.setLen ctx.len - 1
  if ctx.len > 0 and ctx[0] == ' ': ctx = ctx[1 .. ^1]
  if ctxOff < 0: ctxOff = 0
  elif ctxOff > 0 and ctx[0] == ' ': dec ctxOff  # leading indent collapsed above
  var s0 = 0
  if ctxOff > 12:
    s0 = ctxOff - 12
    while s0 < ctxOff and ctx[s0] != ' ': inc s0  # snap to a word start
    if s0 >= ctxOff: s0 = 0  # one very long word: window from the top
  result = ctx[s0 ..< min(ctx.len, s0 + width)]
  if s0 > 0: result = "…" & result
  if s0 + width < ctx.len: result &= "…"
