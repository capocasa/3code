import std/[net, os, sequtils, strformat, strutils]

proc bundledCaFile*(): string =
  ## Path to the `cacert.pem` we ship alongside the binary on macOS /
  ## Windows (see `release.yml`). Returns "" when not present (Linux
  ## release tarball, dev builds) — `newContext` will scan default
  ## system cert locations in that case, which works on every Linux
  ## distro.
  when defined(macosx) or defined(windows):
    let p = parentDir(getAppFilename()) / "cacert.pem"
    if fileExists(p): p else: ""
  else:
    ""

proc bundledSslContext*(): SslContext =
  ## Drop-in `SslContext` for `newHttpClient(sslContext = ...)` and
  ## anywhere else a TLS context is consumed. macOS/Windows ship
  ## OpenSSL whose `OPENSSLDIR` is baked to a build-runner path that
  ## doesn't exist on user systems, so `verifyMode = CVerifyPeer`
  ## can't scan the default location — we feed `cacert.pem` from
  ## next to the binary. Linux passes `caFile = ""` and falls
  ## through to the system trust store. The `streamhttp` SSE path
  ## takes `bundledCaFile()` directly (it builds its own context
  ## internally), so the bundle wiring lives in one place either way.
  newContext(verifyMode = CVerifyPeer, caFile = bundledCaFile())

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

const MarkBoundary = {' ', '\t', '\n', '.', ',', '!', '?', ';', ':',
                      '(', ')', '[', ']', '{', '}', '"', '\'', '/', '<', '>'}

proc isAtBoundary(line: string, i: int): bool =
  ## True if `line[i]` is whitespace/punctuation, OR `i` is out of
  ## bounds (start/end of line). Used to guard italic markers so
  ## `snake_case` and `5*5` don't accidentally italicize.
  i < 0 or i >= line.len or line[i] in MarkBoundary

proc applyInlineMd*(line: string): string =
  ## Strict in-line replacements for `***bold-italic***`, `**bold**`,
  ## `*italic*`/`_italic_`, and `` `code` ``. Emits ANSI within the
  ## agent text's `fgWhite + styleDim` envelope and reverts afterwards
  ## so the rest of the line stays in the off-white tone.
  ## Bold and inline code: `\x1b[1m` (bold/bright). Italic: `\x1b[3m`
  ## plus `\x1b[4m` so it shows on terminals whose monospace font
  ## lacks an italic face (italic alone would be invisible there).
  ## Strict matching: opening delimiter must be immediately followed
  ## by a non-space, closing delimiter immediately preceded by a
  ## non-space, and the inner span must not contain the delimiter.
  ## Italic additionally requires whitespace/punctuation flanking on
  ## the outside, so `snake_case` and `5*5` survive untouched.
  ## Unmatched / malformed markers pass through verbatim.
  result = newStringOfCap(line.len + 32)
  var i = 0
  while i < line.len:
    if i + 2 < line.len and line[i] == '*' and line[i + 1] == '*' and line[i + 2] == '*':
      # `***text***` — bold + italic. Find a closing `***` triplet.
      var j = i + 3
      var found = -1
      while j + 2 < line.len:
        if line[j] == '*' and line[j + 1] == '*' and line[j + 2] == '*':
          found = j; break
        inc j
      if found > i + 3:
        let inner = line[i + 3 ..< found]
        if inner[0] != ' ' and inner[^1] != ' ' and '*' notin inner:
          result.add "\x1b[22m\x1b[1m\x1b[3m\x1b[4m" & applyInlineMd(inner) &
                     "\x1b[24m\x1b[23m\x1b[22m\x1b[2m"
          i = found + 3
          continue
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
          # Bold: real bold (bright). Sits inside the dim envelope and
          # pops out of it. No color change, asterisks dropped. Recurse
          # so nested italic/code inside (e.g. `**_lazy_**`) renders.
          result.add "\x1b[22m\x1b[1m" & applyInlineMd(inner) & "\x1b[22m\x1b[2m"
          i = found + 2
          continue
    if line[i] == '*' and isAtBoundary(line, i - 1):
      # Single `*italic*`. Skip past any `**` sequences while looking
      # for the matching closing `*` so a nested bold doesn't terminate
      # us early. Closing `*` must be followed by a boundary char.
      var j = i + 1
      var found = -1
      while j < line.len:
        if line[j] == '*':
          if j + 1 < line.len and line[j + 1] == '*':
            j += 2
            continue
          if isAtBoundary(line, j + 1):
            found = j
            break
        inc j
      if found > i + 1:
        let inner = line[i + 1 ..< found]
        if inner.len > 0 and inner[0] != ' ' and inner[^1] != ' ' and '*' notin inner:
          # Italic + underline together: italic ANSI alone is invisible
          # on terminals whose monospace font lacks an italic face;
          # underline is universally rendered, so the combo gives a
          # visible cue everywhere while the italic shows for terminals
          # that do support it.
          result.add "\x1b[3m\x1b[4m" & applyInlineMd(inner) & "\x1b[24m\x1b[23m"
          i = found + 1
          continue
    if line[i] == '_' and isAtBoundary(line, i - 1):
      var j = i + 1
      while j < line.len and line[j] != '_':
        inc j
      if j < line.len and j > i + 1 and isAtBoundary(line, j + 1):
        let inner = line[i + 1 ..< j]
        if inner.len > 0 and inner[0] != ' ' and inner[^1] != ' ' and '_' notin inner:
          result.add "\x1b[3m\x1b[4m" & applyInlineMd(inner) & "\x1b[24m\x1b[23m"
          i = j + 1
          continue
    if line[i] == '`':
      var j = i + 1
      while j < line.len and line[j] != '`':
        inc j
      if j < line.len and j > i + 1:
        let inner = line[i + 1 ..< j]
        if inner[0] != ' ' and inner[^1] != ' ':
          # Inline code: bold weight, no color shift.
          result.add "\x1b[22m\x1b[1m" & inner & "\x1b[22m\x1b[2m"
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
  ## visible char at a time until the row fits, never going below a
  ## per-column minimum of `MinCol`. Cells longer than their column
  ## are word-wrapped across multiple visual lines so the row stays
  ## readable. If even `MinCol` per column doesn't fit (too many
  ## columns for the terminal), the table degrades to a vertical
  ## `label: value` rendering: readable, no overflow, but loses the
  ## grid.
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
    # Apply inline markdown to each cell up front: `**bold**` and
    # `` `code` `` get ANSI styling applied (same as paragraph text),
    # marker characters dropped. Width math from here on uses
    # `visibleWidth` so the ANSI escapes don't inflate column widths.
    for j in 0 ..< padded.len:
      padded[j] = applyInlineMd(padded[j])
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
  const MinCol = 16
  proc widthsTotal(ws: seq[int]): int =
    for w in ws: result += w
  if maxWidth > 0:
    let minLine = indentLen + chrome + nCols * MinCol
    if minLine > maxWidth:
      # Too many columns to render even at minimum width. Fall back to
      # a vertical record list: one `label: value` line per cell,
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
  proc rowStr(r: seq[string]): string =
    ## Render a row across as many visual lines as the tallest wrapped
    ## cell needs. Each cell wraps via `wrapAnsi`; cells with fewer
    ## lines pad with blanks so the right border stays aligned.
    var cellLines = newSeq[seq[string]](nCols)
    var maxLines = 1
    for j in 0 ..< nCols:
      let c = if j < r.len: r[j] else: ""
      var lines = wrapAnsi(c, widths[j])
      if lines.len == 0: lines = @[""]
      cellLines[j] = lines
      if lines.len > maxLines: maxLines = lines.len
    var visualRows: seq[string]
    for k in 0 ..< maxLines:
      var cells: seq[string]
      for j in 0 ..< nCols:
        let txt = if k < cellLines[j].len: cellLines[j][k] else: ""
        let pad = widths[j] - visibleWidth(txt)
        cells.add txt & " ".repeat(max(0, pad))
      visualRows.add indent & "│ " & cells.join(" │ ") & " │"
    visualRows.join("\n")
  proc sepStr(left, mid, right: string): string =
    var bars: seq[string]
    for w in widths: bars.add "─".repeat(w + 2)
    indent & left & bars.join(mid) & right
  result = ""
  result.add sepStr("┌", "┬", "┐") & "\n"
  result.add rowStr(headerRow) & "\n"
  result.add sepStr("├", "┼", "┤") & "\n"
  for i, r in bodyRows:
    if i > 0:
      result.add sepStr("├", "┼", "┤") & "\n"
    result.add rowStr(r) & "\n"
  result.add sepStr("└", "┴", "┘") & "\n"

proc tokenSlot*(icon: string, n: int): string =
  ## "iconvalue" — no space between glyph and number. Slots are joined
  ## with two spaces for visual separation. Always renders the actual
  ## value, including 0.
  icon & humanTokens(n)

proc stripPreamble*(s: string): string =
  ## Strip `<session_context>...</session_context>` and
  ## `<project_notes>...</project_notes>` blocks from a stored user
  ## message so the replay UI shows the prompt the user typed, not the
  ## auto-injected context the model needs. Only acts on a leading
  ## block (`s.strip` starts with `<session_context>`); leaves the
  ## string alone if either tag appears mid-message — that would be the
  ## user's own text, not our preamble.
  if not s.strip.startsWith("<session_context>"): return s
  result = s
  for tag in ["session_context", "project_notes"]:
    let openTag = "<" & tag & ">"
    let closeTag = "</" & tag & ">"
    let i = result.find(openTag)
    if i < 0: continue
    let j = result.find(closeTag, i + openTag.len)
    if j < 0: continue
    result = result[0 ..< i] & result[j + closeTag.len .. ^1]
  result = result.strip

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
