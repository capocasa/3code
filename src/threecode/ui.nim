import std/[json, os, sequtils, strformat, strutils, terminal, times]
import types, util, prompts, session, config, api, compact, display, minline

const CommandNames* = [":help", ":tokens", ":clear", ":variant", ":provider",
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
  if words[0] == ":variant" and words.len == 2:
    let prov = currentProvider()
    for v in prov.variants:
      if experimentalEnabled or knownGoodModel(prov.name, prov.variantPrefix & v) != "":
        result.add v
    return

proc readRequired*(editor: var minline.LineEditor, prompt: string,
                  hidden = false, noHistory = true): string =
  while true:
    let s = try: editor.readLine(prompt, hidechars = hidden, noHistory = noHistory).strip
            except EOFError:
              stdout.write "\n"
              die "aborted", ExitConfig
            except minline.InputCancelled:
              continue
    if s != "": return s

proc readOptional*(editor: var minline.LineEditor, prompt: string,
                  hidden = false, noHistory = true): string =
  try: editor.readLine(prompt, hidechars = hidden, noHistory = noHistory).strip
  except EOFError:
    stdout.write "\n"
    die "aborted", ExitConfig
  except minline.InputCancelled: ""

# ---------- Provider wizard ----------

proc printSupported() =
  var seen: seq[string]
  for (p, _, _) in KnownGoodCombos:
    if p notin seen: seen.add p
  stdout.styledWriteLine styleDim, "  supported: ", seen.join(", "), resetStyle

proc readProviderEntry(editor: var minline.LineEditor): string =
  let prevCb = editor.completionCallback
  editor.completionCallback = proc(ed: LineEditor): seq[string] =
    if experimentalEnabled:
      for (n, _) in ProviderCatalog: result.add n
    else:
      for (p, _, _) in KnownGoodCombos:
        if p notin result: result.add p
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
                           variantPrefix: pr.variantPrefix, variants: pr.variants)
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
    let (prefix, variants) = curatedFor(name)
    for v in variants:
      hintLn "    ", resetStyle, v
    while true:
      let prov = ProviderRec(name: name, url: url, key: key,
                             variantPrefix: prefix, variants: variants)
      let prof = Profile(name: name & "." & variants[0], url: url,
                         key: key, variantPrefix: prefix, variant: variants[0])
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
  hint "  fetching variants... ", resetStyle
  stdout.flushFile
  let available = fetchVariants(url, key)
  let prefix = commonVariantPrefix(available)
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
                  else: m
      hintLn "    ", resetStyle, shown
  let prevCb = editor.completionCallback
  editor.completionCallback = proc(ed: LineEditor): seq[string] =
    for m in displayed:
      if prefix != "" and m.startsWith(prefix): result.add m[prefix.len .. ^1]
      else: result.add m
  defer: editor.completionCallback = prevCb
  var prev = ""
  while true:
    let prompt =
      if prev == "": "  variants (space-sep.) : "
      else: &"  variants [{prev}]  : "
    let entered = readOptional(editor, prompt)
    let raw = if entered == "": prev else: entered
    let variants = splitVariants(raw)
    let variantsStr = formatVariants(variants)
    if variants.len == 0:
      stdout.styledWriteLine fgMagenta, "  need at least one variant", resetStyle
      continue
    let prov = ProviderRec(name: name, url: url, key: key,
                           variantPrefix: prefix, variants: variants)
    let prof = Profile(name: name & "." & variants[0], url: url,
                       key: key, variantPrefix: prefix, variant: variants[0])
    hint "  verifying... ", resetStyle
    stdout.flushFile
    let (ok, err) = verifyProfile(prof)
    if ok:
      stdout.styledWriteLine fgGreen, styleBright, "ok", resetStyle
      return prov
    stdout.styledWriteLine fgMagenta, "failed", resetStyle
    stdout.styledWriteLine fgMagenta, "  " & err, resetStyle
    prev = variantsStr
    let choice = readOptional(editor,
      "  [enter]=retry variants, k=re-enter key : ").toLowerAscii
    if choice == "k":
      key = readRequired(editor,
        "  api key              : ", hidden = true)

proc promptEditProvider*(editor: var minline.LineEditor,
                        existing: ProviderRec): ProviderRec =
  hintLn &"  editing '{existing.name}' (enter to keep, ctrl+d to abort)",
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
    let variantsCurrent = formatVariants(existing.variants)
    let newVariants = readOptional(editor,
      &"  variants [{variantsCurrent}]  : ")
    let variants =
      if newVariants == "": existing.variants
      else: splitVariants(newVariants)
    if variants.len == 0:
      stdout.styledWriteLine fgMagenta, "  need at least one variant", resetStyle
      continue
    let prefix = commonVariantPrefix(variants)
    let prof = Profile(name: name & "." & variants[0], url: url,
                       key: key, variantPrefix: prefix, variant: variants[0])
    hint "  verifying... ", resetStyle
    stdout.flushFile
    let (ok, err) = verifyProfile(prof)
    if ok:
      stdout.styledWriteLine fgGreen, styleBright, "ok", resetStyle
      return ProviderRec(name: name, url: url, key: key,
                         variantPrefix: prefix, variants: variants)
    stdout.styledWriteLine fgMagenta, "failed", resetStyle
    stdout.styledWriteLine fgMagenta, "  " & err, resetStyle

proc bootstrapProvider*(editor: var minline.LineEditor): Profile =
  stdout.styledWriteLine fgMagenta, styleBright,
    "  no provider configured — let's add one. (ctrl+d to quit)", resetStyle
  let prov = promptNewProvider(editor)
  activeProviders.add prov
  activeCurrent = prov.name & "." & prov.variants[0]
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
    let tail = if current: &"  [{prof.variant}]" else: ""
    if not experimentalEnabled and not hasKnownGoodVariant(pr):
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
  if prov.variants.len == 0:
    stdout.styledWriteLine fgMagenta,
      &"  provider {target} has no models", resetStyle
    return
  let newCurrent = prov.name & "." & prov.variants[0]
  let candidate = buildProfile(newCurrent, activeProviders, "")
  activeCurrent = newCurrent
  prof = candidate
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  showProfile(prof)
  if not gateExperimental(candidate):
    explainExperimentalGate(candidate)

proc cmdProviderAdd(editor: var minline.LineEditor, prof: var Profile) =
  let prov = promptNewProvider(editor)
  activeProviders.add prov
  if activeCurrent == "":
    activeCurrent = prov.name & "." & prov.variants[0]
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
  let updated = promptEditProvider(editor, activeProviders[idx])
  activeProviders[idx] = updated
  let curName = if activeCurrent == "": "" else: activeCurrent.split('.')[0]
  if curName == target:
    let wantedVariant = prof.variant
    let variant =
      if updated.findVariant(wantedVariant) >= 0: wantedVariant
      else: updated.variants[0]
    activeCurrent = updated.name & "." & variant
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
      activeCurrent = np.name & "." & np.variants[0]
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

proc cmdVariantList(prof: Profile) =
  let prov = currentProvider()
  if prov.name == "":
    hintLn "  no provider selected", resetStyle
    return
  if prov.variants.len == 0:
    hintLn &"  {prov.name}: no variants", resetStyle
    return
  for v in prov.variants:
    let mark = if v == prof.variant: "*" else: " "
    let kg = knownGoodModel(prov.name, prov.variantPrefix & v)
    if kg == "" and not experimentalEnabled:
      stdout.styledWriteLine styleDim, "  ", mark, " ", v, resetStyle
    else:
      let modeTag = if kg != "": &"  ({kg}, known-good)" else: ""
      hintLn "  ", mark, " ", resetStyle, v, styleDim, modeTag, resetStyle

proc cmdVariantSelect(target: string, prof: var Profile) =
  let prov = currentProvider()
  if prov.name == "":
    stdout.styledWriteLine fgMagenta, "  no provider selected", resetStyle
    return
  if prov.findVariant(target) < 0:
    stdout.styledWriteLine fgMagenta, &"  unknown variant: {target}", resetStyle
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

proc cmdVariant(arg: string, prof: var Profile) =
  let parts = arg.splitWhitespace()
  case parts.len
  of 0:
    cmdVariantList(prof)
  of 1:
    cmdVariantSelect(parts[0], prof)
  else:
    stdout.styledWriteLine fgMagenta,
      "  usage: :variant [<name>]", resetStyle

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
  ## Walk from `start` up to the filesystem root. Concatenate every
  ## AGENTS.md found, child first (closest to cwd takes precedence in
  ## the model's reading order). Each file is preceded by its path so
  ## the model can attribute instructions.
  var dir = absolutePath(start)
  while true:
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
  if line.strip == "": return ""
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
    stdout.write HelpText
  of ":tokens":
    if session.usage.totalTokens == 0:
      hintLn "  no tokens used yet", resetStyle
    else:
      var msg = &"  session: {humanTokens(session.usage.totalTokens)}  (in {humanTokens(session.usage.promptTokens)}, out {humanTokens(session.usage.completionTokens)})"
      if session.usage.cachedTokens > 0:
        msg.add &", cache {humanTokens(session.usage.cachedTokens)}"
      hintLn msg, resetStyle
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
  of ":variant":
    cmdVariant(arg, prof)
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
