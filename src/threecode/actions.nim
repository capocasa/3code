import std/[json, os, strformat, strutils, tables, times]
import types, util, shell

proc toolCallToAction*(name: string, args: JsonNode): Action =
  case name
  of "bash":
    Action(kind: akBash, body: args{"command"}.getStr,
           stdin: args{"stdin"}.getStr(""))
  of "write":
    Action(kind: akWrite, path: args{"path"}.getStr, body: args{"body"}.getStr)
  of "patch":
    var act = Action(kind: akPatch, path: args{"path"}.getStr)
    let edits = args{"edits"}
    if edits != nil and edits.kind == JArray:
      for e in edits:
        act.edits.add (e{"search"}.getStr, e{"replace"}.getStr)
    act
  else:
    Action(kind: akBash, body: "echo 'unknown tool: " & name & "'; exit 1")

proc nearestLineHint(content, search: string): string =
  ## When a patch search block didn't match, point the model at the most
  ## similar non-blank line in the file. Operates on the search's first
  ## non-empty line. Uses capped edit distance so the cost stays bounded
  ## even on big files.
  let lines = content.splitLines
  var needle = ""
  for l in search.splitLines:
    let t = l.strip
    if t.len > 0:
      needle = t
      break
  if needle.len == 0 or lines.len == 0: return ""
  let cap = max(8, needle.len div 4)
  var bestLine = -1
  var bestDist = high(int)
  for i, l in lines:
    let lt = l.strip
    if lt.len == 0: continue
    let d = levenshteinCapped(needle, lt, cap)
    if d <= cap and d < bestDist:
      bestDist = d
      bestLine = i + 1
  if bestLine < 0: return ""
  let snip = lines[bestLine - 1].strip
  let trimmed = if snip.len > 80: utf8ByteCut(snip, 77) & "..." else: snip
  &" — nearest match in file: line {bestLine}: \"{trimmed}\""

proc computeDiff*(before, after, label: string): string =
  if before == after: return ""
  let tmp = getTempDir() / ("3code_diff_" & $getCurrentProcessId() & "_" & $epochTime().int64)
  createDir(tmp)
  let ap = tmp / "a"
  let bp = tmp / "b"
  writeFile(ap, before)
  writeFile(bp, after)
  let dp = tmp / "d"
  let wrapped = &"diff -u --label \"a/{label}\" --label \"b/{label}\" \"{ap}\" \"{bp}\" > \"{dp}\" 2>/dev/null"
  discard execShellCmd(wrapped)
  result =
    if fileExists(dp): readFile(dp)
    else: ""
  try: removeDir(tmp) except CatchableError: discard

proc newReadCache*(): ReadCache =
  ReadCache(state: initTable[string, (Time, int)]())

proc fileSig(path: string): (Time, int) =
  try: (getLastModificationTime(path), getFileSize(path).int)
  except CatchableError: (Time(), 0)

proc runAction*(act: Action, cache: ReadCache = nil): tuple[output: string, code: int, diff: string] =
  case act.kind
  of akBash:
    let cmd = act.body.strip
    # Sniff bash for the read-cache integration that lived on `akRead` before
    # the dedicated read tool was dropped. Mutation paths (sed -i, redirects,
    # …) get the stale-write guard so external edits between read and mutate
    # still error out. Pure full reads (`cat path`) get the dedupe shortcut.
    # Both update the cache after a successful run so downstream patch/write
    # see the latest sig.
    let mutPath = bashMutationPath(cmd)
    let (readPath, fullRead) = bashReadPath(cmd)
    if cache != nil and mutPath != "" and mutPath != ".":
      let p = resolvePath(mutPath)
      if p in cache.state and fileExists(p):
        if fileSig(p) != cache.state[p]:
          return (&"error: {p} changed on disk since the last read in this session — re-read before mutating", 1, "")
    if cache != nil and readPath != "" and fullRead:
      let p = resolvePath(readPath)
      if fileExists(p) and p in cache.state and fileSig(p) == cache.state[p]:
        return (&"[unchanged since prior read of {p}; see earlier read in this session]", 0, "")
    # For bash mutations on a single named path (sed -i, ed -s, redirects),
    # snapshot before-content so we can synthesize a green/red diff after the
    # run — keeps the visual feedback `patch` used to give for line-range
    # edits via ed.
    let beforeContent =
      if mutPath != "" and mutPath != "." and fileExists(resolvePath(mutPath)):
        try: readFile(resolvePath(mutPath))
        except CatchableError: ""
      else: ""
    let beforeExists = mutPath != "" and mutPath != "." and
                       fileExists(resolvePath(mutPath))
    let tmp = getTempDir() / ("3code_bash_" & $getCurrentProcessId() & "_" & $epochTime().int64)
    createDir(tmp)
    let outPath = tmp / "out"
    let errPath = tmp / "err"
    let scriptPath = tmp / "cmd.sh"
    let stdinPath = tmp / "stdin"
    # Pager-killing env keeps `git log`, `systemctl`, `man`, etc. from hanging
    # on a TTY that doesn't exist. `timeout --foreground` caps runaways while
    # still propagating terminal SIGINT to the child. Writing the command to
    # a script avoids the shell-escaping minefield. Stdin is always piped
    # from a file (empty when act.stdin is "") so commands can't block on
    # the user's terminal.
    let script = """export PAGER=cat GIT_PAGER=cat PSQL_PAGER=cat MYSQL_PAGER=cat
export LESS= TERM=dumb CI=1 NO_COLOR=1 GIT_TERMINAL_PROMPT=0
export DEBIAN_FRONTEND=noninteractive
""" & cmd & "\n"
    writeFile(scriptPath, script)
    writeFile(stdinPath, act.stdin)
    let wrapped = &"timeout --foreground 120s sh \"{scriptPath}\" <\"{stdinPath}\" >\"{outPath}\" 2>\"{errPath}\""
    let code = execShellCmd(wrapped)
    let rawOut = if fileExists(outPath): readFile(outPath) else: ""
    let rawErr = if fileExists(errPath): readFile(errPath) else: ""
    try: removeDir(tmp) except CatchableError: discard
    let outClip = clipMiddle(rawOut, 2000, 2000)
    let errClip = clipMiddle(rawErr, 1000, 1000)
    # Body omits the "$ {cmd}" echo — the model already has the command in
    # its own tool_call arguments; no reason to send it back. The display
    # layer prepends it from `act.body` for the human.
    var body = ""
    if outClip.len > 0:
      body.add outClip
      if not outClip.endsWith("\n"): body.add "\n"
    if errClip.len > 0:
      body.add "[stderr]\n" & errClip
      if not errClip.endsWith("\n"): body.add "\n"
    if code == 124:
      body.add "[timed out after 120s — wrap long-running commands or run in the background]"
    else:
      body.add &"[exit {code}]"
    if cache != nil and code == 0:
      if readPath != "":
        let p = resolvePath(readPath)
        if fileExists(p): cache.state[p] = fileSig(p)
      if mutPath != "" and mutPath != ".":
        let p = resolvePath(mutPath)
        if fileExists(p): cache.state[p] = fileSig(p)
    var diff = ""
    if mutPath != "" and mutPath != "." and code == 0:
      let p = resolvePath(mutPath)
      let after =
        if fileExists(p):
          try: readFile(p)
          except CatchableError: ""
        else: ""
      # Don't emit a noisy `--- /dev/null` diff for files the command just
      # created — that doubles the body in context. Only show diffs for
      # actual edits.
      if beforeExists and beforeContent != after:
        diff = computeDiff(beforeContent, after, p)
    return (body, code, diff)
  of akRead:
    let path = resolvePath(act.path)
    if not fileExists(path):
      return (&"error: {path} does not exist", 1, "")
    # Dedupe: full reads with no offset/limit on an unchanged file don't
    # re-send the body. Ranged reads still go through (the model may want a
    # different slice than was returned earlier).
    if cache != nil and act.offset <= 0 and act.limit <= 0 and path in cache.state:
      let sig = fileSig(path)
      if sig == cache.state[path]:
        return (&"[unchanged since prior read of {path}; see earlier read in this session]", 0, "")
    let content = try: readFile(path)
                  except CatchableError as e:
                    return (&"error: read {path}: {e.msg}", 1, "")
    if cache != nil:
      cache.state[path] = fileSig(path)
    # Binary-file guard: scan up to 512 bytes for high-density control chars
    # (excluding \t\n\r). If too many, refuse — sending a megabyte of garbage
    # tokens to the model is never useful.
    block binaryCheck:
      let scan = min(512, content.len)
      if scan == 0: break binaryCheck
      var bad = 0
      for k in 0 ..< scan:
        let b = content[k].ord
        if b == 0:
          bad = scan  # any NUL is a hard fail
          break
        if b < 32 and b notin {9, 10, 13}: inc bad
      if bad * 20 > scan:  # > 5%
        return (&"[binary file: {path}, {content.len} bytes — refused]", 0, "")
    const MaxLines = 2000
    const MaxBytes = 60 * 1024
    let lines = content.splitLines
    let total =
      if lines.len > 0 and lines[^1] == "": lines.len - 1
      else: lines.len
    let start = max(0, act.offset - 1)
    if start >= total: return ("", 0, "")
    let explicitLimit = act.limit > 0
    var endi = if explicitLimit: min(total, start + act.limit) else: total
    var capped = false
    if not explicitLimit:
      if endi - start > MaxLines:
        endi = start + MaxLines
        capped = true
      var bytes = 0
      var k = start
      while k < endi:
        let added = lines[k].len + 1
        if bytes + added > MaxBytes:
          capped = true
          break
        bytes += added
        inc k
      if k < endi: endi = k
    var body = lines[start ..< endi].join("\n")
    if capped:
      let shown = endi - start
      body.add &"\n... [file is {total} lines, {content.len} bytes; showed {shown} lines from line {start + 1}. Use read(path, offset, limit) for a specific range.] ..."
    return (body, 0, "")
  of akWrite:
    let path = resolvePath(act.path)
    if cache != nil and path in cache.state and fileExists(path):
      let sig = fileSig(path)
      if sig != cache.state[path]:
        return (&"error: {path} changed on disk since the last read in this session — re-read before writing", 1, "")
    try:
      let dir = parentDir(path)
      if dir != "": createDir(dir)
      let before = if fileExists(path): readFile(path) else: ""
      writeFile(path, act.body)
      if cache != nil:
        cache.state[path] = fileSig(path)
      let diff = computeDiff(before, act.body, path)
      return (&"wrote {path} ({act.body.len} bytes)", 0, diff)
    except CatchableError as e:
      return (&"error: write {path}: {e.msg}", 1, "")
  of akPatch:
    if act.edits.len == 0:
      return (&"error: patch has no edits", 1, "")
    let path = resolvePath(act.path)
    if not fileExists(path):
      return (&"error: {path} does not exist", 1, "")
    if cache != nil and path in cache.state:
      let sig = fileSig(path)
      if sig != cache.state[path]:
        return (&"error: {path} changed on disk since the last read in this session — re-read before patching", 1, "")
    try:
      let before = readFile(path)
      var content = before
      var applied = 0
      for (s, r) in act.edits:
        let (next, ok) = replaceFirst(content, s, r)
        if not ok:
          let hint = nearestLineHint(content, s)
          return (&"error: SEARCH block did not match in {path}{hint}:\n{s}", 1, "")
        content = next
        inc applied
      writeFile(path, content)
      if cache != nil:
        cache.state[path] = fileSig(path)
      let diff = computeDiff(before, content, path)
      return (&"patched {path} ({applied} edit" & (if applied == 1: "" else: "s") & ")", 0, diff)
    except CatchableError as e:
      return (&"error: patch {path}: {e.msg}", 1, "")

proc parseActionsChecked*(text: string):
    tuple[actions: seq[Action], issues: seq[ParseIssue]] =
  ## Text-mode parser with syntax-fail detection. Same recognised forms
  ## as `parseActions`, but additionally flags unterminated fences,
  ## orphan ``` blocks (no `bash` tag and no preceding path), and
  ## malformed SEARCH/REPLACE markers inside a patch. The harness
  ## bounces issues back to the model rather than silently dropping
  ## the action.
  let lines = text.splitLines
  var i = 0
  while i < lines.len:
    let ln = lines[i].strip
    if ln == "```bash" or ln == "```sh" or ln == "```shell":
      let openLine = i + 1
      inc i
      var body = ""
      var closed = false
      while i < lines.len:
        if lines[i].strip == "```":
          closed = true
          inc i
          break
        body.add lines[i] & "\n"
        inc i
      if not closed:
        result.issues.add ParseIssue(line: openLine,
          msg: "unterminated ```bash fence (no closing ``` before end of reply)")
      result.actions.add Action(kind: akBash, body: body)
      continue
    if i + 1 < lines.len and lines[i+1].strip == "```" and looksLikePath(lines[i]):
      let path = lines[i].strip
      let openLine = i + 2
      i += 2
      var body = ""
      var closed = false
      while i < lines.len:
        if lines[i].strip == "```":
          closed = true
          inc i
          break
        body.add lines[i] & "\n"
        inc i
      if not closed:
        result.issues.add ParseIssue(line: openLine,
          msg: "unterminated ``` fence for " & path &
               " (no closing ``` before end of reply)")
      if "<<<<<<< SEARCH" in body or ">>>>>>> REPLACE" in body:
        var act = Action(kind: akPatch, path: path)
        let blines = body.splitLines
        var k = 0
        var inSearch = false
        var inReplace = false
        var s = ""
        var r = ""
        var blockOpenK = -1
        while k < blines.len:
          let bln = blines[k].strip
          let fileLine = openLine + k + 1
          if bln == "<<<<<<< SEARCH":
            if inSearch or inReplace:
              result.issues.add ParseIssue(line: fileLine,
                msg: "patch for " & path &
                  ": new <<<<<<< SEARCH before previous block was closed with >>>>>>> REPLACE")
            inSearch = true
            inReplace = false
            s = ""; r = ""
            blockOpenK = k
            inc k
            continue
          if bln == "=======":
            if not inSearch:
              result.issues.add ParseIssue(line: fileLine,
                msg: "patch for " & path &
                  ": ======= without a preceding <<<<<<< SEARCH")
              inc k
              continue
            inSearch = false
            inReplace = true
            inc k
            continue
          if bln == ">>>>>>> REPLACE":
            if not inReplace:
              result.issues.add ParseIssue(line: fileLine,
                msg: "patch for " & path &
                  ": >>>>>>> REPLACE without a preceding =======")
              inc k
              continue
            act.edits.add (s, r)
            inSearch = false
            inReplace = false
            inc k
            continue
          if inSearch: s.add blines[k] & "\n"
          elif inReplace: r.add blines[k] & "\n"
          inc k
        if inSearch or inReplace:
          let where = if blockOpenK >= 0: openLine + blockOpenK + 1 else: openLine
          result.issues.add ParseIssue(line: where,
            msg: "patch for " & path &
              ": SEARCH/REPLACE block not closed (need <<<<<<< SEARCH … ======= … >>>>>>> REPLACE)")
        result.actions.add act
      else:
        result.actions.add Action(kind: akWrite, path: path, body: body)
      continue
    if ln.startsWith("```") and ln.len > 3:
      let openLine = i + 1
      let lang = ln[3 ..^ 1]
      result.issues.add ParseIssue(line: openLine,
        msg: "```" & lang & " is not a recognised fence — use ```bash for shell, " &
             "or put 'path/to/file' on the line before ``` to write a file")
      inc i
      while i < lines.len and lines[i].strip != "```":
        inc i
      if i < lines.len: inc i
      continue
    if ln == "```":
      let openLine = i + 1
      result.issues.add ParseIssue(line: openLine,
        msg: "bare ``` with no 'path/to/file' on the previous line — " &
             "put the path on its own line first, or use ```bash for shell")
      inc i
      while i < lines.len and lines[i].strip != "```":
        inc i
      if i < lines.len: inc i
      continue
    inc i

proc parseActions*(text: string): seq[Action] =
  ## Text-mode parser. Recognises three fenced-block forms:
  ##   ```bash … ```                              → akBash
  ##   <path>\n``` … ```                          → akWrite
  ##   <path>\n``` <<<<<<< SEARCH … >>>>>>> REPLACE … ``` → akPatch
  ## Multiple SEARCH/REPLACE pairs in one fenced block become one akPatch
  ## with multiple edits. Thin wrapper over `parseActionsChecked` that
  ## drops the issue list — used in spots where we only want the actions.
  parseActionsChecked(text).actions

proc stripActions*(text: string): string =
  ## Mirror of parseActions: returns prose with every action block elided,
  ## collapsing the resulting blank-line runs and trimming leading/trailing
  ## blank lines. Used to suppress the fenced blocks from any post-turn
  ## reprint of the assistant message (the streamer already showed them).
  let lines = text.splitLines
  var kept: seq[string]
  var i = 0
  while i < lines.len:
    let ln = lines[i].strip
    if ln == "```bash" or ln == "```sh" or ln == "```shell":
      inc i
      while i < lines.len and lines[i].strip != "```": inc i
      if i < lines.len: inc i
      continue
    if i + 1 < lines.len and lines[i+1].strip == "```" and looksLikePath(lines[i]):
      i += 2
      while i < lines.len and lines[i].strip != "```": inc i
      if i < lines.len: inc i
      continue
    kept.add lines[i]
    inc i
  var res: seq[string]
  var lastBlank = true
  for l in kept:
    let blank = l.strip.len == 0
    if blank and lastBlank: continue
    res.add l
    lastBlank = blank
  while res.len > 0 and res[^1].strip.len == 0:
    res.setLen res.len - 1
  res.join("\n")
