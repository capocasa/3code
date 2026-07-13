import std/[net, os, sequtils, strformat, strutils, tables, unicode, times]
import types
import threecode/unicodewidth
when defined(posix):
  import std/posix except Time
  import std/termios

# ---------- Color palette ----------
#
# Three-tier palette designed to read on both light and dark terminal
# backgrounds. We don't set a background color (bad form, fights the
# user's terminal config, leaks seams in scrollback, breaks tmux /
# transparent terms). Cyan is the brand tone and is mode-independent;
# grey 244 (dark) is the muted FYI tone.
#
# The white-family colors (`BrightWhiteFg`, `OffWhiteFg`, `GreyFg`) are
# mode-dependent: `applyPalette(colorMode)` resolves them at startup.
# Dark defaults reproduce the prior behaviour; light inverts the family
# (white -> black, off-white -> dark grey, dim white -> lighter dark
# grey). Colourful colors (cyan/green/red/magenta) stay fixed in both
# modes. See `applyPalette` / `applyColorOverrides` / `detectColorMode`.

const
  # Windows Terminal maps ANSI cyan (\e[36m) to a light blue, not cyan.
  # Use bright cyan there so the brand tone renders as actual cyan.
  # Campbell's bright cyan slot is the only one that is true cyan.
  CyanFg* = (when defined(windows): "\x1b[96m" else: "\x1b[36m")
  BoldOn* = "\x1b[1m"
  BlueFg* = "\x1b[34m"
  Reset* = "\x1b[0m"

var
  BrightWhiteFg* = "\x1b[97m"      # assistant text + `:command` help tokens
  OffWhiteFg* = "\x1b[38;5;252m"   # high-tier near-white (tool banners)
  GreyFg* = "\x1b[38;5;244m"       # subtle FYI tier (tool output, markers)

type
  ColorSpec* = tuple
    brightWhite, offWhite, dimWhite: string

var
  DarkPalette*: ColorSpec = (
    brightWhite: "\x1b[97m",        # bright white
    offWhite:    "\x1b[38;5;252m",  # near-white
    dimWhite:    "\x1b[38;5;244m",  # grey 244
  )
  LightPalette*: ColorSpec = (
    # Invert the white family: white -> black, off-white -> dark grey,
    # dim white -> a lighter dark grey. Colourful colors (cyan/green/red/
    # magenta) are unchanged, handled at their call sites.
    brightWhite: "\x1b[30m",        # black
    offWhite:    "\x1b[38;5;238m",  # dark grey
    dimWhite:    "\x1b[38;5;250m",  # lighter dark grey
  )

proc paletteFor*(mode: ColorMode): ColorSpec =
  if mode == cmLight: LightPalette else: DarkPalette

proc applyPalette*(mode: ColorMode) =
  ## Set the white-family `var`s for `mode`. Call once at startup after
  ## detection/config, before any colored output.
  colorMode = mode
  let p = paletteFor(mode)
  BrightWhiteFg = p.brightWhite
  OffWhiteFg = p.offWhite
  GreyFg = p.dimWhite

proc resetPalettes*() =
  ## Restore `DarkPalette` / `LightPalette` to their built-in defaults
  ## and re-resolve the active mode. Used by tests (which mutate the
  # palettes via `applyColorOverrides`) to leave global state clean.
  DarkPalette  = (brightWhite: "\x1b[97m", offWhite: "\x1b[38;5;252m",
                  dimWhite: "\x1b[38;5;244m")
  LightPalette = (brightWhite: "\x1b[30m", offWhite: "\x1b[38;5;238m",
                  dimWhite: "\x1b[38;5;250m")
  applyPalette(colorMode)

proc applyColorOverrides*(dark, light: Table[string, string]) =
  ## Apply user `[colors]` config overrides on top of the mode palettes.
  ## `dark` keys override BOTH modes (a plain config key has no suffix);
  ## `light` keys override light mode only and win for light mode. Keys
  ## are `bright-white`, `off-white`, `dim-white`; values are ANSI escape
  ## sequences. Unknown keys are ignored. Re-resolves the active mode last.
  proc setSpec(t: var ColorSpec; key, val: string) =
    case key
    of "bright-white": t.brightWhite = val
    of "off-white":    t.offWhite = val
    of "dim-white":    t.dimWhite = val
    else: discard
  var dp = DarkPalette
  var lp = LightPalette
  for k, v in dark:
    dp.setSpec(k, v)
    lp.setSpec(k, v)
  for k, v in light:
    lp.setSpec(k, v)
  DarkPalette = dp
  LightPalette = lp
  applyPalette(colorMode)

func parseHex16*(s: string): int =
  ## Parse a 1-to-4 hex-digit colour channel value (OSC 11 emits 1, 2, or
  ## 4 hex digits per channel) scaled to 0..255.
  if s.len == 0: return 0
  try:
    result = parseHexInt(s)
  except ValueError:
    return 0
  case s.len
  of 1: result = result * 255 div 15      # 0..15
  of 2: result = result                  # 0..255
  of 3: result = result * 255 div 4095    # 0..4095
  of 4: result = result * 255 div 65535   # 0..65535
  else: result = (result * 255) div ((1 shl (4 * s.len)) - 1)

func parseOscBg*(reply: string): (int, int, int) =
  ## Extract the (r,g,b) background from an OSC 11 reply, which arrives as
  ## `ESC ] 11 ; rgb:RRRR/GGGG/BBBB ST` (or the legacy `rgb:R/G/B` / a bare
  ## `#rrggbb`). Returns (-1,-1,-1) when no colour can be parsed, so the
  ## caller treats it as undetectable (stays dark). The trailing terminator
  ## (BEL or ESC-backslash ST) and any surrounding OSC framing are stripped
  ## before the colour spec is read.
  let raw = reply.strip()
  if raw.len == 0: return (-1, -1, -1)
  var s = raw
  # Drop a trailing BEL (0x07) or ST (ESC \).
  if s.len > 0 and s[^1] == '\x07': s.setLen(s.len - 1)
  elif s.len >= 2 and s[^2] == '\x1b' and s[^1] == '\\': s.setLen(s.len - 2)
  let i = s.find("rgb:")
  if i >= 0:
    # Keep only hex digits and the channel separators so a stray terminator
    # or OSC framing byte never leaks into a channel value.
    var rest = ""
    for c in s[i + 4 .. ^1]:
      if c in {'0'..'9', 'a'..'f', 'A'..'F', '/'}: rest.add c
    let parts = rest.split('/')
    if parts.len >= 3:
      return (parseHex16(parts[0]), parseHex16(parts[1]), parseHex16(parts[2]))
  let j = s.find('#')
  if j >= 0 and s.len - (j + 1) >= 6:
    let hex = s[j + 1 .. j + 6]
    return (parseHex16(hex[0 .. 1]), parseHex16(hex[2 .. 3]),
            parseHex16(hex[4 .. 5]))
  (-1, -1, -1)

func luminance*(r, g, b: int): float =
  ## Perceptual luminance (ITU-R BT.601 weights). 0..255 -> 0..1.
  (0.299 * r.float + 0.587 * g.float + 0.114 * b.float) / 255.0

proc detectColorMode*(force: ColorMode = cmAuto): ColorMode =
  ## Resolve the active colour mode. A forced `cmDark`/`cmLight` wins
  ## directly. `cmAuto` queries the terminal for its background colour via
  ## OSC 11 (`ESC ] 11 ; ? BEL`), parses the `rgb:...` reply, and picks
  ## light when the background luminance is high. On any failure (not a
  ## tty, the terminal doesn't answer within the poll deadline, an
  ## unparseable reply) it defaults to dark.
  ##
  ## Under the tty test harness the PTY doesn't answer OSC queries, so the
  ## query bytes would pollute captured frames; detection skips the query
  ## there (signalled by `THREECODE_TEST_FRAME_FD`) and stays dark.
  if force == cmDark: return cmDark
  if force == cmLight: return cmLight
  if getEnv("THREECODE_TEST_FRAME_FD").len > 0: return cmDark
  when defined(posix):
    const FdStdin {.used.} = 0.cint
    if isatty(FdStdin) == 0: return cmDark
    var orig: Termios
    if tcGetAttr(FdStdin, addr orig) != 0: return cmDark
    var rawMode = orig
    rawMode.c_lflag = rawMode.c_lflag and not Cflag(ICANON or ECHO)
    rawMode.c_cc[VMIN] = 0.char
    rawMode.c_cc[VTIME] = 0.char
    if tcSetAttr(FdStdin, TCSANOW, addr rawMode) != 0: return cmDark
    # Drain any buffered input before the query so it isn't mistaken for
    # the reply; restore termios no matter how we exit.
    var drain: char
    while posix.read(FdStdin, addr drain, 1) > 0: discard
    try:
      stdout.write "\x1b]11;?\x07"
      stdout.flushFile()
      var buf = ""
      buf.setLen(256)
      var total = 0
      let deadlineMs = 150.cint
      var elapsedMs = 0
      const StepMs = 25.cint
      while elapsedMs < deadlineMs:
        var pfd: TPollfd
        pfd.fd = FdStdin
        pfd.events = POLLIN
        let r = poll(addr pfd, 1.Tnfds, StepMs)
        elapsedMs += StepMs.int
        if r > 0 and (pfd.revents and POLLIN) != 0:
          let n = posix.read(FdStdin, addr buf[total], buf.len - total)
          if n > 0:
            total += n
            # The reply is terminated by BEL (0x07) or ST (ESC \); stop
            # once a terminator lands so we don't block for the full window.
            if '\x07' in buf.toOpenArray(0, total - 1) or
               (total >= 2 and buf[total - 2] == '\x1b' and buf[total - 1] == '\\'):
              break
          else:
            break
      let reply = buf[0 ..< total]
      let (r, g, b) = parseOscBg(reply)
      if r >= 0:
        if luminance(r, g, b) > 0.5: return cmLight
        return cmDark
      return cmDark
    finally:
      discard tcSetAttr(FdStdin, TCSANOW, addr orig)
  else:
    cmDark

proc splitColorOverrides*(flat: Table[string, string]):
    tuple[both, light: Table[string, string]] =
  ## Split a flat `[colors]` map into `(both, light)`. A key ending in
  ## `-light` contributes to light mode only (suffix stripped); any other
  ## key is a plain override that applies to both modes. This is the
  ## cascade: plain keys set both, `-light` keys set light and win there.
  result[0] = initTable[string, string]()
  result[1] = initTable[string, string]()
  for k, v in flat:
    if k.endsWith("-light"):
      result[1][k[0 ..< k.len - 6]] = v
    else:
      result[0][k] = v

proc debugOut*(msg: string) =
  if not debugEnabled: return
  let t = epochTime().formatFloat(ffDecimal, 3)
  stderr.writeLine BlueFg & "[dbg " & t & "] " & msg & Reset

proc debugOut*(msg, tag: string) =
  if not debugEnabled: return
  let t = epochTime().formatFloat(ffDecimal, 3)
  stderr.writeLine BlueFg & "[dbg " & t & "] " & BoldOn & tag &
    Reset & BlueFg & " " & msg & Reset

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

proc connectErrorDetail*(e: ref CatchableError): string =
  ## The message a connect raises. `nativesockets.getAddrInfo` surfaces DNS
  ## failures as `raiseOSError(osLastError(), gai_strerror(...))`, which packs
  ## a useless OS strerror (`Resource temporarily unavailable`) in front of the
  ## real cause, appended as `Additional info: "..."`. Keep only the
  ## `Additional info:` part (the actual diagnosis) and fall back to the whole
  ## message when it isn't there.
  let msg = e.msg.strip
  const Marker = "Additional info: "
  let idx = msg.find(Marker)
  if idx >= 0:
    result = msg[idx + Marker.len .. ^1].strip
    if result.startsWith('"') and result.endsWith('"') and result.len >= 2:
      result = result[1 .. ^2]
  else:
    result = msg

proc userConfigRoot*(): string =
  ## XDG config root for 3code: `~/.config/3code/` on Linux,
  ## `~/Library/Application Support/3code/` on macOS, `%APPDATA%/3code/`
  ## on Windows. Holds user-edited config and skill overrides only.
  getConfigDir() / "3code"

proc userDataRoot*(): string =
  ## XDG data root for 3code: `~/.local/share/3code/` on Linux,
  ## `~/.config/3code/` on macOS, `%APPDATA%/3code/` on Windows (collapses
  ## with config-root there — fine, the split is a Linux convention). Holds
  ## app-managed state: sessions, history, extracted built-in skills.
  ##
  ## `XDG_DATA_HOME` overrides the platform default on all POSIX platforms.
  ## Honoring it on macOS (not just Linux) matches the spec and makes the
  ## data root redirectable for tests; the platform default is unchanged
  ## when the variable is unset.
  when defined(windows):
    getConfigDir() / "3code"
  else:
    let xdg = getEnv("XDG_DATA_HOME")
    when defined(macosx):
      let base = if xdg.len > 0: xdg else: getConfigDir()
    else:
      let base = if xdg.len > 0: xdg else: getHomeDir() / ".local" / "share"
    base / "3code"

proc resolvePath*(path: string): string =
  if path.len == 0: return ""
  var p = path
  if p.startsWith("~"): p = expandTilde(p)
  try: absolutePath(p) except CatchableError: p

proc safeCwd*(): string =
  ## The current working directory, or ``/`` when the process's cwd has
  ## been removed or renamed out from under it. Nim's ``getCurrentDir``
  ## raises ``OSError`` in that case (Linux ``getcwd`` returns ``ENOENT``),
  ## which would crash the REPL. The filesystem no longer has a name for
  ## the deleted dir, so callers that only need an absolute path label
  ## for context, logging, or session identity get ``/`` — every dir-walk,
  ## ``ls``, ``git`` and ``fileExists`` against it then simply finds
  ## nothing and degrades gracefully.
  try: getCurrentDir()
  except OSError: "/"

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

proc sanitizeUtf8*(s: string): string =
  ## Return a copy of `s` that is valid UTF-8: every invalid byte or
  ## malformed sequence is replaced with a single U+FFFD, and every valid
  ## codepoint (including multibyte) passes through untouched.
  ##
  ## Strings that cross a system boundary into a JSON request body must be
  ## valid UTF-8. Tool output and resumed-session text can carry bytes that
  ## aren't — e.g. a command that printed a truncated multi-byte rune left a
  ## lone continuation byte in its result, which `std/json` emits verbatim
  ## into the serialized body. The provider then rejects the whole body with
  ## a 400, and since the offending message recurs in every subsequent
  ## request (tool messages can't be dropped) the session is bricked until
  ## the `.3log` is hand-edited. This is the boundary guard that stops that.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    let b = s[i].uint8
    if b < 0x80:
      result.add s[i]; inc i; continue
    let seqLen =
      if b shr 5 == 0b110: 2
      elif b shr 4 == 0b1110: 3
      elif b shr 3 == 0b11110: 4
      else: 0 # lone continuation byte, or a lead byte > 0xF4
    if seqLen == 0:
      result.add "\uFFFD"; inc i; continue
    var ok = true
    if i + seqLen > s.len: ok = false
    else:
      case seqLen
      of 2:
        if (s[i + 1].uint8 and 0xC0'u8) != 0x80'u8: ok = false
        elif b <= 0xC1'u8: ok = false # overlong (encodes < 0x80)
      of 3:
        if (s[i + 1].uint8 and 0xC0'u8) != 0x80'u8 or
           (s[i + 2].uint8 and 0xC0'u8) != 0x80'u8: ok = false
        elif b == 0xE0'u8 and (s[i + 1].uint8 and 0xE0'u8) == 0x80'u8:
          ok = false # overlong
        elif b == 0xED'u8 and (s[i + 1].uint8 and 0xE0'u8) == 0xA0'u8:
          ok = false # surrogate (U+D800..U+DFFF)
      of 4:
        if (s[i + 1].uint8 and 0xC0'u8) != 0x80'u8 or
           (s[i + 2].uint8 and 0xC0'u8) != 0x80'u8 or
           (s[i + 3].uint8 and 0xC0'u8) != 0x80'u8: ok = false
        elif b == 0xF0'u8 and (s[i + 1].uint8 and 0xF0'u8) == 0x80'u8:
          ok = false # overlong
        elif b == 0xF4'u8 and s[i + 1].uint8 > 0x8F'u8:
          ok = false # > U+10FFFF
        elif b > 0xF4'u8: ok = false
      else: discard
    if ok:
      for k in 0 ..< seqLen: result.add s[i + k]
      inc i, seqLen
    else:
      # Drop only the bad lead byte; any orphaned continuation bytes that
      # follow get re-checked on the next iteration and each become its own
      # U+FFFD, matching WHATWG/W3C decoder best practice (substituting one
      # replacement char per maximal subpart of an ill-formed sequence).
      result.add "\uFFFD"; inc i

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
  ## `*italic*` / `_italic_`, and backtick-code. Body text rides the
  ## terminal's default foreground (no envelope SGR), so the reverts
  ## just cancel bold / italic / underline back to default — no need
  ## to re-engage `\x1b[2m` (we no longer dim the body).
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
          result.add "\x1b[1m\x1b[3m\x1b[4m" & applyInlineMd(inner) &
                     "\x1b[24m\x1b[23m\x1b[22m"
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
          # Bold: real bold (bright). No color change, asterisks
          # dropped. Recurse so nested italic/code inside
          # (e.g. `**_lazy_**`) renders.
          result.add "\x1b[1m" & applyInlineMd(inner) & "\x1b[22m"
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
          result.add "\x1b[1m" & inner & "\x1b[22m"
          i = j + 1
          continue
    result.add line[i]
    inc i

proc visibleWidth*(s: string): int =
  ## Count visible columns in a string that may contain ANSI CSI escape
  ## sequences (`\e[...<letter>`). Each rune is weighted by its East
  ## Asian Width: CJK / emoji count as 2, combining marks as 0.
  var i = 0
  while i < s.len:
    if s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '[':
      i += 2
      while i < s.len and s[i] notin {'A'..'Z', 'a'..'z'}:
        inc i
      if i < s.len: inc i
      continue
    let rl = if (s[i].uint8 and 0xC0'u8) != 0x80'u8: max(1, runeLenAt(s, i)) else: 1
    if (s[i].uint8 and 0xC0'u8) != 0x80'u8:
      inc result, runeCellWidth(s.runeAt(i))
    inc i, rl

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

proc charWrapAnsi*(s: string, width: int): seq[string] =
  ## Character-wrap: break at exactly `width` visible columns, even
  ## mid-word. ANSI CSI escapes pass through without counting toward
  ## width. Lines that fit are returned as-is.
  if width <= 0 or s.len == 0:
    result.add s
    return
  var line = ""
  var lineW = 0
  var i = 0
  while i < s.len:
    if s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '[':
      let start = i
      i += 2
      while i < s.len and s[i] notin {'A'..'Z', 'a'..'z'}:
        inc i
      if i < s.len: inc i
      line.add s[start ..< i]
      continue
    let start = i
    if (s[i].uint8 and 0xC0'u8) != 0x80'u8:
      # start of a visible character
      inc i
      while i < s.len and (s[i].uint8 and 0xC0'u8) == 0x80'u8:
        inc i
      if lineW + 1 > width:
        result.add line
        line = s[start ..< i]
        lineW = 1
      else:
        line.add s[start ..< i]
        inc lineW
    else:
      inc i
  if line.len > 0:
    result.add line

const BannerMaxRows* = 3

proc bannerWrapRows*(prefix, body: string; termW: int): seq[string] =
  ## Wrap a tool banner (icon + command/path) across the terminal width,
  ## mirroring how output lines wrap. The `prefix` (e.g. "$ ") occupies
  ## the first row; continuation rows align under the body with a 2-space
  ## indent. Wide terminals show the whole banner; narrow ones wrap instead
  ## of clipping. After `BannerMaxRows` rows the remainder is dropped with an
  ## ellipsis so an extremely long banner cannot take over the fat prompt.
  let firstW = max(1, termW - visibleWidth(prefix))
  let contW = max(1, termW - 2)
  var first = true
  for chunk in charWrapAnsi(body, if first: firstW else: contW):
    if result.len >= BannerMaxRows:
      result[^1] = utf8ByteCut(result[^1], max(1, result[^1].len - 1)) & "…"
      return
    result.add (if first: prefix else: "  ") & chunk
    first = false

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
  ## with two spaces for visual separation. When the value is 0 the
  ## slot is omitted entirely (returns ""); the caller strips the
  ## preceding spacer too so no dangling gaps appear.
  if n == 0: ""
  else: icon & humanTokens(n)

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

proc isBinaryContent*(s: string): bool =
  ## Scan the first 512 bytes for binary indicators: any NUL byte, or
  ## >5% non-printable control chars (excluding \t \n \r and ANSI escape
  ## sequences). CSI, OSC, and short-form ANSI escapes are skipped so that
  ## colourised/terminal-formatted tool output is not misclassified.
  let scan = min(512, s.len)
  if scan == 0: return false
  var bad = 0
  var k = 0
  while k < scan:
    let b = s[k].ord
    if b == 0: return true
    if b == 27 and k + 1 < scan:
      let next = s[k + 1].ord
      if next == ord('['):
        # CSI: ESC [ <parameter+intermediate bytes 0x20-0x3F> <final 0x40-0x7E>
        inc k, 2
        while k < scan and s[k].ord notin 0x40..0x7E:
          inc k
        if k < scan: inc k
        continue
      if next in {ord(']'), ord('P'), ord('^'), ord('_')}:
        # OSC / DCS / SOS / PM / APC: terminated by BEL (0x07) or ST (ESC \)
        inc k, 2
        while k < scan:
          let tb = s[k].ord
          if tb == 7:
            inc k; break
          if tb == 27 and k + 1 < scan and s[k + 1] == '\\':
            inc k, 2; break
          inc k
        continue
      # Other ESC sequences: skip ESC + 1 byte (covers ESC c, ESC M, etc.)
      inc k, 2
      continue
    if b < 32 and b notin {9, 10, 13}:
      inc bad
    inc k
  bad * 20 > scan

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
