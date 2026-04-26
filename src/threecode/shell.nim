import std/strutils

proc shellTokens*(s: string): seq[string] =
  ## Tokenize a shell snippet by whitespace, honoring single + double quotes.
  ## Backslash-escapes the next character outside quotes. Not a real shell
  ## parser — used only for path extraction in the loop guard.
  var cur = ""
  var quote: char = '\0'
  var i = 0
  while i < s.len:
    let c = s[i]
    if quote != '\0':
      if c == quote: quote = '\0'
      else: cur.add c
      inc i
    elif c in {'\'', '"'}:
      quote = c
      inc i
    elif c == '\\' and i + 1 < s.len:
      cur.add s[i+1]
      i += 2
    elif c in {' ', '\t', '\n'}:
      if cur.len > 0: result.add cur; cur = ""
      inc i
    else:
      cur.add c; inc i
  if cur.len > 0: result.add cur

proc splitStatements*(cmd: string): seq[string] =
  ## Split on top-level `;`, `&&`, `||`, `|` (not inside quotes). Pipeline
  ## stages count as separate statements so `tee`/`sed -i` mid-pipeline
  ## still get extracted. Background `&` is left alone.
  result.add ""
  var quote: char = '\0'
  var i = 0
  while i < cmd.len:
    let c = cmd[i]
    if quote != '\0':
      result[^1].add c
      if c == quote: quote = '\0'
      inc i
      continue
    if c in {'\'', '"'}:
      quote = c
      result[^1].add c
      inc i
      continue
    if c == ';':
      result.add ""
      inc i
      continue
    if (c == '&' or c == '|') and i + 1 < cmd.len and cmd[i+1] == c:
      result.add ""
      i += 2
      continue
    if c == '|':
      result.add ""
      inc i
      continue
    result[^1].add c
    inc i

proc bashMutationPath*(cmd: string): string =
  ## Best-effort: return the first file path that this bash command would
  ## mutate, or "" if no mutation pattern matches. Closes the loop-guard
  ## bypass where models reach for `sed -i` instead of `patch`/`write` and
  ## thrash a file outside the tracker's view.
  ##
  ## Recognised patterns (per top-level statement):
  ## - explicit redirect: `> path`, `>> path`, `>path`, `>>path`
  ## - `sed -i`, `perl -i` (file is the last positional)
  ## - `tee [-a] path`
  ## - `cp/mv path... DEST` (destination is the last positional)
  ## - `rm path`, `touch path`
  ## - `git checkout/restore path` (any positional after the subcommand)
  ## - repo-wide destructives — `git stash [push|pop|apply|drop|clear]`,
  ##   `git reset --hard`, `git clean -f[d[x]]` — return "." (cwd marker)
  for stmt in splitStatements(cmd):
    let raw = shellTokens(stmt.strip)
    if raw.len == 0: continue
    var toks: seq[string]
    var i = 0
    while i < raw.len:
      let t = raw[i]
      if t == ">" or t == ">>":
        if i + 1 < raw.len: return raw[i+1]
        i += 2
        continue
      if t.startsWith(">") and t.len > 1 and t[1] != '&':
        return if t.startsWith(">>"): t[2..^1] else: t[1..^1]
      if t == "<" or t == "2>" or t == "&>" or t == "2>>":
        i += 2
        continue
      if t.startsWith("<") or t.startsWith("2>") or t.startsWith("&>"):
        inc i
        continue
      toks.add t
      inc i
    if toks.len == 0: continue
    case toks[0]
    of "sed", "perl":
      var inPlace = false
      for t in toks[1..^1]:
        if t == "-i" or t.startsWith("-i.") or t.startsWith("-i'") or
           t.startsWith("-i\""):
          inPlace = true; break
      if inPlace:
        for j in countdown(toks.len - 1, 1):
          if not toks[j].startsWith("-"): return toks[j]
    of "ed", "ex":
      # Line editors that read a script and write the file. `ed -s file`
      # / `ex -s -c '…' file` etc. — last positional is the file. Also the
      # zero-positional case (`ed file`); short flags like `-s`, `-c CMD`,
      # `-G`, `-V`, `-p PROMPT` get filtered by the leading-dash check.
      for j in countdown(toks.len - 1, 1):
        let t = toks[j]
        if t.startsWith("-"): continue
        # ex uses `-c CMD` — skip the value if the previous token is `-c`.
        if j >= 2 and toks[j-1] in ["-c", "-p"]: continue
        return t
    of "tee":
      for t in toks[1..^1]:
        if t.startsWith("-"): continue
        return t
    of "cp", "mv":
      var last = ""
      for t in toks[1..^1]:
        if not t.startsWith("-"): last = t
      if last.len > 0: return last
    of "rm", "touch":
      for t in toks[1..^1]:
        if t.startsWith("-"): continue
        return t
    of "git":
      if toks.len < 2: continue
      case toks[1]
      of "checkout", "restore":
        var last = ""
        for j in 2..<toks.len:
          if not toks[j].startsWith("-") and toks[j] != "--": last = toks[j]
        if last.len > 0: return last
      of "stash":
        let sub = if toks.len >= 3: toks[2] else: ""
        case sub
        of "", "push", "pop", "apply", "drop", "clear", "create", "store":
          return "."
        else: discard  # list, show, branch — read-only
      of "reset":
        for t in toks[2..^1]:
          if t == "--hard": return "."
      of "clean":
        for t in toks[2..^1]:
          if t == "-f" or t == "-fd" or t == "-fdx" or t == "-df": return "."
      else: discard
    else: discard
  ""

proc bashReadPath*(cmd: string): tuple[path: string, fullFile: bool] =
  ## Best-effort: return the file path of a pure single-statement read command,
  ## with `fullFile = true` for `cat path` (the only form eligible for
  ## cache-dedupe of unchanged-since-last-read). Returns ("", false) on
  ## anything compound, piped, redirected, or unrecognised. Used to:
  ##   - port the read-cache stale-write guard onto cat/sed-n (so `patch`
  ##     after an external edit still errors)
  ##   - dedupe a re-read of an unchanged file
  ##   - count reads toward Strike-1 saturation
  let stmts = splitStatements(cmd)
  if stmts.len != 1: return ("", false)
  let raw = shellTokens(stmts[0].strip)
  if raw.len == 0: return ("", false)
  var toks: seq[string]
  for t in raw:
    if t == ">" or t == ">>" or t == "<" or t == "2>" or t == "&>" or t == "2>>":
      return ("", false)
    if t.startsWith(">") or t.startsWith("<") or
       t.startsWith("2>") or t.startsWith("&>"):
      return ("", false)
    toks.add t
  if toks.len < 2: return ("", false)
  case toks[0]
  of "cat":
    var paths: seq[string]
    for t in toks[1..^1]:
      if t.startsWith("-"): continue
      paths.add t
    if paths.len == 1: return (paths[0], true)
  of "sed":
    var hasN = false
    var paths: seq[string]
    var i = 1
    while i < toks.len:
      let t = toks[i]
      if t == "-n": hasN = true; inc i; continue
      if t == "-e" or t == "--expression" or t == "-f":
        i += 2; continue
      if t.startsWith("-"): inc i; continue
      paths.add t
      inc i
    # `sed -n 'A,Bp' path` → paths = ['A,Bp', path]; the script counts as a
    # positional but isn't a file. Require exactly two positionals (script +
    # one file) so we don't false-positive on `sed -n '1p' a b`.
    if hasN and paths.len == 2: return (paths[1], false)
  of "head", "tail":
    var paths: seq[string]
    var i = 1
    while i < toks.len:
      let t = toks[i]
      if t == "-n" or t == "-c":
        i += 2; continue
      if t.startsWith("-"): inc i; continue
      paths.add t
      inc i
    if paths.len == 1: return (paths[0], false)
  else: discard
  ("", false)

proc bashIsRecovery*(cmd: string): string =
  ## Returns the offending sub-command (`"git checkout src/foo.nim"`,
  ## `"git stash"`, etc.) when `cmd` looks like the model trying to undo
  ## its own work mid-session — otherwise `""`. Hard-trips the loop guard
  ## to Strike 2 on the first occurrence: these commands wipe the working
  ## tree state the model's plan was based on, so further autonomous turns
  ## almost always make things worse. Branch switches (`git checkout main`,
  ## `git checkout v1.2`) are NOT recovery — only path-shaped restores,
  ## explicit `--` separators, and the wholesale destructives count.
  for stmt in splitStatements(cmd):
    let raw = shellTokens(stmt.strip)
    var toks: seq[string]
    var i = 0
    while i < raw.len:
      let t = raw[i]
      if t == ">" or t == ">>" or t == "<" or t == "2>" or t == "&>" or t == "2>>":
        i += 2; continue
      if t.startsWith(">") or t.startsWith("<") or t.startsWith("2>") or t.startsWith("&>"):
        inc i; continue
      toks.add t; inc i
    if toks.len < 2 or toks[0] != "git": continue
    case toks[1]
    of "restore":
      return toks.join(" ")
    of "checkout":
      # Explicit `--` separator → file restore, no question.
      if "--" in toks[2..^1]: return toks.join(" ")
      # No `--` — disambiguate by shape. Path-like args (contain `/`) are
      # file restores; bare names are branch/tag/ref switches.
      for j in 2..<toks.len:
        let a = toks[j]
        if a.startsWith("-"): continue
        if '/' in a: return toks.join(" ")
    of "reset":
      if "--hard" in toks[2..^1]: return toks.join(" ")
    of "stash":
      let sub = if toks.len >= 3: toks[2] else: ""
      case sub
      of "", "push", "pop", "apply", "drop", "clear", "create", "store":
        return toks.join(" ")
      else: discard  # list, show, branch — read-only
    of "clean":
      for t in toks[2..^1]:
        if t == "-f" or t == "-fd" or t == "-fdx" or t == "-df":
          return toks.join(" ")
    else: discard
  ""
