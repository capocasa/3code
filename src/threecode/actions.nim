## Tool dispatch: translate model tool_call JSON into Actions, then execute.
##
## Two stages, intentionally separated:
##
## **Parse**: `dispatchGlm`, `dispatchGptOss`, etc. accept raw args JSON and
## return an `Action` value. Each family gets its own dispatcher that accepts
## only the tools it was offered in `prompts.nim`. A name outside that set
## returns an `akError` action with a plain message back to the model - no
## crash, no silent reinterpretation across families.
##
## **Execute**: `runAction` drives `akBash` (subprocess), `akRead` (file read
## with optional window), `akWrite`/`akPatch` (file mutations, read-cache
## update), `akWebSearch`/`akWebFetch` (native HTTP), and `akClear`
## (returns a sentinel that triggers a context wipe in the outer loop).
##
## The read cache tracks the last-seen mtime and size of every `read` so
## `patch` can reject stale edits when the file changed since last read.

import std/[json, os, sequtils, strformat, strutils, tables, times]
import types, util, shell, web, config, streamexec, sandbox

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
                  stdin: args{"stdin"}.getStr,
                  timeoutSecs: args{"timeout"}.getInt)
  let argv = args{"cmd"}.getElems
  let line = if argv.len > 0: argv[^1].getStr else: ""
  Action(kind: akBash, body: line,
         stdin: args{"stdin"}.getStr,
         timeoutSecs: args{"timeout"}.getInt)

proc readAction(args: JsonNode): Action =
  Action(kind: akRead,
         path:  args{"path"}.getStr,
         offset: args{"offset"}.getInt,
         limit:  args{"limit"}.getInt)

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

proc clearAction(args: JsonNode): Action =
  Action(kind: akClear,
         body: args{"prompt"}.getStr(""))

proc dispatchGlmOrQwen(family, name: string, args: JsonNode): Action =
  case name
  # Canonical names (the schema we offer glm/qwen/deepseek):
  of "bash": bashAction(args)
  of "read": readAction(args)
  of "write": writeAction(args)
  of "patch": patchAction(args)
  of "update_plan", "todo": planAction(args)
  of "web_search": Action(kind: akWebSearch, body: args{"query"}.getStr)
  of "web_fetch": Action(kind: akWebFetch, body: args{"url"}.getStr)
  of "clear": clearAction(args)
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
  of "read": readAction(args)
  of "apply_patch": applyPatchAction(args)
  of "update_plan", "todo": planAction(args)
  of "web_search": Action(kind: akWebSearch, body: args{"query"}.getStr)
  of "web_fetch": Action(kind: akWebFetch, body: args{"url"}.getStr)
  of "clear": clearAction(args)
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
  of "glm", "qwen", "deepseek", "minimax", "longcat", "hy": dispatchGlmOrQwen(family, name, args)
  of "gpt-oss": dispatchGptOss(family, name, args)
  else: die "unknown family in tool dispatch: '" & family & "'"

proc previewCmd*(body: string): string =
  body.strip.splitLines[0]

proc bannerFor*(act: Action): string =
  ## Returns the parameter portion of the tool banner (no icon/prefix).
  case act.kind
  of akBash:
    previewCmd(act.body)
  of akRead:
    if act.offset > 0 or act.limit > 0:
      let endHint = if act.limit > 0: $(act.offset + act.limit - 1) else: "end"
      &"{act.path} {max(1, act.offset)}-{endHint}"
    else:
      act.path
  of akWrite:
    act.path
  of akPatch:
    act.path
  of akApplyPatch:
    act.path
  of akPlan:
    "update plan"
  of akWebSearch:
    act.body
  of akWebFetch:
    act.body
  of akClear:
    "context cleared"
  of akError:
    "unknown tool '" & act.path & "'"

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

type DiffOp = enum dopEqual, dopDel, dopIns

proc lcsOps(a, b: seq[string]): seq[DiffOp] =
  ## Standard dynamic-programming LCS walk: emits one op per source line
  ## of a (dopEqual / dopDel) plus one dopIns per inserted b line, in
  ## order. O(n*m) table; fine for the file sizes 3code diffs.
  let n = a.len
  let m = b.len
  var dp = newSeqWith(n + 1, newSeq[int](m + 1))
  for i in countdown(n - 1, 0):
    for j in countdown(m - 1, 0):
      if a[i] == b[j]:
        dp[i][j] = dp[i + 1][j + 1] + 1
      else:
        dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
  var i = 0
  var j = 0
  while i < n and j < m:
    if a[i] == b[j]:
      result.add dopEqual; inc i; inc j
    elif dp[i + 1][j] >= dp[i][j + 1]:
      result.add dopDel; inc i
    else:
      result.add dopIns; inc j
  while i < n:
    result.add dopDel; inc i
  while j < m:
    result.add dopIns; inc j

proc computeDiff*(before, after, label: string): string =
  ## Native unified-diff producer. Shelling out to the external `diff`
  ## binary breaks on Windows (no `diff` on stock installs) and on systems
  ## where it isn't on PATH, so we compute the hunks in-process via LCS.
  ## Output is consumed by the green/red painter in display.nim and by
  ## tests that assert changed text appears in the result.
  if before == after: return ""
  # Refuse to diff binary content: emitting raw bytes into the model prompt
  # wastes tokens and corrupts the transcript (e.g. `cat`-ing an ELF binary,
  # or a sed -i on a compiled artifact). The `read` tool already refuses
  # binaries; this covers the shell-mutation and write/patch paths that
  # arrive here with whatever the file held.
  if isBinaryContent(before) or isBinaryContent(after):
    return &"--- a/{label}\n+++ b/{label}\n[binary content changed: diff suppressed]"
  let a = before.splitLines(keepEol = false)
  let b = after.splitLines(keepEol = false)
  let ops = lcsOps(a, b)

  # Map each op to its source index in a / b so we can place context.
  var opA = newSeq[int](ops.len)
  var opB = newSeq[int](ops.len)
  block:
    var ia = 0
    var ib = 0
    for k, op in ops:
      opA[k] = ia
      opB[k] = ib
      case op
      of dopEqual: inc ia; inc ib
      of dopDel: inc ia
      of dopIns: inc ib

  const Ctx = 3
  result = "--- a/" & label & "\n+++ b/" & label & "\n"

  # Group consecutive non-equal ops into hunks, each with its own header
  # and `Ctx` lines of context on either side.
  var k = 0
  while k < ops.len:
    if ops[k] == dopEqual:
      inc k; continue
    let hunkStart = k
    while k < ops.len and ops[k] != dopEqual: inc k
    let k1 = k
    # Expand the window by `Ctx` equal ops backward and forward.
    var lo = hunkStart
    var back = 0
    while lo > 0 and back < Ctx and ops[lo - 1] == dopEqual:
      dec lo; inc back
    var hi = k1
    var fwd = 0
    while hi < ops.len and fwd < Ctx and ops[hi] == dopEqual:
      inc hi; inc fwd
    # Hunk range counts: number of a-side and b-side lines in [lo, hi).
    var aLines = 0
    var bLines = 0
    for x in lo ..< hi:
      case ops[x]
      of dopEqual: inc aLines; inc bLines
      of dopDel: inc aLines
      of dopIns: inc bLines
    let aStart = opA[lo] + 1
    let bStart = opB[lo] + 1
    result.add "@@ -" & $aStart & "," & $aLines & " +" & $bStart & "," & $bLines & " @@\n"
    for x in lo ..< hi:
      case ops[x]
      of dopEqual: result.add " " & a[opA[x]] & "\n"
      of dopDel:   result.add "-" & a[opA[x]] & "\n"
      of dopIns:   result.add "+" & b[opB[x]] & "\n"

proc newReadCache*(): ReadCache =
  ReadCache(state: initTable[string, (Time, int)]())

proc fileSig*(path: string): (Time, int) =
  ## Returns (mtime, size) for the read-cache equality check. On stat failure
  ## (race, perms, NFS), returns (Time(), 0) as a sentinel. This is safe for
  ## cache-miss detection (sentinel != real sig) but can cause a false
  ## cache-hit if the first stat fails and a later stat also fails with the
  ## same sentinel — a narrow race, but worth knowing about.
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

proc runActionStreaming*(act: Action, cache: ReadCache = nil,
    onLine: proc(line: string) = nil): tuple[output: string, code: int, diff: string]

proc runAction*(act: Action, cache: ReadCache = nil): tuple[output: string, code: int, diff: string] =
  case act.kind
  of akBash:
    # Bash execution (native timeout, process-group kill, output clipping,
    # cache + diff) lives in the streaming executor and is shared by both
    # paths. `onLine=nil` gives a plain capture; the streaming display path
    # passes a live callback. There is no duplicated bash branch here.
    return runActionStreaming(act, cache)
  of akRead:
    let path = resolvePath(act.path)
    let (rdOk, rdReason) = sandbox.checkRawPath(act.path, needsWrite = false)
    if not rdOk:
      return (&"error: {rdReason}", 1, "")
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
    const DefaultLineCap = 250
    const MaxLines = 2000
    const MaxBytes = 60 * 1024
    const LineSkipBytes = 2048
    let lines = content.splitLines
    let total =
      if lines.len > 0 and lines[^1] == "": lines.len - 1
      else: lines.len
    let start = max(0, act.offset - 1)
    if start >= total: return ("", 0, "")
    let explicit = act.offset > 0 or act.limit != 0
    let hardCap = if explicit: MaxLines else: DefaultLineCap
    # Compute effective end, respecting hardCap, MaxBytes, and LineSkipBytes.
    var endi = min(total, start + hardCap)
    if act.limit > 0:
      endi = min(endi, start + act.limit)
    var capped = endi < total or (act.limit > 0 and endi - start < act.limit)
    var skipped = 0
    var bytes = 0
    var outLines: seq[string]
    for k in start ..< endi:
      let ln = lines[k]
      if ln.len > LineSkipBytes:
        outLines.add &"[skipped: {ln.len} bytes, single line]"
        inc skipped
        bytes += 40
      else:
        outLines.add ln
        bytes += ln.len + 1
      if bytes > MaxBytes:
        capped = true
        break
    var body = outLines.join("\n")
    if capped:
      let shown = outLines.len
      body.add &"\n... [file is {total} lines, {content.len} bytes; showed {shown} lines from line {start + 1}. Use read(path, offset, limit) for a specific range.] ..."
    elif skipped > 0:
      body.add &"\n... [{skipped} line(s) skipped: over {LineSkipBytes} bytes each] ..."
    return (body, 0, "")
  of akWrite:
    let path = resolvePath(act.path)
    let (wrOk, wrReason) = sandbox.checkRawPath(act.path, needsWrite = true)
    if not wrOk:
      return (&"error: {wrReason}", 1, "")
    try:
      let dir = parentDir(path)
      if dir != "": createDir(dir)
      writeFile(path, act.body)
      if cache != nil:
        cache.state[path] = fileSig(path)
      return (&"wrote {path} ({act.body.len} bytes)", 0, act.body)
    except CatchableError as e:
      return (&"error: write {path}: {e.msg}", 1, "")
  of akPatch:
    if act.edits.len == 0:
      return ("patch has no edits", 1, "")
    if act.path.len == 0:
      return ("error: patch: 'path' argument is required", 1, "")
    let path = resolvePath(act.path)
    let (paOk, paReason) = sandbox.checkRawPath(act.path, needsWrite = true)
    if not paOk:
      return (&"error: {paReason}", 1, "")
    if not fileExists(path):
      return (&"error: {path} does not exist", 1, "")
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
      let summary = if diff.len > 0: diff else: &"patched {path} (no textual change)"
      return (summary, 0, diff)
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
      # Every apply_patch op mutates (add/update/delete), so all need write.
      let (apOk, apReason) = sandbox.checkRawPath(op.path, needsWrite = true)
      if not apOk:
        msgs.add &"error: {apReason}"; anyFail = true; continue
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
            discard applied
            let d = computeDiff(before, content, path)
            if d.len > 0: diffs.add d
            msgs.add "updated " & path & " (" & $applied & " hunk" & (if applied == 1: "" else: "s") & ")"
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
      let hits = webSearch(act.body, activeSearchUrl)
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
  of akClear:
    return ("", 0, "")
  of akError:
    return (act.body, 1, "")

proc runActionStreaming*(act: Action, cache: ReadCache = nil,
    onLine: proc(line: string) = nil): tuple[output: string, code: int, diff: string] =
  ## Like `runAction` but streams bash stdout line-by-line via `onLine`.
  ## Non-bash actions delegate to `runAction` (no streaming needed).
  if act.kind != akBash:
    return runAction(act, cache)
  let cmd = act.body.strip
  let mutPath = bashMutationPath(cmd)
  let (readPath, _) = bashReadPath(cmd)
  let beforeContent =
    if mutPath != "" and mutPath != "." and fileExists(resolvePath(mutPath)):
      try: readFile(resolvePath(mutPath))
      except CatchableError as e:
        debugOut &"diff read failed (before): {e.msg}"
        ""
    else: ""
  let beforeExists = mutPath != "" and mutPath != "." and
                       fileExists(resolvePath(mutPath))
  let (rawOut, code, cap) = runStreamingBash(act, cache, onLine)
  # Cache early-return paths: runStreamingBash returns the error body
  # directly with code != 0 (or 0 for unchanged-read). Detect and
  # short-circuit.
  if rawOut.startsWith("error:") or rawOut.startsWith("[unchanged"):
    return (rawOut, code, "")
  var out2 = rawOut
  if isBinaryContent(out2):
    out2 = &"[binary output: {out2.len} bytes — not shown]"
  let outClip = clipMiddle(out2, 2000, 2000)
  var body = ""
  if outClip.len > 0:
    body.add outClip
    if not outClip.endsWith("\n"): body.add "\n"
  if code == 124:
    body.add &"[timed out after {cap}s. This is your own setting, not a system limit: pass timeout={maxBashTimeoutSecs()} (or any value up to that) and rerun. Or background the work.]"
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
        except CatchableError as e:
          debugOut &"diff read failed (after): {e.msg}"
          ""
      else: ""
    if beforeExists and beforeContent != after:
      diff = computeDiff(beforeContent, after, p)
  if body.len == 0 and code == 0:
    body = "exit 0 (no output)"
  return (body, code, diff)

proc parseActionsChecked*(text: string):
    tuple[actions: seq[Action], issues: seq[ParseIssue]] =
  ## Text-mode parser with syntax-fail detection. Same recognised forms
  ## as `parseActions`, but additionally flags unterminated fences,
  ## orphan code-fence blocks (no `bash` tag and no preceding path), and
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
  ##   [bash fence]                               -> akBash
  ##   <path> then [code fence]                   -> akWrite
  ##   <path> then [SEARCH/REPLACE fence]         -> akPatch
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
