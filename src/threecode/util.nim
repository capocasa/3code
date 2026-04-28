import std/[os, sequtils, strformat, strutils]

proc userConfigRoot*(): string =
  ## XDG config root for 3code: `~/.config/3code/` on Linux,
  ## `~/Library/Application Support/3code/` on macOS, `%APPDATA%/3code/`
  ## on Windows. Holds user-edited config and skill overrides only.
  getConfigDir() / "3code"

proc userDataRoot*(): string =
  ## XDG data root for 3code: `~/.local/share/3code/` on Linux,
  ## `~/Library/Application Support/3code/` on macOS, `%APPDATA%/3code/`
  ## on Windows (collapses with config-root there — fine, the split is
  ## a Linux convention). Holds app-managed state: sessions, history,
  ## extracted built-in skills.
  when defined(windows):
    getConfigDir() / "3code"
  elif defined(macosx):
    getConfigDir() / "3code"
  else:
    let xdg = getEnv("XDG_DATA_HOME")
    let base = if xdg.len > 0: xdg else: getHomeDir() / ".local" / "share"
    base / "3code"

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

proc detectMdHeader*(line: string): (bool, string) =
  ## A line of `###...` followed by a space and at least one non-space
  ## char. Returns (true, body) on match, (false, "") otherwise.
  var i = 0
  while i < line.len and line[i] == '#': inc i
  if i == 0 or i > 6: return (false, "")
  if i >= line.len or line[i] != ' ': return (false, "")
  let body = line[i + 1 .. ^1].strip
  if body.len == 0: return (false, "")
  (true, body)

proc isMdFenceLine*(line: string): bool =
  ## ```` ``` ```` (3+ backticks, optional language label after).
  let s = line.strip
  s.len >= 3 and s.startsWith("```")

proc applyInlineMd*(line: string): string =
  ## Strict in-line replacements for `**bold**` and `` `code` `` —
  ## emits ANSI codes that flip intensity within the agent text's
  ## `fgWhite + styleDim` envelope and revert to dim afterwards so
  ## the rest of the line stays in the off-white tone. Bold pops as
  ## bright white; inline code adds underline so it stays visually
  ## distinct from bold. Strict means: opening delimiter must be
  ## immediately followed by a non-space, closing delimiter must be
  ## immediately preceded by a non-space, and the inner span must
  ## contain no instance of the delimiter. Unmatched / malformed
  ## markers pass through verbatim.
  result = newStringOfCap(line.len + 32)
  var i = 0
  while i < line.len:
    if i + 1 < line.len and line[i] == '*' and line[i + 1] == '*':
      var j = i + 2
      var found = -1
      while j + 1 < line.len:
        if line[j] == '*' and line[j + 1] == '*':
          found = j; break
        inc j
      if found > i + 2:
        let inner = line[i + 2 ..< found]
        if inner[0] != ' ' and inner[^1] != ' ' and '*' notin inner:
          # Bold pops as bright cream so it stays within the LLM tone
          # family — bright white is reserved for user input.
          result.add "\x1b[22m\x1b[1m\x1b[33m" & inner &
                     "\x1b[22m\x1b[2m\x1b[37m"
          i = found + 2
          continue
    if line[i] == '`':
      var j = i + 1
      while j < line.len and line[j] != '`':
        inc j
      if j < line.len and j > i + 1:
        let inner = line[i + 1 ..< j]
        if inner[0] != ' ' and inner[^1] != ' ':
          # Inline code: bright cream + underline.
          result.add "\x1b[22m\x1b[1m\x1b[4m\x1b[33m" & inner &
                     "\x1b[24m\x1b[22m\x1b[2m\x1b[37m"
          i = j + 1
          continue
    result.add line[i]
    inc i

proc visibleWidth*(s: string): int =
  ## Count visible columns in a string that may contain ANSI CSI escape
  ## sequences (`\e[...<letter>`). UTF-8 multi-byte codepoints count as
  ## one column (a coarse approximation — wide CJK / emoji aren't given
  ## width 2; good enough for soft-wrap).
  var i = 0
  while i < s.len:
    if s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '[':
      i += 2
      while i < s.len and s[i] notin {'A'..'Z', 'a'..'z'}:
        inc i
      if i < s.len: inc i
      continue
    if (s[i].uint8 and 0xC0'u8) != 0x80'u8:
      inc result
    inc i

proc wrapAnsi*(s: string, width: int): seq[string] =
  ## Greedy word-wrap on whitespace; each chunk's visible width is at
  ## most `width`. ANSI CSI escape sequences pass through without
  ## counting toward width. Words longer than `width` overflow on their
  ## own line — terminal wrap takes them from there. Multiple inter-word
  ## spaces collapse to one.
  if width <= 0:
    result.add s
    return
  let words = s.split(' ').filterIt(it.len > 0)
  if words.len == 0:
    result.add s
    return
  var line = ""
  var lineW = 0
  for w in words:
    let wW = visibleWidth(w)
    if lineW == 0:
      line = w
      lineW = wW
    elif lineW + 1 + wW <= width:
      line.add ' '
      line.add w
      lineW += 1 + wW
    else:
      result.add line
      line = w
      lineW = wW
  if line.len > 0:
    result.add line

proc isMdTableRow*(line: string): bool =
  ## A markdown-table row both opens and closes with a `|`. Rejects
  ## bare prose that happens to contain a pipe.
  let s = line.strip
  s.len >= 2 and s[0] == '|' and s[^1] == '|'

proc parseMdRow(line: string): seq[string] =
  ## Split a `| a | b | c |` row into its trimmed cell values.
  var s = line.strip
  if s.len > 0 and s[0] == '|': s = s[1 .. ^1]
  if s.len > 0 and s[^1] == '|': s = s[0 ..< ^1]
  s.split('|').mapIt(it.strip)

proc isMdSepRow*(line: string): bool =
  ## Detect the `|---|:---:|---:|` alignment-separator row between
  ## header and body — its cells contain only `-`, `:`, and spaces.
  let cells = parseMdRow(line)
  if cells.len == 0: return false
  for c in cells:
    if c.len == 0: return false
    for ch in c:
      if ch notin {'-', ':', ' '}: return false
  true

proc renderMdTable*(rows: seq[string], indent = "  ", maxWidth = 0): string =
  ## Render a buffered markdown table as an aligned, box-drawn block.
  ## Each output line is prefixed with `indent` so the table sits in
  ## the harness's col-2 content area. Skips the alignment-separator
  ## row but uses it as the header/body divider when present.
  ##
  ## When `maxWidth > 0`, the natural column widths are compressed to
  ## fit `maxWidth` total columns: the widest column is shaved by one
  ## visible char at a time (cells get truncated with `…`) until the
  ## row fits, never going below a per-column minimum of 4. If even
  ## that minimum doesn't fit (too many columns), the table degrades
  ## to a vertical `label: value` rendering — readable, no overflow,
  ## but loses the grid.
  if rows.len == 0: return ""
  let parsed = rows.mapIt(parseMdRow(it))
  var nCols = 0
  for r in parsed:
    if r.len > nCols: nCols = r.len
  if nCols == 0:
    return rows.mapIt(indent & it).join("\n") & "\n"
  var headerRow: seq[string]
  var bodyRows: seq[seq[string]]
  var sawSep = false
  for i, r in parsed:
    var padded = r
    while padded.len < nCols: padded.add ""
    if i == 0:
      headerRow = padded
    elif not sawSep and isMdSepRow(rows[i]):
      sawSep = true
    else:
      bodyRows.add padded
  var widths = newSeq[int](nCols)
  for j, c in headerRow: widths[j] = max(widths[j], visibleWidth(c))
  for r in bodyRows:
    for j, c in r:
      widths[j] = max(widths[j], visibleWidth(c))
  let indentLen = visibleWidth(indent)
  let chrome = 1 + 3 * nCols       # leading │ + (` cell ` + │) per col
  const MinCol = 4
  proc widthsTotal(ws: seq[int]): int =
    for w in ws: result += w
  if maxWidth > 0:
    let minLine = indentLen + chrome + nCols * MinCol
    if minLine > maxWidth:
      # Too many columns to render even at minimum width. Fall back to
      # a vertical record list — one `label: value` line per cell,
      # blank line between records.
      var fb = ""
      for r in bodyRows:
        for j, c in r:
          let label = if j < headerRow.len and headerRow[j].len > 0:
                        headerRow[j]
                      else: $j
          fb.add indent & label & ": " & c & "\n"
        fb.add "\n"
      return fb
    let avail = maxWidth - indentLen - chrome
    while widthsTotal(widths) > avail:
      var maxIdx = 0
      for j in 1 ..< nCols:
        if widths[j] > widths[maxIdx]: maxIdx = j
      if widths[maxIdx] <= MinCol: break
      widths[maxIdx] -= 1
  proc trunc(s: string, w: int): string =
    ## Markdown-balanced cutoff. Walks the cell tracking open `**`
    ## and `` ` `` spans; when the visible budget runs out, falls
    ## back to the last position where every span was closed so we
    ## never leave a dangling `**bold` (instead emits `**bold**` or
    ## drops the span entirely, whichever fits).
    if visibleWidth(s) <= w: return s
    if w <= 0: return ""
    if w == 1: return "…"
    let target = w - 1  # reserve one column for the `…` marker
    var i = 0
    var visible = 0
    var lastBalanced = 0
    var openStar = false
    var openTick = false
    while i < s.len and visible < target:
      if i + 1 < s.len and s[i] == '*' and s[i + 1] == '*':
        openStar = not openStar
        i += 2
        visible += 2
      elif s[i] == '`':
        openTick = not openTick
        inc i
        inc visible
      else:
        if (s[i].uint8 and 0xC0'u8) != 0x80'u8:
          inc visible
        inc i
      if not openStar and not openTick:
        lastBalanced = i
    let cut = if openStar or openTick: lastBalanced else: i
    s[0 ..< cut] & "…"
  proc rowStr(r: seq[string]): string =
    var cells: seq[string]
    for j, c in r:
      let t = trunc(c, widths[j])
      let pad = widths[j] - visibleWidth(t)
      cells.add t & " ".repeat(max(0, pad))
    indent & "│ " & cells.join(" │ ") & " │"
  proc sepStr(left, mid, right: string): string =
    var bars: seq[string]
    for w in widths: bars.add "─".repeat(w + 2)
    indent & left & bars.join(mid) & right
  result = ""
  result.add sepStr("┌", "┬", "┐") & "\n"
  result.add rowStr(headerRow) & "\n"
  result.add sepStr("├", "┼", "┤") & "\n"
  for r in bodyRows: result.add rowStr(r) & "\n"
  result.add sepStr("└", "┴", "┘") & "\n"

proc tokenSlot*(icon: string, n: int): string =
  ## "icon value" with a single space between — icon hugs its number.
  ## Slots are joined with extra spacing for visual separation
  ## (no `·`). Always renders the actual value, including 0 — callers
  ## that need a placeholder for "not yet known" (e.g. the spinner's
  ## ↑/↺ before the response closes) build the dashed form themselves.
  icon & " " & humanTokens(n)

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
