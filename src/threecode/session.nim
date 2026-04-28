import std/[algorithm, json, os, strutils, times]
import types, prompts, util

proc sessionDir*(): string =
  userDataRoot() / "sessions"

proc sessionIdFromPath*(path: string): string =
  let name = path.extractFilename
  if name.endsWith(".json"): name[0 ..< name.len - 5] else: name

proc newSessionPath*(): string =
  let stamp = now().format("yyyyMMdd'T'HHmmss")
  sessionDir() / (stamp & ".json")

proc listSessionPaths*(): seq[string] =
  let d = sessionDir()
  if not dirExists(d): return
  for kind, path in walkDir(d):
    if kind == pcFile and path.endsWith(".json"):
      result.add path
  result.sort(order = SortOrder.Descending)

proc sessionCwd*(path: string): string =
  try: parseJson(readFile(path)){"cwd"}.getStr("")
  except CatchableError: ""

proc listSessionPathsForCwd*(cwd: string): seq[string] =
  for p in listSessionPaths():
    let c = sessionCwd(p)
    if c == cwd or c == "":
      result.add p

proc resolveSessionPath*(id: string, cwd = ""): string =
  ## `id` is bare (no .json) or a full path. Returns "" if not found.
  ## When `id` is empty and `cwd` is set, prefers sessions whose saved cwd
  ## matches (or is unknown); otherwise returns the latest of any.
  if id == "":
    let candidates =
      if cwd != "": listSessionPathsForCwd(cwd)
      else: listSessionPaths()
    if candidates.len == 0: return ""
    return candidates[0]
  if fileExists(id): return id
  let candidate = sessionDir() / (id & ".json")
  if fileExists(candidate): return candidate
  let candidate2 = sessionDir() / id
  if fileExists(candidate2): return candidate2
  ""

proc toolLogToJson*(log: seq[ToolRecord]): JsonNode =
  result = newJArray()
  for rec in log:
    result.add %*{
      "banner": rec.banner,
      "output": rec.output,
      "code": rec.code,
      "kind": $rec.kind,
    }

proc toolLogFromJson*(node: JsonNode): seq[ToolRecord] =
  if node == nil or node.kind != JArray: return
  for item in node:
    if item.kind != JObject: continue
    var k = akBash
    try: k = parseEnum[ActionKind](item{"kind"}.getStr("akBash"))
    except ValueError: discard
    result.add ToolRecord(
      banner: item{"banner"}.getStr(""),
      output: item{"output"}.getStr(""),
      code: item{"code"}.getInt(0),
      kind: k,
    )

proc saveSession*(session: Session, messages: JsonNode) =
  if session.savePath == "": return
  try:
    createDir(session.savePath.parentDir)
    let body = %*{
      "version": 1,
      "created": session.created,
      "updated": $now(),
      "profile": session.profileName,
      "cwd": session.cwd,
      "usage": {
        "promptTokens": session.usage.promptTokens,
        "completionTokens": session.usage.completionTokens,
        "totalTokens": session.usage.totalTokens,
        "cachedTokens": session.usage.cachedTokens,
      },
      "lastPromptTokens": session.lastPromptTokens,
      "messages": messages,
      "toolLog": toolLogToJson(session.toolLog),
    }
    writeFile(session.savePath, body.pretty)
  except CatchableError as e:
    stderr.writeLine "3code: session save failed: " & e.msg

proc loadSessionFile*(path: string): (Session, JsonNode) =
  let raw = try: readFile(path)
            except CatchableError as e:
              die("cannot read session " & path & ": " & e.msg, ExitConfig)
  let j = try: parseJson(raw)
          except CatchableError as e:
            die("bad session json in " & path & ": " & e.msg, ExitConfig)
  var sess = Session(savePath: path)
  sess.profileName = j{"profile"}.getStr("")
  sess.created = j{"created"}.getStr($now())
  sess.cwd = j{"cwd"}.getStr("")
  sess.lastPromptTokens = j{"lastPromptTokens"}.getInt(0)
  let u = j{"usage"}
  if u != nil and u.kind == JObject:
    sess.usage.promptTokens = u{"promptTokens"}.getInt(0)
    sess.usage.completionTokens = u{"completionTokens"}.getInt(0)
    sess.usage.totalTokens = u{"totalTokens"}.getInt(0)
    sess.usage.cachedTokens = u{"cachedTokens"}.getInt(0)
  sess.toolLog = toolLogFromJson(j{"toolLog"})
  var messages = j{"messages"}
  if messages == nil or messages.kind != JArray:
    messages = %* [{"role": "system", "content": DefaultSystemPrompt}]
  (sess, messages)

proc firstUserMessage*(messages: JsonNode): string =
  if messages == nil or messages.kind != JArray: return ""
  for m in messages:
    if m.kind == JObject and m{"role"}.getStr == "user":
      return m{"content"}.getStr("")
  ""

proc historyFile*(): string =
  let dir = userDataRoot()
  try:
    createDir(dir)
    result = dir / "history"
  except OSError, IOError:
    result = ""
