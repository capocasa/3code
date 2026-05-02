import std/[algorithm, json, os, strutils, tables, times]
import types, prompts, util, actions

const SessionExt* = ".3log"

# ---------------------------------------------------------------------------
# Session storage: human-readable indented-records.
#
# A session.3log is an append-of-records text file. Each record is a header
# line at column 0, followed by zero or more body lines indented exactly two
# spaces. Blank lines visually separate records but are also accepted as
# body content while a record is open (so editors that strip trailing
# whitespace round-trip cleanly).
#
#   header := role [' ' arg]*
#   arg    := positional | key=value | +flag[=value]
#   body   := ('  ' line '\n')*
#
# Roles:
#   session     - one per file, top of the file. Created stamp + profile + cwd.
#   system      - the system prompt (body = prompt text).
#   user        - user input (body = message text).
#   reasoning   - merges into the next assistant's reasoning_content.
#   assistant   - assistant text content (body). Followed by zero or more
#                 tool_use records that join its tool_calls, optionally
#                 closed by a tokens record carrying usage.
#   tool_use    - one per tool call. Header: id, tool name, optional path.
#                 Body holds command / file body / patch text using
#                 `-- name --` section markers when a tool needs more
#                 than one section.
#   tool_result - one per tool response. Header: id, exit=N, optional flags.
#                 Body is the merged stdout/stderr returned to the model.
#   tokens      - per-callModel token usage. Header-only, no body.
# ---------------------------------------------------------------------------

const Roles = ["session", "system", "context", "project_notes",
               "user", "reasoning", "assistant",
               "tool_use", "tool_result", "tokens"]

# ---------- paths ----------

proc sessionDir*(): string =
  userDataRoot() / "sessions"

proc sessionIdFromPath*(path: string): string =
  let name = path.extractFilename
  if name.endsWith(SessionExt): name[0 ..< name.len - SessionExt.len] else: name

proc newSessionPath*(): string =
  let stamp = now().format("yyyyMMdd'T'HHmmss")
  sessionDir() / (stamp & SessionExt)

proc listSessionPaths*(): seq[string] =
  let d = sessionDir()
  if not dirExists(d): return
  for kind, path in walkDir(d):
    if kind == pcFile and path.endsWith(SessionExt):
      result.add path
  result.sort(order = SortOrder.Descending)

# ---------- record parser ----------

type
  Record = object
    role: string
    args: seq[string]
    body: string

proc isHeaderLine(line: string): bool =
  if line.len == 0: return false
  if line[0] == ' ' or line[0] == '\t': return false
  for r in Roles:
    if line == r or line.startsWith(r & " "):
      return true
  false

proc trimTrailingEmpty(s: var seq[string]) =
  while s.len > 0 and s[^1].len == 0:
    s.setLen s.len - 1

proc parseRecords(text: string): seq[Record] =
  var current = Record()
  var inRecord = false
  var bodyLines: seq[string]
  proc flush(buf: var seq[Record]) =
    if not inRecord: return
    trimTrailingEmpty(bodyLines)
    current.body = bodyLines.join("\n")
    buf.add current
    current = Record()
    bodyLines.setLen 0
    inRecord = false
  for line in text.splitLines:
    if isHeaderLine(line):
      flush(result)
      let parts = line.split(' ')
      current.role = parts[0]
      if parts.len > 1:
        for p in parts[1 .. ^1]:
          if p.len > 0: current.args.add p
      inRecord = true
    elif inRecord:
      if line.len >= 2 and line[0] == ' ' and line[1] == ' ':
        bodyLines.add line[2 .. ^1]
      elif line.len == 0:
        bodyLines.add ""
      else:
        bodyLines.add line  # tolerate misindented body
  flush(result)

proc parseArgs(args: seq[string]): tuple[
    pos: seq[string],
    kv: Table[string, string],
    flags: Table[string, string]] =
  result.kv = initTable[string, string]()
  result.flags = initTable[string, string]()
  for a in args:
    if a.len == 0: continue
    if a[0] == '+':
      let body = a[1 .. ^1]
      let eq = body.find('=')
      if eq < 0: result.flags[body] = ""
      else: result.flags[body[0 ..< eq]] = body[eq + 1 .. ^1]
    elif '=' in a:
      let eq = a.find('=')
      result.kv[a[0 ..< eq]] = a[eq + 1 .. ^1]
    else:
      result.pos.add a

proc parseSections(body: string): seq[(string, string)] =
  ## Split `body` on `-- name --` separator lines. The first section is
  ## unlabeled (label=""). Section markers must occupy the entire line,
  ## with no leading whitespace, so prose that mentions "-- foo --" mid-line
  ## doesn't accidentally split a section.
  var label = ""
  var current: seq[string]
  for line in body.splitLines:
    if line.startsWith("-- ") and line.endsWith(" --") and line.len >= 7:
      let inner = line[3 .. ^4].strip
      result.add (label, current.join("\n"))
      label = inner
      current.setLen 0
    else:
      current.add line
  result.add (label, current.join("\n"))

# ---------- record → wire JSON ----------

proc sectionText(sections: seq[(string, string)], label: string): string =
  for s in sections:
    if s[0] == label: return s[1]
  ""

proc recordToToolCall(r: Record): JsonNode =
  ## Reconstruct the OpenAI-shape tool_call JSON the model originally
  ## emitted. Loses any extra fields the model included beyond what each
  ## dispatcher reads, which the model would have ignored on the next
  ## turn anyway.
  let (pos, _, _) = parseArgs(r.args)
  let id = if pos.len >= 1: pos[0] else: ""
  let tool = if pos.len >= 2: pos[1] else: ""
  let path = if pos.len >= 3: pos[2] else: ""
  let sections = parseSections(r.body)
  let args =
    case tool
    of "bash":
      var a = newJObject()
      a["command"] = %sectionText(sections, "")
      let stdin = sectionText(sections, "stdin")
      if stdin.len > 0: a["stdin"] = %stdin
      a
    of "shell":
      let line = sectionText(sections, "")
      let stdin = sectionText(sections, "stdin")
      var cmdArr = newJArray()
      cmdArr.add %"bash"
      cmdArr.add %"-lc"
      cmdArr.add %line
      var a = newJObject()
      a["cmd"] = cmdArr
      if stdin.len > 0: a["stdin"] = %stdin
      a
    of "write":
      %*{"path": path, "body": sectionText(sections, "")}
    of "patch":
      var arr = newJArray()
      var search = ""
      for s in sections:
        case s[0]
        of "search": search = s[1]
        of "replace":
          arr.add %*{"search": search, "replace": s[1]}
          search = ""
        else: discard
      %*{"path": path, "edits": arr}
    of "apply_patch":
      %*{"input": sectionText(sections, "")}
    of "update_plan", "todo":
      var items = newJArray()
      for s in sections:
        if s[0] == "item":
          var lines = s[1].splitLines
          let status = if lines.len > 0: lines[0].strip else: "pending"
          let text = if lines.len > 1: lines[1 .. ^1].join("\n").strip else: ""
          if text.len > 0:
            items.add %*{"text": text, "status": status}
      %*{"items": items}
    else:
      newJObject()
  %*{
    "id": id,
    "type": "function",
    "function": {"name": tool, "arguments": $args}
  }

proc recordToUsage(r: Record): JsonNode =
  let (_, kv, _) = parseArgs(r.args)
  proc num(k: string): int =
    try: parseInt(kv.getOrDefault(k, "0")) except ValueError: 0
  let fresh = num("fresh")
  let cached = num("cached")
  let prompt = fresh + cached
  var elapsed = 0
  if "elapsed" in kv:
    let e = kv["elapsed"]
    let trimmed = if e.endsWith("s"): e[0 ..< e.len - 1] else: e
    try: elapsed = parseInt(trimmed) except ValueError: discard
  result = %*{
    "promptTokens": prompt,
    "completionTokens": num("out"),
    "totalTokens": prompt + num("out"),
    "cachedTokens": cached,
    "elapsed": elapsed,
  }
  # Preserve timestamp positionally (first non-key arg).
  let (pos, _, _) = parseArgs(r.args)
  if pos.len > 0: result["ts"] = %pos[0]

# ---------- writer ----------

proc splitPreamble(content: string): tuple[ctx, notes, body: string] =
  ## Peel `<session_context>...</session_context>` and the optional trailing
  ## `<project_notes>...</project_notes>` off a user message's content.
  ## Mirror of `buildUserMessage` / `stripPreamble`: only acts on a leading
  ## block, so a user who literally writes `<session_context>` mid-message
  ## stays intact.
  if not content.strip.startsWith("<session_context>"):
    return ("", "", content)
  var s = content
  for tag in ["session_context", "project_notes"]:
    let openTag = "<" & tag & ">"
    let closeTag = "</" & tag & ">"
    let i = s.find(openTag)
    if i < 0: continue
    let j = s.find(closeTag, i + openTag.len)
    if j < 0: continue
    let inner = s[i + openTag.len ..< j].strip
    if tag == "session_context": result.ctx = inner
    else: result.notes = inner
    s = s[0 ..< i] & s[j + closeTag.len .. ^1]
  result.body = s.strip

proc joinPreamble(ctx, notes, body: string): string =
  ## Inverse of `splitPreamble`. Reassembles the wire-format user content
  ## the model originally saw. Both blocks are optional; `body` may be
  ## empty if the user sent no text alongside the preamble.
  var pre = ""
  if ctx.len > 0:
    pre.add "<session_context>\n" & ctx & "\n</session_context>"
  if notes.len > 0:
    if pre.len > 0: pre.add "\n\n"
    pre.add "<project_notes>\n" & notes & "\n</project_notes>"
  if pre.len == 0: return body
  if body.len == 0: return pre
  pre & "\n\n" & body

proc indentBody(body: string): string =
  if body.len == 0: return ""
  var b = body
  if b.endsWith("\n"): b.setLen b.len - 1
  var lines = b.split('\n')
  for i, l in lines: lines[i] = "  " & l
  result = lines.join("\n") & "\n"

proc emitRecord(s: var string, header, body: string) =
  s.add header
  s.add '\n'
  s.add indentBody(body)
  s.add '\n'

proc emitHeaderOnly(s: var string, header: string) =
  s.add header
  s.add "\n\n"

proc emitToolUse(s: var string, tc: JsonNode) =
  let id = tc{"id"}.getStr("")
  let fn = tc{"function"}
  let rawName = if fn != nil: fn{"name"}.getStr("") else: ""
  let argsStr = if fn != nil: fn{"arguments"}.getStr("") else: ""
  let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
             except CatchableError: newJObject()
  var name = rawName
  let pipe = name.find("<|")
  if pipe >= 0: name = name[0 ..< pipe]
  case name
  of "bash":
    let cmd = args{"command"}.getStr("")
    let stdin = args{"stdin"}.getStr("")
    var body = cmd
    if stdin.len > 0:
      if not body.endsWith("\n"): body.add "\n"
      body.add "-- stdin --\n" & stdin
    emitRecord s, "tool_use " & id & " bash", body
  of "shell":
    let argv = args{"cmd"}.getElems
    let line = if argv.len > 0: argv[^1].getStr else: ""
    let stdin = args{"stdin"}.getStr("")
    var body = line
    if stdin.len > 0:
      if not body.endsWith("\n"): body.add "\n"
      body.add "-- stdin --\n" & stdin
    emitRecord s, "tool_use " & id & " shell", body
  of "write":
    let path = args{"path"}.getStr("")
    emitRecord s, "tool_use " & id & " write " & path, args{"body"}.getStr("")
  of "patch":
    let path = args{"path"}.getStr("")
    var body = ""
    let edits = args{"edits"}
    if edits != nil and edits.kind == JArray:
      for e in edits:
        if body.len > 0 and not body.endsWith("\n"): body.add "\n"
        body.add "-- search --\n"
        body.add e{"search"}.getStr("")
        if not body.endsWith("\n"): body.add "\n"
        body.add "-- replace --\n"
        body.add e{"replace"}.getStr("")
    emitRecord s, "tool_use " & id & " patch " & path, body
  of "apply_patch":
    emitRecord s, "tool_use " & id & " apply_patch", args{"input"}.getStr("")
  of "update_plan", "todo":
    var body = ""
    let items =
      if args{"items"} != nil and args{"items"}.kind == JArray: args{"items"}
      else: args{"steps"}
    for item in items.getElems:
      if body.len > 0 and not body.endsWith("\n"): body.add "\n"
      body.add "-- item --\n"
      body.add item{"status"}.getStr("pending") & "\n"
      body.add item{"text"}.getStr(item{"description"}.getStr(""))
    emitRecord s, "tool_use " & id & " " & name, body
  else:
    # Unknown tool name: preserve the JSON args verbatim in the body so
    # nothing is lost. Tool name itself stays in the header.
    emitRecord s, "tool_use " & id & " " & name, $args

proc emitTokens(s: var string, usage: JsonNode) =
  if usage == nil or usage.kind != JObject: return
  let total = usage{"totalTokens"}.getInt(0)
  if total <= 0: return
  let prompt = usage{"promptTokens"}.getInt(0)
  let cached = usage{"cachedTokens"}.getInt(0)
  let fresh = max(0, prompt - cached)
  let outTok = usage{"completionTokens"}.getInt(0)
  let elapsed = usage{"elapsed"}.getInt(0)
  let ts = usage{"ts"}.getStr("")
  let hit = if prompt > 0: int((cached.float * 100.0) / prompt.float + 0.5)
            else: 0
  var hdr = "tokens"
  if ts.len > 0: hdr.add " " & ts
  hdr.add " fresh=" & $fresh
  hdr.add " cached=" & $cached
  hdr.add " out=" & $outTok
  hdr.add " hit=" & $hit & "%"
  hdr.add " elapsed=" & $elapsed & "s"
  emitHeaderOnly s, hdr

proc renderSession*(session: Session, messages: JsonNode): string =
  var s = ""
  var hdr = "session"
  if session.created.len > 0: hdr.add " " & session.created
  if session.profileName.len > 0: hdr.add " profile=" & session.profileName
  if session.cwd.len > 0: hdr.add " cwd=" & session.cwd
  emitHeaderOnly s, hdr
  if messages == nil or messages.kind != JArray: return s
  # Map tool_call_id → exit code via the parallel toolLog (entries are
  # appended in the same order tool_calls fire across the message stream).
  var idToExit = initTable[string, int]()
  block:
    var idx = 0
    for m in messages:
      if m.kind != JObject: continue
      if m{"role"}.getStr != "assistant": continue
      let tcs = m{"tool_calls"}
      if tcs == nil or tcs.kind != JArray: continue
      for tc in tcs:
        let id = tc{"id"}.getStr
        if idx < session.toolLog.len:
          idToExit[id] = session.toolLog[idx].code
        inc idx
  for m in messages:
    if m.kind != JObject: continue
    case m{"role"}.getStr
    of "system":
      # Skip — the system prompt is rebuilt from the profile on every
      # `refreshSystemPrompt`, so what's on disk is stale the moment we
      # resume. Saving 5-10KB of boilerplate per session also pushes the
      # actual conversation too far down to skim.
      discard
    of "user":
      let raw = m{"content"}.getStr("")
      let (ctx, notes, body) = splitPreamble(raw)
      if ctx.len > 0: emitRecord s, "context", ctx
      if notes.len > 0: emitRecord s, "project_notes", notes
      emitRecord s, "user", body
    of "assistant":
      let reasoning = m{"reasoning_content"}.getStr("")
      if reasoning.len > 0:
        emitRecord s, "reasoning", reasoning
      emitRecord s, "assistant", m{"content"}.getStr("")
      let tcs = m{"tool_calls"}
      if tcs != nil and tcs.kind == JArray:
        for tc in tcs:
          emitToolUse s, tc
      emitTokens s, m{"usage"}
    of "tool":
      let id = m{"tool_call_id"}.getStr
      let exitCode = idToExit.getOrDefault(id, 0)
      emitRecord s, "tool_result " & id & " exit=" & $exitCode,
                 m{"content"}.getStr("")
    else: discard
  s

# ---------- save / load ----------

proc saveSession*(session: Session, messages: JsonNode) =
  if session.savePath == "": return
  try:
    createDir(session.savePath.parentDir)
    writeFile(session.savePath, renderSession(session, messages))
  except CatchableError as e:
    stderr.writeLine "3code: session save failed: " & e.msg

proc buildToolLogFromMessages(messages: JsonNode,
                              exitByCallId: Table[string, int]): seq[ToolRecord] =
  var idToContent = initTable[string, string]()
  for m in messages:
    if m.kind != JObject: continue
    if m{"role"}.getStr != "tool": continue
    idToContent[m{"tool_call_id"}.getStr] = m{"content"}.getStr("")
  for m in messages:
    if m.kind != JObject: continue
    if m{"role"}.getStr != "assistant": continue
    let tcs = m{"tool_calls"}
    if tcs == nil or tcs.kind != JArray: continue
    for tc in tcs:
      let id = tc{"id"}.getStr
      let fn = tc{"function"}
      let rawName = if fn != nil: fn{"name"}.getStr else: ""
      let argsStr = if fn != nil: fn{"arguments"}.getStr("") else: ""
      let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                 except CatchableError: newJObject()
      var name = rawName
      let pipe = name.find("<|")
      if pipe >= 0: name = name[0 ..< pipe]
      let act =
        case name
        of "bash":
          Action(kind: akBash,
                 body: args{"command"}.getStr,
                 stdin: args{"stdin"}.getStr)
        of "shell":
          let argv = args{"cmd"}.getElems
          let line = if argv.len > 0: argv[^1].getStr else: ""
          Action(kind: akBash, body: line, stdin: args{"stdin"}.getStr)
        of "write":
          Action(kind: akWrite,
                 path: args{"path"}.getStr,
                 body: args{"body"}.getStr)
        of "patch":
          var a = Action(kind: akPatch, path: args{"path"}.getStr)
          let edits = args{"edits"}
          if edits != nil and edits.kind == JArray:
            for e in edits:
              a.edits.add (e{"search"}.getStr, e{"replace"}.getStr)
          a
        of "apply_patch":
          Action(kind: akApplyPatch, body: args{"input"}.getStr)
        of "update_plan", "todo":
          var a = Action(kind: akPlan)
          let items =
            if args{"items"} != nil and args{"items"}.kind == JArray: args{"items"}
            else: args{"steps"}
          for item in items.getElems:
            let text = item{"text"}.getStr(item{"description"}.getStr)
            if text.len > 0:
              a.plan.add PlanItem(text: text, status: item{"status"}.getStr)
          a
        else:
          Action(kind: akError, path: name)
      result.add ToolRecord(
        banner: bannerFor(act),
        output: idToContent.getOrDefault(id, ""),
        code: exitByCallId.getOrDefault(id, 0),
        kind: act.kind,
      )

proc buildPlanFromMessages(messages: JsonNode,
                           exitByCallId: Table[string, int]): seq[PlanItem] =
  for m in messages:
    if m.kind != JObject: continue
    if m{"role"}.getStr != "assistant": continue
    let tcs = m{"tool_calls"}
    if tcs == nil or tcs.kind != JArray: continue
    for tc in tcs:
      let id = tc{"id"}.getStr
      if exitByCallId.getOrDefault(id, 0) != 0: continue
      let fn = tc{"function"}
      let rawName = if fn != nil: fn{"name"}.getStr else: ""
      var name = rawName
      let pipe = name.find("<|")
      if pipe >= 0: name = name[0 ..< pipe]
      if name != "update_plan" and name != "todo": continue
      let argsStr = if fn != nil: fn{"arguments"}.getStr("") else: ""
      let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                 except CatchableError: newJObject()
      let items =
        if args{"items"} != nil and args{"items"}.kind == JArray: args{"items"}
        else: args{"steps"}
      result.setLen 0
      for item in items.getElems:
        let text = item{"text"}.getStr(item{"description"}.getStr)
        if text.len > 0:
          result.add PlanItem(text: text, status: item{"status"}.getStr)

proc loadSessionFile*(path: string): (Session, JsonNode) =
  let raw = try: readFile(path)
            except CatchableError as e:
              die("cannot read session " & path & ": " & e.msg, ExitConfig)
  let records = parseRecords(raw)
  var sess = Session(savePath: path)
  var messages = newJArray()
  var pendingReasoning = ""
  var pendingCtx = ""
  var pendingNotes = ""
  var lastAssistant: JsonNode = nil
  var exitByCallId = initTable[string, int]()
  for r in records:
    let (pos, kv, _) = parseArgs(r.args)
    case r.role
    of "session":
      if pos.len > 0: sess.created = pos[0]
      if "profile" in kv: sess.profileName = kv["profile"]
      if "cwd" in kv: sess.cwd = kv["cwd"]
    of "system":
      messages.add %*{"role": "system", "content": r.body}
      lastAssistant = nil
    of "context":
      pendingCtx = r.body
    of "project_notes":
      pendingNotes = r.body
    of "user":
      let content = joinPreamble(pendingCtx, pendingNotes, r.body)
      pendingCtx = ""
      pendingNotes = ""
      messages.add %*{"role": "user", "content": content}
      lastAssistant = nil
    of "reasoning":
      pendingReasoning = r.body
    of "assistant":
      let msg = %*{"role": "assistant",
                   "content": r.body,
                   "reasoning_content": pendingReasoning}
      pendingReasoning = ""
      messages.add msg
      lastAssistant = msg
    of "tool_use":
      if lastAssistant == nil:
        stderr.writeLine "3code: orphan tool_use in " & path
        continue
      let tc = recordToToolCall(r)
      var tcs = lastAssistant{"tool_calls"}
      if tcs == nil:
        tcs = newJArray()
        lastAssistant["tool_calls"] = tcs
      tcs.add tc
    of "tokens":
      if lastAssistant != nil:
        let u = recordToUsage(r)
        lastAssistant["usage"] = u
        sess.usage.promptTokens += u{"promptTokens"}.getInt(0)
        sess.usage.completionTokens += u{"completionTokens"}.getInt(0)
        sess.usage.totalTokens += u{"totalTokens"}.getInt(0)
        sess.usage.cachedTokens += u{"cachedTokens"}.getInt(0)
        sess.lastPromptTokens = u{"promptTokens"}.getInt(0)
    of "tool_result":
      let id = if pos.len > 0: pos[0] else: ""
      let exitCode = try: parseInt(kv.getOrDefault("exit", "0"))
                     except ValueError: 0
      exitByCallId[id] = exitCode
      messages.add %*{"role": "tool", "tool_call_id": id, "content": r.body}
      lastAssistant = nil
    else: discard
  if messages.len == 0 or messages[0]{"role"}.getStr != "system":
    let backfill = newJArray()
    backfill.add %*{"role": "system", "content": DefaultSystemPrompt}
    for m in messages: backfill.add m
    messages = backfill
  sess.toolLog = buildToolLogFromMessages(messages, exitByCallId)
  sess.plan = buildPlanFromMessages(messages, exitByCallId)
  (sess, messages)

# ---------- session listing helpers ----------

type SessionPreview* = object
  cwd*: string
  profile*: string
  msgCount*: int
  firstUser*: string

proc previewSession*(path: string): SessionPreview =
  ## Fast peek for `--list` and `:sessions` — reads the file, parses just
  ## enough to show cwd / profile / count / first user line. Doesn't
  ## reconstruct the full message tree.
  let raw = try: readFile(path) except CatchableError: return
  for r in parseRecords(raw):
    let (_, kv, _) = parseArgs(r.args)
    case r.role
    of "session":
      if "profile" in kv: result.profile = kv["profile"]
      if "cwd" in kv: result.cwd = kv["cwd"]
    of "system": inc result.msgCount
    of "user":
      inc result.msgCount
      if result.firstUser.len == 0:
        result.firstUser = stripPreamble(r.body)
    of "assistant", "tool_result":
      inc result.msgCount
    else: discard

proc sessionCwd*(path: string): string =
  previewSession(path).cwd

proc listSessionPathsForCwd*(cwd: string): seq[string] =
  for p in listSessionPaths():
    let c = sessionCwd(p)
    if c == cwd or c == "":
      result.add p

proc resolveSessionPath*(id: string, cwd = ""): string =
  ## `id` is bare (no extension) or a full path. Returns "" if not found.
  ## When `id` is empty and `cwd` is set, prefers sessions whose saved cwd
  ## matches (or is unknown); otherwise returns the latest of any.
  if id == "":
    let candidates =
      if cwd != "": listSessionPathsForCwd(cwd)
      else: listSessionPaths()
    if candidates.len == 0: return ""
    return candidates[0]
  if fileExists(id): return id
  let candidate = sessionDir() / (id & SessionExt)
  if fileExists(candidate): return candidate
  let candidate2 = sessionDir() / id
  if fileExists(candidate2): return candidate2
  ""

# ---------- back-compat shims kept for callers ----------

proc usageFromJson*(j: JsonNode): Usage =
  if j == nil or j.kind != JObject: return
  Usage(
    promptTokens: j{"promptTokens"}.getInt(0),
    completionTokens: j{"completionTokens"}.getInt(0),
    totalTokens: j{"totalTokens"}.getInt(0),
    cachedTokens: j{"cachedTokens"}.getInt(0),
  )

proc firstUserMessage*(messages: JsonNode): string =
  if messages == nil or messages.kind != JArray: return ""
  for m in messages:
    if m.kind == JObject and m{"role"}.getStr == "user":
      return stripPreamble(m{"content"}.getStr(""))
  ""

proc historyFile*(): string =
  let dir = userDataRoot()
  try:
    createDir(dir)
    result = dir / "history"
  except OSError, IOError:
    result = ""
