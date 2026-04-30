import std/[json, os, sequtils, strformat, strutils, terminal, times]
import types, util, prompts, session, config, api, compact, display, minline

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
  # Pre-populate with known-good models for this provider (KnownGoodCombos order),
  # shown in the same short form the completion callback uses.
  var knownGoodInit: seq[string]
  for combo in KnownGoodCombos:
    if combo[0].toLowerAscii == name.toLowerAscii:
      for avail in available:
        if avail == combo[1]:
          let shown = if prefix != "" and combo[1].startsWith(prefix):
                        combo[1][prefix.len .. ^1]
                      else: shortModel(combo[1])
          knownGoodInit.add shown
          break
  var prev = knownGoodInit.join(" ")
  while true:
    let prompt =
      if prev == "": "  models (space-sep.)  : "
      else: &"  models [{prev}]  : "
    let entered = readOptional(editor, prompt)
    let raw = if entered == "": prev else: entered
    let rawModels = splitModels(raw)
    # When prefix is empty, the wizard displays short model names (e.g.
    # "gpt-oss-120b") but the API requires the full path prefix
    # ("openai/gpt-oss-120b"). Resolve each entered name against the
    # fetched list so the stored model IDs are always wire-correct.
    var models: seq[string]
    for rm in rawModels:
      if prefix != "":
        models.add rm
      else:
        var full = rm
        for avail in available:
          if (avail == rm or shortModel(avail) == rm) and "/" in avail:
            full = avail  # path-prefixed form wins (e.g. openai/gpt-oss-120b)
            break
          elif (avail == rm or shortModel(avail) == rm) and full == rm:
            full = avail  # bare form as fallback
        models.add full
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
    # Show short names in the retry default even when full IDs are stored.
    var retryShorts: seq[string]
    for m in models:
      retryShorts.add if prefix == "": shortModel(m) else: m
    prev = retryShorts.join(" ")
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
      let kgSuffix = if experimentalEnabled and kg != "": "*" else: ""
      hintLn "  ", mark, " ", resetStyle, m & kgSuffix, resetStyle

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

proc readInput*(editor: var minline.LineEditor, done: var bool): string =
  ## Read a line of user input. Entry contract: bar+prompt are visible
  ## at the current bottom of the cursor's content (bar at row K,
  ## prompt at row K+1, cursor at K col 0). Walks down to the prompt
  ## row, clears it (so minline's prompt overwrites the static dim
  ## `❯ `), reads input. After Enter the cursor is wherever minline
  ## left it; we don't try to clean up — `emitUserSubmit` will walk
  ## back to the bar row using `splitLines(line).len + 1` and
  ## clear-to-end-of-screen from there, repainting the receipt over
  ## the old bar row.
  #
  # Move from bar row down to prompt row + clear (so the bright cyan
  # `❯ ` minline draws lands on a clean row, replacing the dim glyph).
  stdout.write "\n\r\x1b[2K"
  var line = try: editor.readLine("❯ ")
             except EOFError:
               done = true; return ""
             except minline.InputCancelled:
               return ""
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
    let cont = try: editor.readLine("  ")
               except EOFError:
                 done = true; break
               except minline.InputCancelled:
                 return ""
    line = line[0 ..< line.len - 1] & "\n" & cont
  if line.strip == "":
    # Empty input: walk back to bar row and repaint bar+prompt so
    # they stay glued to the cursor's bottom (otherwise each empty
    # Enter would push the prompt one row lower than the bar).
    let n = max(1, line.splitLines.len)
    stdout.write "\x1b[" & $(n + 1) & "A\r\x1b[J"
    repaintBarPrompt(BrightPromptColor)
    return ""
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
