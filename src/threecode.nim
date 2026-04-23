import std/[httpclient, json, os, osproc, strutils, strformat, sequtils, streams, terminal, parsecfg, parseopt, times, atomics, critbits]
import minline
import threecode/web

const Version = staticRead("../threecode.nimble").splitLines().filterIt(it.startsWith("version")).
    mapIt(it.split("=")[1].strip().strip(chars = {'"'}))[0]

const
  ExitUsage = 2
  ExitConfig = 3
  ExitApi = 5

const SystemPrompt = """
You are 3code, a minimal coding agent running in a terminal.

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

A single file block may contain multiple SEARCH/REPLACE pairs. SEARCH blocks must match the file byte-for-byte; if one does not match, the edit fails and you must retry with a corrected SEARCH.

When the task is done, reply with prose and no action blocks.

## Gathering context

Before guessing, look things up. Assume you know nothing about this repo until you have read it.

- Working directory: use `rg`, `grep -rn`, `find`, `ls`, or `cat` (via a bash block) to locate the relevant file, function, config key, version, or dependency. Read files rather than inventing their contents.
- Web: when you need API details, library docs, error-message meanings, or any current fact you are not sure about, shell out:

  ```bash
  3code web "exact query string"
  ```

  prints a numbered list of result titles / URLs / snippets from DuckDuckGo. Then fetch the most promising one as readable text:

  ```bash
  3code fetch https://example.com/some/page
  ```

  Use these freely — one or two searches up front beats a failed attempt. Prefer official docs and source over blogspam.
"""

const ConfigExample = """  [settings]
  current = "openai.gpt-4o-mini"

  [provider]
  name = "openai"
  url = "https://api.openai.com/v1"
  key = "sk-..."
  models = "gpt-4o-mini, gpt-4o"

(values are Nim string literals — always wrap them in double quotes.)
"""

const HelpText = """
commands:
  :help         show this message
  :tokens       show token usage for this session
  :clear        reset conversation (keeps system prompt)
  :model        show current provider and model
  :show [N]     show full output of tool call N (default: last)
  :log          list all tool calls this session
  :q :quit      exit (also Ctrl-D)

input:
  single-line   just type and press Enter
  multi-line    type three double-quotes on its own line, enter lines, close the same way
  up / down     recall history; down past last clears the line
"""

type
  ActionKind* = enum akBash, akWrite, akPatch
  Action* = object
    kind*: ActionKind
    path*: string
    body*: string
    edits*: seq[(string, string)]
  Profile = object
    name, url, key, model: string
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
    name, url, key: string
    models: seq[string]

proc splitModels(s: string): seq[string] =
  for m in s.split(','):
    let t = m.strip
    if t.len > 0: result.add t

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
        of "models": prov.models = splitModels(e.value)
        else: discard
      else: discard
    of cfgError:
      die &"{path}: {e.msg}", ExitConfig
  p.close
  (current, providers)

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
  Profile(name: prov.name & "." & model, url: prov.url, key: prov.key, model: model)

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
        fgBlack, styleBright, &"  {label} {elapsed:4.1f}s", resetStyle
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

proc callModel(p: Profile, messages: JsonNode, usage: var Usage): string =
  let client = newHttpClient(timeout = -1)
  defer: client.close()
  client.headers = newHttpHeaders({
    "Authorization": "Bearer " & p.key,
    "Content-Type": "application/json"
  })
  let body = %*{
    "model": p.model,
    "messages": messages,
    "stream": false
  }
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
  stdout.styledWrite fgBlack, styleBright,
    (if usage.totalTokens > 0:
       &"  ↑ {usage.promptTokens} tok · ↓ {usage.completionTokens} tok · {elapsed:.1f}s"
     else:
       &"  ↓ ~{text.len div 4} tok · {elapsed:.1f}s"),
    resetStyle, "\n"
  stdout.flushFile
  j["choices"][0]["message"]["content"].getStr

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
    stdout.styledWriteLine fgBlack, styleBright, l, resetStyle
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
    stdout.styledWriteLine fgBlack, styleBright,
      &"  … {hidden} line" & (if hidden == 1: "" else: "s") &
      &" hidden · :show {idx} for full …", resetStyle
    for i in footer - CompactTail ..< footer: printLine(lines[i])
  if footer < lines.len: printLine(lines[footer])

proc printActionResult(act: Action, res: string, code: int, idx: int) =
  if act.kind == akBash:
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

proc welcome(p: Profile): minline.LineEditor =
  stdout.styledWriteLine fgCyan, styleBright, "  ╭─╮"
  stdout.styledWriteLine fgCyan, styleBright, "   ─┤  ", resetStyle, fgWhite, styleBright, "3code ", resetStyle, fgBlack, styleBright, "v" & Version
  stdout.styledWriteLine fgCyan, styleBright, "  ╰─╯"
  stdout.write "\n"
  stdout.styledWriteLine fgBlack, styleBright, "  model    ", resetStyle, p.name
  stdout.write "\n"
  stdout.styledWriteLine fgBlack, styleBright, "  type a prompt. :help for commands. :q or Ctrl-D to exit."
  stdout.flushFile
  installEditorTweaks()
  result = minline.initEditor(historyFile = historyFile())

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
    let reply = callModel(p, messages, usage)
    session.promptTokens += usage.promptTokens
    session.completionTokens += usage.completionTokens
    session.totalTokens += usage.totalTokens
    messages.add %*{"role": "assistant", "content": reply}
    stdout.write "\n"
    stdout.styledWrite fgCyan, reply, resetStyle, "\n"
    stdout.flushFile
    let actions = parseActions(reply)
    if actions.len == 0: break
    var results = ""
    for act in actions:
      let idx = toolLog.len + 1
      stdout.styledWrite fgYellow, styleBright, "» ", resetStyle,
        fgYellow, bannerFor(act), resetStyle,
        fgBlack, styleBright, &"   [T{idx}]", resetStyle, "\n"
      stdout.flushFile
      let (r, code) = runAction(act)
      toolLog.add ToolRecord(banner: bannerFor(act), output: r, code: code, kind: act.kind)
      printActionResult(act, r, code, idx)
      results.add "--- " & bannerFor(act) & " ---\n" & r & "\n"
    messages.add %*{"role": "user", "content": results}

proc showTool(arg: string) =
  if toolLog.len == 0:
    stdout.styledWriteLine fgBlack, styleBright, "  no tool calls yet", resetStyle
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
  if rec.kind == akBash:
    for l in rec.output.splitLines: printLine(l)
  else:
    if rec.code == 0:
      stdout.styledWriteLine fgGreen, rec.output, resetStyle
    else:
      stdout.styledWriteLine fgRed, styleBright, rec.output, resetStyle

proc listTools() =
  if toolLog.len == 0:
    stdout.styledWriteLine fgBlack, styleBright, "  no tool calls yet", resetStyle
    return
  for i, rec in toolLog:
    let tag = &"T{i+1}"
    let lines = rec.output.splitLines.len
    let mark = if rec.code == 0: "✓" else: "✗"
    let color = if rec.code == 0: fgGreen else: fgRed
    stdout.styledWrite fgBlack, styleBright, &"  {tag:>4}  ", resetStyle,
      color, mark, resetStyle, " ",
      rec.banner,
      fgBlack, styleBright, &"   ({lines} line" & (if lines == 1: "" else: "s") & ")",
      resetStyle, "\n"

proc handleCommand(cmd: string, messages: var JsonNode, session: Usage,
                   prof: Profile): bool =
  ## returns true if the input was a recognised command
  let c = cmd.strip
  if c.len == 0 or c[0] != ':': return false
  let sp = c.find({' ', '\t'})
  let name = if sp < 0: c else: c[0 ..< sp]
  let arg = if sp < 0: "" else: c[sp+1 .. ^1].strip
  case name
  of ":help", ":h", ":?":
    stdout.write HelpText
  of ":tokens", ":t":
    if session.totalTokens == 0:
      stdout.styledWriteLine fgBlack, styleBright, "  no tokens used yet", resetStyle
    else:
      stdout.styledWriteLine fgBlack, styleBright,
        &"  session: {session.totalTokens} tok  (in {session.promptTokens}, out {session.completionTokens})",
        resetStyle
  of ":clear":
    messages = %* [{"role": "system", "content": SystemPrompt}]
    toolLog.setLen 0
    stdout.styledWriteLine fgBlack, styleBright, "  context cleared", resetStyle
  of ":model":
    stdout.styledWriteLine fgBlack, styleBright,
      &"  model  {prof.name}", resetStyle
  of ":show", ":s":
    showTool(arg)
  of ":log", ":l":
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
  let prof = loadProfile(model)
  var messages = %* [{"role": "system", "content": SystemPrompt}]
  var session: Usage

  if prompt != "":
    messages.add %*{"role": "user", "content": prompt}
    runTurns(prof, messages, session)
    if session.totalTokens > 0:
      stdout.styledWriteLine fgBlack, styleBright,
        &"  · {session.totalTokens} tok total", resetStyle
    return

  var editor = welcome(prof)
  while true:
    var done = false
    let line = readInput(editor, done)
    if done:
      echo ""
      break
    if line == "": continue
    let t = line.strip
    if t in ["exit", "quit", ":q", ":quit", ":exit"]: break
    if handleCommand(line, messages, session, prof): continue
    messages.add %*{"role": "user", "content": line}
    runTurns(prof, messages, session)

when isMainModule:
  main()
