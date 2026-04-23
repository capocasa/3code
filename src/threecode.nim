import std/[httpclient, json, os, strutils, strformat, sequtils, streams, terminal, parsecfg, parseopt, times, atomics, critbits, uri, algorithm]
import threecode/minline
import threecode/web

const Version = staticRead("../threecode.nimble").splitLines().filterIt(it.startsWith("version")).
    mapIt(it.split("=")[1].strip().strip(chars = {'"'}))[0]

const
  ExitUsage = 2
  ExitConfig = 3
  ExitApi = 5

template hint(args: varargs[untyped]) =
  stdout.styledWrite(fgCyan, styleBright, args, resetStyle)

template hintLn(args: varargs[untyped]) =
  stdout.styledWriteLine(fgCyan, styleBright, args, resetStyle)

template err(args: varargs[untyped]) =
  stdout.styledWrite(fgRed, styleBright, args, resetStyle)

template errLn(args: varargs[untyped]) =
  stdout.styledWriteLine(fgRed, styleBright, args, resetStyle)

const SystemPrompt = """
You are 3code, a coding agent running in a terminal.

Call the provided tools (`bash`, `read`, `write`, `patch`) to take actions. After your turn the harness runs each tool call and feeds results back. You may emit prose alongside tool calls. When the task is done, reply with prose and no tool calls.

- `bash(command)` — run a shell command; output and exit code come back.
- `read(path, offset?, limit?)` — read a file, or a line range of it. `offset` is 1-indexed.
- `write(path, body)` — create or overwrite a file.
- `patch(path, edits)` — apply exact-match search/replace edits to an existing file. `edits` is an array of `{search, replace}` objects. Each `search` must be copied byte-for-byte from a prior `read` — same indentation, same trailing whitespace, same line endings. Paraphrased or reformatted matches will fail; on failure retry with a corrected `search`.

Tone: dry wit welcome where it's earned — funny because it's true, a wry aside that also tells the user something real. Skip forced cheer, emoji, and filler like "Great question!".

## Working effectively

### Orient & plan

- Orient first. On a fresh task in an unfamiliar repo, run `ls` and read the README and the build manifest (`*.nimble`, `package.json`, `Cargo.toml`, `pyproject.toml`, etc.) before editing. Skip only for obviously trivial tasks.
- Plan multi-step tasks. For anything beyond a one-liner, sketch a 3–8 step plan before touching files; work the steps in order and note when each is done.

### Scope & style

- Stay in scope. Do what was asked, nothing more. Don't refactor, reformat, add comments/docstrings, or handle hypothetical edge cases the user didn't mention.
- Match the local style. Before writing new code, glance at a neighboring file for naming, imports, error-handling pattern, and indentation. Don't impose your own taste.
- Edit surgically. For a small fix use `patch`, not `write`. For a rename, `patch` the definition and call sites — don't rewrite each file whole.

### Find out, don't guess

- Gather context before guessing. Read real files; don't invent their contents.
- Search before reading. Use `rg` or `grep -rn` (via `bash`) to locate the handful of lines you care about, then `read` only that file — with `offset` / `limit` when the file is large. Prefer `read` over `bash cat` for any file over ~100 lines so you keep range control. Don't read whole files or whole directories unless you actually need them. Prefer `find -maxdepth 2` or `ls` over recursive scans.
- Probe when unsure. When you don't know how an API, library, regex, or command actually behaves, write a short throwaway script in a temp dir (`mktemp -d`, or under `/tmp/`) and run it — don't guess. Clean up the temp dir before moving on.
- Local before web. Installed dependencies, vendored source, CHANGELOGs, `tests/`, `example/`, and `man` pages usually answer the question faster and more accurately than a web search. Check them first. Reach for the web only when the local tree genuinely lacks the info.

### Finish cleanly

- Verify before declaring done. After changes, run the project's tests, build, or typecheck; then `git diff` / `git status` (if it's a git repo) to confirm the change is what you intended and nothing accidental tagged along. Don't call the task complete if anything's off.
- Stop when done. If a task already looks complete when you start, say so and stop — don't invent work.
- Pause before irreversible ops outside the working directory (`rm -rf` of other paths, force-push, database drops, destructive git history rewrites). Explain and wait for the user.

## Finding things

- Files: the `read` tool.
- Search in the working tree: `rg`, `grep -rn`, `find`, `ls` via `bash`.
- Web (for current facts, API details, or docs the local tree doesn't have): `bash` out to `3code web "query"` for numbered DuckDuckGo results; then `3code fetch <url>` for readable page text. Prefer official docs over blogspam.
"""

let ToolsJson = %*[
  {
    "type": "function",
    "function": {
      "name": "bash",
      "description": "Run a shell command. Returns combined stdout/stderr and exit code.",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {"type": "string", "description": "Shell command to execute."}
        },
        "required": ["command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "read",
      "description": "Read a file. Omit offset/limit to read the whole file; otherwise return a line range. `offset` is 1-indexed.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string"},
          "offset": {"type": "integer", "description": "1-indexed line to start at."},
          "limit": {"type": "integer", "description": "Maximum number of lines to return."}
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "write",
      "description": "Write a whole file (create or overwrite). Parent directories are created as needed.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string"},
          "body": {"type": "string"}
        },
        "required": ["path", "body"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "patch",
      "description": "Patch an existing file with one or more exact-match search/replace edits. Each search string must match the current file byte-for-byte.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string"},
          "edits": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "search": {"type": "string"},
                "replace": {"type": "string"}
              },
              "required": ["search", "replace"]
            }
          }
        },
        "required": ["path", "edits"]
      }
    }
  }
]

const ConfigExample = """  [settings]
  current = "openai.gpt-4o-mini"

  [provider]
  name = "openai"
  url = "https://api.openai.com/v1"
  key = "sk-..."
  models = "gpt-4o-mini gpt-4o"

(values are Nim string literals — always wrap them in double quotes.)
"""

const HelpText = """
3code — the economical coding agent. bring your own third-party endpoint.

commands:
  :help             show this message
  :tokens           show token usage for this session
  :clear            reset conversation (keeps system prompt)
  :model            list models for current provider (current marked with *)
  :model X          switch to model X (within current provider)
  :provider         list configured providers (current marked with *)
  :provider X       switch to provider X (model defaults to first in its list)
  :provider add     add a new provider (interactive, verified)
  :provider edit X  edit provider X (url, key, models)
  :provider rm X    remove provider X
  :prompt           show the active system prompt
  :show [N]         show full output of tool call N (default: last)
  :log              list all tool calls this session
  :sessions         list recent saved sessions
  :compact          compact older tool output in context
  :q :quit          exit (also Ctrl-D)

input:
  single-line   just type and press Enter
  multi-line    type three double-quotes on its own line, enter lines, close the same way
  up / down     recall history; down past last clears the line
  tab           complete :commands, provider names, model names

recommended (cache = documented prompt caching):
  deepinfra  (cache)   qwen3-coder-480b, kimi-k2.5
  deepseek   (cache)   deepseek-v3.2
  together             qwen3-coder-480b, kimi-k2.5
  groq                 kimi-k2.5  (fast, no cache)
models outside this list are your tokens to burn.
"""

type
  ActionKind* = enum akBash, akRead, akWrite, akPatch
  Action* = object
    kind*: ActionKind
    path*: string
    body*: string
    edits*: seq[(string, string)]
    offset*: int
    limit*: int
  Profile = object
    name, url, key, modelPrefix, model: string
  Usage* = object
    promptTokens*, completionTokens*, totalTokens*, cachedTokens*: int
  ToolRecord* = object
    banner*: string
    output*: string
    code*: int
    kind*: ActionKind
  Session = object
    usage: Usage
    lastPromptTokens: int
    toolLog: seq[ToolRecord]
    savePath: string
    profileName: string
    created: string

proc die(msg: string, code = 1) {.noreturn.} =
  stderr.writeLine "3code: " & msg
  quit code

proc buildSystemPrompt(p: Profile): string =
  if p.name == "": return SystemPrompt
  let dot = p.name.find('.')
  let provider = if dot < 0: p.name else: p.name[0 ..< dot]
  result = SystemPrompt
  if not result.endsWith("\n"): result.add "\n"
  result.add &"\nRunning {p.model} via {provider}.\n"

proc refreshSystemPrompt(messages: JsonNode, p: Profile) =
  if messages == nil or messages.kind != JArray or messages.len == 0: return
  let m = messages[0]
  if m.kind != JObject or m{"role"}.getStr != "system": return
  m["content"] = %buildSystemPrompt(p)

proc configPath(): string =
  getConfigDir() / "3code" / "config"

proc sessionDir(): string =
  getConfigDir() / "3code" / "sessions"

proc sessionIdFromPath(path: string): string =
  let name = path.extractFilename
  if name.endsWith(".json"): name[0 ..< name.len - 5] else: name

proc newSessionPath(): string =
  let stamp = now().format("yyyyMMdd'T'HHmmss")
  sessionDir() / (stamp & ".json")

proc listSessionPaths(): seq[string] =
  let d = sessionDir()
  if not dirExists(d): return
  for kind, path in walkDir(d):
    if kind == pcFile and path.endsWith(".json"):
      result.add path
  result.sort(order = SortOrder.Descending)

proc resolveSessionPath(id: string): string =
  ## `id` is bare (no .json) or a full path. Returns "" if not found.
  if id == "":
    let all = listSessionPaths()
    if all.len == 0: return ""
    return all[0]
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

proc saveSession(session: Session, messages: JsonNode) =
  if session.savePath == "": return
  try:
    createDir(session.savePath.parentDir)
    let body = %*{
      "version": 1,
      "created": session.created,
      "updated": $now(),
      "profile": session.profileName,
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

proc loadSessionFile(path: string): (Session, JsonNode) =
  let raw = try: readFile(path)
            except CatchableError as e:
              die("cannot read session " & path & ": " & e.msg, ExitConfig)
  let j = try: parseJson(raw)
          except CatchableError as e:
            die("bad session json in " & path & ": " & e.msg, ExitConfig)
  var sess = Session(savePath: path)
  sess.profileName = j{"profile"}.getStr("")
  sess.created = j{"created"}.getStr($now())
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
    messages = %* [{"role": "system", "content": SystemPrompt}]
  (sess, messages)

proc firstUserMessage(messages: JsonNode): string =
  if messages == nil or messages.kind != JArray: return ""
  for m in messages:
    if m.kind == JObject and m{"role"}.getStr == "user":
      return m{"content"}.getStr("")
  ""

# ---------- Context compaction (B.1) ----------

const
  CompactThresholdFrac = 0.8
  CompactKeepRecent = 10
  CompactedMarker = "[compacted — tool output elided; use :show to view]"

proc contextWindowFor(model: string): int =
  let m = model.toLowerAscii
  if "kimi-k2" in m: 128_000
  elif "qwen3-coder" in m or "qwen3_coder" in m: 262_144
  elif "qwen" in m: 128_000
  elif "claude" in m: 200_000
  elif "gpt-5" in m: 400_000
  elif "gpt-4" in m: 128_000
  elif "o1" in m or "o3" in m or "o4" in m: 200_000
  elif "deepseek" in m: 128_000
  elif "gemini" in m: 1_000_000
  elif "llama" in m: 128_000
  elif "glm" in m: 128_000
  elif "mistral" in m or "mixtral" in m: 128_000
  else: 128_000

proc compactHistory*(messages: JsonNode, keepRecent = CompactKeepRecent): int =
  ## Replace `content` of old `tool` messages with a short marker. Returns
  ## the number of messages compacted. System prompt (index 0) and the last
  ## `keepRecent` messages are left untouched.
  if messages == nil or messages.kind != JArray: return 0
  if messages.len <= keepRecent + 1: return 0
  let cutoff = messages.len - keepRecent
  for i in 1 ..< cutoff:
    let m = messages[i]
    if m.kind != JObject: continue
    if m{"role"}.getStr != "tool": continue
    let c = m{"content"}.getStr("")
    if c.len <= CompactedMarker.len + 32: continue
    if c.startsWith("[compacted"): continue
    m["content"] = %CompactedMarker
    inc result

type
  ProviderRec = object
    name, url, key, modelPrefix: string
    models: seq[string]

var activeCurrent: string
var activeProviders: seq[ProviderRec]

const CommandNames = [":help", ":tokens", ":clear", ":model", ":provider",
                      ":prompt", ":show", ":log", ":sessions", ":compact",
                      ":q", ":quit", ":exit"]

proc currentProvider(): ProviderRec =
  let dot = activeCurrent.find('.')
  let name = if dot < 0: activeCurrent else: activeCurrent[0 ..< dot]
  for pr in activeProviders:
    if pr.name == name: return pr
  ProviderRec()

proc completionFor(line: string): seq[string] =
  let words = line.split(' ')
  if words.len == 0: return
  let last = words[^1]
  if words.len == 1:
    if last == "" or last.startsWith(":"):
      return @CommandNames
    return
  if words[0] == ":provider":
    if words.len == 2:
      for pr in activeProviders: result.add pr.name
      for sub in ["add", "edit", "rm"]: result.add sub
      return
    if words.len == 3 and words[1] in ["edit", "rm", "remove"]:
      for pr in activeProviders: result.add pr.name
      return
  if words[0] == ":model" and words.len == 2:
    for m in currentProvider().models: result.add m
    return

proc splitModels(s: string): seq[string] =
  for m in s.splitWhitespace:
    if m.len > 0: result.add m

proc expandEnvValue(s: string): string =
  ## Expand a leading `$VAR` reference (after any surrounding whitespace) to
  ## the value of the environment variable. Plain values pass through
  ## unchanged.
  let t = s.strip
  if t.len > 1 and t[0] == '$':
    return getEnv(t[1 .. ^1])
  s

proc parseConfigFile(path: string): (string, seq[ProviderRec]) =
  ## Streaming parse so that repeated [provider] sections accumulate as a list.
  var current = ""
  var providers: seq[ProviderRec]
  var section = ""
  var prov: ProviderRec
  var inProvider = false
  let stream = newFileStream(path, fmRead)
  if stream == nil: die &"cannot open {path}", ExitConfig
  var p: CfgParser
  p.open(stream, path)
  proc flush() =
    if inProvider:
      providers.add prov
      prov = ProviderRec()
      inProvider = false
  while true:
    let e = p.next
    case e.kind
    of cfgEof: flush(); break
    of cfgSectionStart:
      flush()
      section = e.section
      if section == "provider": inProvider = true
    of cfgKeyValuePair, cfgOption:
      let v = expandEnvValue(e.value)
      case section
      of "settings":
        if e.key == "current": current = v
      of "provider":
        case e.key
        of "name": prov.name = v
        of "url": prov.url = v.strip(chars = {'/', ' '})
        of "key": prov.key = v
        of "model_prefix": prov.modelPrefix = v
        of "models": prov.models = splitModels(v)
        else: discard
      else: discard
    of cfgError:
      die &"{path}: {e.msg}", ExitConfig
  p.close
  (current, providers)

proc quoteVal(s: string): string =
  result = "\""
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    else: result.add c
  result.add "\""

proc writeConfigFile(path: string, current: string,
                     providers: seq[ProviderRec]) =
  createDir(path.parentDir)
  var buf = "[settings]\n"
  buf.add "current = " & quoteVal(current) & "\n"
  for pr in providers:
    buf.add "\n[provider]\n"
    buf.add "name = " & quoteVal(pr.name) & "\n"
    buf.add "url = " & quoteVal(pr.url) & "\n"
    buf.add "key = " & quoteVal(pr.key) & "\n"
    if pr.modelPrefix != "":
      buf.add "model_prefix = " & quoteVal(pr.modelPrefix) & "\n"
    buf.add "models = " & quoteVal(pr.models.join(" ")) & "\n"
  writeFile(path, buf)

proc loadStateOrEmpty(path: string): (string, seq[ProviderRec]) =
  if not fileExists(path): return ("", @[])
  parseConfigFile(path)

proc buildProfile(current: string, providers: seq[ProviderRec],
                  wanted: string): Profile =
  ## Resolve a Profile from in-memory state; empty Profile on failure.
  if providers.len == 0: return Profile()
  var pick = wanted
  if pick == "": pick = current
  if pick == "": pick = providers[0].name
  let dot = pick.find('.')
  let name = if dot < 0: pick else: pick[0 ..< dot]
  var model = if dot < 0: "" else: pick[dot + 1 .. ^1]
  for pr in providers:
    if pr.name == name:
      if pr.url == "" or pr.key == "" or pr.models.len == 0:
        return Profile()
      if model == "":
        model = pr.models[0]
      elif model notin pr.models:
        return Profile()
      return Profile(name: pr.name & "." & model, url: pr.url,
                     key: pr.key, modelPrefix: pr.modelPrefix, model: model)
  Profile()

proc loadProfile(wanted: string): Profile =
  let path = configPath()
  if not fileExists(path):
    stderr.writeLine "3code: no config at " & path
    stderr.writeLine ""
    stderr.writeLine "create it with at least one [provider] section, e.g.:"
    stderr.writeLine ""
    stderr.writeLine ConfigExample
    quit ExitConfig
  let (current, providers) = parseConfigFile(path)
  if providers.len == 0:
    die &"no [provider] section in {path}", ExitConfig
  var pick = wanted
  if pick == "": pick = current
  if pick == "": pick = providers[0].name
  if pick == "":
    die &"no current provider set in {path} and first [provider] has no name", ExitConfig
  let dot = pick.find('.')
  let name = if dot < 0: pick else: pick[0 ..< dot]
  var model = if dot < 0: "" else: pick[dot + 1 .. ^1]
  var prov: ProviderRec
  var found = false
  for p in providers:
    if p.name == name:
      prov = p
      found = true
      break
  if not found:
    die &"provider '{name}' not found in {path}", ExitConfig
  if prov.url == "": die &"provider '{name}': url not set in {path}", ExitConfig
  if prov.key == "": die &"provider '{name}': key not set in {path}", ExitConfig
  if prov.models.len == 0: die &"provider '{name}': models not set in {path}", ExitConfig
  if model == "":
    model = prov.models[0]
  elif model notin prov.models:
    die &"provider '{name}': model '{model}' not in models list ({prov.models.join(\", \")})", ExitConfig
  Profile(name: prov.name & "." & model, url: prov.url, key: prov.key,
          modelPrefix: prov.modelPrefix, model: model)

# ---------- Spinner ----------

var spinnerStop: Atomic[bool]
var spinnerThread: Thread[string]

proc spinnerLoop(label: string) {.thread.} =
  const frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  let start = epochTime()
  var i = 0
  while not spinnerStop.load(moRelaxed):
    let elapsed = epochTime() - start
    try:
      stdout.styledWrite "\r", fgCyan, styleBright, frames[i mod frames.len], resetStyle,
        fgCyan, styleBright, &"  {label} {elapsed.int}s", resetStyle
      stdout.flushFile
    except CatchableError: discard
    sleep 80
    inc i
  try:
    stdout.write "\r\x1b[2K"
    stdout.flushFile
  except CatchableError: discard

proc startSpinner(label: string) =
  spinnerStop.store(false, moRelaxed)
  createThread(spinnerThread, spinnerLoop, label)

proc stopSpinner() =
  spinnerStop.store(true, moRelaxed)
  joinThread(spinnerThread)

proc humanBytes(n: int): string =
  if n < 1024: &"{n}B"
  elif n < 1024 * 1024: &"{n.float/1024:.1f}KB"
  else: &"{n.float/1024/1024:.2f}MB"

# ---------- Model call ----------

proc toolCallToAction*(name: string, args: JsonNode): Action =
  case name
  of "bash":
    Action(kind: akBash, body: args{"command"}.getStr)
  of "read":
    Action(kind: akRead, path: args{"path"}.getStr,
           offset: args{"offset"}.getInt(0),
           limit: args{"limit"}.getInt(0))
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

proc parseUsage*(u: JsonNode): Usage =
  ## Parses an OpenAI-compatible `usage` object. Cached-token accounting
  ## differs by provider: OpenAI/DeepInfra/Anthropic report it under
  ## `prompt_tokens_details.cached_tokens`; DeepSeek reports it flat as
  ## `prompt_cache_hit_tokens`. We accept either.
  if u == nil or u.kind != JObject: return
  result.promptTokens = u{"prompt_tokens"}.getInt(0)
  result.completionTokens = u{"completion_tokens"}.getInt(0)
  result.totalTokens = u{"total_tokens"}.getInt(0)
  let details = u{"prompt_tokens_details"}
  if details != nil and details.kind == JObject:
    result.cachedTokens = details{"cached_tokens"}.getInt(0)
  if result.cachedTokens == 0:
    result.cachedTokens = u{"prompt_cache_hit_tokens"}.getInt(0)

proc callModel(p: Profile, messages: JsonNode, usage: var Usage, sessionUsage: Usage): JsonNode =
  let client = newHttpClient(timeout = 180_000)
  defer: client.close()
  client.headers = newHttpHeaders({
    "Authorization": "Bearer " & p.key,
    "Content-Type": "application/json"
  })
  var body = %*{
    "model": p.modelPrefix & p.model,
    "messages": messages,
    "stream": false
  }
  body["tools"] = ToolsJson
  body["tool_choice"] = %"auto"
  let bodyStr = $body
  let t0 = epochTime()
  var spinLabel = &"thinking · session ↑ {sessionUsage.promptTokens} · ↓ {sessionUsage.completionTokens}"
  if sessionUsage.cachedTokens > 0:
    spinLabel.add &" · cache {sessionUsage.cachedTokens}"
  startSpinner(spinLabel)
  const MaxAttempts = 3
  var resp: Response
  var attempt = 0
  while true:
    inc attempt
    var errMsg = ""
    var retryable = false
    try:
      resp = client.request(p.url & "/chat/completions", HttpPost, bodyStr)
    except CatchableError as e:
      errMsg = "network: " & e.msg
      retryable = true
    if errMsg == "":
      let c = resp.code.int
      if c == 429 or c == 500 or c == 502 or c == 503 or c == 504:
        errMsg = "api " & $resp.code
        retryable = true
    if errMsg == "" or attempt >= MaxAttempts or not retryable:
      stopSpinner()
      if errMsg != "":
        die(errMsg & (if resp.code.int != 0: ": " & resp.body else: ""), ExitApi)
      break
    let retryAfter = (if errMsg.startsWith("api"):
                       try: parseInt($resp.headers.getOrDefault("retry-after"))
                       except CatchableError: 0
                     else: 0)
    let backoff = if retryAfter > 0: retryAfter else: 1 shl (attempt - 1)
    stopSpinner()
    stderr.writeLine &"3code: {errMsg}; retry {attempt + 1}/{MaxAttempts} in {backoff}s"
    sleep(backoff * 1000)
    startSpinner(&"retry {attempt + 1}/{MaxAttempts}")
  let text = resp.body
  let elapsed = epochTime() - t0
  let j = parseJson(text)
  if "error" in j: die("api error: " & $j["error"], ExitApi)
  if "usage" in j:
    usage = parseUsage(j["usage"])
  if usage.totalTokens > 0:
    hint &"  ↑ {usage.promptTokens} tok · ↓ {usage.completionTokens} tok"
    if usage.cachedTokens > 0:
      stdout.styledWrite(styleDim, &" · cache {usage.cachedTokens}", resetStyle)
    hint &" · {elapsed.int}s", resetStyle, "\n"
  else:
    hint &"  ↓ ~{text.len div 4} tok · {elapsed.int}s", resetStyle, "\n"
  stdout.flushFile
  j["choices"][0]["message"]

proc verifyProfile(p: Profile): (bool, string) =
  let client = newHttpClient(timeout = 20000)
  defer: client.close()
  client.headers = newHttpHeaders({
    "Authorization": "Bearer " & p.key,
    "Content-Type": "application/json"
  })
  let body = $(%*{
    "model": p.modelPrefix & p.model,
    "messages": [%*{"role": "user", "content": "ping"}],
    "max_tokens": 1,
    "stream": false
  })
  try:
    let r = client.request(p.url & "/chat/completions", HttpPost, body)
    if r.code == Http200:
      let j = try: parseJson(r.body)
              except CatchableError: return (false, "bad json in response")
      if "error" in j: return (false, $j["error"])
      return (true, "")
    let snip = r.body[0 ..< min(200, r.body.len)]
    return (false, $r.code & ": " & snip)
  except CatchableError as e:
    return (false, e.msg)

proc fetchModels(url, key: string): seq[string] =
  let client = newHttpClient(timeout = 20000)
  defer: client.close()
  client.headers = newHttpHeaders({"Authorization": "Bearer " & key})
  try:
    let r = client.request(url & "/models", HttpGet)
    if r.code != Http200: return @[]
    let j = try: parseJson(r.body) except CatchableError: return @[]
    let arr = if j.kind == JArray: j
              elif "data" in j and j["data"].kind == JArray: j["data"]
              else: return @[]
    for item in arr:
      if item.kind == JString: result.add item.getStr
      elif item.kind == JObject and "id" in item: result.add item["id"].getStr
  except CatchableError:
    return @[]

proc replaceFirst*(s, needle, repl: string): (string, bool) =
  let idx = s.find(needle)
  if idx < 0: return (s, false)
  (s[0 ..< idx] & repl & s[idx + needle.len .. ^1], true)

proc clipMiddle(s: string, head, tail: int): string =
  if s.len <= head + tail: s
  else: s[0 ..< head] & "\n... [truncated] ...\n" & s[^tail .. ^1]

proc computeDiff(before, after, label: string): string =
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

proc runAction*(act: Action): tuple[output: string, code: int, diff: string] =
  case act.kind
  of akBash:
    let cmd = act.body.strip
    let tmp = getTempDir() / ("3code_bash_" & $getCurrentProcessId() & "_" & $epochTime().int64)
    createDir(tmp)
    let outPath = tmp / "out"
    let errPath = tmp / "err"
    let wrapped = &"({cmd}) >\"{outPath}\" 2>\"{errPath}\""
    let code = execShellCmd(wrapped)
    let rawOut = if fileExists(outPath): readFile(outPath) else: ""
    let rawErr = if fileExists(errPath): readFile(errPath) else: ""
    try: removeDir(tmp) except CatchableError: discard
    let outClip = clipMiddle(rawOut, 4000, 4000)
    let errClip = clipMiddle(rawErr, 2000, 2000)
    var body = &"$ {cmd}\n"
    if outClip.len > 0:
      body.add outClip
      if not outClip.endsWith("\n"): body.add "\n"
    if errClip.len > 0:
      body.add "[stderr]\n" & errClip
      if not errClip.endsWith("\n"): body.add "\n"
    body.add &"[exit {code}]"
    (body, code, "")
  of akRead:
    if not fileExists(act.path):
      return (&"error: {act.path} does not exist", 1, "")
    let content = readFile(act.path)
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
    if act.offset <= 0 and not explicitLimit and not capped and endi == total:
      return (content, 0, "")
    var body = lines[start ..< endi].join("\n")
    if capped:
      let shown = endi - start
      body.add &"\n... [file is {total} lines, {content.len} bytes; showed {shown} lines from line {start + 1}. Use read(path, offset, limit) for a specific range.] ..."
    (body, 0, "")
  of akWrite:
    let dir = parentDir(act.path)
    if dir != "": createDir(dir)
    let before = if fileExists(act.path): readFile(act.path) else: ""
    writeFile(act.path, act.body)
    let diff = computeDiff(before, act.body, act.path)
    (&"wrote {act.path} ({act.body.len} bytes)", 0, diff)
  of akPatch:
    if act.edits.len == 0:
      return (&"error: patch has no edits", 1, "")
    if not fileExists(act.path):
      return (&"error: {act.path} does not exist", 1, "")
    let before = readFile(act.path)
    var content = before
    var applied = 0
    for (s, r) in act.edits:
      let (next, ok) = replaceFirst(content, s, r)
      if not ok:
        return (&"error: SEARCH block did not match in {act.path}:\n{s}", 1, "")
      content = next
      inc applied
    writeFile(act.path, content)
    let diff = computeDiff(before, content, act.path)
    (&"patched {act.path} ({applied} edit" & (if applied == 1: "" else: "s") & ")", 0, diff)

# ---------- Display ----------

proc previewCmd(body: string, width = 64): string =
  let first = body.strip.splitLines[0]
  if first.len > width: first[0 ..< width-1] & "…" else: first

proc bannerFor(act: Action): string =
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

const
  CompactHead = 3
  CompactTail = 10
  CompactThreshold = CompactHead + CompactTail + 2  # below this, show everything

proc trimTrailingBlank(lines: var seq[string]) =
  while lines.len > 0 and lines[^1].strip == "":
    lines.setLen lines.len - 1

proc printLine(l: string) =
  if l.startsWith("$ "):
    hintLn l, resetStyle
  elif l.startsWith("[exit "):
    if l == "[exit 0]":
      stdout.styledWriteLine fgGreen, l, resetStyle
    else:
      stdout.styledWriteLine fgRed, styleBright, l, resetStyle
  else:
    stdout.writeLine l

proc printBashCompact(res: string, idx: int) =
  var lines = res.splitLines
  trimTrailingBlank(lines)
  if lines.len <= CompactThreshold:
    for l in lines: printLine(l)
    return
  # keep "$ cmd" line + head body + hidden marker + tail body + "[exit N]"
  var header = 0
  if header < lines.len and lines[header].startsWith("$ "):
    printLine(lines[header]); inc header
  var footer = lines.len
  if footer > 0 and lines[footer-1].startsWith("[exit "):
    dec footer
  let bodyLen = footer - header
  if bodyLen <= CompactThreshold:
    for i in header ..< footer: printLine(lines[i])
  else:
    for i in header ..< header + CompactHead: printLine(lines[i])
    let hidden = bodyLen - CompactHead - CompactTail
    hintLn &"  … {hidden} line" & (if hidden == 1: "" else: "s") &
      &" hidden · :show {idx} for full …", resetStyle
    for i in footer - CompactTail ..< footer: printLine(lines[i])
  if footer < lines.len: printLine(lines[footer])

proc printDiff(diff: string) =
  const DiffHead = 15
  const DiffTail = 20
  var lines = diff.splitLines
  while lines.len > 0 and lines[^1].strip == "":
    lines.setLen lines.len - 1
  if lines.len == 0: return
  proc paint(l: string) =
    if l.startsWith("@@"):
      stdout.styledWriteLine fgCyan, l, resetStyle
    elif l.startsWith("+++") or l.startsWith("---"):
      stdout.styledWriteLine styleDim, l, resetStyle
    elif l.len > 0 and l[0] == '+':
      stdout.styledWriteLine fgGreen, l, resetStyle
    elif l.len > 0 and l[0] == '-':
      stdout.styledWriteLine fgRed, l, resetStyle
    else:
      stdout.writeLine l
  if lines.len <= DiffHead + DiffTail + 2:
    for l in lines: paint(l)
    return
  for i in 0 ..< DiffHead: paint(lines[i])
  let hidden = lines.len - DiffHead - DiffTail
  hintLn &"  … {hidden} line" & (if hidden == 1: "" else: "s") &
    " hidden · `git diff` for full …", resetStyle
  for i in lines.len - DiffTail ..< lines.len: paint(lines[i])

proc printActionResult(act: Action, res: string, code: int, idx: int, diff = "") =
  if act.kind in {akBash, akRead}:
    printBashCompact(res, idx)
  else:
    if code == 0:
      stdout.styledWriteLine fgGreen, res, resetStyle
    else:
      stdout.styledWriteLine fgRed, styleBright, res, resetStyle
  if diff.len > 0:
    printDiff(diff)

# ---------- History / editor ----------

proc historyFile(): string =
  getConfigDir() / "3code" / "history"

# Track up-navigation so "down past last" can return to blank line.
var navigatedUp: bool = false
var origDown, origUp: proc(ed: var LineEditor) {.closure.}

proc installEditorTweaks() =
  origUp = KEYMAP["up"]
  origDown = KEYMAP["down"]
  KEYMAP["up"] = proc(ed: var LineEditor) =
    origUp(ed)
    navigatedUp = true
  KEYMAP["down"] = proc(ed: var LineEditor) =
    let before = ed.lineText
    origDown(ed)
    if navigatedUp and ed.lineText == before:
      ed.changeLine("")
      navigatedUp = false
  # also reset the flag when the line is cleared via ctrl+u
  let origClear = KEYMAP["ctrl+u"]
  KEYMAP["ctrl+u"] = proc(ed: var LineEditor) =
    origClear(ed)
    navigatedUp = false

proc showProfile(p: Profile) =
  if p.name == "": return
  let dot = p.name.find('.')
  let provider = if dot < 0: p.name else: p.name[0 ..< dot]
  stdout.styledWriteLine fgCyan, styleBright, "  provider ", resetStyle, provider
  stdout.styledWriteLine fgCyan, styleBright, "  model    ", resetStyle, p.model

proc welcome(p: Profile): minline.LineEditor =
  stdout.styledWriteLine fgCyan, styleBright, "  ╭─╮"
  stdout.styledWriteLine fgCyan, styleBright, "   ─┤  ", resetStyle, fgWhite, styleBright, "3code ", resetStyle, fgCyan, styleBright, "v" & Version,
    resetStyle, styleDim, "   the economical coding agent"
  stdout.styledWriteLine fgCyan, styleBright, "  ╰─╯"
  stdout.write "\n"
  if p.name != "":
    showProfile(p)
    stdout.write "\n"
    stdout.styledWriteLine fgCyan, styleBright, "  type a prompt. :help for commands. :q or Ctrl-D to exit.", resetStyle
  stdout.flushFile
  installEditorTweaks()
  result = minline.initEditor(historyFile = historyFile())
  result.completionCallback = proc(ed: LineEditor): seq[string] =
    completionFor(ed.lineText)

# Read one logical input. Returns "" to mean "skip" (e.g. empty, or command
# already handled). Sets `done` when the user wants to exit.
proc readInput(editor: var minline.LineEditor, done: var bool): string =
  let line = try: editor.readLine("> ")
             except EOFError:
               done = true; return ""
  navigatedUp = false
  let s = line.strip
  if s == "": return ""
  if s == "\"\"\"":
    var buf: seq[string]
    while true:
      let l = try: editor.readLine("… ")
              except EOFError:
                done = true; break
      if l.strip == "\"\"\"": break
      buf.add l
    return buf.join("\n")
  return line

# ---------- Session loop ----------

proc runTurns(p: Profile, messages: var JsonNode, session: var Session) =
  while true:
    var usage: Usage
    let msg = callModel(p, messages, usage, session.usage)
    session.usage.promptTokens += usage.promptTokens
    session.usage.completionTokens += usage.completionTokens
    session.usage.totalTokens += usage.totalTokens
    session.usage.cachedTokens += usage.cachedTokens
    session.lastPromptTokens = usage.promptTokens
    messages.add msg
    saveSession(session, messages)
    let window = contextWindowFor(p.model)
    if usage.promptTokens > 0 and
       usage.promptTokens.float > CompactThresholdFrac * window.float:
      let n = compactHistory(messages)
      if n > 0:
        hintLn &"  · compacted {n} old tool result" &
          (if n == 1: "" else: "s") &
          &" (context at {usage.promptTokens}/{window} tokens)",
          resetStyle
        saveSession(session, messages)
    stdout.write "\n"
    let content = msg{"content"}.getStr("")
    let tcNode = msg{"tool_calls"}
    let toolCalls =
      if tcNode != nil and tcNode.kind == JArray: tcNode
      else: newJArray()
    if toolCalls.len > 0:
      if content.strip.len > 0:
        stdout.styledWrite fgCyan, content, resetStyle, "\n"
        stdout.flushFile
      for tc in toolCalls:
        let id = tc{"id"}.getStr
        let fn = tc{"function"}
        let name = if fn != nil and fn.kind == JObject: fn{"name"}.getStr else: ""
        let argsStr =
          if fn != nil and fn.kind == JObject: fn{"arguments"}.getStr("") else: ""
        let args =
          try: parseJson(if argsStr == "": "{}" else: argsStr)
          except CatchableError as e:
            stderr.writeLine "3code: tool_call " & name &
              " has malformed arguments JSON (" & e.msg & "): " & argsStr
            newJObject()
        let act = toolCallToAction(name, args)
        let idx = session.toolLog.len + 1
        stdout.styledWrite fgYellow, styleBright, "» ", resetStyle,
          fgYellow, bannerFor(act), resetStyle,
          fgCyan, styleBright, &"   [T{idx}]", resetStyle, "\n"
        stdout.flushFile
        let (r, code, diff) = runAction(act)
        session.toolLog.add ToolRecord(banner: bannerFor(act), output: r, code: code, kind: act.kind)
        printActionResult(act, r, code, idx, diff)
        messages.add %*{"role": "tool", "tool_call_id": id, "content": r}
      saveSession(session, messages)
      continue
    if content.strip.len > 0:
      stdout.styledWrite fgCyan, content, resetStyle, "\n"
      stdout.flushFile
    else:
      stdout.styledWriteLine fgRed, styleBright,
        "  (empty reply — no content, no tool calls)", resetStyle
    break

proc showTool(arg: string, toolLog: seq[ToolRecord]) =
  if toolLog.len == 0:
    hintLn "  no tool calls yet", resetStyle
    return
  var n = toolLog.len
  if arg != "":
    try: n = parseInt(arg)
    except ValueError:
      stdout.styledWriteLine fgRed, "show: not a number: ", arg, resetStyle
      return
  if n < 1 or n > toolLog.len:
    stdout.styledWriteLine fgRed,
      &"show: T{n} out of range (1..{toolLog.len})", resetStyle
    return
  let rec = toolLog[n-1]
  stdout.styledWriteLine fgYellow, styleBright, &"── T{n}  ", rec.banner, resetStyle
  if rec.kind in {akBash, akRead}:
    for l in rec.output.splitLines: printLine(l)
  else:
    if rec.code == 0:
      stdout.styledWriteLine fgGreen, rec.output, resetStyle
    else:
      stdout.styledWriteLine fgRed, styleBright, rec.output, resetStyle

proc listTools(toolLog: seq[ToolRecord]) =
  if toolLog.len == 0:
    hintLn "  no tool calls yet", resetStyle
    return
  for i, rec in toolLog:
    let tag = &"T{i+1}"
    let lines = rec.output.splitLines.len
    let mark = if rec.code == 0: "✓" else: "✗"
    let color = if rec.code == 0: fgGreen else: fgRed
    hint &"  {tag:>4}  ", resetStyle,
      color, mark, resetStyle, " ",
      rec.banner,
      fgCyan, styleBright, &"   ({lines} line" & (if lines == 1: "" else: "s") & ")",
      resetStyle, "\n"

# ---------- Provider management ----------

const ProviderCatalog: seq[(string, string)] = @[
  ("anthropic",   "https://api.anthropic.com/v1"),
  ("baseten",     "https://inference.baseten.co/v1"),
  ("cerebras",    "https://api.cerebras.ai/v1"),
  ("deepinfra",   "https://api.deepinfra.com/v1/openai"),
  ("deepseek",    "https://api.deepseek.com/v1"),
  ("fireworks",   "https://api.fireworks.ai/inference/v1"),
  ("friendli",    "https://api.friendli.ai/serverless/v1"),
  ("google",      "https://generativelanguage.googleapis.com/v1beta/openai"),
  ("groq",        "https://api.groq.com/openai/v1"),
  ("hyperbolic",  "https://api.hyperbolic.xyz/v1"),
  ("mistral",     "https://api.mistral.ai/v1"),
  ("moonshot",    "https://api.moonshot.ai/v1"),
  ("moonshot-cn", "https://api.moonshot.cn/v1"),
  ("nebius",      "https://api.tokenfactory.nebius.com/v1"),
  ("nvidia",      "https://integrate.api.nvidia.com/v1"),
  ("openai",      "https://api.openai.com/v1"),
  ("openrouter",  "https://openrouter.ai/api/v1"),
  ("ovh",         "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1"),
  ("perplexity",  "https://api.perplexity.ai"),
  ("qwen",        "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
  ("qwen-cn",     "https://dashscope.aliyuncs.com/compatible-mode/v1"),
  ("qwen-us",     "https://dashscope-us.aliyuncs.com/compatible-mode/v1"),
  ("sambanova",   "https://api.sambanova.ai/v1"),
  ("scaleway",    "https://api.scaleway.ai/v1"),
  ("together",    "https://api.together.xyz/v1"),
  ("together-eu", "https://eu.api.together.xyz/v1"),
  ("xai",         "https://api.x.ai/v1"),
  ("zai",         "https://api.z.ai/api/paas/v4"),
  ("zai-coding",  "https://api.z.ai/api/coding/paas/v4"),
]

proc catalogUrl(name: string): string =
  for (n, u) in ProviderCatalog:
    if n == name: return u
  ""

proc readRequired(editor: var minline.LineEditor, prompt: string,
                  hidden = false): string =
  while true:
    let s = try: editor.readLine(prompt, hidechars = hidden).strip
            except EOFError:
              stdout.write "\n"
              die "aborted", ExitConfig
    if s != "": return s

proc readOptional(editor: var minline.LineEditor, prompt: string,
                  hidden = false): string =
  try: editor.readLine(prompt, hidechars = hidden).strip
  except EOFError:
    stdout.write "\n"
    die "aborted", ExitConfig

proc defaultNameFromUrl(url: string): string =
  let host = parseUri(url).hostname
  if host == "": return ""
  let labels = host.split('.')
  if labels.len >= 2: labels[^2]
  else: labels[0]

proc commonModelPrefix(models: seq[string]): string =
  if models.len < 2: return ""
  var prefix = models[0]
  for m in models[1 .. ^1]:
    var i = 0
    while i < prefix.len and i < m.len and prefix[i] == m[i]:
      inc i
    prefix = prefix[0 ..< i]
    if prefix.len == 0: return ""
  let slash = prefix.rfind('/')
  if slash < 0: "" else: prefix[0 .. slash]

const RecommendedWizardLines = [
  "  recommended (cache = documented prompt caching):",
  "    deepinfra  (cache)   qwen3-coder-480b, kimi-k2.5",
  "    deepseek   (cache)   deepseek-v3.2",
  "    together             qwen3-coder-480b, kimi-k2.5",
  "    groq                 kimi-k2.5  (fast, no cache)",
  "  models outside this list are your tokens to burn.",
]

proc printRecommended() =
  for line in RecommendedWizardLines:
    stdout.styledWriteLine styleDim, line, resetStyle

proc readProviderEntry(editor: var minline.LineEditor): string =
  let prevCb = editor.completionCallback
  editor.completionCallback = proc(ed: LineEditor): seq[string] =
    for (n, _) in ProviderCatalog: result.add n
  result = readRequired(editor, "  provider name or url : ")
  editor.completionCallback = prevCb

proc promptNewProvider(editor: var minline.LineEditor): ProviderRec =
  printRecommended()
  stdout.write "\n"
  while true:
    let entry = readProviderEntry(editor)
    var name, url: string
    if entry.startsWith("http://") or entry.startsWith("https://"):
      url = entry.strip(chars = {'/', ' '})
      let suggested = defaultNameFromUrl(url)
      let namePrompt =
        if suggested == "": "  name                 : "
        else: &"  name [{suggested}]     : "
      name = readOptional(editor, namePrompt)
      if name == "": name = suggested
    else:
      name = entry
      let cu = catalogUrl(name)
      if cu != "":
        let urlEntry = readOptional(editor, &"  url [{cu}]     : ")
          .strip(chars = {'/', ' '})
        url = if urlEntry == "": cu else: urlEntry
      else:
        url = readRequired(editor, "  api base url         : ")
          .strip(chars = {'/', ' '})
    if name == "":
      stdout.styledWriteLine fgRed, "  name required", resetStyle
      continue
    var clash = false
    for pr in activeProviders:
      if pr.name == name:
        clash = true
        break
    if clash:
      stdout.styledWriteLine fgRed, &"  name already used: {name}", resetStyle
      continue
    var key = readRequired(editor, "  api key              : ", hidden = true)
    hint "  fetching models...   ", resetStyle
    stdout.flushFile
    let available = fetchModels(url, key)
    let prefix = commonModelPrefix(available)
    if available.len == 0:
      hintLn "unavailable — enter manually", resetStyle
    else:
      let header =
        if prefix == "": &"{available.len} available"
        else: &"{available.len} available (prefix: {prefix})"
      hintLn header, resetStyle
      for m in available:
        let shown = if prefix != "" and m.startsWith(prefix): m[prefix.len .. ^1]
                    else: m
        hintLn "    ", resetStyle, shown
    let prevCb = editor.completionCallback
    editor.completionCallback = proc(ed: LineEditor): seq[string] =
      for m in available:
        if prefix != "" and m.startsWith(prefix): result.add m[prefix.len .. ^1]
        else: result.add m
    defer: editor.completionCallback = prevCb
    var prev = ""
    while true:
      let prompt =
        if prev == "": "  models (space-sep.)  : "
        else: &"  models [{prev}]  : "
      let entered = readOptional(editor, prompt)
      let raw = if entered == "": prev else: entered
      let models = splitModels(raw)
      let modelsStr = models.join(" ")
      if models.len == 0:
        stdout.styledWriteLine fgRed, "  need at least one model", resetStyle
        continue
      let prov = ProviderRec(name: name, url: url, key: key,
                             modelPrefix: prefix, models: models)
      let prof = Profile(name: name & "." & models[0], url: url,
                         key: key, modelPrefix: prefix, model: models[0])
      hint "  verifying... ", resetStyle
      stdout.flushFile
      let (ok, err) = verifyProfile(prof)
      if ok:
        stdout.styledWriteLine fgGreen, styleBright, "ok", resetStyle
        return prov
      stdout.styledWriteLine fgRed, styleBright, "failed", resetStyle
      stdout.styledWriteLine fgRed, "  " & err, resetStyle
      prev = modelsStr
      let choice = readOptional(editor,
        "  [enter]=retry models, k=re-enter key : ").toLowerAscii
      if choice == "k":
        key = readRequired(editor,
          "  api key              : ", hidden = true)

proc promptEditProvider(editor: var minline.LineEditor,
                        existing: ProviderRec): ProviderRec =
  hintLn &"  editing '{existing.name}' (enter to keep, ctrl+d to abort)",
    resetStyle
  while true:
    let newUrl = readOptional(editor,
      &"  url [{existing.url}]  : ").strip(chars = {'/', ' '})
    let url = if newUrl == "": existing.url else: newUrl
    let newKey = readOptional(editor,
      "  api key [keep existing] : ", hidden = true)
    let key = if newKey == "": existing.key else: newKey
    let modelsCurrent = existing.models.join(" ")
    let newModels = readOptional(editor,
      &"  models [{modelsCurrent}]  : ")
    let models =
      if newModels == "": existing.models
      else: splitModels(newModels)
    if models.len == 0:
      stdout.styledWriteLine fgRed, "  need at least one model", resetStyle
      continue
    let prefix = commonModelPrefix(models)
    let prof = Profile(name: existing.name & "." & models[0], url: url,
                       key: key, modelPrefix: prefix, model: models[0])
    hint "  verifying... ", resetStyle
    stdout.flushFile
    let (ok, err) = verifyProfile(prof)
    if ok:
      stdout.styledWriteLine fgGreen, styleBright, "ok", resetStyle
      return ProviderRec(name: existing.name, url: url, key: key,
                         modelPrefix: prefix, models: models)
    stdout.styledWriteLine fgRed, styleBright, "failed", resetStyle
    stdout.styledWriteLine fgRed, "  " & err, resetStyle

proc bootstrapProvider(editor: var minline.LineEditor): Profile =
  stdout.styledWriteLine fgYellow, styleBright,
    "  no provider configured — let's add one. (ctrl+d to quit)", resetStyle
  let prov = promptNewProvider(editor)
  activeProviders.add prov
  activeCurrent = prov.name & "." & prov.models[0]
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  hintLn &"  saved to {configPath()}", resetStyle
  buildProfile(activeCurrent, activeProviders, "")

proc cmdProviderList(prof: Profile) =
  if activeProviders.len == 0:
    hintLn "  no providers", resetStyle
    return
  let curName = if prof.name == "": "" else: prof.name.split('.')[0]
  for pr in activeProviders:
    let current = pr.name == curName
    let mark = if current: "*" else: " "
    let tail = if current: &"  [{prof.model}]" else: ""
    hintLn "  ", mark, " ", resetStyle, pr.name, tail

proc cmdProviderSelect(target: string, prof: var Profile) =
  var prov: ProviderRec
  var found = false
  for pr in activeProviders:
    if pr.name == target:
      prov = pr
      found = true
      break
  if not found:
    stdout.styledWriteLine fgRed, &"  unknown provider: {target}", resetStyle
    return
  if prov.models.len == 0:
    stdout.styledWriteLine fgRed,
      &"  provider {target} has no models", resetStyle
    return
  activeCurrent = prov.name & "." & prov.models[0]
  prof = buildProfile(activeCurrent, activeProviders, "")
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  showProfile(prof)

proc cmdProviderAdd(editor: var minline.LineEditor, prof: var Profile) =
  let prov = promptNewProvider(editor)
  activeProviders.add prov
  if activeCurrent == "":
    activeCurrent = prov.name & "." & prov.models[0]
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  if prof.name == "":
    prof = buildProfile(activeCurrent, activeProviders, "")
  hintLn &"  added {prov.name}", resetStyle

proc cmdProviderEdit(target: string, editor: var minline.LineEditor,
                     prof: var Profile) =
  var idx = -1
  for i, pr in activeProviders:
    if pr.name == target: idx = i; break
  if idx < 0:
    stdout.styledWriteLine fgRed, &"  unknown provider: {target}", resetStyle
    return
  let updated = promptEditProvider(editor, activeProviders[idx])
  activeProviders[idx] = updated
  let curName = if activeCurrent == "": "" else: activeCurrent.split('.')[0]
  if curName == target:
    let wantedModel = prof.model
    let model =
      if wantedModel in updated.models: wantedModel
      else: updated.models[0]
    activeCurrent = updated.name & "." & model
    prof = buildProfile(activeCurrent, activeProviders, "")
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  hintLn &"  updated {target}", resetStyle

proc cmdProviderRm(target: string, prof: var Profile) =
  var idx = -1
  for i, pr in activeProviders:
    if pr.name == target: idx = i; break
  if idx < 0:
    stdout.styledWriteLine fgRed, &"  unknown provider: {target}", resetStyle
    return
  activeProviders.delete(idx)
  let curName = if activeCurrent == "": "" else: activeCurrent.split('.')[0]
  if curName == target:
    if activeProviders.len > 0:
      let np = activeProviders[0]
      activeCurrent = np.name & "." & np.models[0]
      prof = buildProfile(activeCurrent, activeProviders, "")
    else:
      activeCurrent = ""
      prof = Profile()
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  hintLn &"  removed {target}", resetStyle

proc cmdProvider(arg: string, editor: var minline.LineEditor,
                 prof: var Profile) =
  let parts = arg.splitWhitespace()
  if parts.len == 0:
    cmdProviderList(prof)
    return
  case parts[0]
  of "add":
    if parts.len != 1:
      stdout.styledWriteLine fgRed, "  usage: :provider add", resetStyle
    else:
      cmdProviderAdd(editor, prof)
  of "edit":
    if parts.len != 2:
      stdout.styledWriteLine fgRed,
        "  usage: :provider edit <name>", resetStyle
    else:
      cmdProviderEdit(parts[1], editor, prof)
  of "rm", "remove":
    if parts.len != 2:
      stdout.styledWriteLine fgRed,
        &"  usage: :provider {parts[0]} <name>", resetStyle
    else:
      cmdProviderRm(parts[1], prof)
  else:
    if parts.len != 1:
      stdout.styledWriteLine fgRed,
        "  usage: :provider [<name> | add | rm <name>]", resetStyle
    else:
      cmdProviderSelect(parts[0], prof)

proc cmdModelList(prof: Profile) =
  let prov = currentProvider()
  if prov.name == "":
    hintLn "  no provider selected", resetStyle
    return
  if prov.models.len == 0:
    hintLn &"  {prov.name}: no models", resetStyle
    return
  for m in prov.models:
    let mark = if m == prof.model: "*" else: " "
    hintLn "  ", mark, " ", resetStyle, m

proc cmdModelSelect(target: string, prof: var Profile) =
  let prov = currentProvider()
  if prov.name == "":
    stdout.styledWriteLine fgRed, "  no provider selected", resetStyle
    return
  if target notin prov.models:
    stdout.styledWriteLine fgRed, &"  unknown model: {target}", resetStyle
    return
  activeCurrent = prov.name & "." & target
  prof = buildProfile(activeCurrent, activeProviders, "")
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  showProfile(prof)

proc cmdModel(arg: string, prof: var Profile) =
  let parts = arg.splitWhitespace()
  case parts.len
  of 0:
    cmdModelList(prof)
  of 1:
    cmdModelSelect(parts[0], prof)
  else:
    stdout.styledWriteLine fgRed,
      "  usage: :model [<name>]", resetStyle

proc handleCommand(cmd: string, messages: var JsonNode, session: var Session,
                   prof: var Profile, editor: var minline.LineEditor): bool =
  ## returns true if the input was a recognised command
  let c = cmd.strip
  if c.len == 0 or c[0] != ':': return false
  let sp = c.find({' ', '\t'})
  let name = if sp < 0: c else: c[0 ..< sp]
  let arg = if sp < 0: "" else: c[sp+1 .. ^1].strip
  case name
  of ":help", ":?":
    stdout.write HelpText
  of ":tokens":
    if session.usage.totalTokens == 0:
      hintLn "  no tokens used yet", resetStyle
    else:
      var msg = &"  session: {session.usage.totalTokens} tok  (in {session.usage.promptTokens}, out {session.usage.completionTokens})"
      if session.usage.cachedTokens > 0:
        msg.add &", cache {session.usage.cachedTokens}"
      hintLn msg, resetStyle
  of ":clear":
    messages = %* [{"role": "system", "content": buildSystemPrompt(prof)}]
    session.toolLog.setLen 0
    session.usage = Usage()
    session.lastPromptTokens = 0
    if session.savePath != "":
      session.savePath = newSessionPath()
      session.created = $now()
    hintLn "  context cleared", resetStyle
  of ":model":
    cmdModel(arg, prof)
    session.profileName = prof.name
  of ":provider":
    cmdProvider(arg, editor, prof)
    session.profileName = prof.name
  of ":prompt":
    let sp = buildSystemPrompt(prof)
    stdout.write sp
    if not sp.endsWith("\n"): stdout.write "\n"
  of ":show":
    showTool(arg, session.toolLog)
  of ":log":
    listTools(session.toolLog)
  of ":sessions":
    let paths = listSessionPaths()
    if paths.len == 0:
      hintLn "  no saved sessions", resetStyle
    else:
      for p in paths:
        let id = sessionIdFromPath(p)
        var count = 0
        var first = ""
        try:
          let j = parseJson(readFile(p))
          let msgs = j{"messages"}
          if msgs != nil and msgs.kind == JArray: count = msgs.len
          first = firstUserMessage(msgs)
        except CatchableError: discard
        let mark = if session.savePath == p: "*" else: " "
        let snip =
          if first.len == 0: ""
          elif first.len > 60: "  " & first[0 ..< 57] & "..."
          else: "  " & first
        hint &"  {mark} ", resetStyle, id, fgCyan, styleBright,
          &"   ({count} msg" & (if count == 1: "" else: "s") & ")",
          resetStyle, snip, "\n"
  of ":compact":
    let n = compactHistory(messages)
    if n == 0:
      hintLn "  nothing to compact", resetStyle
    else:
      hintLn &"  · compacted {n} tool result" &
        (if n == 1: "" else: "s"), resetStyle
      saveSession(session, messages)
  else:
    stdout.styledWriteLine fgRed, "unknown command: ", c, "  (try :help)", resetStyle
  return true

proc usage() {.noreturn.} =
  stderr.writeLine """usage: 3code [options] [prompt...]
       3code web <query...>         # DuckDuckGo search, plain-text results
       3code fetch <url>            # GET url, return readable text

  -m, --model PROVIDER[.MODEL]   pick model from config (overrides [settings])
  -r, --resume[=ID]    resume latest saved session (or by id)
  -v, --version        print version
  -h, --help           this message

config: """ & configPath()
  quit ExitUsage

proc runWeb(args: seq[string]) =
  if args.len == 0:
    die "web: missing query", ExitUsage
  let query = args.join(" ")
  let hits = try: webSearch(query)
             except CatchableError as e: die("web: " & e.msg, ExitApi)
  stdout.write formatHits(hits)
  if hits.len > 0: stdout.write "\n"

proc runFetch(args: seq[string]) =
  if args.len != 1:
    die "fetch: expected one url", ExitUsage
  let text = try: fetchUrl(args[0])
             except CatchableError as e: die("fetch: " & e.msg, ExitApi)
  stdout.write capText(text)
  stdout.write "\n"

proc main() =
  var model = ""
  var args: seq[string]
  var pending = ""  # flag awaiting a space-separated value
  var resume = false
  var resumeId = ""
  var p = initOptParser(commandLineParams())
  for kind, k, v in p.getopt():
    case kind
    of cmdShortOption, cmdLongOption:
      case k
      of "v", "version": echo Version; return
      of "h", "help": usage()
      of "m", "model":
        if v != "": model = v
        else: pending = "model"
      of "r", "resume":
        resume = true
        if v != "": resumeId = v
      else: die("unknown option: -" & (if k.len == 1: "" else: "-") & k, ExitUsage)
    of cmdArgument:
      if pending == "model":
        model = k
        pending = ""
      else:
        args.add k
    of cmdEnd: discard
  if pending != "":
    die("option --" & pending & " requires a value", ExitUsage)

  if args.len > 0:
    case args[0]
    of "web": runWeb(args[1 .. ^1]); return
    of "fetch": runFetch(args[1 .. ^1]); return
    else: discard

  let prompt = args.join(" ")
  var session: Session
  var messages: JsonNode

  if resume:
    let path = resolveSessionPath(resumeId)
    if path == "":
      if resumeId == "":
        die("no saved sessions in " & sessionDir(), ExitConfig)
      else:
        die("session not found: " & resumeId, ExitConfig)
    (session, messages) = loadSessionFile(path)
  else:
    messages = %* [{"role": "system", "content": SystemPrompt}]
    session.created = $now()
    session.savePath = newSessionPath()

  if prompt != "" and not resume:
    let prof = loadProfile(model)
    session.profileName = prof.name
    messages.add %*{"role": "user", "content": prompt}
    refreshSystemPrompt(messages, prof)
    runTurns(prof, messages, session)
    if session.usage.totalTokens > 0:
      hintLn &"  · {session.usage.totalTokens} tok total", resetStyle
    return

  (activeCurrent, activeProviders) = loadStateOrEmpty(configPath())
  let wantedProfile =
    if model != "": model
    elif resume and session.profileName != "": session.profileName
    else: ""
  var prof = buildProfile(activeCurrent, activeProviders, wantedProfile)
  var editor = welcome(prof)
  if prof.name == "":
    prof = bootstrapProvider(editor)
  session.profileName = prof.name
  if resume:
    hintLn &"  · resumed {sessionIdFromPath(session.savePath)}  " &
      &"({messages.len} msg" & (if messages.len == 1: "" else: "s") & ")",
      resetStyle
    if prompt != "":
      messages.add %*{"role": "user", "content": prompt}
      refreshSystemPrompt(messages, prof)
      runTurns(prof, messages, session)
  while true:
    var done = false
    let line = readInput(editor, done)
    if done:
      echo ""
      break
    if line == "": continue
    let t = line.strip
    if t in ["exit", "quit", ":q", ":quit", ":exit"]: break
    if handleCommand(line, messages, session, prof, editor): continue
    if prof.name == "":
      stdout.styledWriteLine fgRed,
        "  no provider configured. use :provider add", resetStyle
      continue
    messages.add %*{"role": "user", "content": line}
    refreshSystemPrompt(messages, prof)
    runTurns(prof, messages, session)

when isMainModule:
  main()
