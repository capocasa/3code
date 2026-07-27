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

import std/[algorithm, atomics, json, os, sequtils, strformat, strutils, tables, terminal, times]
import types, util, prompts, session, config, api, compact, display, minline,
  fatprompt, streamexec, sandbox, engine as termengine

const CommandNames* = [":help", ":tokens", ":clear", ":model", ":provider",
                      ":reasoning", ":streaming", ":notify", ":prompt", ":show",
                      ":log", ":sessions", ":summarize", ":version", ":sandbox",
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
  of ":help", ":?", ":tokens", ":show", ":log", ":sessions", ":prompt", ":version":
    ckSafeImmediate
  of ":streaming", ":notify":
    if parts.len == 0 or (parts.len == 1 and parts[0] == "list"): ckSafeImmediate
    else: ckMutating
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
  of ":sandbox":
    # `:sandbox` and `:sandbox show` are safe; the allow/deny/readonly
    # verbs append to the sandbox file and reload, so they mutate.
    if parts.len == 0 or (parts.len == 1 and parts[0] == "show"): ckSafeImmediate
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
    if not experimentalEnabled:
      for r in ReasoningLevels: result.add r
    return
  if words[0] == ":streaming" and words.len == 2:
    result.add "on"
    result.add "off"
    return
  if words[0] == ":notify" and words.len == 2:
    result.add "on"
    result.add "off"
    return
  if words[0] == ":sandbox" and words.len == 2:
    result.add "show"
    result.add "allow"
    result.add "readonly"
    result.add "deny"
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
        try: wizardReadLine(editor, prompt, hidechars = hidden,
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
  try: wizardReadLine(editor, prompt, hidechars = hidden, noHistory = noHistory).strip
  except EOFError:
    stdout.write "\n"
    die "aborted", ExitConfig

# ---------- Provider wizard ----------

proc verifyAndReport(name, url, key: string; models: seq[string]): bool =
  ## Verify the first model of the candidate provider and paint the
  ## `verifying... ok/failed` status. Returns true when the provider
  ## verified.
  let prof = Profile(name: name & "." & models[0], url: url,
                     key: key, model: models[0])
  hint "  verifying... ", resetStyle
  stdout.flushFile
  let (ok, err) = verifyProfile(prof)
  if ok:
    stdout.styledWriteLine fgGreen, styleBright, "ok", resetStyle
    return true
  errLn "failed: " & err
  false

proc printSupported() =
  var seen: seq[string]
  for combo in KnownGoodCombos:
    if combo.provider notin seen: seen.add combo.provider
  subtleWriteLn(stdout, "  supported: " & seen.join(", "))

proc readProviderEntry(editor: var minline.LineEditor): string =
  let prevCb = editor.completionCallback
  editor.completionCallback = proc(ed: LineEditor): seq[string] =
    if experimentalEnabled:
      for (n, _) in ProviderCatalog: result.add n
    else:
      for combo in KnownGoodCombos:
        if combo.provider notin result: result.add combo.provider
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
  # API keys are not unique: the same key may legitimately back several
  # providers (e.g. an aggregator offering the same model under different
  # names, or separate provider entries for different model sets). So a
  # matching key is never a blocker; only a duplicate *name* is.
  var name, url: string
  var inferred = inferProvider(key)
  if not experimentalEnabled and inferred != "" and
     curatedFor(inferred).len == 0:
    inferred = ""  # not in whitelist; fall through to manual entry
  if inferred == "":
    while true:
      let (n, u) = promptNameAndUrl(editor)
      if n == "":
        errLn "name required"
        continue
      for pr in activeProviders:
        if pr.name == n:
          errLn &"already configured as {n}"
          raise newException(minline.InputCancelled, "duplicate name")
      name = n
      url = u
      break
  else:
    name = inferred
    url = catalogUrl(inferred)
    # duplicate name? abort the add — a key alone is fine, but two
    # providers can't share a name (it's the config selector).
    for pr in activeProviders:
      if pr.name == name:
        errLn &"already configured as {name}"
        raise newException(minline.InputCancelled, "duplicate name")
    hintLn "  detected: ", resetStyle, name, GreyFg, " -> ", url, Reset
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
        errLn "need at least one model"
      elif unknown.len > 0:
        errLn "unknown known-good model: " & unknown.join(", ")
        prev = models.mapIt(shortModel(it)).join(" ")
      elif verifyAndReport(name, url, key, models):
        return ProviderRec(name: name, url: url, key: key, models: models)
      else:
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
  let sortedAvailable = available.sorted
  let lookup = shortToFull(sortedAvailable)
  if fetchErr.len > 0:
    errLn "unavailable — ", fetchErr
  elif sortedAvailable.len == 0:
    hintLn "unavailable — enter manually", resetStyle
  else:
    hintLn &"{sortedAvailable.len} available", resetStyle
    for m in sortedAvailable:
      hintLn "    ", resetStyle, shortModel(m)
  let prevCb = editor.completionCallback
  editor.completionCallback = proc(ed: LineEditor): seq[string] =
    for m in sortedAvailable: result.add shortModel(m)
  defer: editor.completionCallback = prevCb
  # Pre-populate with known-good models for this provider (KnownGoodCombos order).
  var knownGoodInit: seq[string]
  for combo in KnownGoodCombos:
    if combo.provider.toLowerAscii == name.toLowerAscii:
      for avail in sortedAvailable:
        if avail == combo.model:
          knownGoodInit.add shortModel(combo.model)
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
      errLn "need at least one model"
      continue
    if verifyAndReport(name, url, key, models):
      return ProviderRec(name: name, url: url, key: key, models: models)
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
  hintLn &"  editing '{existing.name}' (enter to keep; ctrl+c/esc clears line, empty line aborts)",
    resetStyle
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
        errLn &"name already used: {name}"
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
    let sortedAvailable = available.sorted
    let prevCb = editor.completionCallback
    editor.completionCallback = proc(ed: LineEditor): seq[string] =
      sortedAvailable.mapIt(shortModel(it))
    defer: editor.completionCallback = prevCb
    if fetchErr.len > 0:
      errLn "unavailable — ", fetchErr
    elif sortedAvailable.len == 0:
      hintLn "  unavailable — enter manually", resetStyle
    else:
      hintLn &"  {sortedAvailable.len} available", resetStyle
      for m in sortedAvailable:
        hintLn "    ", resetStyle, shortModel(m)
    let modelsCurrent = existing.models.mapIt(shortModel(it)).join(" ")
    let newModels = readOptional(editor,
      &"  models [{modelsCurrent}]  : ")
    let rawModels = if newModels == "": existing.models
                   else: splitModels(newModels)
    # Resolve short names against the fetched model list; unknown names
    # pass through as-is (full id entered by the user).
    let lookup = shortToFull(sortedAvailable)
    let models = rawModels.mapIt(lookup.getOrDefault(it, it))
    if models.len == 0:
      errLn "need at least one model"
      continue
    if verifyAndReport(name, url, key, models):
      return ProviderRec(name: name, url: url, key: key, models: models)

proc bootstrapProvider*(editor: var minline.LineEditor): Profile =
  stdout.styledWriteLine fgMagenta,
    "no provider configured, let's add one. (ctrl+c to abort; esc clears line)",
    resetStyle
  let prov = try: promptNewProvider(editor)
             except minline.InputCancelled:
               die "aborted", ExitConfig
  activeProviders.add prov
  activeCurrent = prov.name & "." & firstModel(prov)
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  hintLn &"  saved to {configPath()}", resetStyle
  # The wizard's last `wizardReadLine` left `inputModalActive` held so
  # the input thread could not race these post-writes; release it now that
  # the config write and the "saved to" line have flushed, matching the
  # `wizardFinish` the main loop calls after a `:provider` cdModal command.
  wizardFinish()
  buildProfile(activeCurrent, activeProviders, "")

# ---------- Provider / model commands ----------

proc cmdProviderList(prof: Profile): string =
  if activeProviders.len == 0:
    return hintLnS("no providers")
  let curName = if prof.name == "": "" else: prof.name.split('.')[0]
  for pr in activeProviders:
    let current = pr.name == curName
    let tail = if current: &"  [{shortModel(prof.model)}]" else: ""
    if not experimentalEnabled and not hasKnownGoodModel(pr):
      result.add GreyFg & pr.name & tail & Reset & "\r\n"
    else:
      result.add hintLnS(pr.name & tail)

proc cmdProviderSelect(target: string, prof: var Profile): string =
  var prov: ProviderRec
  var found = false
  for pr in activeProviders:
    if pr.name == target:
      prov = pr
      found = true
      break
  if not found:
    return errLnS(&"unknown provider: {target}")
  if prov.models.len == 0:
    return errLnS(&"provider {target} has no models")
  let newCurrent = prov.name & "." & firstModel(prov)
  let candidate = buildProfile(newCurrent, activeProviders, "")
  activeCurrent = newCurrent
  prof = candidate
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  result = profileLinesS(prof)
  if not gateExperimental(candidate):
    result.add errLnS(experimentalGateText(candidate))

proc cmdProviderAdd(editor: var minline.LineEditor, prof: var Profile): string =
  # Cancel propagates from `wizardReadLine` through `promptNewProvider`
  # back to `handleCommandResult`, which turns it into an empty
  # `cdModal` return. No message, no state change — the prompt is
  # repainted by the input thread's cancel handler before we get
  # here.
  let prov = promptNewProvider(editor)
  activeProviders.add prov
  if activeCurrent == "":
    activeCurrent = prov.name & "." & firstModel(prov)
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  if prof.name == "":
    prof = buildProfile(activeCurrent, activeProviders, "")
  hintLnS(&"added {prov.name}") & profileLinesS(prof)

proc cmdProviderEdit(target: string, editor: var minline.LineEditor,
                     prof: var Profile): string =
  var idx = -1
  for i, pr in activeProviders:
    if pr.name == target: idx = i; break
  if idx < 0:
    return errLnS(&"unknown provider: {target}")
  let updated = promptEditProvider(editor, activeProviders[idx])
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
  hintLnS(&"updated {target}")

proc cmdProviderRm(target: string, prof: var Profile): string =
  var idx = -1
  for i, pr in activeProviders:
    if pr.name == target: idx = i; break
  if idx < 0:
    return errLnS(&"unknown provider: {target}")
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
  hintLnS(&"removed {target}")

proc cmdProvider(arg: string, editor: var minline.LineEditor,
                 prof: var Profile): string =
  let parts = arg.splitWhitespace()
  if parts.len == 0 or (parts.len == 1 and parts[0] == "list"):
    return cmdProviderList(prof)
  case parts[0]
  of "add":
    if parts.len != 1:
      return errLnS("usage: :provider add")
    cmdProviderAdd(editor, prof)
  of "edit":
    if parts.len != 2:
      return errLnS("usage: :provider edit <name>")
    cmdProviderEdit(parts[1], editor, prof)
  of "rm", "remove":
    if parts.len != 2:
      return errLnS(&"usage: :provider {parts[0]} <name>")
    cmdProviderRm(parts[1], prof)
  else:
    if parts.len != 1:
      return errLnS("usage: :provider [<name> | add | rm <name>]")
    cmdProviderSelect(parts[0], prof)

proc cmdModelList(prof: Profile): string =
  let prov = currentProvider()
  if prov.name == "":
    return hintLnS("no provider selected")
  if prov.models.len == 0:
    return hintLnS(&"{prov.name}: no models")
  for m in orderedModels(prov):
    let short = shortModel(m)
    let kg = knownGoodFamily(prov.name, m)
    if kg == "" and not experimentalEnabled:
      result.add GreyFg & short & Reset & "\r\n"
    else:
      let kgSuffix = if experimentalEnabled and kg != "": "*" else: ""
      result.add hintLnS(short & kgSuffix)

proc cmdModelSelect(target: string, prof: var Profile): string =
  let prov = currentProvider()
  if prov.name == "":
    return errLnS("no provider selected")
  let idx = prov.findModel(target)
  if idx < 0:
    return errLnS(&"unknown model: {target}")
  let fullModel = prov.models[idx]
  let newCurrent = prov.name & "." & fullModel
  let candidate = buildProfile(newCurrent, activeProviders, "")
  if not gateExperimental(candidate):
    return errLnS(experimentalGateText(candidate))
  activeCurrent = newCurrent
  prof = candidate
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  profileLinesS(prof)

proc cmdModel(arg: string, prof: var Profile): string =
  let parts = arg.splitWhitespace()
  case parts.len
  of 0:
    return cmdModelList(prof)
  of 1:
    if parts[0] == "list":
      return cmdModelList(prof)
    return cmdModelSelect(parts[0], prof)
  else:
    return errLnS("usage: :model [<name>]")

proc cmdReasoningList(prof: Profile): string =
  let prov = providerForProfile(prof)
  if prov.name == "":
    return hintLnS("no provider selected")
  if experimentalEnabled:
    let cur = if prof.reasoning == "": "(none)" else: prof.reasoning
    result.add hintLnS("reasoning: " & cur)
    result.add hintLnS("experimental: level is free-form, type any value")
    return
  let levels = availableReasonings(prov, prof.family, prof.model)
  if levels.len == 0:
    return hintLnS(&"{prof.family}: no reasoning knob")
  for r in levels:
    let mark = if r == prof.reasoning: "*" else: " "
    result.add hintLnS(mark & " " & r)

proc cmdReasoningSelect(target: string, prof: var Profile): string =
  let prov = providerForProfile(prof)
  if prov.name == "":
    return errLnS("no provider selected")
  let value = target.toLowerAscii
  if not experimentalEnabled:
    let levels = availableReasonings(prov, prof.family, prof.model)
    if value notin levels:
      return errLnS(&"unknown reasoning level: {target} (choose from {levels.join(\" \")})")
  prof.reasoning = value
  for i, pr in activeProviders:
    if pr.name == prov.name:
      activeProviders[i].reasoning = value
      break
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  profileLinesS(prof)

proc cmdReasoning(arg: string, prof: var Profile): string =
  let parts = arg.splitWhitespace()
  case parts.len
  of 0:
    return cmdReasoningList(prof)
  of 1:
    if parts[0] == "list":
      return cmdReasoningList(prof)
    return cmdReasoningSelect(parts[0], prof)
  else:
    return errLnS("usage: :reasoning [<level>]")

proc cmdStreamingList(): string =
  let mark = if streamingEnabled: "on" else: "off"
  hintLnS("streaming: " & mark &
    "  (on = live SSE output, off = single request/response)")

proc cmdStreamingSelect(target: string): string =
  case target.toLowerAscii
  of "on":
    streamingEnabled = true
  of "off":
    streamingEnabled = false
  else:
    return errLnS(&"unknown value: {target} (choose on or off)")
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  cmdStreamingList()

proc cmdStreaming(arg: string): string =
  let parts = arg.splitWhitespace()
  case parts.len
  of 0:
    return cmdStreamingList()
  of 1:
    if parts[0] == "list":
      return cmdStreamingList()
    return cmdStreamingSelect(parts[0])
  else:
    return errLnS("usage: :streaming [on|off]")

proc cmdNotifyList(): string =
  let mark = if notifyEnabled: "on" else: "off"
  hintLnS("notify: " & mark &
    "  (on = desktop notification when a turn ends, off = silent)")

proc cmdNotifySelect(target: string): string =
  case target.toLowerAscii
  of "on":
    notifyEnabled = true
  of "off":
    notifyEnabled = false
  else:
    return errLnS(&"unknown value: {target} (choose on or off)")
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  cmdNotifyList()

proc cmdNotify(arg: string): string =
  let parts = arg.splitWhitespace()
  case parts.len
  of 0:
    return cmdNotifyList()
  of 1:
    if parts[0] == "list":
      return cmdNotifyList()
    return cmdNotifySelect(parts[0])
  else:
    return errLnS("usage: :notify [on|off]")

proc cmdSandboxSettingSelect(target: string): string =
  case target.toLowerAscii
  of "on":
    sandboxEnabled = true
  of "off":
    sandboxEnabled = false
  else:
    return errLnS(&"unknown value: {target} (choose on or off)")
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  hintLnS("sandbox: " & (if sandboxEnabled: "on" else: "off") &
    "  (on = enforce the .3code/sandbox policy, off = run unconfined)")

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
  of ":streaming":
    "streaming"
  of ":notify":
    "notify"
  else:
    name.strip(chars = {':'})

# ---------- Session preamble + user-input prep ----------

proc loadAgentsMd(start: string): string =
  ## Walk from `start` up to the filesystem root, collecting project-notes
  ## files in precedence order. At each directory level, `3CODE.md` is read
  ## before `AGENTS.md` (both load when both exist). The deepest level (cwd)
  ## is emitted first, so more-deeply-nested files take precedence by virtue
  ## of appearing earlier in the developer message.
  var dir = resolvePath(start)
  while true:
    for name in ["3CODE.md", "AGENTS.md"]:
      let candidate = dir / name
      if not fileExists(candidate): continue
      try:
        let body = readFile(candidate)
        if isBinaryContent(body): continue
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
  let wrapped = when defined(windows):
    let b = resolveBash()
    if b.len == 0: return ""
    # `timeout` (MSYS2 coreutils) bounds the run; the redirect lives outside
    # bash quotes so cmd.exe handles it with Windows-correct `2>nul`.
    &"{b} -lc \"timeout {timeoutS}s {cmd}\" >\"{outPath}\" 2>nul"
  else:
    &"timeout {timeoutS}s sh -c \"{cmd}\" >\"{outPath}\" 2>/dev/null"
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
    var wasInterrupt = false
    if consumeQueuedInput(line, echoRows, cmdWasQuit, wasInterrupt):
      navigatedUp = false
      editor.echoRows = echoRows
      if line.strip == "":
        # Empty submission must leave the prompt/footer on the same visual
        # floor instead of drifting downward. The input thread's editor
        # already repainted itself after Enter, so its row model is live;
        # repainting the current footer frame walks up from it and redraws
        # everything at the same anchor.
        if liveEditorFooterAnchored():
          termengine.renderFooter(footerFrame(fatPromptState),
                                  inputThreadRunning, inputEditor)
        releaseIdleSubmittedInput()
        return ""
      return line
    if wasInterrupt:
      # An idle Ctrl-C / ESC: the input thread already repainted the empty
      # prompt in place, so no walk-back. Just clear the idle-submitted flag
      # and return to the prompt loop.
      navigatedUp = false
      releaseIdleSubmittedInput()
      return ""
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
  let parts = arg.splitWhitespace()
  let kind = classifyCommand(c)
  if kind == ckModal:
    stdout.write "\r\n"
    stdout.flushFile
    # The modal wizard runs each prompt on the input thread (see
    # `wizardReadLine`), so it owns `inputModalActive` and the
    # per-field save/restore dance itself. The controller only needs
    # to call the wizard and let it return. Cancel propagates as
    # `minline.InputCancelled` from `wizardReadLine`; we let it
    # propagate up to the outer `try` in `handleCommandResult` and
    # turn it into an empty `cdModal` return so the main loop
    # restores its idle state.
    var wizardBody = ""
    try:
      case name
      of ":provider":
        wizardBody = cmdProvider(arg, editor, prof)
        session.profileName = prof.name
        # Usage errors (`:provider add <extra>`) never enter the wizard;
        # they come back as an error body. Surface those through the
        # normal transcript path instead of swallowing them.
        if wizardBody.len > 0 and wizardBody.contains("usage:"):
          return CommandResult(recognized: true, ok: false,
                               name: commandTitle(name, arg, false),
                               body: wizardBody, plainBody: false,
                               disposition: cdTranscriptResult)
      else:
        discard
    except minline.InputCancelled:
      discard
    return CommandResult(recognized: true, ok: true,
                         name: commandTitle(name, arg, true),
                         body: wizardBody,
                         disposition: cdModal)
  var ok = true
  var body = ""
  template resp(b: string) = body.add cmdResponseS(b)
  template respErr(b: string) = body.add cmdErrorS(b)
  block dispatch:
    case name
    of ":help", ":?":
      body.add renderHelpS()
    of ":tokens":
      if session.usage.totalTokens == 0:
        resp "no tokens used yet"
      else:
        let fresh = max(0, session.usage.promptTokens - session.usage.cachedTokens)
        let line = tokenSlot("↑", fresh) &
          "  " & tokenSlot("↻", session.usage.cachedTokens) &
          "  " & tokenSlot("↓", session.usage.completionTokens) &
          "  total " & humanTokens(session.usage.totalTokens)
        resp line
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
        clearDraft(session)
        releaseSessionLock(session.savePath)
        session.savePath = newSessionPath()
        session.created = $now()
        session.cwd = safeCwd()
        acquireSessionLock(session.savePath)
      resp "════════════════════════════════════════"
    of ":model":
      body.add cmdModel(arg, prof)
      session.profileName = prof.name
    of ":provider":
      body.add cmdProvider(arg, editor, prof)
      session.profileName = prof.name
    of ":reasoning":
      body.add cmdReasoning(arg, prof)
    of ":streaming":
      body.add cmdStreaming(arg)
    of ":notify":
      body.add cmdNotify(arg)
    of ":prompt":
      resp buildSystemPrompt(prof)
    of ":version":
      resp "3code v" & Version
    of ":sandbox":
      # `:sandbox show` (or bare) dumps the rules; allow/readonly/deny
      # append a line and reload. The path arg is written verbatim so
      # relative paths stay portable in the file.
      let verb = if parts.len == 0: "show" else: parts[0]
      case verb
      of "show":
        if sandbox.active:
          resp sandbox.renderSandbox(sandbox.current)
        else:
          resp "sandbox not active"
      of "on", "off":
        body.add cmdSandboxSettingSelect(verb)
      of "allow", "readonly", "deny":
        if parts.len < 2:
          ok = false
          respErr ":sandbox " & verb & " needs a path"
        else:
          let argPath = parts[1 .. ^1].join(" ")
          let access =
            case verb
            of "allow": akWritable
            of "readonly": akReadOnly
            else: akDeny
          let sf = sandbox.sandboxPathInCwd()
          if sandbox.appendRule(sf, argPath, access):
            sandbox.current = sandbox.loadCascaded(getCurrentDir())
            resp "sandbox updated: " & verb & " " & argPath
          else:
            ok = false
            respErr "could not write sandbox file at " & sf
      else:
        ok = false
        respErr "unknown :sandbox verb: " & verb &
          "  (show, on, off, allow, readonly, deny)"
    of ":show":
      body.add showToolS(arg, session.toolLog)
    of ":log":
      body.add listToolsS(session.toolLog)
    of ":sessions":
      # Listing is directory-scoped by design; the full set lives under
      # `sessionDir()`. `showCwd` is threaded through as false to keep
      # the re-enable path a one-line flip here and in the `-l` handler.
      let showCwd = false
      let askedAll = arg.strip.toLowerAscii in ["all", "-a", "--all"]
      let paths = listSessionPathsForCwd(safeCwd())
      if paths.len == 0:
        resp "no saved sessions for this directory"
      else:
        body.add printSessionListS(paths, session.savePath, showCwd)
      if askedAll:
        let dir = collapseHome(sessionDir())
        resp "listing is scoped to this directory — run from " & dir &
                    " for all"
    of ":summarize":
      if prof.name == "":
        ok = false
        respErr "no provider configured. use :provider add"
      else:
        let n = summarizeHistory(messages, prof)
        if n == 0:
          ok = false
          resp "failed or not worth it"
        else:
          resp &"collapsed {n} message" &
            (if n == 1: "" else: "s") &
            " into a synthetic recap"
          saveSession(session, messages)
    else:
      ok = false
      let suggestion = nearestCommand(name)
      if suggestion != "":
        respErr "unknown command: " & c & "  did you mean " & suggestion & "?"
      else:
        respErr "unknown command: " & c & "  (try :help)"
  let title = commandTitle(name, arg, ok)
  let disposition =
    case kind
    of ckSafeImmediate: cdHarnessOnly
    of ckModal: cdModal
    else: cdTranscriptResult
  CommandResult(recognized: true, ok: ok, name: title,
                body: body,
                plainBody: ok,
                clearFooter: ok and title == "profile",
                disposition: disposition)
