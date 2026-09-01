## Config file parsing and provider/profile resolution.
##
## The config file is a sequence of `[provider]` sections and an optional
## `[settings]` section (see `config.example` in the project root for the
## format). `parseConfigFile` turns it into a list of `ProviderRec` values;
## `buildProfile` resolves a provider.model string to a `Profile` ready for
## API calls.
##
## Known-good validation lives here: a profile must correspond to a
## `KnownGoodCombos` entry unless `experimentalEnabled` is true. Tab-completion
## and `:model` cycling both walk `KnownGoodCombos` order, so the curated
## ranking determines what the user sees first when tabbing through models.

import std/[os, parsecfg, sequtils, streams, strformat, strutils, tables, terminal, uri]
when defined(posix):
  import std/posix except SocketHandle
import types, prompts, util, auth_openai, modelname, minline

type
  ProviderRec* = object
    ## In-memory mirror of a [provider] section. `family` is the optional
    ## experimental override (broad name like "glm"/"qwen"/"gpt-oss") used
    ## to pick a system prompt; only honored when --experimental is on.
    ## Known-good combos ignore it. `models` is the list of full API model
    ## ids (e.g. "openai/gpt-oss-120b") as sent on the wire. `modelPrefix`
    ## is only populated transiently when reading old config files that
    ## stored a separate `model_prefix` key; it is expanded into the model
    ## ids on load and never written back out.
    name*, url*, key*, modelPrefix*, family*: string
    auth*: string  ## "oauth" = subscription login (tokens in the auth
                   ## store, `key` stays empty); anything else = static key.
    models*: seq[string]
    reasoning*: string  ## persisted current reasoning level for this
                        ## provider ("low" / "medium" / "high"), empty if
                        ## the user hasn't picked one — `buildProfile`
                        ## then falls back to the known-good default.
    reasonings*: seq[string]  ## available reasoning levels for `:reasoning`
                              ## listing. Empty means "fall back to the
                              ## model default" (`defaultReasoningsFor`).

func shortModel*(model: string): string =
  ## Everything after the last `/` in a model id. This is the
  ## user-visible short name: `gpt-oss-120b` for `openai/gpt-oss-120b`,
  ## `glm-5p1` for `accounts/fireworks/models/glm-5p1`. When there is no
  ## slash, the model id is already a bare name and is returned as-is.
  let slash = model.rfind('/')
  if slash < 0: model else: model[slash + 1 .. ^1]

proc shortToFull*(models: seq[string]): Table[string, string] =
  ## Maps each short model name (after the last `/`) to the full model id.
  ## When two full ids share the same short name — e.g. nvidia sometimes
  ## lists a model both as `org/model-name` and bare `model-name` — only
  ## the first occurrence is kept. This mirrors the display list: the
  ## user sees both names, picks the short one, and gets the first match.
  ## If genuine ambiguity arises in the future we can promote a conflict
  ## notice here; for now silent first-wins is the right trade-off.
  for m in models:
    let s = shortModel(m)
    if s notin result:
      result[s] = m

func findModel*(p: ProviderRec, name: string): int =
  ## Matches by full model id, by short name (everything after the last
  ## `/`), or by normalized name. Short-name matching handles
  ## `:variant <name>` from users who type the bare model name and old
  ## `current = provider.shortname` config values that haven't been
  ## rewritten yet. Normalized matching lets any provider spelling
  ## (`zai-glm-5-3-flash`, `glm-5p3-flash`) select the canonical entry.
  for i, m in p.models:
    if m == name or shortModel(m) == name: return i
  let wanted = normalizeModelName(name)
  for i, m in p.models:
    if normalizeModelName(m) == wanted: return i
  -1

var activeCurrent*: string
var activeProviders*: seq[ProviderRec]
var activeSearchKey*: string = ""
  ## The key for the *active* search engine, resolved at config load from
  ## the engine-specific `[search] exa-key` / `brave-key` (or the matching
  ## env var `EXA_API_KEY` / `BRAVE_API_KEY`). Keyless by default: exa and
  ## parallel work without a key, brave requires one.

var activeSearchKeys*: Table[string, string]
  ## All configured search keys, keyed by engine name (`exa`, `brave`).
  ## Mirrors what was read from `[search] exa-key` / `brave-key`. The
  ## `activeSearchKey` is derived from this for the active engine; this map
  ## is kept so a future engine switch doesn't require a config re-read.

const SearchEngineEnv*: array[2, (string, string)] = [
  ("exa", "EXA_API_KEY"),
  ("brave", "BRAVE_API_KEY")
]
  ## Engines that take an optional key, mapped to the env var that supplies
  ## it. `parallel` is keyless in practice, so it has no entry. Used by
  ## `resolveSearchKey` to fall back to the environment.

var activeSearchEngine*: string = "exa"
  ## Active search engine: "exa" (default), "parallel", or "brave". Set via
  ## `[search] engine = "..."`. No automatic failover — the chosen engine is
  ## used as-is, and a missing key is an error only if that engine needs one
  ## (brave does; exa and parallel are keyless by default).

var activeShortcuts*: Table[string, string]
  ## [shortcuts] map loaded from the active config, exposed so minline can
  ## apply the user's bindings at startup and after config reloads.

var bashPathOverride*: string
  ## Windows-only. `[settings]` `bash_path = "..."` overrides MSYS2
  ## detection in `streamexec.resolveBash` for users with bash at a
  ## non-standard location. Empty on POSIX (where /bin/sh is always used).

proc gateExperimental*(p: Profile): bool =
  ## True if the profile is allowed to run a turn under current policy:
  ## empty profile (caller handles that), known-good model, or the
  ## `--experimental` override. False otherwise — caller should bail out
  ## and call `explainExperimentalGate` for the user-facing hint.
  p.name == "" or isKnownGood(p) or experimentalEnabled

proc emitTestFrameEvent*() =
  ## Same hook as turns.nim's emitTestFrameEvent, for render boundaries that
  ## live in config.nim (the experimental-gate refusal). Tests synchronize on
  ## this instead of wall-clock polling.
  when defined(posix):
    let fdText = getEnv("THREECODE_TEST_FRAME_FD")
    if fdText.len > 0:
      try:
        let fd = cint(parseInt(fdText))
        var ch = 'f'
        discard posix.write(fd, addr ch, 1)
        let ackText = getEnv("THREECODE_TEST_FRAME_ACK_FD")
        if ackText.len > 0:
          let ackFd = cint(parseInt(ackText))
          var ack: array[1, char]
          discard posix.read(ackFd, addr ack[0], 1)
      except CatchableError:
        discard

proc experimentalGateText*(p: Profile): string =
  ## The experimental-gate notice as a string (magenta styling applied
  ## by the caller's err path). Empty when the profile is not gated.
  let dot = p.name.find('.')
  let display =
    if dot < 0: p.name
    else: p.name[0 ..< dot] & " " & p.name[dot+1 .. ^1]
  display & " is experimental (start 3code with --experimental to use anyway, not recommended)"

proc explainExperimentalGate*(p: Profile) =
  stdout.styledWriteLine fgMagenta,
    experimentalGateText(p),
    resetStyle
  emitTestFrameEvent()

proc hasKnownGoodModel*(prov: ProviderRec): bool =
  for m in prov.models:
    if knownGoodFamily(prov.name, m) != "": return true
  false

proc orderedModels*(prov: ProviderRec): seq[string] =
  ## Models in the order they should be presented to the user and used
  ## for default selection:
  ##   1. Known-good models in KnownGoodCombos order (curated quality ranking).
  ##   2. Experimental models in config-file order, appended after.
  ## This way the best-tested model is always first regardless of how the
  ## config was written or the API listed them.
  let p = canonicalKnownGoodProvider(prov.name)
  for combo in KnownGoodCombos:
    if combo.provider.toLowerAscii == p:
      for m in prov.models:
        if matchesKnownGoodModel(combo.model, m):
          result.add m
          break
  for m in prov.models:
    if knownGoodFamily(prov.name, m) == "":
      result.add m

proc firstModel*(prov: ProviderRec): string =
  ## First model in KnownGoodCombos order, or `models[0]` if none are
  ## known-good (e.g. a provider added with --experimental).
  let ordered = orderedModels(prov)
  if ordered.len > 0: ordered[0]
  elif prov.models.len > 0: prov.models[0]
  else: ""

proc firstKnownGoodCombo*(providers: seq[ProviderRec]): string =
  ## "<provider>.<model>" of the first known-good (provider, model) pair
  ## across `providers`, walking KnownGoodCombos order so the curated
  ## ranking drives the fallback, not config-file order.
  for combo in KnownGoodCombos:
    for pr in providers:
      if pr.url == "" or (pr.key == "" and pr.auth != "oauth"): continue
      if canonicalKnownGoodProvider(pr.name) != combo.provider.toLowerAscii: continue
      for m in pr.models:
        if matchesKnownGoodModel(combo.model, m):
          return pr.name & "." & m
  ""

proc currentProvider*(): ProviderRec =
  let dot = activeCurrent.find('.')
  let name = if dot < 0: activeCurrent else: activeCurrent[0 ..< dot]
  for pr in activeProviders:
    if pr.name == name: return pr
  ProviderRec()

proc providerForProfile*(prof: Profile): ProviderRec =
  ## The provider rec backing a profile, looked up by the provider prefix
  ## of `prof.name` ("nebius.zai-org/GLM-5.1" -> nebius). Falls back to
  ## `currentProvider()` when the name has no dot (e.g. a bare default).
  let dot = prof.name.find('.')
  if dot >= 0:
    let name = prof.name[0 ..< dot]
    for pr in activeProviders:
      if pr.name == name: return pr
  return currentProvider()

var subscriptionTokenForImpl*: proc(provider: string): string {.closure.}
  ## Indirection so config.nim stays free of the OAuth stack: startup
  ## installs auth_xai's resolver here. Nil means no subscription auth in
  ## this binary (tests, minimal builds) — oauth providers then fail
  ## closed (empty bearer).

proc subscriptionBearer*(p: Profile): string =
  ## Bearer resolver installed as `api.bearerHook` at startup. Returns ""
  ## for key-based providers (hook result falls back to `p.key`); for
  ## `auth = "oauth"` providers it vends the stored subscription token,
  ## refreshing when near expiry. During wizard verify the provider is not
  ## in `activeProviders` yet, so empty-key profiles whose name is a known
  ## subscription target also resolve.
  if subscriptionTokenForImpl == nil: return ""
  let dot = p.name.find('.')
  let name = if dot >= 0: p.name[0 ..< dot] else: ""
  for pr in activeProviders:
    if pr.name == name:
      if pr.auth != "oauth": return ""
      return subscriptionTokenForImpl(pr.name)
  if p.key == "" and name != "":
    return subscriptionTokenForImpl(name)
  ""

var extraHeadersImpl*: proc(provider: string): seq[(string, string)] {.closure.}
  ## Same indirection as `subscriptionTokenForImpl`: config stays free of
  ## the auth modules. Startup installs `chatgptExtraHeaders` below.

proc extraHeadersFor*(p: Profile): seq[(string, string)] =
  ## Extra request headers for `p`, resolved by provider prefix
  ## ("chatgpt.gpt-5.4" -> chatgpt). Installed as `api.extraHeadersHook`.
  if extraHeadersImpl == nil: return
  let dot = p.name.find('.')
  if dot < 0: return
  extraHeadersImpl(p.name[0 ..< dot])

proc chatgptExtraHeaders*(provider: string): seq[(string, string)] =
  ## Headers the ChatGPT Codex backend requires on every request, keyed
  ## to the stored subscription token's account id. Empty seq for any
  ## other provider (and when logged out: the bearer fails first).
  if provider.toLowerAscii != "chatgpt": return
  result = @[("OpenAI-Beta", "responses=experimental"),
             ("originator", "3code")]
  let acc = auth_openai.accountId()
  if acc != "":
    result.add ("chatgpt-account-id", acc)

proc splitModels*(s: string): seq[string] =
  ## Whitespace- (and comma-) separated list of bare model names. Family
  ## lives elsewhere — KnownGoodCombos hardcodes it; the [provider]
  ## `family = ...` key supplies an experimental override.
  for raw in s.splitWhitespace:
    let m = raw.strip(chars = {',', ' '})
    if m.len > 0: result.add m

proc formatModels*(models: seq[string]): string = models.join(" ")

proc expandEnvValue(s: string): string =
  ## Expand a leading `$VAR` reference (after any surrounding whitespace) to
  ## the value of the environment variable. Plain values pass through
  ## unchanged.
  let t = s.strip
  if t.len > 1 and t[0] == '$':
    return getEnv(t[1 .. ^1])
  s

type
  RawEntry* = tuple[section, key, value: string, line: int]
    ## A key/value pair as written, before env expansion, with the line it
    ## appeared on. Collected during the streaming parse so `validateConfig`
    ## can report `path:line:` for a bad section/key/value without re-reading.

const
  PermittedSections = ["settings", "search", "colors", "provider", "shortcuts"]
  SettingsKeys = ["current", "notify", "streaming", "sandbox",
                  "sandbox_enabled", "patient_retry", "patient-retry",
                  "sandbox_wall_warn",
                  "tone", "mode", "bash_path", "bash-path",
                  "auto_update"]
  SearchKeys = ["exa-key", "brave-key", "key", "engine"]
  ColorKeys = ["bright-white", "off-white", "dim-white"]
  ProviderKeys = ["name", "url", "key", "model_prefix", "family",
                  "models", "reasoning", "reasonings", "auth"]
  SearchEngines = ["exa", "parallel", "brave"]
  # `light` is the canonical light-background value; `bright` is the
  # legacy spelling and stays accepted so existing configs keep working.
  ColorModes = ["auto", "dark", "light", "bright"]
  BoolValues = ["on", "true", "yes", "1", "off", "false", "no", "0"]

proc permittedKey(section, key: string): bool =
  case section
  of "settings": key in SettingsKeys
  of "search": key in SearchKeys
  of "colors":
    # Plain key or a `-light` suffixed variant of a permitted base.
    let base = if key.endsWith("-light"): key[0 ..< key.len - 6] else: key
    base in ColorKeys
  of "provider": key in ProviderKeys
  of "shortcuts": key in minline.ShortcutNames
  else: false

proc validateConfig*(path: string; entries: seq[RawEntry]): string =
  ## Reject unknown sections, unknown keys, bad enum values, and empty
  ## values. Returns the first violation as a `path:line:` message, or ""
  ## when the config is schema-clean. The caller decides how to surface it
  ## (`parseConfigFile` passes it to `die` with `ExitConfig`). Empty
  ## `current`/`key`/`url`/`models` are tolerated here — those are
  ## structural gaps `loadProfile` already diagnoses with its own messages;
  ## this pass is about the schema, not provider completeness.
  for ent in entries:
    if ent.section notin PermittedSections:
      return &"{path}:{ent.line}: unknown section [{ent.section}]"
    if not permittedKey(ent.section, ent.key):
      return &"{path}:{ent.line}: unknown key '{ent.key}' in [{ent.section}]"
    if ent.value.strip == "":
      # Empty key is fine for auth=oauth providers (and is also a structural
      # gap loadProfile diagnoses). Empty current/url/models likewise.
      # Empty [shortcuts] values are explicit unbinds, so they are allowed.
      if not (ent.section == "provider" and ent.key == "key") and
         not (ent.section == "settings" and ent.key == "current") and
         not (ent.section == "shortcuts"):
        return &"{path}:{ent.line}: empty value for '{ent.key}' in [{ent.section}]"
    case ent.section
    of "search":
      if ent.key == "engine" and
          ent.value.strip.toLowerAscii notin SearchEngines:
        return &"{path}:{ent.line}: unknown search engine '{ent.value}' " &
               "(expected one of: exa, parallel, brave)"
    of "settings":
      if ent.key in ["notify", "streaming", "sandbox", "sandbox_enabled",
                      "patient_retry", "patient-retry",
          "sandbox_wall_warn"] and
          ent.value.strip.toLowerAscii notin BoolValues:
        return &"{path}:{ent.line}: bad value '{ent.value}' for '{ent.key}' " &
               "(expected on/off/true/false/yes/no/1/0)"
      if ent.key in ["tone", "mode"] and
          ent.value.strip.toLowerAscii notin ColorModes:
        return &"{path}:{ent.line}: unknown tone '{ent.value}' " &
               "(expected one of: auto, dark, light)"
    of "shortcuts":
      if ent.value.strip != "":
        try:
          discard minline.parseShortcutSpec(ent.value)
        except ValueError:
          return &"{path}:{ent.line}: invalid shortcut value '{ent.value}' for '{ent.key}'"
    else: discard
  ""

proc parseConfigFile*(path: string): (string, seq[ProviderRec], Table[string, string], Table[string, string], string, Table[string, string]) =
  ## Streaming parse so that repeated [provider] sections accumulate as a list.
  ## Returns `(current, providers, colors, searchKeys, searchEngine, shortcuts)`.
  ## `searchKeys` maps engine name -> key for each `[search] exa-key` /
  ## `brave-key` set (empty table when none). A legacy bare `[search] key`
  ## is accepted and filed under the active engine for backward compat.
  ## `searchEngine` is the optional `[search] engine` value ("" when absent,
  ## meaning the default `exa`). `colors` is the flat
  ## `[colors]` map (raw keys verbatim, including any `-light` suffix); the
  ## caller routes it through `splitColorOverrides` + `applyColorOverrides`.
  var current = ""
  var searchKeys: Table[string, string]
  var searchEngine = ""
  var providers: seq[ProviderRec]
  var colors: Table[string, string]
  var shortcuts: Table[string, string]
  var section = ""
  var prov: ProviderRec
  var inProvider = false
  var entries: seq[RawEntry]
  let stream = newFileStream(path, fmRead)
  if stream == nil: die &"cannot open {path}", ExitConfig
  var p: CfgParser
  p.open(stream, path)
  proc flush() =
    if inProvider:
      # Backward compat: old configs wrote `model_prefix = "openai/"` and
      # stored bare names like `"gpt-oss-120b"` in `models`. Expand them
      # to full ids here so the rest of the codebase only ever sees full
      # ids. The prefix is never written back out.
      if prov.modelPrefix != "":
        for i in 0 ..< prov.models.len:
          if not prov.models[i].startsWith(prov.modelPrefix):
            prov.models[i] = prov.modelPrefix & prov.models[i]
        prov.modelPrefix = ""
      # Backward compat: an oauth provider whose `auth = "oauth"` line was
      # lost (written by a binary that dropped the field) reads back as an
      # empty-key API-key provider and fails buildProfile's completeness
      # check, silently disabling the provider. An empty key is only ever
      # meaningful for a subscription login, so re-mark the known
      # subscription twins here instead of asking the user to re-add.
      if prov.auth == "" and prov.key == "" and
         prov.name.toLowerAscii in ["supergrok", "chatgpt"]:
        prov.auth = "oauth"
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
      entries.add (section, e.key, e.value, p.getLine())
      let v = expandEnvValue(e.value)
      case section
      of "colors":
        colors[e.key] = v
      of "settings":
        case e.key
        of "current": current = v
        of "notify":
          case v.toLowerAscii
          of "on", "true", "yes", "1": notifyEnabled = true
          of "off", "false", "no", "0": notifyEnabled = false
          else: discard
        of "streaming":
          # Same boolean dialect as `notify`. Default is on (set in types.nim);
          # an explicit `off` opts into the reliable request/response path.
          case v.toLowerAscii
          of "on", "true", "yes", "1": streamingEnabled = true
          of "off", "false", "no", "0": streamingEnabled = false
          else: discard
        of "sandbox", "sandbox_enabled":
          # Same boolean dialect as `notify`/`streaming`. Default on; an
          # explicit `off` disables sandbox enforcement entirely (bash runs
          # unconfined, in-process checks pass through).
          case v.toLowerAscii
          of "on", "true", "yes", "1": sandboxEnabled = true
          of "off", "false", "no", "0": sandboxEnabled = false
          else: discard
        of "patient_retry", "patient-retry":
          # Same boolean dialect. Default on; an explicit `off` makes
          # retryable failures surface after the initial ramp-up (~1min)
          # instead of entering the long patient hold.
          case v.toLowerAscii
          of "on", "true", "yes", "1": patientRetryEnabled = true
          of "off", "false", "no", "0": patientRetryEnabled = false
          else: discard
        of "sandbox_wall_warn":
          # Silences only the Windows "wall not set up" warning; the
          # fence itself is unaffected.
          case v.toLowerAscii
          of "on", "true", "yes", "1": sandboxWallWarn = true
          of "off", "false", "no", "0": sandboxWallWarn = false
          else: discard
        of "tone", "mode":
          # `auto` detects the background (default); `dark`/`light` force a
          # palette. `mode`/`bright` are the legacy spellings and stay
          # accepted so existing configs keep working.
          case v.strip.toLowerAscii
          of "auto": colorModePref = cmAuto
          of "dark": colorModePref = cmDark
          of "light", "bright": colorModePref = cmLight
          else: discard
        of "bash_path", "bash-path":
          bashPathOverride = v
        else: discard
      of "search":
        case e.key
        of "exa-key": searchKeys["exa"] = v
        of "brave-key": searchKeys["brave"] = v
        of "key":
          # Legacy bare key: file it under the active engine (or exa if no
          # engine was set yet). Keeps old single-key configs working.
          searchKeys[if searchEngine != "": searchEngine else: "exa"] = v
        of "engine": searchEngine = v.strip.toLowerAscii
        else: discard
      of "provider":
        case e.key
        of "name": prov.name = v
        of "url": prov.url = v.strip(chars = {'/', ' '})
        of "key": prov.key = v
        of "model_prefix": prov.modelPrefix = v
        of "family": prov.family = v
        of "models": prov.models = splitModels(v)
        of "reasoning": prov.reasoning = v.strip.toLowerAscii
        of "reasonings": prov.reasonings = splitModels(v).mapIt(it.toLowerAscii)
        of "auth": prov.auth = v.strip.toLowerAscii
        else: discard
      of "shortcuts":
        shortcuts[e.key] = v
      else: discard
    of cfgError:
      die &"{path}: {e.msg}", ExitConfig
  p.close
  let verr = validateConfig(path, entries)
  if verr != "": die verr, ExitConfig
  (current, providers, colors, searchKeys, searchEngine, shortcuts)

func quoteVal(s: string): string =
  result = "\""
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    else: result.add c
  result.add "\""

proc writeConfigFile*(path: string, current: string,
                     providers: seq[ProviderRec]) =
  createDir(path.parentDir)
  # Models are always persisted in normalized form; the wire ids stay
  # untouched in memory. `current` may name a model too.
  var providers = providers
  for pr in providers.mitems:
    pr.models = pr.models.mapIt(normalizeModelName(it))
  let current = normalizeModelName(current)
  var buf = "[settings]\n"
  buf.add "current = " & quoteVal(current) & "\n"
  if activeSearchKeys.len > 0 or activeSearchEngine != "exa":
    buf.add "\n[search]\n"
    if activeSearchEngine != "exa":
      buf.add "engine = " & quoteVal(activeSearchEngine) & "\n"
    for engine in ["exa", "brave"]:
      if activeSearchKeys.hasKey(engine) and activeSearchKeys[engine] != "":
        buf.add engine & "-key = " & quoteVal(activeSearchKeys[engine]) & "\n"
  # Persist the streaming/notify toggles only when off — on is the default,
  # so a user who never changes them keeps a clean config. This also matches
  # the defaults in types.nim.
  if not streamingEnabled:
    buf.add "streaming = \"off\"\n"
  if not notifyEnabled:
    buf.add "notify = \"off\"\n"
  if not sandboxEnabled:
    buf.add "sandbox = \"off\"\n"
  if not patientRetryEnabled:
    buf.add "patient_retry = \"off\"\n"
  if not sandboxWallWarn:
    buf.add "sandbox_wall_warn = \"off\"\n"
  # Persist the colour tone only when it differs from `auto` (the default).
  if colorModePref != cmAuto:
    let label = if colorModePref == cmDark: "dark" else: "light"
    buf.add "tone = " & quoteVal(label) & "\n"
  if activeShortcuts.len > 0:
    buf.add "\n[shortcuts]\n"
    for cmd, spec in activeShortcuts:
      buf.add cmd & " = " & quoteVal(spec) & "\n"
  for pr in providers:
    buf.add "\n[provider]\n"
    buf.add "name = " & quoteVal(pr.name) & "\n"
    buf.add "url = " & quoteVal(pr.url) & "\n"
    if pr.key != "" or pr.auth != "oauth":
      buf.add "key = " & quoteVal(pr.key) & "\n"
    if pr.auth != "":
      buf.add "auth = " & quoteVal(pr.auth) & "\n"
    if pr.family != "":
      buf.add "family = " & quoteVal(pr.family) & "\n"
    buf.add "models = " & quoteVal(formatModels(pr.models)) & "\n"
    if pr.reasoning != "":
      buf.add "reasoning = " & quoteVal(pr.reasoning) & "\n"
    if pr.reasonings.len > 0:
      buf.add "reasonings = " & quoteVal(formatModels(pr.reasonings)) & "\n"
  writeFile(path, buf)

proc configPath*(): string =
  userConfigRoot() / "config"

proc resolveSearchKey*(engine: string; keys: Table[string, string]): string =
  ## The engine-specific `[search] exa-key` / `brave-key` wins; otherwise the
  ## env var for the active engine is consulted (`EXA_API_KEY` /
  ## `BRAVE_API_KEY`). Returns "" when neither is set, which is fine for the
  ## keyless engines (exa, parallel) and surfaces as a runtime error for brave.
  if keys.hasKey(engine) and keys[engine] != "": return keys[engine]
  for (name, envVar) in SearchEngineEnv:
    if name == engine and existsEnv(envVar):
      return getEnv(envVar)
  ""

proc loadStateOrEmpty*(path: string): (string, seq[ProviderRec], Table[string, string]) =
  ## Returns `(current, providers, colors)` and updates `activeSearchKey` /
  ## `activeSearchEngine` / `activeSearchKeys` / `activeShortcuts` as a side
  ## effect when the config sets them. `colors` is the flat `[colors]` map
  ## for the caller to route through the cascade. Missing file is benign.
  if not fileExists(path): return ("", @[], initTable[string, string]())
  let (current, providers, colors, searchKeys, searchEngine, shortcuts) = parseConfigFile(path)
  if searchEngine != "": activeSearchEngine = searchEngine
  activeSearchKeys = searchKeys
  activeSearchKey = resolveSearchKey(activeSearchEngine, activeSearchKeys)
  activeShortcuts = shortcuts
  minline.configuredShortcuts = activeShortcuts
  (current, providers, colors)

proc resolveFamily*(prov: ProviderRec, prof: Profile): string =
  ## Family is resolved at profile-build time:
  ## 1. KnownGoodCombos hardcode (always wins; ignores config and -x)
  ## 2. provider-level `family = ...` — only honored under --experimental
  ## 3. default → "glm"
  let kg = knownGoodFamily(prof)
  if kg != "": return kg
  if experimentalEnabled and prov.family.strip != "":
    return prov.family.strip.toLowerAscii
  "glm"

proc resolveReasoning*(prov: ProviderRec, prof: Profile): string =
  ## Reasoning level resolution at profile-build time:
  ## 1. provider config `reasoning = ...` (user picked / persisted)
  ## 2. KnownGoodCombos default for this (provider, model)
  ## 3. "" — caller treats as "no wire param"
  ##
  ## In experimental mode the known-good default is skipped: reasoning
  ## stays empty (no wire param) unless the user picks one. The effort
  ## level for an uncured model can't be guessed, and an empty value is
  ## the safe default: passing nothing beats passing a wrong knob.
  if prov.reasoning != "": return prov.reasoning
  if not experimentalEnabled:
    let dot = prof.name.find('.')
    if dot >= 0:
      let kg = knownGoodReasoning(prof.name[0 ..< dot], prof.model)
      if kg != "": return kg
  ""

proc availableReasonings*(prov: ProviderRec, family, model: string): seq[string] =
  ## Value set offered by `:reasoning` for the active provider+model. The
  ## per-provider config override wins; otherwise the model-aware default
  ## from the known-good table (glm has per-model value sets).
  ##
  ## In experimental mode the set is empty: the effort level is
  ## free-form (the user types whatever the model's wire surface accepts),
  ## so there is no fixed list to validate or tab-complete against.
  if experimentalEnabled: return @[]
  if prov.reasonings.len > 0: prov.reasonings
  else: defaultReasoningsFor(prov.name, model, family)

proc buildProfile*(current: string, providers: seq[ProviderRec],
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
      if pr.url == "" or (pr.key == "" and pr.auth != "oauth") or
         pr.models.len == 0:
        return Profile()
      var fullModel =
        if model == "": firstModel(pr)
        else:
          let i = pr.findModel(model)
          if i < 0: return Profile()
          pr.models[i]
      if fullModel == "": return Profile()
      # Config stores normalized ids; the wire needs the full id from
      # the known-good table when the pair is curated.
      let wire = knownGoodWireModel(pr.name, fullModel)
      if wire != "": fullModel = wire
      var prof = Profile(name: pr.name & "." & fullModel, url: pr.url,
                         key: pr.key, model: fullModel)
      prof.family = resolveFamily(pr, prof)
      let (_, ver, vrt) = knownGoodTags(pr.name, fullModel)
      prof.version = ver
      prof.variant = vrt
      prof.reasoning = resolveReasoning(pr, prof)
      return prof
  Profile()

proc loadProfile*(wanted: string): Profile =
  let path = configPath()
  if not fileExists(path):
    stderr.writeLine "3code: no config at " & path
    stderr.writeLine ""
    stderr.writeLine "create it with at least one [provider] section, e.g.:"
    stderr.writeLine ""
    stderr.writeLine ConfigExample
    quit ExitConfig
  let (current, providers, _, searchKeys, searchEngine, shortcuts) = parseConfigFile(path)
  if searchEngine != "": activeSearchEngine = searchEngine
  activeSearchKeys = searchKeys
  activeSearchKey = resolveSearchKey(activeSearchEngine, activeSearchKeys)
  activeShortcuts = shortcuts
  minline.configuredShortcuts = activeShortcuts
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
  if prov.key == "" and prov.auth != "oauth":
    die &"provider '{name}': key not set in {path}", ExitConfig
  if prov.models.len == 0: die &"provider '{name}': models not set in {path}", ExitConfig
  var fullModel =
    if model == "": firstModel(prov)
    else:
      let i = prov.findModel(model)
      if i < 0:
        die &"provider '{name}': model '{model}' not in models list ({prov.models.join(\", \")})", ExitConfig
      prov.models[i]
  if fullModel == "":
    die &"provider '{name}': models list is empty", ExitConfig
  let wire = knownGoodWireModel(prov.name, fullModel)
  if wire != "": fullModel = wire
  var prof = Profile(name: prov.name & "." & fullModel, url: prov.url,
                     key: prov.key, model: fullModel)
  prof.family = resolveFamily(prov, prof)
  let (_, ver, vrt) = knownGoodTags(prov.name, fullModel)
  prof.version = ver
  prof.variant = vrt
  prof.reasoning = resolveReasoning(prov, prof)
  if wanted == "" and not experimentalEnabled and not isKnownGood(prof):
    let fallback = firstKnownGoodCombo(providers)
    if fallback != "":
      let alt = buildProfile(fallback, providers, "")
      if alt.name != "": return alt
  prof

const ProviderCatalog*: seq[(string, string)] = @[
  ("aki",         "https://aki.io/openai/v1"),
  ("anthropic",   "https://api.anthropic.com/v1"),
  ("arcee",       "https://conductor.arcee.ai/v1"),
  ("baseten",     "https://inference.baseten.co/v1"),
  ("cerebras",    "https://api.cerebras.ai/v1"),
  ("cheaperinference", "https://api.cheaperinference.com/v1"),
  ("crof",        "https://crof.ai/v1"),
  ("deepinfra",   "https://api.deepinfra.com/v1/openai"),
  ("deepseek",    "https://api.deepseek.com/v1"),
  ("fireworks",   "https://api.fireworks.ai/inference/v1"),
  ("friendli",    "https://api.friendli.ai/serverless/v1"),
  ("google",      "https://generativelanguage.googleapis.com/v1beta/openai"),
  ("greenpt",     "https://api.greenpt.ai/v1"),
  ("groq",        "https://api.groq.com/openai/v1"),
  ("hetzner",     "https://inference.hetzner.com/api/v1"),
  ("huggingface", "https://router.huggingface.co/v1"),
  ("hyperbolic",  "https://api.hyperbolic.xyz/v1"),
  ("inceptron",   "https://api.inceptron.io/v1"),
  ("kimi",        "https://api.moonshot.ai/v1"),
  ("kimicode",    "https://api.kimi.com/coding/v1"),
  ("lyceum",      "https://api.lyceum.technology/openai/v1"),
  ("minimax",     "https://api.minimax.io/v1"),
  ("minimax-cn",  "https://api.minimaxi.com/v1"),
  ("mistral",     "https://api.mistral.ai/v1"),
  ("moonshot",    "https://api.moonshot.ai/v1"),
  ("moonshot-cn", "https://api.moonshot.cn/v1"),
  ("nanogpt",     "https://nano-gpt.com/api/v1"),
  ("nebius",      "https://api.tokenfactory.nebius.com/v1"),
  ("nvidia",      "https://integrate.api.nvidia.com/v1"),
  ("novita",      "https://api.novita.ai/openai"),
  ("openai",      "https://api.openai.com/v1"),
  ("opencode",    "https://opencode.ai/zen/v1"),
  ("opencodego",  "https://opencode.ai/zen/go/v1"),
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
  ("venice",      "https://api.venice.ai/api/v1"),
  ("xai",         "https://api.x.ai/v1"),
  ("zai",         "https://api.z.ai/api/paas/v4"),
  ("zaicode",     "https://api.z.ai/api/coding/paas/v4"),
]
  ## Skipped on purpose: `cortects.ai` is a router (an OpenAI-compatible
  ## front-end that fans out to other providers' models), so adding it
  ## here would just duplicate the underlying providers we already list.
  ## Routers belong in user config when wanted, not in the catalog.

proc catalogUrl*(name: string): string =
  when defined(providerStub):
    if name == "stub":
      return "stub://provider"
  for (n, u) in ProviderCatalog:
    if n == name: return u
  ""

const KeyPrefixCatalog*: seq[(string, string)] = @[
  ("sk-ant-",  "anthropic"),
  ("sk-or-",   "openrouter"),
  ("sk-proj-", "openai"),
  ("gsk_",     "groq"),
  ("xai-",     "xai"),
  ("pplx-",    "perplexity"),
  ("nvapi-",   "nvidia"),
  ("fw_",      "fireworks"),
  ("csk-",     "cerebras"),
  ("ir_live_", "cheaperinference"),
  ("tgp_",     "together"),
  ("AIza",     "google"),
  ("VENICE_",  "venice"),
]

proc inferProvider*(key: string): string =
  ## Returns catalog provider name, or "" if key prefix is not uniquely identifying.
  when defined(providerStub):
    if key == "stub":
      return "stub"
  for (p, n) in KeyPrefixCatalog:
    if key.startsWith(p): return n
  ""

proc defaultNameFromUrl*(url: string): string =
  let host = parseUri(url).hostname
  if host == "": return ""
  let labels = host.split('.')
  if labels.len >= 2: labels[^2]
  else: labels[0]

proc curatedFor*(provider: string): seq[string] =
  ## Full model ids from KnownGoodCombos for the given provider name.
  let p = canonicalKnownGoodProvider(provider)
  for c in KnownGoodCombos:
    if c[0].toLowerAscii == p: result.add c[1]

proc preferCurated*(provider: string, models: var seq[string]) =
  ## Rewrites entries of `models` that spell a curated known-good model
  ## with extra qualifiers to the curated wire id. Endpoints occasionally
  ## list ids they don't serve on chat/completions (kimicode listed
  ## kimi-k3-256k, then 401'd it with "set model id as k3"), and the
  ## verification ping doesn't catch it: that gateway serves unknown ids
  ## too. The known-good id is the one that actually works, so it wins.
  for m in models.mitems:
    let wire = knownGoodWireModel(provider, m)
    if wire != "": m = wire
