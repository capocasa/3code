## The goal-mode ignore cascade: gitignore syntax, three sources, one
## in-harness evaluator.
##
## Nothing here runs git or reads inside `.git/`: `.gitignore` files are
## plain pattern lists read as data, parsed by this module alone (the
## single evaluator rule — no external ignore evaluator of any kind).
## The cascade concatenates three sources, last match wins, `!`
## negation in a later source re-includes what an earlier one
## excluded:
##
## 1. global defaults — `~/p/nimignore` when that file exists, else the
##    embedded copy (same content: VCS internals, dependency trees,
##    build caches, and `.3code/` itself, so the snapshot store sits
##    outside the walk);
## 2. `.gitignore` — per directory, git's own order, deepest wins;
## 3. `.3code/ignore` — the override point, always evaluated last.
##
## Pruning rule: a directory is pruned from the walk only when its own
## evaluation ends ignored AND no anchored negation from any source
## could match beneath it — plain ignores never prune, so
## `build/` + `!build/output.txt` in the cascade keeps `output.txt`
## reachable (git cannot do this; it never descends into `build/`).
## Bare-name negations (`!keep.log`) do not block pruning: they name no
## subtree, so honoring them would un-prune every ignored directory in
## the tree, `.git/` included. Under an already-pruned directory they
## behave exactly as git does — silently unreachable.
##
## Subset honored: comments, blank lines, name/glob patterns
## (`*`, `?`, `[...]`, `**`), trailing-`/` dirs, leading-`/` and
## interior-slash anchors, `!` negation, `\` escapes. Matching is
## case-sensitive except on Windows.

import std/[options, os, strutils]

type
  IgnorePattern* = object
    ## One gitignore-syntax line, parsed.
    negated*: bool     ## leading `!`
    dirOnly*: bool     ## trailing `/`
    anchored*: bool    ## leading `/` or an interior `/`: matches only
                       ## from the source file's directory
    segs*: seq[string]  ## pattern split on `/`; `**` is its own segment
    plain*: seq[bool]  ## per segment: no wildcard chars (fast compare)

  IgnoreRule* = object
    ## A pattern plus the scope it was read in: the directory (relative
    ## to the walk root, `@[]` is the root) whose `.gitignore` carried
    ## it. Global and `.3code/ignore` rules scope to the root.
    scopeSegs*: seq[string]
    pat*: IgnorePattern

  IgnoreCascade* = object
    ## The per-walk rule store: the base (global defaults) and final
    ## (`.3code/ignore`) tiers. The middle tier — the per-directory
    ## `.gitignore` chain — is built by the walker and passed to
    ## `ignored` as the chain between the two.
    base*: seq[IgnoreRule]
    final*: seq[IgnoreRule]

var globalIgnoreFile* = getHomeDir() / "p" / "nimignore"
  ## The global defaults source. When absent (or unreadable — a
  ## directory of the same name counts), the embedded defaults below
  ## apply. A var so tests can point it somewhere hermetic.

const EmbeddedGlobalIgnore* = """.git/
.hg/
node_modules/
__pycache__/
target/
nimcache/
.nimcache/
.3code/
"""
  ## The shipped defaults: the old `ManifestSkipDirs` list as patterns.

# ---------------------------------------------------------------------------
# Pattern matching
# ---------------------------------------------------------------------------

proc matchAtom(p: string; pi: var int; c: char): bool =
  ## Match the atom at `p[pi]` against `c`, advancing `pi` past it.
  ## `\` takes the next char literally, `?` matches any char, `[...]` a
  ## character class (with `!`/`^` negation and `a-z` ranges); anything
  ## else matches itself. A class without a closing `]` is treated as a
  ## literal `[`.
  if p[pi] == '\\' and pi + 1 < p.len:
    result = p[pi + 1] == c
    inc pi, 2
  elif p[pi] == '?':
    result = true
    inc pi
  elif p[pi] == '[':
    var j = pi + 1
    var neg = false
    if j < p.len and p[j] in {'!', '^'}:
      neg = true
      inc j
    var matched = false
    var first = true
    while j < p.len and (p[j] != ']' or first):
      first = false
      if p[j] == '\\' and j + 1 < p.len:
        if p[j + 1] == c: matched = true
        inc j
      elif j + 2 < p.len and p[j + 1] == '-' and p[j + 2] != ']':
        if p[j] <= c and c <= p[j + 2]: matched = true
        inc j, 3
      else:
        if p[j] == c: matched = true
        inc j
    if j >= p.len:
      result = p[pi] == c
      inc pi
      return
    result = matched != neg
    pi = j + 1
  else:
    result = p[pi] == c
    inc pi

proc segMatchRaw(p, s: string; plainP: bool): bool =
  ## Glob match within one path segment: `*` (any run, via
  ## backtracking), `?`, classes, escapes. A wildcard-free pattern (the
  ## common case) is a plain compare.
  if plainP: return p == s
  var pi = 0
  var si = 0
  var starPi = -1
  var starSi = 0
  while si < s.len:
    if pi < p.len and p[pi] == '*':
      starPi = pi
      inc pi
      starSi = si
      continue
    if pi < p.len:
      var pp = pi
      if matchAtom(p, pp, s[si]):
        pi = pp
        inc si
        continue
      if starPi >= 0:
        pi = starPi + 1
        inc starSi
        si = starSi
        continue
      return false
    elif starPi >= 0:
      pi = starPi + 1
      inc starSi
      si = starSi
    else:
      return false
  while pi < p.len and p[pi] == '*': inc pi
  pi == p.len

proc segMatchPlain(p, s: string; plainP: bool): bool =
  when defined(windows):
    segMatchRaw(p.toLowerAscii, s.toLowerAscii, plainP)
  else:
    segMatchRaw(p, s, plainP)

proc segMatch*(p, s: string): bool =
  segMatchPlain(p, s, p.find({'*', '?', '[', '\\'}) < 0)

proc matchAt(ps: seq[string]; plain: seq[bool]; ts: seq[string];
             pi, ti, tiEnd: int): bool =
  ## Full match of pattern segments `ps[pi..]` against path segments
  ## `ts[ti ..< tiEnd]`; a `**` segment matches zero or more path
  ## segments (one or more when trailing).
  if pi == ps.len: return ti == tiEnd
  if ps[pi] == "**":
    # A trailing `**` matches everything INSIDE (one or more segments);
    # elsewhere `**` may also absorb nothing (`a/**/b` matches `a/b`).
    let least = if pi == ps.len - 1: 1 else: 0
    var skip = least
    while ti + skip <= tiEnd:
      if matchAt(ps, plain, ts, pi + 1, ti + skip, tiEnd): return true
      inc skip
    return false
  if ti >= tiEnd: return false
  if not segMatchPlain(ps[pi], ts[ti], plain[pi]): return false
  matchAt(ps, plain, ts, pi + 1, ti + 1, tiEnd)

func scopePrefixLen(r: IgnoreRule; segs: seq[string]): int =
  ## The rule's scope length when it is a prefix of `segs`, else -1.
  ## Index walk, no slicing: this runs per rule per walked path.
  if r.scopeSegs.len > segs.len: return -1
  for i in 0 ..< r.scopeSegs.len:
    if r.scopeSegs[i] != segs[i]: return -1
  r.scopeSegs.len

proc patMatch(pat: IgnorePattern; segs: seq[string]; lo, hiEx: int): bool =
  ## Does `pat` match `segs[lo ..< hiEx]`?
  if pat.anchored:
    matchAt(pat.segs, pat.plain, segs, 0, lo, hiEx)
  else:
    hiEx > lo and segMatchPlain(pat.segs[0], segs[hiEx - 1], pat.plain[0])

proc ruleMatchesPath(r: IgnoreRule; segs: seq[string]; isDir: bool): bool =
  ## Does the rule decide the path `segs`? It matches the path itself
  ## (a dir-only pattern requires a directory) or any ancestor
  ## directory (git's exclusion propagation: contents of an ignored
  ## directory are ignored — which here also propagates negations).
  let sLen = scopePrefixLen(r, segs)
  if sLen < 0: return false
  if segs.len == sLen: return false
  if not r.pat.anchored:
    # Single-segment pattern: it matches the subject's own basename
    # and any ancestor — one scan over the segments instead of a
    # patMatch per ancestor. This is the hot path (the defaults and
    # most gitignore lines are plain names).
    let s0 = r.pat.segs[0]
    let s0Plain = r.pat.plain[0]
    let last =
      if r.pat.dirOnly and not isDir: segs.len - 1  # ancestors only
      else: segs.len
    for i in sLen ..< last:
      if segMatchPlain(s0, segs[i], s0Plain): return true
    return false
  if (not r.pat.dirOnly or isDir) and
      patMatch(r.pat, segs, sLen, segs.len): return true
  for i in sLen + 1 ..< segs.len:
    if patMatch(r.pat, segs, sLen, i): return true
  false

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

proc parseIgnoreLine(l: string): Option[IgnorePattern] =
  var s = l
  # Trailing spaces are stripped unless escaped (gitignore rule).
  var e = s.len
  while e > 0 and s[e - 1] in {' ', '\t'}:
    if e >= 2 and s[e - 2] == '\\': break
    dec e
  s = s[0 ..< e]
  s = s.strip(leading = true)
  if s.len == 0 or s[0] == '#': return
  var pat = IgnorePattern()
  if s[0] == '!':
    pat.negated = true
    s = s[1 ..^ 1]
  elif s.len >= 2 and s[0] == '\\' and s[1] == '!':
    s = s[1 ..^ 1]  # escaped literal !
  if s.len == 0: return
  while s.len > 0 and s[^1] == '/':
    pat.dirOnly = true
    s = s[0 ..< s.len - 1]
  if s.len == 0: return
  if s[0] == '/':
    pat.anchored = true
    s = s[1 ..^ 1]
  if s.len == 0: return
  if '/' in s: pat.anchored = true
  for seg in s.split('/'):
    if seg.len > 0:
      pat.segs.add seg
      pat.plain.add seg.find({'*', '?', '[', '\\'}) < 0
  if pat.segs.len == 0: return
  some pat

proc parseIgnore*(text, scope: string): seq[IgnoreRule] =
  ## Parse gitignore-syntax text into rules scoped to `scope` (a
  ## directory relative to the walk root; "" is the root).
  let scopeSegs = if scope.len == 0: @[] else: scope.split('/')
  for l in text.splitLines:
    let p = parseIgnoreLine(l)
    if p.isSome:
      result.add IgnoreRule(scopeSegs: scopeSegs, pat: p.get)

proc globalRules*(): seq[IgnoreRule] =
  ## The base tier: `~/p/nimignore` when present (it replaces the
  ## defaults wholesale), else the embedded copy.
  let text =
    try:
      if fileExists(globalIgnoreFile): readFile(globalIgnoreFile) else: ""
    except CatchableError:
      ""
  if text.strip.len > 0: parseIgnore(text, "")
  else: parseIgnore(EmbeddedGlobalIgnore, "")

proc newCascade*(root: string): IgnoreCascade =
  ## The per-walk rule store for `root`: base tier loaded now, final
  ## tier from `root/.3code/ignore` when one exists. The `.gitignore`
  ## tier is accumulated by the walker between them.
  result.base = globalRules()
  try:
    if fileExists(root / ".3code" / "ignore"):
      result.final = parseIgnore(readFile(root / ".3code" / "ignore"), "")
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

proc ignoredSegs*(c: IgnoreCascade; chain: openArray[IgnoreRule];
                  segs: seq[string]; isDir: bool): bool =
  ## Last-match-wins over the concatenated cascade — base tier, then
  ## the `.gitignore` chain in walk order (root first, deepest last),
  ## then the final tier. No match at all means not ignored.
  var hit = false
  var ign = false
  for r in c.base:
    if ruleMatchesPath(r, segs, isDir):
      hit = true
      ign = not r.pat.negated
  for r in chain:
    if ruleMatchesPath(r, segs, isDir):
      hit = true
      ign = not r.pat.negated
  for r in c.final:
    if ruleMatchesPath(r, segs, isDir):
      hit = true
      ign = not r.pat.negated
  hit and ign

proc ignored*(c: IgnoreCascade; chain: openArray[IgnoreRule];
              rel: string; isDir: bool): bool =
  ignoredSegs(c, chain, rel.split('/'), isDir)

proc feasibleUnder(ps: seq[string]; plain: seq[bool];
                   segs: seq[string]; pi, qi, qiEnd: int): bool =
  ## Could the anchored pattern `ps` match some path strictly beneath
  ## the directory `segs[qi ..< qiEnd]`? Walks it positionally: every
  ## segment must be matchable, and the pattern must have at least one
  ## segment left to spend below it (`**` absorbs freely).
  if qi == qiEnd: return pi < ps.len
  if pi == ps.len: return false
  if ps[pi] == "**":
    return feasibleUnder(ps, plain, segs, pi + 1, qi, qiEnd) or
        feasibleUnder(ps, plain, segs, pi, qi + 1, qiEnd)
  if not segMatchPlain(ps[pi], segs[qi], plain[pi]): return false
  feasibleUnder(ps, plain, segs, pi + 1, qi + 1, qiEnd)

proc couldReincludeSegs*(c: IgnoreCascade; chain, childOwn: openArray[IgnoreRule];
                        dirSegs: seq[string]): bool =
  ## The no-pruning half of the rule: could any anchored negation from
  ## any source — base tier, ancestor `.gitignore` chain, the
  ## directory's own `.gitignore`, final tier — match a path strictly
  ## beneath `dirSegs`? Bare-name negations never qualify (they name no
  ## subtree; see the module header).
  template scan(rules: untyped) =
    for r in rules:
      if not r.pat.negated or not r.pat.anchored: continue
      let sLen = scopePrefixLen(r, dirSegs)
      if sLen < 0: continue
      if feasibleUnder(r.pat.segs, r.pat.plain, dirSegs, 0, sLen,
          dirSegs.len): return true
  scan(c.base)
  scan(chain)
  scan(childOwn)
  scan(c.final)
  false

proc couldReinclude*(c: IgnoreCascade; chain, childOwn: openArray[IgnoreRule];
                     relDir: string): bool =
  couldReincludeSegs(c, chain, childOwn, relDir.split('/'))
