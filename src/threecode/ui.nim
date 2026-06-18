## REPL command dispatch and provider/model wizards.
##
## Handles all `:cmd` input that is not a prompt to the model. The command set
## is narrow by design: introspection (`:show`, `:log`, `:tokens`), context
## management (`:clear`, `:summarize`), provider/model switching
## (`:provider`, `:model`, `:reasoning`).
##
## Tab-completion in `tabComplete` walks `KnownGoodCombos` and the live
## provider list to offer only valid model names. The provider-add wizard in
## `runProviderAdd` validates the API key with a one-token probe before saving.

import std/[json, os, sequtils, strformat, strutils, tables, terminal, times]
import types, util, prompts, session, config, api, compact, display, minline,
  fatprompt

const CommandNames* = [":help", ":tokens", ":clear", ":model", ":provider",
                      ":reasoning", ":prompt", ":show", ":log", ":sessions",
                      ":summarize",
                      ":q", ":quit", ":exit"]

type WizardReadLineHook* = proc(prompt: string, hidden,
                                noHistory: bool): string {.closure.}

type
  CommandKind* = enum
    ckUnknown, ckSafeImmediate, ckMutating, ckModal, ckQuit
  CommandDisposition* = enum
    cdTranscriptResult, cdHarnessOnly, cdModal
  CommandResult* = object
    recognized*: bool
    ok*: bool
    name*: string
    body*: string
    plainBody*: bool
    clearFooter*: bool
    disposition*: CommandDisposition

var wizardReadLineHook*: WizardReadLineHook

proc handleCommandResult*(cmd: string, messages: var JsonNode,
                          session: var Session, prof: var Profile,
                          editor: var minline.LineEditor): CommandResult

proc classifyCommand*(cmd: string): CommandKind =
  let c = cmd.strip
  if c.len == 0 or c[0] != ':':
    return ckUnknown
  let sp = c.find({' ', '\t'})
  let name = if sp < 0: c else: c[0 ..< sp]
  let arg = if sp < 0: "" else: c[sp+1 .. ^1].strip
  let parts = arg.splitWhitespace()
  case name
  of ":help", ":?", ":tokens", ":show", ":log", ":sessions", ":prompt":
    ckSafeImmediate
  of ":provider":
    if parts.len == 0:
      ckSafeImmediate
    elif parts.len == 1 and parts[0] == "list":
      ckSafeImmediate
    elif parts.len >= 1 and parts[0] in ["add", "edit"]:
      ckModal
    else:
      ckMutating
  of ":model":
    if parts.len == 0 or (parts.len == 1 and parts[0] == "list"): ckSafeImmediate
    else: ckMutating
  of ":reasoning":
    if parts.len == 0 or (parts.len == 1 and parts[0] == "list"): ckSafeImmediate
    else: ckMutating
  of ":clear", ":summarize":
    ckMutating
  of ":quit", ":q", ":exit":
    ckQuit
  else:
    ckUnknown

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
    for m in orderedModels(prov):
      if experimentalEnabled or knownGoodFamily(prov.name, m) != "":
        result.add shortModel(m)
    return
  if words[0] == ":reasoning" and words.len == 2:
    for r in ReasoningLevels: result.add r
    return

proc readRequired*(editor: var minline.LineEditor, prompt: string,
                  hidden = false, noHistory = true): string =
  ## ctrl+c raises `minline.InputCancelled` to the caller; ctrl+d aborts
  ## the program. Empty input keeps re-prompting.
  while true:
    let s =
      if wizardReadLineHook != nil:
        wizardReadLineHook(prompt, hidden, noHistory).strip
      else:
        try: editor.readLine(prompt, hidechars = hidden,
                             noHistory = noHistory).strip
        except EOFError:
          stdout.write "\n"
          die "aborted", ExitConfig
    if s != "": return s

proc readOptional*(editor: var minline.LineEditor, prompt: string,
                  hidden = false, noHistory = true): string =
  ## ctrl+c raises `minline.InputCancelled` to the caller; ctrl+d aborts
  ## the program. Empty input is returned as "".
  if wizardReadLineHook != nil:
    return wizardReadLineHook(prompt, hidden, noHistory).strip
  try: editor.readLine(prompt, hidechars = hidden, noHistory = noHistory).strip
  except EOFError:
    stdout.write "\n"
    die "aborted", ExitConfig

# ---------- Provider wizard ----------

proc printSupported() =
  var seen: seq[string]
  for combo in KnownGoodCombos:
    if combo[0] notin seen: seen.add combo[0]
  subtleWriteLn(stdout, "  supported: " & seen.join(", "))

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
     curatedFor(inferred).len == 0:
    inferred = ""  # not in whitelist; fall through to manual entry
  if inferred != "":
    name = inferred
    url = catalogUrl(inferred)
    # same provider already exists? offer to update key instead
    for pr in activeProviders:
      if pr.name == name:
        hintLn "  detected: ", resetStyle, name, GreyFg,
               " -> already configured, updating key", Reset
        return ProviderRec(name: pr.name, url: pr.url, key: key,
                           models: pr.models)
    hintLn "  detected: ", resetStyle, name, GreyFg, " -> ", url, Reset
  else:
    while true:
      let (n, u) = promptNameAndUrl(editor)
      if n == "":
        errLn "  name required"
        continue
      var clash = false
      for pr in activeProviders:
        if pr.name == n:
          clash = true
          break
      if clash:
        errLn &"  name already used: {n}"
        continue
      name = n
      url = u
      break
  if not experimentalEnabled:
    let curated = curatedFor(name)
    for m in curated:
      hintLn "    ", resetStyle, shortModel(m)
    if curated.len == 0:
      # Provider not in known‑good list; give a clear hint.
      hintLn &"  provider {name} not known‑good; enable --experimental to use it", resetStyle
      raise newException(minline.InputCancelled, "")
    let lookup = shortToFull(curated)
    var prev = curated.mapIt(shortModel(it)).join(" ")
    let prevCb = editor.completionCallback
    editor.completionCallback = proc(ed: LineEditor): seq[string] =
      for m in curated: result.add shortModel(m)
    defer: editor.completionCallback = prevCb
    while true:
      let entered = readOptional(editor, &"  models [{prev}]  : ")
      let raw = if entered == "": prev else: entered
      let rawModels = splitModels(raw)
      var models: seq[string]
      var unknown: seq[string]
      for rm in rawModels:
        let resolved = lookup.getOrDefault(rm, rm)
        if resolved in curated:
          models.add resolved
        else:
          unknown.add rm
      if models.len == 0:
        errLn "  need at least one model"
      elif unknown.len > 0:
        errLn "  unknown known-good model: " & unknown.join(", ")
        prev = models.mapIt(shortModel(it)).join(" ")
      else:
        let prov = ProviderRec(name: name, url: url, key: key, models: models)
        let prof = Profile(name: name & "." & models[0], url: url,
                           key: key, model: models[0])
        hint "  verifying... ", resetStyle
        stdout.flushFile
        let (ok, err) = verifyProfile(prof)
        if ok:
          stdout.styledWriteLine fgGreen, styleBright, "ok", resetStyle
          return prov
        errLn "  failed: " & err
        prev = models.mapIt(shortModel(it)).join(" ")
      let choice = readOptional(editor,
        "  [enter]=retry models, k=re-enter key, c=cancel : ").toLowerAscii
      if choice == "k":
        key = readRequired(editor,
          "  api key              : ", hidden = true)
      elif choice == "c":
        # User wants to abort the provider addition
        raise newException(minline.InputCancelled, "cancelled by user")
  hint "  fetching models...   ", resetStyle
  stdout.flushFile
  let (available, fetchErr) = fetchModels(url, key)
  let lookup = shortToFull(available)
  if fetchErr.len > 0:
    errLn "unavailable — ", fetchErr
  elif available.len == 0:
    hintLn "unavailable — enter manually", resetStyle
  else:
    hintLn &"{available.len} available", resetStyle
    for m in available:
      hintLn "    ", resetStyle, shortModel(m)
  let prevCb = editor.completionCallback
  editor.completionCallback = proc(ed: LineEditor): seq[string] =
    for m in available: result.add shortModel(m)
  defer: editor.completionCallback = prevCb
  # Pre-populate with known-good models for this provider (KnownGoodCombos order).
  var knownGoodInit: seq[string]
  for combo in KnownGoodCombos:
    if combo[0].toLowerAscii == name.toLowerAscii:
      for avail in available:
        if avail == combo[1]:
          knownGoodInit.add shortModel(combo[1])
          break
  var prev = knownGoodInit.join(" ")
  while true:
    let prompt =
      if prev == "": "  models (space-sep.)  : "
      else: &"  models [{prev}]  : "
    let entered = readOptional(editor, prompt)
    let raw = if entered == "": prev else: entered
    let rawModels = splitModels(raw)
    # Resolve each entered name (short or full) to its full id using the
    # fetched list. If the user typed a short name, `lookup` resolves it;
    # if they typed a full id that was in the list, it passes through
    # unchanged; unknown names are kept as-is.
    var models: seq[string]
    for rm in rawModels:
      models.add lookup.getOrDefault(rm, rm)
    if models.len == 0:
      errLn "  need at least one model"
      continue
    let prov = ProviderRec(name: name, url: url, key: key, models: models)
    let prof = Profile(name: name & "." & models[0], url: url,
                       key: key, model: models[0])
    hint "  verifying... ", resetStyle
    stdout.flushFile
    let (ok, err) = verifyProfile(prof)
    if ok:
      stdout.styledWriteLine fgGreen, styleBright, "ok", resetStyle
      return prov
    errLn "  failed: " & err
    prev = models.mapIt(shortModel(it)).join(" ")
    let choice = readOptional(editor,
      "  [enter]=retry models, k=re-enter key, c=cancel : ").toLowerAscii
    if choice == "k":
      key = readRequired(editor,
        "  api key              : ", hidden = true)
    elif choice == "c":
      raise newException(minline.InputCancelled, "cancelled by user")

proc promptEditProvider*(editor: var minline.LineEditor,
                        existing: ProviderRec): ProviderRec =
  hintLn &"  editing '{existing.name}' (enter to keep, ctrl+c to abort)",
    resetStyle
  subtleWriteLn(stdout,
    "  # tip: change name + url to point at a fine-tune deployment")
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
        errLn &"  name already used: {name}"
        continue
    let newUrl = readOptional(editor,
      &"  url [{existing.url}]  : ").strip(chars = {'/', ' '})
    let url = if newUrl == "": existing.url else: newUrl
    let newKey = readOptional(editor,
      "  api key [keep existing] : ", hidden = true)
    let key = if newKey == "": existing.key else: newKey
    hint "  fetching models...   ", resetStyle
    stdout.flushFile
    let (available, fetchErr) = fetchModels(url, key)
    let prevCb = editor.completionCallback
    editor.completionCallback = proc(ed: LineEditor): seq[string] =
      available.mapIt(shortModel(it))
    defer: editor.completionCallback = prevCb
    if fetchErr.len > 0:
      errLn "  unavailable — ", fetchErr
    elif available.len == 0:
      hintLn "  unavailable — enter manually", resetStyle
    else:
      hintLn &"  {available.len} available", resetStyle
      for m in available:
        hintLn "    ", resetStyle, shortModel(m)
    let modelsCurrent = existing.models.mapIt(shortModel(it)).join(" ")
    let newModels = readOptional(editor,
      &"  models [{modelsCurrent}]  : ")
    let rawModels = if newModels == "": existing.models
                   else: splitModels(newModels)
    # Resolve short names against the fetched model list; unknown names
    # pass through as-is (full id entered by the user).
    let lookup = shortToFull(available)
    let models = rawModels.mapIt(lookup.getOrDefault(it, it))
    if models.len == 0:
      errLn "  need at least one model"
      continue
    let prof = Profile(name: name & "." & models[0], url: url,
                       key: key, model: models[0])
    hint "  verifying... ", resetStyle
    stdout.flushFile
    let (ok, err) = verifyProfile(prof)
    if ok:
      stdout.styledWriteLine fgGreen, styleBright, "ok", resetStyle
      return ProviderRec(name: name, url: url, key: key, models: models)
    errLn "  failed: " & err

proc bootstrapProvider*(editor: var minline.LineEditor): Profile =
  stdout.styledWriteLine fgMagenta, styleBright,
    "  no provider configured, let's add one. (ctrl+c or ctrl+d to quit)",
    resetStyle
  let prov = try: promptNewProvider(editor)
             except minline.InputCancelled:
               die "aborted", ExitConfig
  activeProviders.add prov
  activeCurrent = prov.name & "." & firstModel(prov)
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
    let tail = if current: &"  [{shortModel(prof.model)}]" else: ""
    if not experimentalEnabled and not hasKnownGoodModel(pr):
      subtleWriteLn(stdout,
        "  " & mark & " " & pr.name & tail)
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
    errLn &"  unknown provider: {target}"
    return
  if prov.models.len == 0:
    errLn &"  provider {target} has no models"
    return
  let newCurrent = prov.name & "." & firstModel(prov)
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
    activeCurrent = prov.name & "." & firstModel(prov)
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
    errLn &"  unknown provider: {target}"
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
      else: firstModel(updated)
    activeCurrent = updated.name & "." & model
    prof = buildProfile(activeCurrent, activeProviders, "")
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  hintLn &"  updated {target}", resetStyle

proc cmdProviderRm(target: string, prof: var Profile) =
  var idx = -1
  for i, pr in activeProviders:
    if pr.name == target: idx = i; break
  if idx < 0:
    errLn &"  unknown provider: {target}"
    return
  activeProviders.delete(idx)
  let curName = if activeCurrent == "": "" else: activeCurrent.split('.')[0]
  if curName == target:
    if activeProviders.len > 0:
      let np = activeProviders[0]
      activeCurrent = np.name & "." & firstModel(np)
      prof = buildProfile(activeCurrent, activeProviders, "")
    else:
      activeCurrent = ""
      prof = Profile()
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  hintLn &"  removed {target}", resetStyle

proc cmdProvider(arg: string, editor: var minline.LineEditor,
                 prof: var Profile) =
  let parts = arg.splitWhitespace()
  if parts.len == 0 or (parts.len == 1 and parts[0] == "list"):
    cmdProviderList(prof)
    return
  case parts[0]
  of "add":
    if parts.len != 1:
      errLn "  usage: :provider add"
    else:
      cmdProviderAdd(editor, prof)
  of "edit":
    if parts.len != 2:
      errLn "  usage: :provider edit <name>"
    else:
      cmdProviderEdit(parts[1], editor, prof)
  of "rm", "remove":
    if parts.len != 2:
      errLn &"  usage: :provider {parts[0]} <name>"
    else:
      cmdProviderRm(parts[1], prof)
  else:
    if parts.len != 1:
      errLn "  usage: :provider [<name> | add | rm <name>]"
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
  for m in orderedModels(prov):
    let mark = if m == prof.model: "*" else: " "
    let short = shortModel(m)
    let kg = knownGoodFamily(prov.name, m)
    if kg == "" and not experimentalEnabled:
      subtleWriteLn(stdout, "  " & mark & " " & short)
    else:
      let kgSuffix = if experimentalEnabled and kg != "": "*" else: ""
      hintLn "  ", mark, " ", resetStyle, short & kgSuffix, resetStyle

proc cmdModelSelect(target: string, prof: var Profile) =
  let prov = currentProvider()
  if prov.name == "":
    errLn "  no provider selected"
    return
  let idx = prov.findModel(target)
  if idx < 0:
    errLn &"  unknown model: {target}"
    return
  let fullModel = prov.models[idx]
  let newCurrent = prov.name & "." & fullModel
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
    if parts[0] == "list":
      cmdModelList(prof)
    else:
      cmdModelSelect(parts[0], prof)
  else:
    errLn "  usage: :model [<name>]"

proc cmdReasoningList(prof: Profile) =
  let prov = providerForProfile(prof)
  if prov.name == "":
    hintLn "  no provider selected", resetStyle
    return
  let levels = availableReasonings(prov, prof.family, prof.model)
  if levels.len == 0:
    hintLn &"  {prof.family}: no reasoning knob", resetStyle
    return
  for r in levels:
    let mark = if r == prof.reasoning: "*" else: " "
    hintLn "  ", mark, " ", resetStyle, r

proc cmdReasoningSelect(target: string, prof: var Profile) =
  let prov = providerForProfile(prof)
  if prov.name == "":
    errLn "  no provider selected"
    return
  let value = target.toLowerAscii
  let levels = availableReasonings(prov, prof.family, prof.model)
  if value notin levels:
    errLn &"  unknown reasoning level: {target} (choose from {levels.join(\" \")})"
    return
  prof.reasoning = value
  for i, pr in activeProviders:
    if pr.name == prov.name:
      activeProviders[i].reasoning = value
      break
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  showProfile(prof)

proc cmdReasoning(arg: string, prof: var Profile) =
  let parts = arg.splitWhitespace()
  case parts.len
  of 0:
    cmdReasoningList(prof)
  of 1:
    if parts[0] == "list":
      cmdReasoningList(prof)
    else:
      cmdReasoningSelect(parts[0], prof)
  else:
    errLn "  usage: :reasoning [<level>]"

proc nearestCommand(name: string): string =
  var bestDist = high(int)
  for c in CommandNames:
    let d = levenshtein(name.toLowerAscii, c.toLowerAscii)
    if d < bestDist:
      bestDist = d
      result = c
  if bestDist > 2: result = ""

proc commandTitle(name, arg: string; ok: bool): string =
  if not ok and name notin CommandNames:
    return "command"
  case name
  of ":?":
    "help"
  of ":provider":
    let parts = arg.splitWhitespace()
    if parts.len == 0:
      "providers"
    elif parts[0] in ["add", "edit", "rm", "remove"]:
      "provider " & (if parts[0] == "remove": "rm" else: parts[0])
    else:
      "profile"
  of ":model":
    if arg.len == 0: "models" else: "profile"
  of ":reasoning":
    if arg.len == 0: "reasoning" else: "profile"
  else:
    name.strip(chars = {':'})

# ---------- Session preamble + user-input prep ----------

proc loadAgentsMd(start: string): string =
  ## Walk from `start` up to the filesystem root. At each level, prefer
  ## 3CODE.md over AGENTS.md. If 3CODE.md is found, load it and stop
  ## (never mix both files). Otherwise collect AGENTS.md as before.
  var dir = resolvePath(start)
  while true:
    let candidate3 = dir / "3CODE.md"
    if fileExists(candidate3):
      try:
        let body = readFile(candidate3)
        if not isBinaryContent(body):
          result = "# " & candidate3 & "\n\n" & body
      except CatchableError: discard
      break
    let candidate = dir / "AGENTS.md"
    if fileExists(candidate):
      try:
        let body = readFile(candidate)
        if not isBinaryContent(body):
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
            if isBinaryContent(s): "[binary file: " & raw & " — skipped]"
            elif s.len > Cap: utf8ByteCut(s, Cap) & "\n... [truncated; file is " & $s.len & " bytes]"
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
    sessionPreamble(safeCwd()) & "\n\n" & body
  else:
    body

proc readInput*(editor: var minline.LineEditor, done: var bool): string =
  ## Read a line submitted by the persistent input thread. The same
  ## ``minline.readLineWith`` path owns idle prompt input and active-turn
  ## buffered input; the controller only consumes completed lines here.
  ensureInputThreadStarted()
  while true:
    if not inputThreadRunning and inputEditor != nil:
      ensureInputThreadStarted()
    var line = ""
    var echoRows = 0
    var cmdWasQuit = false
    if consumeQueuedInput(line, echoRows, cmdWasQuit):
      navigatedUp = false
      editor.echoRows = echoRows
      if line.strip == "":
        resetPromptInputAfterEmpty(editor.echoRows)
        return ""
      return line
    if cmdWasQuit:
      done = true
      return ""
    sleep 5

# ---------- Command dispatcher ----------

proc handleCommand*(cmd: string, messages: var JsonNode, session: var Session,
                   prof: var Profile, editor: var minline.LineEditor): bool =
  ## returns true if the input was a recognised command
  let res = handleCommandResult(cmd, messages, session, prof, editor)
  if not res.recognized:
    return false
  if res.body.len > 0:
    stdout.write res.body
    stdout.flushFile
  true

proc handleCommandResult*(cmd: string, messages: var JsonNode,
                          session: var Session, prof: var Profile,
                          editor: var minline.LineEditor): CommandResult =
  ## Execute a REPL command and return its terminal body instead of writing
  ## directly to scrollback. Command internals still use the legacy display
  ## helpers; their stdout is captured here so the outer controller can commit
  ## one high-level transcript item.
  let c = cmd.strip
  if c.len == 0 or c[0] != ':':
    return CommandResult(recognized: false)
  let sp = c.find({' ', '\t'})
  let name = if sp < 0: c else: c[0 ..< sp]
  let arg = if sp < 0: "" else: c[sp+1 .. ^1].strip
  let kind = classifyCommand(c)
  if kind == ckModal:
    stdout.write "\r\n"
    stdout.flushFile
    let savedOnSubmit = editor.onSubmit
    let savedPreRedraw = editor.preRedraw
    let savedPostRedraw = editor.postRedraw
    let savedDeferSubmit = editor.deferSubmit
    let savedSubmitIcon = editor.submitIcon
    let savedRenderSuffix = editor.renderSuffix
    let savedRenderSuffixCursor = editor.renderSuffixCursor
    editor.onSubmit = nil
    editor.preRedraw = nil
    editor.postRedraw = nil
    editor.deferSubmit = false
    editor.submitIcon = ""
    editor.renderSuffix = ""
    editor.renderSuffixCursor = false
    defer:
      editor.onSubmit = savedOnSubmit
      editor.preRedraw = savedPreRedraw
      editor.postRedraw = savedPostRedraw
      editor.deferSubmit = savedDeferSubmit
      editor.submitIcon = savedSubmitIcon
      editor.renderSuffix = savedRenderSuffix
      editor.renderSuffixCursor = savedRenderSuffixCursor
    case name
    of ":provider":
      cmdProvider(arg, editor, prof)
      session.profileName = prof.name
    else:
      discard
    return CommandResult(recognized: true, ok: true,
                         name: commandTitle(name, arg, true),
                         disposition: cdModal)
  var ok = true
  let body = captureStdoutWrites:
    case name
    of ":help", ":?":
      renderHelp()
    of ":tokens":
      if session.usage.totalTokens == 0:
        cmdResponse "no tokens used yet"
      else:
        let fresh = max(0, session.usage.promptTokens - session.usage.cachedTokens)
        let line = tokenSlot("↑", fresh) &
          "  " & tokenSlot("↻", session.usage.cachedTokens) &
          "  " & tokenSlot("↓", session.usage.completionTokens) &
          "  total " & humanTokens(session.usage.totalTokens)
        cmdResponse line
    of ":clear":
      messages = %* [{"role": "system", "content": buildSystemPrompt(prof)}]
      session.toolLog.setLen 0
      session.usage = Usage()
      session.lastPromptTokens = 0
      session.readCache = nil
      session.plan.setLen 0
      emitFatPromptEvent clearPendingHintEvent()
      emitFatPromptEvent clearBarEvent()
      if session.savePath != "":
        releaseSessionLock(session.savePath)
        session.savePath = newSessionPath()
        session.created = $now()
        session.cwd = safeCwd()
        acquireSessionLock(session.savePath)
      cmdResponse "════════════════════════════════════════"
    of ":model":
      cmdModel(arg, prof)
      session.profileName = prof.name
    of ":provider":
      cmdProvider(arg, editor, prof)
      session.profileName = prof.name
    of ":reasoning":
      cmdReasoning(arg, prof)
    of ":prompt":
      cmdResponse buildSystemPrompt(prof)
    of ":show":
      showTool(arg, session.toolLog)
    of ":log":
      listTools(session.toolLog)
    of ":sessions":
      let showAll = arg.strip.toLowerAscii in ["all", "-a", "--all"]
      let paths =
        if showAll: listSessionPaths()
        else: listSessionPathsForCwd(safeCwd())
      if paths.len == 0:
        cmdResponse (if showAll: "no saved sessions"
                     else: "no saved sessions for this directory  (try `:sessions all`)")
      else:
        printSessionList(paths, session.savePath, showAll)
    of ":summarize":
      if prof.name == "":
        ok = false
        cmdError "no provider configured. use :provider add"
      else:
        let n = summarizeHistory(messages, prof)
        if n == 0:
          ok = false
          cmdResponse "failed or not worth it"
        else:
          cmdResponse &"collapsed {n} message" &
            (if n == 1: "" else: "s") &
            " into a synthetic recap"
          saveSession(session, messages)
    else:
      ok = false
      let suggestion = nearestCommand(name)
      if suggestion != "":
        cmdError "unknown command: " & c & "  did you mean " & suggestion & "?"
      else:
        cmdError "unknown command: " & c & "  (try :help)"
  let title = commandTitle(name, arg, ok)
  let disposition =
    case kind
    of ckSafeImmediate: cdHarnessOnly
    of ckModal: cdModal
    else: cdTranscriptResult
  CommandResult(recognized: true, ok: ok, name: title,
                body: body,
                plainBody: ok and (title == "profile" or title == "clear"),
                clearFooter: ok and title == "profile",
                disposition: disposition)
