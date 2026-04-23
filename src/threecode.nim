import std/[httpclient, json, os, osproc, strutils, strformat, sequtils, streams, terminal, parsecfg, parseopt, times, atomics, critbits, uri]
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

const SystemPromptText = """
You are 3code, a coding agent running in a terminal.

You act by emitting fenced code blocks. After your turn the harness executes them and replies with their results. Mix prose and action blocks freely.

Three action forms:

1. Run a shell command:

```bash
ls -la
```

2. Write a whole file (creates or overwrites). Put the path on its own line immediately before the fence:

path/to/file.nim
```
echo "hello"
```

3. Patch an existing file with one or more exact-match edits. Put the path on its own line, then inside the fence use SEARCH/REPLACE markers:

path/to/file.nim
```
<<<<<<< SEARCH
old code that matches exactly
=======
new code
>>>>>>> REPLACE
```

A single file block may contain multiple SEARCH/REPLACE pairs. SEARCH blocks must match the file byte-for-byte — copy from a prior `cat` exactly, preserving indentation, trailing whitespace, and line endings. Paraphrased or reformatted matches will fail; on failure retry with a corrected SEARCH.

When the task is done, reply with prose and no action blocks.

## Working effectively

- Orient first. On a fresh task in an unfamiliar repo, `ls` and read the README and the build manifest (`*.nimble`, `package.json`, `Cargo.toml`, `pyproject.toml`, etc.) before editing. Skip only for obviously trivial tasks.
- Plan multi-step tasks. For anything beyond a one-liner, sketch a 3–8 step plan before touching files; work the steps in order and note when each is done.
- Stay in scope. Do what was asked, nothing more. Don't refactor, reformat, add comments/docstrings, or handle hypothetical edge cases the user didn't mention.
- Match the local style. Before writing new code, glance at a neighboring file for naming, imports, error-handling pattern, and indentation. Don't impose your own taste.
- Edit surgically. For a small fix use a SEARCH/REPLACE patch block, not a full-file write. For a rename, patch the definition and call sites — don't rewrite each file whole.
- Verify before declaring done. After making changes, run the project's tests, build, or typecheck; then `git diff` / `git status` (if it's a git repo) to confirm the change is what you intended and nothing accidental tagged along. Don't call the task complete if anything's off.
- Gather context before guessing. Read real files; don't invent their contents.
- Search before reading. Use `rg` or `grep -rn` to locate the handful of lines you care about, then `cat` only that file — or `sed -n 'A,Bp' file` for a specific line range when the file is large. Don't cat whole files or whole directories unless you actually need them. Prefer `find -maxdepth 2` or `ls` over recursive scans.
- Probe when unsure. When you don't know how an API, library, regex, or command actually behaves, write a short throwaway script in a temp dir (`mktemp -d`, or under `/tmp/`) and run it — don't guess. Clean up the temp dir before moving on.
- Local before web. Installed dependencies, vendored source, CHANGELOGs, `tests/`, `example/`, and `man` pages usually answer the question faster and more accurately than a web search. Check them first. Reach for the web only when the local tree genuinely lacks the info.
- Stop when done. If a task already looks complete when you start, say so and stop — don't invent work.
- Pause before irreversible ops outside the working directory (`rm -rf` of other paths, force-push, database drops, destructive git history rewrites). Explain and wait for the user.

## Finding things

- Files and search in the working tree: `cat`, `rg`, `grep -rn`, `find`, `ls` via a bash block.
- Web (for current facts, API details, or docs the local tree doesn't have): `3code web "query"` prints numbered DuckDuckGo results; `3code fetch <url>` returns the page as readable text. Prefer official docs over blogspam.
"""

const SystemPromptTools = """
You are 3code, a coding agent running in a terminal.

Call the provided tools (`bash`, `read`, `write`, `patch`) to take actions. After your turn the harness runs each tool call and feeds results back. You may emit prose alongside tool calls. When the task is done, reply with prose and no tool calls.

- `bash(command)` — run a shell command; output and exit code come back.
- `read(path, offset?, limit?)` — read a file, or a line range of it. `offset` is 1-indexed.
- `write(path, body)` — create or overwrite a file.
- `patch(path, edits)` — apply exact-match search/replace edits to an existing file. `edits` is an array of `{search, replace}` objects. Each `search` must be copied byte-for-byte from a prior `read` — same indentation, same trailing whitespace, same line endings. Paraphrased or reformatted matches will fail; on failure retry with a corrected `search`.

## Working effectively

- Orient first. On a fresh task in an unfamiliar repo, run `ls` and read the README and the build manifest (`*.nimble`, `package.json`, `Cargo.toml`, `pyproject.toml`, etc.) before editing. Skip only for obviously trivial tasks.
- Plan multi-step tasks. For anything beyond a one-liner, sketch a 3–8 step plan before touching files; work the steps in order and note when each is done.
- Stay in scope. Do what was asked, nothing more. Don't refactor, reformat, add comments/docstrings, or handle hypothetical edge cases the user didn't mention.
- Match the local style. Before writing new code, glance at a neighboring file for naming, imports, error-handling pattern, and indentation. Don't impose your own taste.
- Edit surgically. For a small fix use `patch`, not `write`. For a rename, `patch` the definition and call sites — don't rewrite each file whole.
- Verify before declaring done. After changes, run the project's tests, build, or typecheck; then `git diff` / `git status` (if it's a git repo) to confirm the change is what you intended and nothing accidental tagged along. Don't call the task complete if anything's off.
- Gather context before guessing. Read real files; don't invent their contents.
- Search before reading. Use `rg` or `grep -rn` (via `bash`) to locate the handful of lines you care about, then `read` only that file — with `offset` / `limit` when the file is large. Prefer `read` over `bash cat` for any file over ~100 lines so you keep range control. Don't read whole files or whole directories unless you actually need them. Prefer `find -maxdepth 2` or `ls` over recursive scans.
- Probe when unsure. When you don't know how an API, library, regex, or command actually behaves, write a short throwaway script in a temp dir (`mktemp -d`, or under `/tmp/`) and run it — don't guess. Clean up the temp dir before moving on.
- Local before web. Installed dependencies, vendored source, CHANGELOGs, `tests/`, `example/`, and `man` pages usually answer the question faster and more accurately than a web search. Check them first. Reach for the web only when the local tree genuinely lacks the info.
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
commands:
  :help             show this message
  :tokens           show token usage for this session
  :clear            reset conversation (keeps system prompt)
  :model            list models for current provider (current marked with *)
  :model X          switch to model X (within current provider)
  :provider         list configured providers (current marked with *)
  :provider X       switch to provider X (model defaults to first in its list)
  :provider add     add a new provider (interactive, verified)
  :provider rm X    remove provider X
  :show [N]         show full output of tool call N (default: last)
  :log              list all tool calls this session
  :q :quit          exit (also Ctrl-D)

input:
  single-line   just type and press Enter
  multi-line    type three double-quotes on its own line, enter lines, close the same way
  up / down     recall history; down past last clears the line
  tab           complete :commands, provider names, model names
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
    name, url, key, modelPrefix, model, mode: string
  Usage = object
    promptTokens, completionTokens, totalTokens: int
  ToolRecord = object
    banner: string
    output: string
    code: int
    kind: ActionKind

var toolLog: seq[ToolRecord]

proc die(msg: string, code = 1) {.noreturn.} =
  stderr.writeLine "3code: " & msg
  quit code

proc configPath(): string =
  getConfigDir() / "3code" / "config"

type
  ProviderRec = object
    name, url, key, modelPrefix, mode: string
    models: seq[string]

var activeCurrent: string
var activeProviders: seq[ProviderRec]

const CommandNames = [":help", ":tokens", ":clear", ":model", ":provider",
                      ":show", ":log", ":q", ":quit", ":exit"]

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
  if words[0] == ":provider" and words.len == 2:
    for pr in activeProviders: result.add pr.name
    return
  if words[0] == ":model" and words.len == 2:
    for m in currentProvider().models: result.add m
    return

proc splitModels(s: string): seq[string] =
  for m in s.splitWhitespace:
    if m.len > 0: result.add m

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
      case section
      of "settings":
        if e.key == "current": current = e.value
      of "provider":
        case e.key
        of "name": prov.name = e.value
        of "url": prov.url = e.value.strip(chars = {'/', ' '})
        of "key": prov.key = e.value
        of "model_prefix": prov.modelPrefix = e.value
        of "mode": prov.mode = e.value
        of "models": prov.models = splitModels(e.value)
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
    if pr.mode != "":
      buf.add "mode = " & quoteVal(pr.mode) & "\n"
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
                     key: pr.key, modelPrefix: pr.modelPrefix, model: model,
                     mode: pr.mode)
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
          modelPrefix: prov.modelPrefix, model: model, mode: prov.mode)

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

proc systemPromptFor*(p: Profile): string =
  if p.mode == "text": SystemPromptText else: SystemPromptTools

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

proc callModel(p: Profile, messages: JsonNode, usage: var Usage): JsonNode =
  let client = newHttpClient(timeout = -1)
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
  if p.mode != "text":
    body["tools"] = ToolsJson
    body["tool_choice"] = %"auto"
  let bodyStr = $body
  let t0 = epochTime()
  startSpinner(&"thinking · ↑ ~{bodyStr.len div 4} tok")
  let resp = try:
    let r = client.request(p.url & "/chat/completions", HttpPost, bodyStr)
    stopSpinner()
    r
  except CatchableError as e:
    stopSpinner()
    die("network: " & e.msg, ExitApi)
  let text = resp.body
  let elapsed = epochTime() - t0
  if resp.code != Http200:
    die("api " & $resp.code & ": " & text, ExitApi)
  let j = parseJson(text)
  if "error" in j: die("api error: " & $j["error"], ExitApi)
  if "usage" in j:
    let u = j["usage"]
    usage.promptTokens = u{"prompt_tokens"}.getInt(0)
    usage.completionTokens = u{"completion_tokens"}.getInt(0)
    usage.totalTokens = u{"total_tokens"}.getInt(0)
  let info =
    if usage.totalTokens > 0:
      &"  ↑ {usage.promptTokens} tok · ↓ {usage.completionTokens} tok · {elapsed.int}s"
    else:
      &"  ↓ ~{text.len div 4} tok · {elapsed.int}s"
  hint info, resetStyle, "\n"
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

# ---------- Parser ----------

proc looksLikePath*(s: string): bool =
  let t = s.strip
  if t.len == 0 or t.len > 200: return false
  if ' ' in t or '\t' in t: return false
  if t.startsWith("```") or t.startsWith("#"): return false
  '/' in t or '.' in t

proc parseActions*(text: string): seq[Action] =
  let lines = text.splitLines
  var i = 0
  while i < lines.len:
    let ln = lines[i].strip
    if ln == "```bash" or ln == "```sh" or ln == "```shell":
      inc i
      var body = ""
      while i < lines.len and lines[i].strip != "```":
        body.add lines[i] & "\n"
        inc i
      if i < lines.len: inc i
      result.add Action(kind: akBash, body: body)
      continue
    if i + 1 < lines.len and lines[i+1].strip == "```" and looksLikePath(lines[i]):
      let path = lines[i].strip
      i += 2
      var body = ""
      while i < lines.len and lines[i].strip != "```":
        body.add lines[i] & "\n"
        inc i
      if i < lines.len: inc i
      if "<<<<<<< SEARCH" in body:
        var act = Action(kind: akPatch, path: path)
        let blines = body.splitLines
        var k = 0
        while k < blines.len:
          if blines[k].strip == "<<<<<<< SEARCH":
            inc k
            var s = ""
            while k < blines.len and blines[k].strip != "=======":
              s.add blines[k] & "\n"
              inc k
            if k < blines.len: inc k
            var r = ""
            while k < blines.len and blines[k].strip != ">>>>>>> REPLACE":
              r.add blines[k] & "\n"
              inc k
            if k < blines.len: inc k
            act.edits.add (s, r)
          else:
            inc k
        result.add act
      else:
        result.add Action(kind: akWrite, path: path, body: body)
      continue
    inc i

proc stripActions*(text: string): string =
  ## Return `text` with every action block elided, so the user sees prose only.
  ## Mirrors `parseActions` block detection. Collapses runs of blank lines
  ## created by the elision and trims leading/trailing blank lines.
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
  var lastBlank = true  # trims leading blank lines
  for l in kept:
    let blank = l.strip.len == 0
    if blank and lastBlank: continue
    res.add l
    lastBlank = blank
  while res.len > 0 and res[^1].strip.len == 0:
    res.setLen res.len - 1
  res.join("\n")

proc replaceFirst*(s, needle, repl: string): (string, bool) =
  let idx = s.find(needle)
  if idx < 0: return (s, false)
  (s[0 ..< idx] & repl & s[idx + needle.len .. ^1], true)

proc runAction*(act: Action): (string, int) =
  case act.kind
  of akBash:
    let cmd = act.body.strip
    let (output, code) = execCmdEx(cmd)
    var tail = output
    if tail.len > 8000: tail = tail[0 ..< 4000] & "\n... [truncated] ...\n" & tail[^4000 .. ^1]
    (&"$ {cmd}\n{tail}[exit {code}]", code)
  of akRead:
    if not fileExists(act.path):
      return (&"error: {act.path} does not exist", 1)
    let content = readFile(act.path)
    const MaxLines = 2000
    const MaxBytes = 60 * 1024
    let lines = content.splitLines
    let total =
      if lines.len > 0 and lines[^1] == "": lines.len - 1
      else: lines.len
    let start = max(0, act.offset - 1)
    if start >= total: return ("", 0)
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
      return (content, 0)
    var body = lines[start ..< endi].join("\n")
    if capped:
      let shown = endi - start
      body.add &"\n... [file is {total} lines, {content.len} bytes; showed {shown} lines from line {start + 1}. Use read(path, offset, limit) for a specific range.] ..."
    (body, 0)
  of akWrite:
    let dir = parentDir(act.path)
    if dir != "": createDir(dir)
    writeFile(act.path, act.body)
    (&"wrote {act.path} ({act.body.len} bytes)", 0)
  of akPatch:
    if not fileExists(act.path):
      return (&"error: {act.path} does not exist", 1)
    var content = readFile(act.path)
    var applied = 0
    for (s, r) in act.edits:
      let (next, ok) = replaceFirst(content, s, r)
      if not ok:
        return (&"error: SEARCH block did not match in {act.path}:\n{s}", 1)
      content = next
      inc applied
    writeFile(act.path, content)
    (&"patched {act.path} ({applied} edit" & (if applied == 1: "" else: "s") & ")", 0)

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

proc printActionResult(act: Action, res: string, code: int, idx: int) =
  if act.kind in {akBash, akRead}:
    printBashCompact(res, idx)
  else:
    if code == 0:
      stdout.styledWriteLine fgGreen, res, resetStyle
    else:
      stdout.styledWriteLine fgRed, styleBright, res, resetStyle

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
  stdout.styledWriteLine fgCyan, styleBright, "   ─┤  ", resetStyle, fgWhite, styleBright, "3code ", resetStyle, fgCyan, styleBright, "v" & Version
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

proc runTurns(p: Profile, messages: var JsonNode, session: var Usage) =
  while true:
    var usage: Usage
    let msg = callModel(p, messages, usage)
    session.promptTokens += usage.promptTokens
    session.completionTokens += usage.completionTokens
    session.totalTokens += usage.totalTokens
    messages.add msg
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
        let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                   except CatchableError: newJObject()
        let act = toolCallToAction(name, args)
        let idx = toolLog.len + 1
        stdout.styledWrite fgYellow, styleBright, "» ", resetStyle,
          fgYellow, bannerFor(act), resetStyle,
          fgCyan, styleBright, &"   [T{idx}]", resetStyle, "\n"
        stdout.flushFile
        let (r, code) = runAction(act)
        toolLog.add ToolRecord(banner: bannerFor(act), output: r, code: code, kind: act.kind)
        printActionResult(act, r, code, idx)
        messages.add %*{"role": "tool", "tool_call_id": id, "content": r}
      continue
    let prose = stripActions(content)
    if prose.len > 0:
      stdout.styledWrite fgCyan, prose, resetStyle, "\n"
      stdout.flushFile
    let actions = parseActions(content)
    if actions.len == 0:
      if content.strip.len == 0:
        stdout.styledWriteLine fgRed, styleBright,
          "  (empty reply — no content, no tool calls)", resetStyle
      break
    var results = ""
    for act in actions:
      let idx = toolLog.len + 1
      stdout.styledWrite fgYellow, styleBright, "» ", resetStyle,
        fgYellow, bannerFor(act), resetStyle,
        fgCyan, styleBright, &"   [T{idx}]", resetStyle, "\n"
      stdout.flushFile
      let (r, code) = runAction(act)
      toolLog.add ToolRecord(banner: bannerFor(act), output: r, code: code, kind: act.kind)
      printActionResult(act, r, code, idx)
      results.add "--- " & bannerFor(act) & " ---\n" & r & "\n"
    messages.add %*{"role": "user", "content": results}

proc showTool(arg: string) =
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

proc listTools() =
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

proc readOptional(editor: var minline.LineEditor, prompt: string): string =
  try: editor.readLine(prompt).strip
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

proc readProviderEntry(editor: var minline.LineEditor): string =
  let prevCb = editor.completionCallback
  editor.completionCallback = proc(ed: LineEditor): seq[string] =
    for (n, _) in ProviderCatalog: result.add n
  result = readRequired(editor, "  provider name or url : ")
  editor.completionCallback = prevCb

proc promptNewProvider(editor: var minline.LineEditor): ProviderRec =
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
    let key = readRequired(editor, "  api key              : ", hidden = true)
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
    let mark = if pr.name == curName: "*" else: " "
    hintLn "  ", mark, " ", resetStyle,
                           pr.name

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

proc handleCommand(cmd: string, messages: var JsonNode, session: Usage,
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
    if session.totalTokens == 0:
      hintLn "  no tokens used yet", resetStyle
    else:
      hintLn &"  session: {session.totalTokens} tok  (in {session.promptTokens}, out {session.completionTokens})",
        resetStyle
  of ":clear":
    messages = %* [{"role": "system", "content": systemPromptFor(prof)}]
    toolLog.setLen 0
    hintLn "  context cleared", resetStyle
  of ":model":
    cmdModel(arg, prof)
  of ":provider":
    cmdProvider(arg, editor, prof)
  of ":show":
    showTool(arg)
  of ":log":
    listTools()
  else:
    stdout.styledWriteLine fgRed, "unknown command: ", c, "  (try :help)", resetStyle
  return true

proc usage() {.noreturn.} =
  stderr.writeLine """usage: 3code [options] [prompt...]
       3code web <query...>         # DuckDuckGo search, plain-text results
       3code fetch <url>            # GET url, return readable text

  -m, --model PROVIDER[.MODEL]   pick model from config (overrides [settings])
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
  var session: Usage

  if prompt != "":
    let prof = loadProfile(model)
    var messages = %* [{"role": "system", "content": systemPromptFor(prof)}]
    messages.add %*{"role": "user", "content": prompt}
    runTurns(prof, messages, session)
    if session.totalTokens > 0:
      hintLn &"  · {session.totalTokens} tok total", resetStyle
    return

  (activeCurrent, activeProviders) = loadStateOrEmpty(configPath())
  var prof = buildProfile(activeCurrent, activeProviders, model)
  var editor = welcome(prof)
  if prof.name == "":
    prof = bootstrapProvider(editor)
  var messages = %* [{"role": "system", "content": systemPromptFor(prof)}]
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
    runTurns(prof, messages, session)

when isMainModule:
  main()
