import std/[httpclient, json, os, osproc, strutils, strformat, sequtils, terminal, parsecfg, parseopt, tables]

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
"""

const ConfigExample = """  [3code]
  profile = openai

  [openai]
  url = r"https://api.openai.com/v1"
  key = r"sk-..."
  model = "gpt-4o-mini"

(values are Nim string literals — use r"..." for anything with a colon.)
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

proc die(msg: string, code = 1) {.noreturn.} =
  stderr.writeLine "3code: " & msg
  quit code

proc configPath(): string =
  getConfigDir() / "3code" / "config"

proc loadProfile(wanted: string): Profile =
  let path = configPath()
  if not fileExists(path):
    stderr.writeLine "3code: no config at " & path
    stderr.writeLine ""
    stderr.writeLine "create it with at least one model profile, e.g.:"
    stderr.writeLine ""
    stderr.writeLine ConfigExample
    quit ExitConfig
  let cfg = loadConfig(path)
  var pick = wanted
  if pick == "":
    pick = cfg.getSectionValue("3code", "profile")
  if pick == "":
    # fall back to first non-[3code] section
    for section in cfg.keys:
      if section != "" and section != "3code":
        pick = section
        break
  if pick == "":
    die "no model profile defined in " & path, ExitConfig
  let url = cfg.getSectionValue(pick, "url").strip(chars = {'/', ' '})
  let key = cfg.getSectionValue(pick, "key")
  let model = cfg.getSectionValue(pick, "model")
  if url == "": die &"profile [{pick}]: url not set in {path}", ExitConfig
  if key == "": die &"profile [{pick}]: key not set in {path}", ExitConfig
  if model == "": die &"profile [{pick}]: model not set in {path}", ExitConfig
  Profile(name: pick, url: url, key: key, model: model)

proc callModel(p: Profile, messages: JsonNode): string =
  let client = newHttpClient(timeout = 120_000)
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
  let resp = try: client.request(p.url & "/chat/completions", HttpPost, $body)
             except CatchableError as e: die("network: " & e.msg, ExitApi)
  let text = resp.body
  if resp.code != Http200:
    die("api " & $resp.code & ": " & text, ExitApi)
  let j = parseJson(text)
  if "error" in j: die("api error: " & $j["error"], ExitApi)
  j["choices"][0]["message"]["content"].getStr

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

proc runAction*(act: Action): string =
  case act.kind
  of akBash:
    let cmd = act.body.strip
    let (output, code) = execCmdEx(cmd)
    var tail = output
    if tail.len > 8000: tail = tail[0 ..< 4000] & "\n... [truncated] ...\n" & tail[^4000 .. ^1]
    &"$ {cmd}\n{tail}[exit {code}]"
  of akWrite:
    let dir = parentDir(act.path)
    if dir != "": createDir(dir)
    writeFile(act.path, act.body)
    &"wrote {act.path} ({act.body.len} bytes)"
  of akPatch:
    if not fileExists(act.path):
      return &"error: {act.path} does not exist"
    var content = readFile(act.path)
    var applied = 0
    for (s, r) in act.edits:
      let (next, ok) = replaceFirst(content, s, r)
      if not ok:
        return &"error: SEARCH block did not match in {act.path}:\n{s}"
      content = next
      inc applied
    writeFile(act.path, content)
    &"patched {act.path} ({applied} edit" & (if applied == 1: "" else: "s") & ")"

proc describe(act: Action): string =
  case act.kind
  of akBash: "bash"
  of akWrite: "write " & act.path
  of akPatch: "patch " & act.path

proc welcome(p: Profile) =
  stdout.styledWriteLine fgCyan, styleBright, "  ╭─╮"
  stdout.styledWriteLine fgCyan, styleBright, "   ─┤  ", resetStyle, fgWhite, styleBright, "3code ", resetStyle, fgBlack, styleBright, "v" & Version
  stdout.styledWriteLine fgCyan, styleBright, "  ╰─╯"
  stdout.write "\n"
  stdout.styledWriteLine fgBlack, styleBright, "  profile  ", resetStyle, p.name
  stdout.styledWriteLine fgBlack, styleBright, "  model    ", resetStyle, p.model
  stdout.write "\n"
  stdout.styledWriteLine fgBlack, styleBright, "  type a prompt. :q or Ctrl-D to exit."
  stdout.flushFile

proc runTurns(p: Profile, messages: var JsonNode) =
  while true:
    let reply = callModel(p, messages)
    messages.add %*{"role": "assistant", "content": reply}
    stdout.write "\n"
    stdout.styledWrite fgCyan, reply, resetStyle, "\n"
    stdout.flushFile
    let actions = parseActions(reply)
    if actions.len == 0: break
    var results = ""
    for act in actions:
      stdout.styledWrite fgYellow, "» ", describe(act), "\n", resetStyle
      stdout.flushFile
      let r = runAction(act)
      stdout.write r & "\n"
      results.add "--- " & describe(act) & " ---\n" & r & "\n"
    messages.add %*{"role": "user", "content": results}

proc usage() {.noreturn.} =
  stderr.writeLine """usage: 3code [options] [prompt...]

  -p, --profile NAME   use named profile from config
  -v, --version        print version
  -h, --help           this message

config: """ & configPath()
  quit ExitUsage

proc main() =
  var profile = ""
  var prompt = ""
  var p = initOptParser(commandLineParams())
  for kind, k, v in p.getopt():
    case kind
    of cmdShortOption, cmdLongOption:
      case k
      of "v", "version": echo Version; return
      of "h", "help": usage()
      of "p", "profile": profile = v
      else: die("unknown option: -" & (if k.len == 1: "" else: "-") & k, ExitUsage)
    of cmdArgument:
      if prompt.len > 0: prompt.add " "
      prompt.add k
    of cmdEnd: discard

  let prof = loadProfile(profile)
  var messages = %* [{"role": "system", "content": SystemPrompt}]

  if prompt != "":
    messages.add %*{"role": "user", "content": prompt}
    runTurns(prof, messages)
    return

  welcome(prof)
  while true:
    stdout.styledWrite fgGreen, styleBright, "\n> ", resetStyle
    stdout.flushFile
    var line: string
    try:
      line = stdin.readLine
    except EOFError:
      echo ""
      break
    if line.strip == "": continue
    if line.strip in ["exit", "quit", ":q"]: break
    messages.add %*{"role": "user", "content": line}
    runTurns(prof, messages)

when isMainModule:
  main()
