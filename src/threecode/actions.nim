import std/[json, os, strformat, strutils, tables, times]
import types, util, shell, web

# ---------------------------------------------------------------------------
# Tool dispatch: strictly per-model.
#
# Each model gets its own dispatcher, accepting only the tool names it was
# actually offered in `prompts.nim`. A model emitting a name outside its
# offered set lands in the catch-all (probably training leakage) and gets a
# clear error back — no silent reinterpretation across models.
#
# All accessors are nil-safe (`getStr`/`getElems` return defaults for nil
# or wrong-typed nodes). Garbage args produce an empty-bodied Action;
# runAction returns a clean error rather than crashing.
# ---------------------------------------------------------------------------

proc stripHarmonyChannel(name: string): string =
  ## gpt-oss decorates names like `shell<|channel|>commentary`. Strip
  ## the suffix so dispatch can match on the bare name. Only meaningful
  ## for gpt-oss — other models don't emit it.
  let idx = name.find("<|")
  if idx >= 0: name[0 ..< idx] else: name

proc unknownTool(family, name: string): Action =
  ## A tool name no dispatcher recognised, even after alias routing.
  ## Returns an akError action with a short, plain message so the
  ## model gets a structured reply instead of a silent confab. Most
  ## common misnames (`bash`/`shell`, `write`/`patch`/`edit`,
  ## `apply_patch`/`applypatch`/`apply-patch`) are aliased upstream
  ## and never reach this path.
  let bare = stripHarmonyChannel(name)
  Action(kind: akError, path: bare,
         body: "Error: tool '" & bare & "' is not available. " &
               "This harness exposes shell-style commands and file " &
               "edits; re-emit using the tools you were offered.")

proc bashAction(args: JsonNode): Action =
  ## Accepts both shapes that show up in practice:
  ## - glm/qwen `bash`: `{command: "...", stdin?: "..."}`
  ## - gpt-oss/Codex `shell`: `{cmd: ["bash", "-lc", "..."]}`
  ## Either way the result is an akBash with the command line as body.
  ## When both keys are present, `command` wins (same shape the previous
  ## glm/qwen dispatcher used). All accessors are nil-safe — `getStr`
  ## and `getElems` return defaults for missing keys or wrong types.
  let cmdStr = args{"command"}.getStr
  if cmdStr.len > 0:
    return Action(kind: akBash, body: cmdStr,
                  stdin: args{"stdin"}.getStr)
  let argv = args{"cmd"}.getElems
  let line = if argv.len > 0: argv[^1].getStr else: ""
  Action(kind: akBash, body: line, stdin: args{"stdin"}.getStr)

proc writeAction(args: JsonNode): Action =
  Action(kind: akWrite,
         path: args{"path"}.getStr,
         body: args{"body"}.getStr)

proc patchAction(args: JsonNode): Action =
  var act = Action(kind: akPatch, path: args{"path"}.getStr)
  for e in args{"edits"}.getElems:
    act.edits.add (e{"search"}.getStr, e{"replace"}.getStr)
  act

proc applyPatchAction(args: JsonNode): Action =
  Action(kind: akApplyPatch, body: args{"input"}.getStr)

proc planAction(args: JsonNode): Action =
  var act = Action(kind: akPlan)
  let src =
    if args{"items"} != nil and args{"items"}.kind == JArray: args{"items"}
    else: args{"steps"}
  for it in src.getElems:
    let text = it{"text"}.getStr(it{"description"}.getStr)
    let status = it{"status"}.getStr
    if text.len > 0:
      act.plan.add PlanItem(text: text, status: status)
  act

proc dispatchGlmOrQwen(family, name: string, args: JsonNode): Action =
  case name
  # Canonical names (the schema we offer glm/qwen/deepseek):
  of "bash": bashAction(args)
  of "write": writeAction(args)
  of "patch": patchAction(args)
  of "update_plan", "todo": planAction(args)
  of "web_search": Action(kind: akWebSearch, body: args{"query"}.getStr)
  of "web_fetch": Action(kind: akWebFetch, body: args{"url"}.getStr)
  # Aliases — gpt-oss-shape names that show up as training leakage.
  # Lossless: `shell` → akBash, `apply_patch` → akApplyPatch (we have
  # the V4A parser), `edit` → akPatch (same shape as patch). Routed
  # silently rather than warning the model out of it.
  of "shell": bashAction(args)
  of "apply_patch", "applypatch", "apply-patch": applyPatchAction(args)
  of "edit": patchAction(args)
  else:
    unknownTool(family, name)

proc dispatchGptOss(family, rawName: string, args: JsonNode): Action =
  case stripHarmonyChannel(rawName)
  # Canonical names (the schema we offer gpt-oss):
  of "shell": bashAction(args)
  of "apply_patch": applyPatchAction(args)
  of "update_plan", "todo": planAction(args)
  of "web_search": Action(kind: akWebSearch, body: args{"query"}.getStr)
  of "web_fetch": Action(kind: akWebFetch, body: args{"url"}.getStr)
  # Aliases — glm/qwen-shape names that show up as training leakage,
  # plus the misspellings Codex's own prompt warns about. Routed
  # silently rather than warning the model out of it.
  of "bash": bashAction(args)
  of "applypatch", "apply-patch": applyPatchAction(args)
  of "write": writeAction(args)
  of "patch", "edit": patchAction(args)
  else:
    unknownTool(family, rawName)

proc toolCallToAction*(family, name: string, args: JsonNode): Action =
  ## Routes a tool_call to the dispatcher for the active family. The family
  ## label comes from `Profile.family` ("glm" / "qwen" / "gpt-oss"); the
  ## case statement below mirrors `setup` in `prompts.nim`.
  case family
  of "glm", "qwen", "deepseek": dispatchGlmOrQwen(family, name, args)
  of "gpt-oss": dispatchGptOss(family, name, args)
  else: die "unknown family in tool dispatch: '" & family & "'"

proc previewCmd*(body: string, width = 64): string =
  let first = body.strip.splitLines[0]
  if first.len > width: first[0 ..< width-1] & "…" else: first

proc bannerFor*(act: Action): string =
  case act.kind
  of akBash:
    "bash   " & previewCmd(act.body)
  of akRead:
    if act.offset > 0 or act.limit > 0:
      let endHint = if act.limit > 0: $(act.offset + act.limit - 1) else: "end"
      &"read   {act.path}  [lines {max(1, act.offset)}-{endHint}]"
    else:
      &"read   {act.path}"
  of akWrite:
    &"write  {act.path}  ({humanBytes(act.body.len)})"
  of akPatch:
    &"patch  {act.path}  ({act.edits.len} edit" & (if act.edits.len == 1: "" else: "s") & ")"
  of akApplyPatch:
    let nl = act.body.count('\n')
    &"apply_patch  ({nl} line" & (if nl == 1: "" else: "s") & ")"
  of akPlan:
    &"plan   ({act.plan.len} item" & (if act.plan.len == 1: "" else: "s") & ")"
  of akWebSearch:
    "web    search " & act.body
  of akWebFetch:
    "web    fetch " & act.body
  of akError:
    "error  unknown tool '" & act.path & "'"

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

type
  V4AOpKind = enum vkAdd, vkUpdate, vkDelete
  V4AOp = object
    kind: V4AOpKind
    path: string
    body: string                  ## vkAdd: full content
    edits: seq[(string, string)]  ## vkUpdate: one (search, replace) per hunk

proc parseV4APatch(text: string): seq[V4AOp] =
  ## Parse Codex's V4A format (`*** Begin Patch ... *** End Patch`) into a
  ## sequence of file operations. Tolerant: hunks may omit the `@@` anchor;
  ## context lines may omit the leading space (some emitters do).
  let lines = text.splitLines
  var i = 0
  while i < lines.len and not lines[i].startsWith("*** Begin Patch"):
    inc i
  if i < lines.len: inc i
  while i < lines.len:
    let line = lines[i]
    if line.startsWith("*** End Patch"): break
    if line.startsWith("*** Add File: "):
      let path = line["*** Add File: ".len .. ^1].strip
      inc i
      var body = ""
      while i < lines.len and not lines[i].startsWith("***"):
        let l = lines[i]
        if l.startsWith("@@"):
          raise newException(ValueError,
            "Add File '" & path & "': '@@' hunk anchor is not valid in an Add File body — emit only '+'-prefixed lines for new files")
        if l.len > 0 and l[0] == '-':
          raise newException(ValueError,
            "Add File '" & path & "': '-'-prefixed line is not valid in an Add File body — emit only '+'-prefixed lines for new files")
        if l.len > 0 and l[0] == '+': body.add l[1 .. ^1] & "\n"
        else: body.add l & "\n"
        inc i
      result.add V4AOp(kind: vkAdd, path: path, body: body)
    elif line.startsWith("*** Delete File: "):
      let path = line["*** Delete File: ".len .. ^1].strip
      inc i
      result.add V4AOp(kind: vkDelete, path: path)
    elif line.startsWith("*** Update File: "):
      let path = line["*** Update File: ".len .. ^1].strip
      inc i
      var op = V4AOp(kind: vkUpdate, path: path)
      var search = ""
      var replace = ""
      proc flush() =
        if search.len > 0 or replace.len > 0:
          op.edits.add (search, replace)
          search.setLen 0
          replace.setLen 0
      while i < lines.len and not lines[i].startsWith("***"):
        let l = lines[i]
        if l.startsWith("@@"):
          flush()
          inc i
          continue
        if l.len == 0:
          search.add "\n"
          replace.add "\n"
        else:
          case l[0]
          of '-':
            search.add l[1 .. ^1] & "\n"
          of '+':
            replace.add l[1 .. ^1] & "\n"
          of ' ':
            search.add l[1 .. ^1] & "\n"
            replace.add l[1 .. ^1] & "\n"
          else:
            search.add l & "\n"
            replace.add l & "\n"
        inc i
      flush()
      result.add op
    else:
      inc i

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
    if isBinaryContent(content):
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
    if act.path.len == 0:
      return ("error: patch: 'path' argument is required", 1, "")
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
  of akApplyPatch:
    var ops: seq[V4AOp]
    try:
      ops = parseV4APatch(act.body)
    except ValueError as e:
      return (&"error: apply_patch: {e.msg}", 1, "")
    if ops.len == 0:
      return ("error: apply_patch: no operations parsed (need *** Begin Patch ... *** End Patch with at least one *** Add/Update/Delete File: line)", 1, "")
    var msgs: seq[string]
    var diffs = ""
    var anyFail = false
    for op in ops:
      if op.path.len == 0:
        msgs.add "error: missing path on operation"; anyFail = true
        continue
      let path = resolvePath(op.path)
      case op.kind
      of vkAdd:
        try:
          let dir = parentDir(path)
          if dir != "": createDir(dir)
          let before = if fileExists(path): readFile(path) else: ""
          writeFile(path, op.body)
          if cache != nil: cache.state[path] = fileSig(path)
          msgs.add &"added {path} ({op.body.len} bytes)"
          let d = computeDiff(before, op.body, path)
          if d.len > 0: diffs.add d
        except CatchableError as e:
          msgs.add &"error: add {path}: {e.msg}"
          anyFail = true
      of vkUpdate:
        if not fileExists(path):
          msgs.add &"error: update {path}: does not exist"
          anyFail = true
          continue
        if cache != nil and path in cache.state and
           fileSig(path) != cache.state[path]:
          msgs.add &"error: {path} changed on disk since the last read in this session — re-read before patching"
          anyFail = true
          continue
        try:
          let before = readFile(path)
          var content = before
          var applied = 0
          var hunkOk = true
          for (s, r) in op.edits:
            let (next, ok) = replaceFirst(content, s, r)
            if not ok:
              let hint = nearestLineHint(content, s)
              msgs.add &"error: hunk did not match in {path}{hint}:\n{s}"
              hunkOk = false
              anyFail = true
              break
            content = next
            inc applied
          if hunkOk:
            writeFile(path, content)
            if cache != nil: cache.state[path] = fileSig(path)
            msgs.add &"patched {path} ({applied} hunk" &
                     (if applied == 1: "" else: "s") & ")"
            let d = computeDiff(before, content, path)
            if d.len > 0: diffs.add d
        except CatchableError as e:
          msgs.add &"error: update {path}: {e.msg}"
          anyFail = true
      of vkDelete:
        try:
          if fileExists(path):
            let before = readFile(path)
            removeFile(path)
            if cache != nil: cache.state.del(path)
            msgs.add &"deleted {path}"
            let d = computeDiff(before, "", path)
            if d.len > 0: diffs.add d
          else:
            msgs.add &"deleted {path} (already missing)"
        except CatchableError as e:
          msgs.add &"error: delete {path}: {e.msg}"
          anyFail = true
    return (msgs.join("\n"), (if anyFail: 1 else: 0), diffs)
  of akPlan:
    if act.plan.len == 0:
      return ("error: update_plan requires at least one item", 1, "")
    var inProgress = 0
    var lines: seq[string]
    for item in act.plan:
      let status =
        case item.status
        of "pending", "in_progress", "completed": item.status
        else: "pending"
      if status == "in_progress": inc inProgress
      lines.add status & ": " & item.text
    if inProgress > 1:
      return ("error: update_plan must have at most one in_progress item", 1, "")
    return (lines.join("\n"), 0, "")
  of akWebSearch:
    if act.body.len == 0:
      return ("error: web_search requires a query", 1, "")
    try:
      let hits = webSearch(act.body)
      return (formatHits(hits), 0, "")
    except CatchableError as e:
      return ("error: web_search: " & e.msg, 1, "")
  of akWebFetch:
    if act.body.len == 0:
      return ("error: web_fetch requires a url", 1, "")
    try:
      let text = fetchUrl(act.body)
      return (capText(text), 0, "")
    except CatchableError as e:
      return ("error: web_fetch: " & e.msg, 1, "")
  of akError:
    return (act.body, 1, "")

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
