import std/[os, strformat, strutils]

proc resolvePath*(path: string): string =
  if path.len == 0: return ""
  var p = path
  if p.startsWith("~"): p = expandTilde(p)
  try: absolutePath(p) except CatchableError: p

proc utf8ByteCut*(s: string, n: int): string =
  ## Slice `s` to at most `n` bytes, backing up to a UTF-8 codepoint
  ## boundary so the result is valid UTF-8. Strings in JSON request bodies
  ## must be valid UTF-8 — Pydantic-backed providers (deepinfra) reject
  ## the body with "There was an error parsing the body" when a naive byte
  ## slice splits a multi-byte rune (e.g. `→` chopped after two bytes).
  if s.len <= n: return s
  var cut = n
  while cut > 0 and (s[cut].uint8 and 0xC0'u8) == 0x80'u8:
    dec cut
  s[0 ..< cut]

proc utf8ByteCutEnd*(s: string, n: int): string =
  ## Take the last up-to-`n` bytes of `s`, advancing past any leading UTF-8
  ## continuation byte so the result is valid UTF-8. Mirror of `utf8ByteCut`
  ## for tail slices (used by `clipMiddle`).
  if s.len <= n: return s
  var start = s.len - n
  while start < s.len and (s[start].uint8 and 0xC0'u8) == 0x80'u8:
    inc start
  s[start .. ^1]

proc clipMiddle*(s: string, head, tail: int): string =
  if s.len <= head + tail: s
  else: utf8ByteCut(s, head) & "\n... [truncated] ...\n" & utf8ByteCutEnd(s, tail)

proc humanBytes*(n: int): string =
  if n < 1024: &"{n}B"
  elif n < 1024 * 1024: &"{n.float/1024:.1f}KB"
  else: &"{n.float/1024/1024:.2f}MB"

proc humanTokens*(n: int): string =
  if n < 1000: $n
  else: &"{n.float/1000:.1f}k"

proc collapseHome*(path: string): string =
  ## Collapse the user's home dir prefix to `~/`. Guards against the
  ## `getHomeDir()` trailing-slash footgun that produced things like
  ## `~e/hellodeepseek` for `/home/carlo/e/hellodeepseek`.
  let home = getHomeDir()
  if home.len == 0 or not path.startsWith(home):
    return path
  var rel = path[home.len .. ^1]
  while rel.startsWith("/"): rel = rel[1 .. ^1]
  if rel.len == 0: "~" else: "~/" & rel

proc replaceFirst*(s, needle, repl: string): (string, bool) =
  let idx = s.find(needle)
  if idx < 0: return (s, false)
  (s[0 ..< idx] & repl & s[idx + needle.len .. ^1], true)

proc looksLikePath*(s: string): bool =
  ## Heuristic for the path-on-its-own-line preceding a write/patch fence in
  ## text mode. Rejects prose (whitespace inside, fence markers, headings).
  ## Accepts anything containing `/` or `.` — paths typically have one.
  let t = s.strip
  if t.len == 0 or t.len > 200: return false
  if ' ' in t or '\t' in t: return false
  if t.startsWith("```") or t.startsWith("#"): return false
  '/' in t or '.' in t

proc levenshtein*(a, b: string): int =
  if a.len == 0: return b.len
  if b.len == 0: return a.len
  var prev = newSeq[int](b.len + 1)
  var curr = newSeq[int](b.len + 1)
  for j in 0 .. b.len: prev[j] = j
  for i in 1 .. a.len:
    curr[0] = i
    for j in 1 .. b.len:
      let cost = if a[i-1] == b[j-1]: 0 else: 1
      curr[j] = min(min(curr[j-1] + 1, prev[j] + 1), prev[j-1] + cost)
    swap(prev, curr)
  prev[b.len]

proc levenshteinCapped*(a, b: string, cap: int): int =
  ## Standard edit distance with an early cutoff: returns `cap+1` once the
  ## minimum row value exceeds `cap`. Cap keeps the cost linear-ish for the
  ## "compare against every file line" use case.
  if a.len == 0: return b.len
  if b.len == 0: return a.len
  if abs(a.len - b.len) > cap: return cap + 1
  var prev = newSeq[int](b.len + 1)
  var curr = newSeq[int](b.len + 1)
  for j in 0 .. b.len: prev[j] = j
  for i in 1 .. a.len:
    curr[0] = i
    var rowMin = curr[0]
    for j in 1 .. b.len:
      let cost = if a[i-1] == b[j-1]: 0 else: 1
      curr[j] = min(min(curr[j-1] + 1, prev[j] + 1), prev[j-1] + cost)
      if curr[j] < rowMin: rowMin = curr[j]
    if rowMin > cap: return cap + 1
    swap(prev, curr)
  prev[b.len]
