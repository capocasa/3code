import std/[json, os, sequtils, strformat, strutils, terminal, times]
import types, util, prompts, session, config, api, compact, display, minline,
       statusbar

const CommandNames* = [":help", ":tokens", ":clear", ":model", ":provider",
                      ":prompt", ":show", ":log", ":sessions", ":compact",
                      ":summarize", ":think", ":q", ":quit", ":exit"]

proc completionFor*(line: string): seq[string] =
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
      return
    if words.len == 3 and words[1] in ["edit", "rm", "remove"]:
      for pr in activeProviders: result.add pr.name
      return
  if words[0] == ":model" and words.len == 2:
    let prov = currentProvider()
    for m in prov.models:
      if experimentalEnabled or knownGoodFamily(prov.name, prov.modelPrefix & m) != "":
        result.add m
    return

proc readRequired*(editor: var minline.LineEditor, prompt: string,
                  hidden = false, noHistory = true): string =
  ## ctrl+c raises `minline.InputCancelled` to the caller; ctrl+d aborts
  ## the program. Empty input keeps re-prompting.
  while true:
    let s = try: editor.readLine(prompt, hidechars = hidden, noHistory = noHistory).strip
            except EOFError:
              stdout.write "\n"
              die "aborted", ExitConfig
    if s != "": return s

proc readOptional*(editor: var minline.LineEditor, prompt: string,
                  hidden = false, noHistory = true): string =
  ## ctrl+c raises `minline.InputCancelled` to the caller; ctrl+d aborts
  ## the program. Empty input is returned as "".
  try: editor.readLine(prompt, hidechars = hidden, noHistory = noHistory).strip
  except EOFError:
    stdout.write "\n"
    die "aborted", ExitConfig

# ---------- Provider wizard ----------

proc printSupported() =
  var seen: seq[string]
  for combo in KnownGoodCombos:
    if combo[0] notin seen: seen.add combo[0]
  stdout.styledWriteLine styleDim, "  supported: ", seen.join(", "), resetStyle

proc readProviderEntry(editor: var minline.LineEditor): string =
  let prevCb = editor.completionCallback
  editor.completionCallback = proc(ed: LineEditor): seq[string] =
    if experimentalEnabled:
      for (n, _) in ProviderCatalog: result.add n
    else:
      for combo in KnownGoodCombos:
        if combo[0] notin result: result.add combo[0]
  let label =
    if experimentalEnabled: "  provider name or url : "
    else: "  provider name        : "
  result = readRequired(editor, label)
  editor.completionCallback = prevCb

proc promptNameAndUrl(editor: var minline.LineEditor): (string, string) =
  let entry = readProviderEntry(editor)
  var name, url: string
  if experimentalEnabled and
     (entry.startsWith("http://") or entry.startsWith("https://")):
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
    if experimentalEnabled:
      if cu != "":
        let urlEntry = readOptional(editor, &"  url [{cu}]     : ")
          .strip(chars = {'/', ' '})
        url = if urlEntry == "": cu else: urlEntry
      else:
        url = readRequired(editor, "  api base url         : ")
          .strip(chars = {'/', ' '})
    else:
      url = cu
  (name, url)

proc promptNewProvider*(editor: var minline.LineEditor): ProviderRec =
  printSupported()
  stdout.write "\n"
  var key = readRequired(editor, "  api key              : ", hidden = true)
  # same key already configured?
  for pr in activeProviders:
    if pr.key == key:
      hintLn &"  already configured as {pr.name}", resetStyle
      return pr
  var name, url: string
  var inferred = inferProvider(key)
  if not experimentalEnabled and inferred != "" and
     curatedFor(inferred)[1].len == 0:
    inferred = ""  # not in whitelist; fall through to manual entry
  if inferred != "":
    name = inferred
    url = catalogUrl(inferred)
    # same provider already exists? offer to update key instead
    for pr in activeProviders:
      if pr.name == name:
        hintLn "  detected: ", resetStyle, name, styleDim,
               " -> already configured, updating key", resetStyle
        return ProviderRec(name: pr.name, url: pr.url, key: key,
                           modelPrefix: pr.modelPrefix, models: pr.models)
    hintLn "  detected: ", resetStyle, name, styleDim, " -> ", url, resetStyle
  else:
    while true:
      let (n, u) = promptNameAndUrl(editor)
      if n == "":
        stdout.styledWriteLine fgMagenta, "  name required", resetStyle
        continue
      var clash = false
      for pr in activeProviders:
        if pr.name == n:
          clash = true
          break
      if clash:
        stdout.styledWriteLine fgMagenta, &"  name already used: {n}", resetStyle
        continue
      name = n
      url = u
      break
  if not experimentalEnabled:
    let (prefix, models) = curatedFor(name)
    for m in models:
      hintLn "    ", resetStyle, m
    if models.len == 0:
      # Provider not in known‑good list; give a clear hint.
      hintLn &"  provider {name} not known‑good; enable --experimental to use it", resetStyle
      raise newException(minline.InputCancelled, "")
    while true:
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
      stdout.styledWriteLine fgMagenta, "failed", resetStyle
      stdout.styledWriteLine fgMagenta, "  " & err, resetStyle
      let choice = readOptional(editor,
        "  [enter]=retry, k=re-enter key : ").toLowerAscii
      if choice == "k":
        key = readRequired(editor,
          "  api key              : ", hidden = true)
  hint "  fetching models...   ", resetStyle
  stdout.flushFile
  let available = fetchModels(url, key)
  let prefix = commonModelPrefix(available)
  let displayed = available
  if available.len == 0:
    hintLn "unavailable — enter manually", resetStyle
  else:
    let header =
      if prefix == "": &"{displayed.len} available"
      else: &"{displayed.len} available (prefix: {prefix})"
    hintLn header, resetStyle
    for m in displayed:
      let shown = if prefix != "" and m.startsWith(prefix): m[prefix.len .. ^1]
                  else: shortModel(m)
      hintLn "    ", resetStyle, shown
  let prevCb = editor.completionCallback
  editor.completionCallback = proc(ed: LineEditor): seq[string] =
    for m in displayed:
      if prefix != "" and m.startsWith(prefix): result.add m[prefix.len .. ^1]
      else: result.add shortModel(m)
  defer: editor.completionCallback = prevCb
  var prev = ""
  while true:
    let prompt =
      if prev == "": "  models (space-sep.)  : "
      else: &"  models [{prev}]  : "
    let entered = readOptional(editor, prompt)
    let raw = if entered == "": prev else: entered
    let models = splitModels(raw)
    let modelsStr = formatModels(models)
    if models.len == 0:
      stdout.styledWriteLine fgMagenta, "  need at least one model", resetStyle
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
    stdout.styledWriteLine fgMagenta, "failed", resetStyle
    stdout.styledWriteLine fgMagenta, "  " & err, resetStyle
    prev = modelsStr
    let choice = readOptional(editor,
      "  [enter]=retry models, k=re-enter key : ").toLowerAscii
    if choice == "k":
      key = readRequired(editor,
        "  api key              : ", hidden = true)

proc promptEditProvider*(editor: var minline.LineEditor,
                        existing: ProviderRec): ProviderRec =
  hintLn &"  editing '{existing.name}' (enter to keep, ctrl+c to abort)",
    resetStyle
  stdout.styledWriteLine styleDim,
    "  # tip: change name + url to point at a fine-tune deployment", resetStyle
  while true:
    let newName = readOptional(editor,
      &"  name [{existing.name}]  : ")
    let name = if newName == "": existing.name else: newName
    if name != existing.name:
      var clash = false
      for pr in activeProviders:
        if pr.name != existing.name and pr.name == name:
          clash = true
          break
      if clash:
        stdout.styledWriteLine fgMagenta,
          &"  name already used: {name}", resetStyle
        continue
    let newUrl = readOptional(editor,
      &"  url [{existing.url}]  : ").strip(chars = {'/', ' '})
    let url = if newUrl == "": existing.url else: newUrl
    let newKey = readOptional(editor,
      "  api key [keep existing] : ", hidden = true)
    let key = if newKey == "": existing.key else: newKey
    let modelsCurrent = formatModels(existing.models)
    let newModels = readOptional(editor,
      &"  models [{modelsCurrent}]  : ")
    let models =
      if newModels == "": existing.models
      else: splitModels(newModels)
    if models.len == 0:
      stdout.styledWriteLine fgMagenta, "  need at least one model", resetStyle
      continue
    let prefix = commonModelPrefix(models)
    let prof = Profile(name: name & "." & models[0], url: url,
                       key: key, modelPrefix: prefix, model: models[0])
    hint "  verifying... ", resetStyle
    stdout.flushFile
    let (ok, err) = verifyProfile(prof)
    if ok:
      stdout.styledWriteLine fgGreen, styleBright, "ok", resetStyle
      return ProviderRec(name: name, url: url, key: key,
                         modelPrefix: prefix, models: models)
    stdout.styledWriteLine fgMagenta, "failed", resetStyle
    stdout.styledWriteLine fgMagenta, "  " & err, resetStyle

proc bootstrapProvider*(editor: var minline.LineEditor): Profile =
  stdout.styledWriteLine fgMagenta, styleBright,
    "  no provider configured, let's add one. (ctrl+c or ctrl+d to quit)",
    resetStyle
  let prov = try: promptNewProvider(editor)
             except minline.InputCancelled:
               die "aborted", ExitConfig
  activeProviders.add prov
  activeCurrent = prov.name & "." & prov.models[0]
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  hintLn &"  saved to {configPath()}", resetStyle
  buildProfile(activeCurrent, activeProviders, "")

# ---------- Provider / model commands ----------

proc cmdProviderList(prof: Profile) =
  if activeProviders.len == 0:
    hintLn "  no providers", resetStyle
    return
  let curName = if prof.name == "": "" else: prof.name.split('.')[0]
  for pr in activeProviders:
    let current = pr.name == curName
    let mark = if current: "*" else: " "
    let tail = if current: &"  [{prof.model}]" else: ""
    if not experimentalEnabled and not hasKnownGoodModel(pr):
      stdout.styledWriteLine styleDim,
        "  ", mark, " ", pr.name, tail, resetStyle
    else:
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
    stdout.styledWriteLine fgMagenta, &"  unknown provider: {target}", resetStyle
    return
  if prov.models.len == 0:
    stdout.styledWriteLine fgMagenta,
      &"  provider {target} has no models", resetStyle
    return
  let newCurrent = prov.name & "." & prov.models[0]
  let candidate = buildProfile(newCurrent, activeProviders, "")
  activeCurrent = newCurrent
  prof = candidate
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  showProfile(prof)
  if not gateExperimental(candidate):
    explainExperimentalGate(candidate)

proc cmdProviderAdd(editor: var minline.LineEditor, prof: var Profile) =
  let prov = try: promptNewProvider(editor)
             except minline.InputCancelled:
               hintLn "  cancelled", resetStyle
               return
  activeProviders.add prov
  if activeCurrent == "":
    activeCurrent = prov.name & "." & prov.models[0]
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  if prof.name == "":
    prof = buildProfile(activeCurrent, activeProviders, "")
  hintLn &"  added {prov.name}", resetStyle
  showProfile(prof)

proc cmdProviderEdit(target: string, editor: var minline.LineEditor,
                     prof: var Profile) =
  var idx = -1
  for i, pr in activeProviders:
    if pr.name == target: idx = i; break
  if idx < 0:
    stdout.styledWriteLine fgMagenta, &"  unknown provider: {target}", resetStyle
    return
  let updated = try: promptEditProvider(editor, activeProviders[idx])
                except minline.InputCancelled:
                  hintLn "  cancelled", resetStyle
                  return
  activeProviders[idx] = updated
  let curName = if activeCurrent == "": "" else: activeCurrent.split('.')[0]
  if curName == target:
    let wantedModel = prof.model
    let model =
      if updated.findModel(wantedModel) >= 0: wantedModel
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
    stdout.styledWriteLine fgMagenta, &"  unknown provider: {target}", resetStyle
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
      stdout.styledWriteLine fgMagenta, "  usage: :provider add", resetStyle
    else:
      cmdProviderAdd(editor, prof)
  of "edit":
    if parts.len != 2:
      stdout.styledWriteLine fgMagenta,
        "  usage: :provider edit <name>", resetStyle
    else:
      cmdProviderEdit(parts[1], editor, prof)
  of "rm", "remove":
    if parts.len != 2:
      stdout.styledWriteLine fgMagenta,
        &"  usage: :provider {parts[0]} <name>", resetStyle
    else:
      cmdProviderRm(parts[1], prof)
  else:
    if parts.len != 1:
      stdout.styledWriteLine fgMagenta,
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
    let kg = knownGoodFamily(prov.name, prov.modelPrefix & m)
    if kg == "" and not experimentalEnabled:
      stdout.styledWriteLine styleDim, "  ", mark, " ", m, resetStyle
    else:
      let modeTag = if kg != "": "  (known-good)" else: ""
      hintLn "  ", mark, " ", resetStyle, m, styleDim, modeTag, resetStyle

proc cmdModelSelect(target: string, prof: var Profile) =
  let prov = currentProvider()
  if prov.name == "":
    stdout.styledWriteLine fgMagenta, "  no provider selected", resetStyle
    return
  if prov.findModel(target) < 0:
    stdout.styledWriteLine fgMagenta, &"  unknown model: {target}", resetStyle
    return
  let newCurrent = prov.name & "." & target
  let candidate = buildProfile(newCurrent, activeProviders, "")
  if not gateExperimental(candidate):
    explainExperimentalGate(candidate)
    return
  activeCurrent = newCurrent
  prof = candidate
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
    stdout.styledWriteLine fgMagenta,
      "  usage: :model [<name>]", resetStyle

proc nearestCommand(name: string): string =
  var bestDist = high(int)
  for c in CommandNames:
    let d = levenshtein(name.toLowerAscii, c.toLowerAscii)
    if d < bestDist:
      bestDist = d
      result = c
  if bestDist > 2: result = ""

# ---------- Session preamble + user-input prep ----------

proc loadAgentsMd(start: string): string =
  ## Walk from `start` up to the filesystem root. At each level, prefer
  ## 3CODE.md over AGENTS.md. If 3CODE.md is found, load it and stop
  ## (never mix both files). Otherwise collect AGENTS.md as before.
  var dir = absolutePath(start)
  while true:
    let candidate3 = dir / "3CODE.md"
    if fileExists(candidate3):
      try:
        let body = readFile(candidate3)
        result = "# " & candidate3 & "\n\n" & body
      except CatchableError: discard
      break
    let candidate = dir / "AGENTS.md"
    if fileExists(candidate):
      try:
        let body = readFile(candidate)
        if result.len > 0: result.add "\n\n"
        result.add "# " & candidate & "\n\n" & body
      except CatchableError: discard
    let parent = parentDir(dir)
    if parent == dir or parent == "": break
    dir = parent

proc shellCapture(cmd: string, timeoutS = 3): string =
  ## Run a short shell command via `sh -c` and return its stdout (trimmed).
  ## Empty on failure — used purely to gather context, so failures are silent.
  ## `cmd` must be a literal, never user-controlled input; no shell escaping
  ## is performed.
  let tmp = getTempDir() / ("3code_ctx_" & $getCurrentProcessId() & "_" & $epochTime().int64)
  createDir(tmp)
  let outPath = tmp / "out"
  let wrapped = &"timeout {timeoutS}s sh -c \"{cmd}\" >\"{outPath}\" 2>/dev/null"
  discard execShellCmd(wrapped)
  result =
    if fileExists(outPath): readFile(outPath).strip
    else: ""
  try: removeDir(tmp) except CatchableError: discard

proc sessionPreamble*(cwd: string): string =
  ## Build a one-shot context block to prepend to the first user message of
  ## a fresh session: cwd, git state, top-level listing, AGENTS.md content.
  var lines: seq[string]
  let displayCwd = collapseHome(cwd)
  lines.add "cwd: " & displayCwd
  let inGit = shellCapture("git rev-parse --is-inside-work-tree") == "true"
  if inGit:
    let branch = shellCapture("git rev-parse --abbrev-ref HEAD")
    let dirty = shellCapture("git status --porcelain | wc -l")
    var gitLine = "git: " & (if branch == "": "(detached)" else: branch)
    if dirty != "" and dirty != "0":
      gitLine.add ", " & dirty & " uncommitted"
    lines.add gitLine
    let recent = shellCapture("git log --oneline -3")
    if recent != "":
      lines.add "recent commits:"
      for l in recent.splitLines:
        let s = l.strip
        if s.len == 0: continue
        let trimmed = if s.len > 80: utf8ByteCut(s, 77) & "..." else: s
        lines.add "  " & trimmed
  let listing = shellCapture("ls -1 --color=never | head -30")
  if listing != "":
    let entries = listing.splitLines.filterIt(it.strip.len > 0)
    lines.add "files in cwd: " & entries.join(" ")
  let notes = loadAgentsMd(cwd)
  result = "<session_context>\n" & lines.join("\n") & "\n</session_context>"
  if notes.len > 0:
    result.add "\n\n<project_notes>\n" & notes & "\n</project_notes>"

proc inlineAtFiles*(msg: string): string =
  ## Find @path tokens (whitespace-delimited, must follow whitespace or start
  ## of input). For each that resolves to an existing regular file under cwd,
  ## append `\n\n=== {path} ===\n<content>` (capped) to the message. Leave the
  ## @token visible so the model sees the user's intent.
  result = msg
  var seen: seq[string]
  var i = 0
  while i < msg.len:
    let prevOk = i == 0 or msg[i-1] in {' ', '\t', '\n'}
    if prevOk and msg[i] == '@' and i + 1 < msg.len and msg[i+1] notin {' ', '\t', '\n', '@'}:
      var j = i + 1
      while j < msg.len and msg[j] notin {' ', '\t', '\n'}:
        inc j
      let raw = msg[i+1 ..< j]
      let path = resolvePath(raw)
      if path notin seen and fileExists(path):
        seen.add path
        const Cap = 64 * 1024
        let content =
          try:
            let s = readFile(path)
            if s.len > Cap: utf8ByteCut(s, Cap) & "\n... [truncated; file is " & $s.len & " bytes]"
            else: s
          except CatchableError as e:
            "[error reading file: " & e.msg & "]"
        result.add "\n\n=== " & raw & " ===\n" & content
      i = j
    else:
      inc i

proc isFirstUserMessage*(messages: JsonNode): bool =
  if messages == nil or messages.kind != JArray: return true
  for m in messages:
    if m.kind == JObject and m{"role"}.getStr == "user":
      return false
  true

proc buildUserMessage*(messages: JsonNode, raw: string): string =
  ## Apply @file inlining always; prepend the session preamble (cwd, git
  ## state, AGENTS.md, ls) only on the first user message of a session so
  ## resumed conversations don't re-inject stale context.
  let body = inlineAtFiles(raw)
  if isFirstUserMessage(messages):
    sessionPreamble(getCurrentDir()) & "\n\n" & body
  else:
    body

proc readInputStatus(editor: var minline.LineEditor, done: var bool): string =
  ## Status-bar mode: read input on the prompt row (H). Multi-line
  ## continuation (trailing `\`) loops back through the same row,
  ## accumulating logical lines. On submission, settles the previous
  ## turn's **token receipt** into the scroll region (right under the
  ## prior LLM response, before the new echoed prompt) and then echoes
  ## the typed prompt below it in dim. The receipt is deliberately
  ## *not* rendered while the user is still typing — that would put a
  ## record on screen whose data exactly matches the live token bar
  ## above it. By delaying until Enter, the redundant on-screen window
  ## collapses to the few milliseconds before the next spinner kicks
  ## the bar to fresh values.
  # Re-show the cursor (the streaming path hid it). It'll blink at
  # the prompt row for the duration of input, then be hidden again
  # when the next `callModel` starts.
  statusbar.showCursor()
  var lines: seq[string]
  var prefix = "❯ "
  while true:
    statusbar.moveCursorToPrompt()
    stdout.write "\x1b[2K\x1b[37m"
    let line = try: editor.readLine(prefix)
               except EOFError:
                 stdout.write "\x1b[0m"
                 done = true
                 break
               except minline.InputCancelled:
                 stdout.write "\x1b[0m"
                 statusbar.moveCursorToPrompt()
                 stdout.write "\x1b[2K"
                 stdout.styledWrite fgWhite, "❯ ", resetStyle
                 statusbar.parkInScroll()
                 return ""
    stdout.write "\x1b[0m"
    lines.add line
    var trailing = 0
    var i = line.len - 1
    while i >= 0 and line[i] == '\\':
      inc trailing; dec i
    if trailing mod 2 == 0: break
    lines[^1] = line[0 ..< line.len - 1]
    prefix = "  "
  # Reset the prompt row to a blank `❯ ` (cursor stays after the
  # prefix, but we'll park in the scroll region below before returning).
  statusbar.moveCursorToPrompt()
  stdout.write "\x1b[2K"
  stdout.styledWrite fgWhite, "❯ ", resetStyle
  if done or lines.len == 0:
    statusbar.parkInScroll()
    return ""
  let combined = lines.join("\n")
  if combined.strip == "":
    statusbar.parkInScroll()
    return ""
  # User has committed to a new turn. Settle the previous turn's
  # receipt now (so it lands in the scroll region right under the
  # prior LLM response, just above the echo we're about to write),
  # then echo the typed input in dim. We always emit one `\n` to
  # space the echo away from whatever's above; on turns that *did*
  # have a receipt to settle, add a second `\n` so the visible blank
  # row sits between the model's output (LLM + receipt) and the
  # next prompt. The very first prompt (no prior turn → nothing to
  # settle) skips the second `\n`, which is what saves one blank
  # below the welcome banner.
  let hadReceipt = api.pendingHint.active
  statusbar.parkInScroll()
  api.settlePendingHint()
  stdout.write "\n"
  if hadReceipt:
    stdout.write "\n"
  for idx, l in lines:
    let lp = if idx == 0: "❯ " else: "  "
    stdout.styledWrite fgWhite, styleDim, lp & l, resetStyle, "\n"
  stdout.flushFile
  combined

proc readInput*(editor: var minline.LineEditor, done: var bool): string =
  if statusbar.isActive():
    return readInputStatus(editor, done)
  stdout.write "\n"
  # Plain white while the user types; reset on every exit path so the
  # rest of the UI keeps its own colours. The LLM body uses fgWhite +
  # dim (off-white) so plain white reads brighter by contrast.
  stdout.write "\x1b[37m"
  var line = try: editor.readLine("❯ ")
             except EOFError:
               stdout.write "\x1b[0m"
               done = true; return ""
             except minline.InputCancelled:
               stdout.write "\x1b[0m"
               return ""
  stdout.write "\x1b[0m"
  navigatedUp = false
  # Trailing unescaped `\` continues to the next line, joined with `\n`.
  # Even count = literal trailing backslashes, no continuation.
  while true:
    var trailing = 0
    var i = line.len - 1
    while i >= 0 and line[i] == '\\':
      inc trailing
      dec i
    if trailing mod 2 == 0: break
    stdout.write "\x1b[37m"
    let cont = try: editor.readLine("  ")
               except EOFError:
                 stdout.write "\x1b[0m"
                 done = true; break
               except minline.InputCancelled:
                 stdout.write "\x1b[0m"
                 return ""
    stdout.write "\x1b[0m"
    line = line[0 ..< line.len - 1] & "\n" & cont
  if line.strip == "": return ""
  # Redraw the just-submitted prompt + body in dim so it recedes as
  # the assistant's reply scrolls below it. Cursor is currently one
  # row below the last input line; walk up N rows, rewrite each in
  # dim, and end where we started.
  let entered = line.splitLines
  let n = entered.len
  if n > 0:
    stdout.write "\x1b[" & $n & "A"
    var idx = 0
    for l in entered:
      let prefix = if idx == 0: "❯ " else: "  "
      stdout.write "\r\x1b[2K"
      stdout.styledWrite fgWhite, prefix & l, resetStyle, "\n"
      inc idx
    stdout.flushFile
  return line

# ---------- Command dispatcher ----------

proc handleCommand*(cmd: string, messages: var JsonNode, session: var Session,
                   prof: var Profile, editor: var minline.LineEditor): bool =
  ## returns true if the input was a recognised command
  let c = cmd.strip
  if c.len == 0 or c[0] != ':': return false
  let sp = c.find({' ', '\t'})
  let name = if sp < 0: c else: c[0 ..< sp]
  let arg = if sp < 0: "" else: c[sp+1 .. ^1].strip
  case name
  of ":help", ":?":
    stdout.styledWrite fgCyan, styleDim, HelpText, resetStyle
  of ":tokens":
    if session.usage.totalTokens == 0:
      hintLn "  no tokens used yet", resetStyle
    else:
      let fresh = max(0, session.usage.promptTokens - session.usage.cachedTokens)
      let line = tokenSlot("↑", fresh) &
        "  " & tokenSlot("↻", session.usage.cachedTokens) &
        "  " & tokenSlot("↓", session.usage.completionTokens) &
        "  total " & humanTokens(session.usage.totalTokens)
      stdout.styledWrite(styleDim, line, resetStyle, "\n")
  of ":clear":
    messages = %* [{"role": "system", "content": buildSystemPrompt(prof)}]
    session.toolLog.setLen 0
    session.usage = Usage()
    session.lastPromptTokens = 0
    if session.savePath != "":
      session.savePath = newSessionPath()
      session.created = $now()
      session.cwd = getCurrentDir()
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
    let showAll = arg.strip.toLowerAscii in ["all", "-a", "--all"]
    let paths =
      if showAll: listSessionPaths()
      else: listSessionPathsForCwd(getCurrentDir())
    if paths.len == 0:
      hintLn (if showAll: "  no saved sessions"
              else: "  no saved sessions for this directory  (try `:sessions all`)"),
        resetStyle
    else:
      printSessionList(paths, session.savePath, showAll)
  of ":compact":
    let n = compactHistory(messages)
    if n == 0:
      hintLn "  nothing to compact", resetStyle
    else:
      hintLn &"  · compacted {n} tool result" &
        (if n == 1: "" else: "s"), resetStyle
      saveSession(session, messages)
  of ":think":
    case arg.strip.toLowerAscii
    of "", "toggle":
      showThinking = not showThinking
    of "on", "show", "yes": showThinking = true
    of "off", "hide", "no": showThinking = false
    else:
      stdout.styledWriteLine fgMagenta, "  usage: :think [on|off]", resetStyle
      return true
    hintLn "  thinking ticker ", (if showThinking: "on" else: "off"), resetStyle
  of ":summarize":
    if prof.name == "":
      stdout.styledWriteLine fgMagenta,
        "  no provider configured. use :provider add", resetStyle
    else:
      hint "  · summarizing... ", resetStyle
      stdout.flushFile
      let n = summarizeHistory(messages, prof)
      if n == 0:
        stdout.styledWriteLine styleDim, "failed or not worth it", resetStyle
      else:
        stdout.styledWriteLine fgCyan, styleBright, "done", resetStyle
        hintLn &"  · collapsed {n} message" &
          (if n == 1: "" else: "s") &
          &" into a synthetic recap", resetStyle
        saveSession(session, messages)
  else:
    let suggestion = nearestCommand(name)
    if suggestion != "":
      stdout.styledWriteLine fgMagenta, "unknown command: ", c,
        fgCyan, styleBright, &"  did you mean {suggestion}?", resetStyle
    else:
      stdout.styledWriteLine fgMagenta, "unknown command: ", c, "  (try :help)", resetStyle
  return true
