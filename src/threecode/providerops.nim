## Non-interactive provider-management operations, shared by the
## `3code provider` CLI (cli.nim) and 3code-app's settings page. Every
## proc here edits the same config file through the same code path —
## the `activeCurrent` / `activeProviders` globals plus
## `writeConfigFile` — so the CLI, the REPL and the GUI cannot drift
## apart. Only the view layer differs per caller.
##
## Contract: the caller loads the config first (`loadStateOrEmpty`, or
## `tryLoadStateOrEmpty` where dying on a malformed file is not
## acceptable — a server process must answer, not exit). Every proc
## returns "" on success or a user-facing error message; nothing here
## echoes, quits or dies. The whole load-edit-write sequence is
## synchronous: a host with an event loop must run it without yielding
## between load and write, since the state lives in the config module's
## globals.

import std/[strformat, strutils, tables]
import types, config, prompts, auth_anthropic, auth_google

type
  OauthLoginProc* = proc(name: string): string
    ## Brings up the subscription browser login for a twin name
    ## (supergrok, chatgpt, geminicli, claudecode) and returns "oauth".
    ## The terminal implementation lives in ui.nim (`oauthLoginFor`) —
    ## providerops stays TTY-free and takes it as a callback so both
    ## the CLI and non-terminal hosts share this entry resolution.

proc providerNameTaken*(name: string): bool =
  for pr in activeProviders:
    if pr.name == name: return true
  false

proc resolveProviderEntry*(entry, keyFlag: string;
                            oauthLogin: OauthLoginProc = nil): ProviderRec {.raises: [ValueError].} =
  ## Name/url/key resolution from the wizard's first field, minus the
  ## prompts. `entry` is a catalog name, an http(s) url, an api key, or
  ## a subscription login name. The key comes from `--key` (or the
  ## entry itself when it is one). Subscription logins go through the
  ## `oauthLogin` callback (the CLI passes ui's browser flow; callers
  ## without one get an error pointing at the terminal). Raises
  ## ValueError with a user-facing message on anything it cannot
  ## resolve.
  let entryLower = entry.toLowerAscii
  if entryLower in ["supergrok", "chatgpt", "geminicli", "claudecode"]:
    if providerNameTaken(entryLower):
      raise newException(ValueError, "already configured: " & entryLower)
    if oauthLogin == nil:
      raise newException(ValueError, "subscription login for " & entryLower &
        " needs the terminal: run `3code provider add " & entryLower & "`")
    let auth =
      try: oauthLogin(entryLower)
      except Exception as e:
        raise newException(ValueError, e.msg)
    let url =
      if entryLower == "geminicli": auth_google.CloudCodeApiUrl
      elif entryLower == "claudecode": auth_anthropic.ClaudeApiUrl
      else: catalogUrl(canonicalKnownGoodProvider(entryLower))
    return ProviderRec(name: entryLower, url: url, auth: auth)
  if entry.startsWith("http://") or entry.startsWith("https://"):
    if not experimentalEnabled:
      raise newException(ValueError, "custom urls need --experimental")
    if keyFlag == "":
      raise newException(ValueError, "--key required with a url entry")
    let url = entry.strip(chars = {'/', ' '})
    var name = defaultNameFromUrl(url)
    if name == "": name = keyFlag
    if name == "":
      raise newException(ValueError, "cannot infer a name from " & url &
        "; use a catalog name entry instead")
    if providerNameTaken(name):
      raise newException(ValueError, "already configured: " & name)
    return ProviderRec(name: name, url: url, key: keyFlag)
  let inferred = inferProvider(entry)
  if inferred != "":
    if not experimentalEnabled and curatedFor(inferred).len == 0:
      raise newException(ValueError, "key prefix not recognized: " & entry)
    if providerNameTaken(inferred):
      raise newException(ValueError, "already configured: " & inferred)
    return ProviderRec(name: inferred, url: catalogUrl(inferred), key: entry)
  # Catalog provider name; the key rides in --key (or the entry is a
  # bare unrecognized token, which the wizard would also refuse).
  let name = entryLower
  if not experimentalEnabled and curatedFor(name).len == 0:
    raise newException(ValueError, "unknown provider: " & name)
  if providerNameTaken(name):
    raise newException(ValueError, "already configured: " & name)
  var url = catalogUrl(name)
  if url == "": url = catalogUrl(canonicalKnownGoodProvider(name))
  if url == "":
    raise newException(ValueError, "no catalog url for " & name)
  if keyFlag == "":
    raise newException(ValueError, "api key required (--key)")
  ProviderRec(name: name, url: url, key: keyFlag)

proc resolveProviderModels*(prov: ProviderRec, modelsFlag: string): seq[string] {.raises: [ValueError].} =
  ## The provider's model list: `--models` when given, else the curated
  ## known-good set. Entered names resolve through the curated list
  ## (short or full spelling); unknown names are an error unless
  ## --experimental, where they pass through verbatim.
  let curated = curatedFor(prov.name)
  if modelsFlag == "":
    if curated.len == 0:
      raise newException(ValueError, "no known-good models for " &
        prov.name & "; pass --models")
    return curated
  let lookup = shortToFull(curated)
  for rm in splitModels(modelsFlag):
    if experimentalEnabled:
      result.add lookup.getOrDefault(rm, rm)
    elif lookup.getOrDefault(rm, rm) in curated:
      result.add lookup.getOrDefault(rm, rm)
    else:
      raise newException(ValueError, "unknown known-good model: " & rm)
  if result.len == 0:
    raise newException(ValueError, "need at least one model")

proc reconcileCurrentFor*(name: string) =
  ## After an edit changed `name`'s model list: keep the live model when
  ## it survived the edit, else fall back to the provider's remembered
  ## default (the wizard's edit path does the same).
  let dot = activeCurrent.find('.')
  let curName = if dot < 0: "" else: activeCurrent[0 ..< dot]
  if curName != name: return
  for i, pr in activeProviders:
    if pr.name == name:
      let model = rememberedModel(pr)
      activeCurrent = pr.name & "." & model
      setCurrentModel(pr.name, model)
      break

proc addProvider*(entry, keyFlag, modelsFlag: string;
                  oauthLogin: OauthLoginProc = nil): tuple[err: string, prov: ProviderRec] =
  ## Resolve an entry + key + model list to a complete provider rec,
  ## append it, and make it current when nothing else is. The rec comes
  ## back for the caller's confirmation line.
  var prov: ProviderRec
  try:
    prov = resolveProviderEntry(entry, keyFlag, oauthLogin)
    prov.models = resolveProviderModels(prov, modelsFlag)
  except ValueError as e:
    return (e.msg, ProviderRec())
  activeProviders.add prov
  if activeCurrent == "":
    activeCurrent = prov.name & "." & firstModel(prov)
    setCurrentModel(prov.name, firstModel(prov))
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  ("", prov)

proc setProviderModels*(name: string, models: seq[string]): string =
  var idx = -1
  for i, pr in activeProviders:
    if pr.name == name: idx = i; break
  if idx < 0:
    return &"unknown provider: {name}"
  var prov = activeProviders[idx]
  try:
    prov.models = resolveProviderModels(prov, models.join(" "))
  except ValueError as e:
    return e.msg
  activeProviders[idx] = prov
  reconcileCurrentFor(name)
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  ""

proc removeProvider*(name: string): string =
  var idx = -1
  for i, pr in activeProviders:
    if pr.name == name: idx = i; break
  if idx < 0:
    return &"unknown provider: {name}"
  activeProviders.delete(idx)
  let dot = activeCurrent.find('.')
  let curName = if dot < 0: "" else: activeCurrent[0 ..< dot]
  if curName == name:
    if activeProviders.len > 0:
      let np = activeProviders[0]
      let model = rememberedModel(np)
      activeCurrent = np.name & "." & model
      setCurrentModel(np.name, model)
    else:
      activeCurrent = ""
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  ""

proc upsertProviderRec*(p: ProviderRec; keepMissingSecrets: bool): string =
  ## Replace the provider with the same name, else append it — the
  ## settings-form equivalent of the wizard's add/edit pair. With
  ## `keepMissingSecrets`, an empty `key`/`url` keeps the stored value
  ## (a form that never re-shows secrets) and `auth`/`family`/
  ## `reasoning`/`reasonings`/`currentModel` pass through untouched
  ## when `p` leaves them at their defaults. The current selection is
  ## reconciled the way an in-place model-list edit is.
  var idx = -1
  for i, pr in activeProviders:
    if pr.name == p.name: idx = i; break
  if idx < 0:
    activeProviders.add p
    if activeCurrent == "":
      activeCurrent = p.name & "." & firstModel(p)
      setCurrentModel(p.name, firstModel(p))
  else:
    var merged = p
    let stored = activeProviders[idx]
    if keepMissingSecrets:
      if merged.url == "": merged.url = stored.url
      if merged.key == "": merged.key = stored.key
      if merged.auth == "": merged.auth = stored.auth
      if merged.family == "": merged.family = stored.family
      if merged.reasoning == "": merged.reasoning = stored.reasoning
      if merged.reasonings.len == 0: merged.reasonings = stored.reasonings
      if merged.currentModel == "": merged.currentModel = stored.currentModel
    activeProviders[idx] = merged
  reconcileCurrentFor(p.name)
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  ""

proc setCurrentSpec*(spec: string): string =
  ## Point `current` at `provider.model` — the persistence core of the
  ## REPL's `:model`/`:provider` switches, minus the session profile and
  ## the directory-sticky current (neither exists in a non-interactive
  ## caller). Model may be the short spelling; the full list id is what
  ## gets stored. Enforces the same gates as the REPL: verification-
  ## class models are refused, and an experimental (non-known-good)
  ## pick needs the caller to run under --experimental.
  let dot = spec.find('.')
  if dot < 1 or dot == spec.len - 1:
    return &"current must be provider.model, got: {spec}"
  let pname = spec[0 ..< dot]
  let model = spec[dot + 1 .. ^1]
  var prov: ProviderRec
  for pr in activeProviders:
    if pr.name == pname: prov = pr
  if prov.name == "":
    return &"no provider named {pname}"
  let idx = prov.findModel(model)
  if idx < 0:
    return &"unknown model: {model}"
  let fullModel = prov.models[idx]
  if isDecisionModel(fullModel):
    return &"{shortModel(fullModel)} is a verification-class model: it " &
      "cannot run turns"
  let newCurrent = prov.name & "." & fullModel
  let candidate = buildProfile(newCurrent, activeProviders, "")
  if candidate.name != "" and not gateExperimental(candidate):
    return experimentalGateText(candidate)
  setCurrentModel(prov.name, fullModel)
  activeCurrent = newCurrent
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  ""
