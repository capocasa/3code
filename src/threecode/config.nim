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
## and `:model` cycling walk the wizard-entered model order: the first model
## the user entered is the default and cycling follows config order.

import std/[options, os, parsecfg, sequtils, streams, strformat, strutils, tables, terminal, uri]
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
    currentModel*: string  ## persisted last-used model for this provider
                           ## (`current_model` in the [provider] section).
                           ## `:provider <name>` switches back to it instead
                           ## of the first wizard-entered model. Empty means
                           ## no selection recorded yet.
  ParamsRec* = object
    ## One `[params]` section: model-parameter overrides scoped to a
    ## (provider, model) pair. `model` empty means the whole provider.
    ## Fields merge across matching sections at profile-build time
    ## (`resolveParams`): provider-wide entries apply first, then
    ## model-scoped ones over them, each in file order.
    provider*, model*: string
    params*: ModelParams

func shortModel*(model: string): string =
  ## The user-visible model name: everything after the last `/`, then
  ## canonicalized. Slash-delimited authors (`openai/gpt-oss-120b`)
  ## and dash-flattened ones (`zai-glm-5-3` on mistral,
  ## `z-ai-glm-5-3-flash` on venice) reduce to the same canonical form
  ## (`glm-5.3`), so one model shows one name regardless of provider.
  ## Ids no family parses keep their slash-stripped spelling.
  let slash = model.rfind('/')
  let bare = if slash < 0: model else: model[slash + 1 .. ^1]
  normalizeModelName(bare)

proc shortToFull*(models: seq[string]): Table[string, string] =
  ## Maps each canonical short name (`shortModel`) to the full model id.
  ## When two full ids share the short name — one model under two
  ## spellings, like mistral's `glm-5-2` and `zai-glm-5-2` — only the
  ## first occurrence is kept. This mirrors the display list: the user
  ## sees each model once, picks the short name, gets the first match.
  ## If genuine ambiguity arises in the future we can promote a conflict
  ## notice here; for now silent first-wins is the right trade-off.
  for m in models:
    let s = shortModel(m)
    if s notin result:
      result[s] = m

func findModel*(p: ProviderRec, name: string): int =
  ## Matches by full model id, by canonical short name, or by normalized
  ## name. Short-name matching handles
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
var baselineCurrent*: string
  ## The `current` value as loaded from the config file at startup (before
  ## any in-session command changed it). `writeConfigFile` diffs against it
  ## to tell "this instance changed current" apart from "another instance
  ## changed current on disk" — the latter must not be clobbered.
var baselineProviders*: seq[ProviderRec]
  ## Same startup snapshot for the provider list. A provider that differs
  ## from BOTH this baseline and the in-memory list was edited by another
  ## 3code instance since startup; `writeConfigFile` keeps the disk version.
var activeParams*: seq[ParamsRec]
  ## Every `[params]` section from the active config, in file order. Kept
  ## so `writeConfigFile` can persist them and `buildProfile` can resolve
  ## the entry matching the current (provider, model).
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
  ## Windows-only. `[settings]` `bash_path = "..."` overrides bash
  ## detection in `streamexec.resolveBash` for users with bash at a
  ## non-standard location. Empty on POSIX (where /bin/sh is always used).

var bashSourcePref*: string
  ## All OS. `[settings]` `bash = "..."`: "auto" (default) keeps
  ## the normal detection order; any other value is a full path to the
  ## shell to use, overriding detection. Same shape as `bash_path`, but
  ## honored on every OS.

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
  ## Models in the order the user entered them in the provider wizard, as
  ## persisted in the config file. Completion cycling, `:model` listing and
  ## default selection all use this order; the first entry is the default
  ## when switching providers.
  prov.models

proc firstModel*(prov: ProviderRec): string =
  ## First model in wizard-entered order: the default when switching
  ## providers or booting with a model-less `current`.
  if prov.models.len > 0: prov.models[0]
  else: ""

proc rememberedModel*(prov: ProviderRec): string =
  ## The model `:provider <name>` lands on: the provider's persisted
  ## selection when it still resolves against its models list, else the
  ## first wizard-entered model. Stale entries (model since removed in an
  ## edit) fall back silently.
  if prov.currentModel != "":
    let i = prov.findModel(prov.currentModel)
    if i >= 0: return prov.models[i]
  firstModel(prov)

proc setCurrentModel*(provName, model: string) =
  ## Record `model` as `provName`'s persisted default; the next
  ## `writeConfigFile` flushes it. `model` is resolved against the
  ## provider's models list first so the config always stores a list id,
  ## never a wire spelling that only the known-good table knows.
  for i, pr in activeProviders:
    if pr.name == provName:
      let idx = pr.findModel(model)
      activeProviders[i].currentModel =
        if idx >= 0: pr.models[idx] else: model
      break

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

func dedupModels*(models: seq[string]): seq[string] =
  ## First occurrence wins, keyed on the canonical name. Providers list
  ## one model under two spellings (mistral serves `glm-5-2` and
  ## `zai-glm-5-2`); pickers and config writes want each model once.
  var seen: seq[string]
  for m in models:
    let key = normalizeModelName(m)
    if key notin seen:
      seen.add key
      result.add m

proc splitModels*(s: string): seq[string] =
  ## Whitespace- (and comma-) separated list of bare model names. Family
  ## lives elsewhere — KnownGoodCombos hardcodes it; the [provider]
  ## `family = ...` key supplies an experimental override. Twin
  ## spellings of one model collapse to the first (`glm-5-2` and
  ## `zai-glm-5-2` are the same model on mistral).
  for raw in s.splitWhitespace:
    let m = raw.strip(chars = {',', ' '})
    if m.len > 0: result.add m
  result = dedupModels(result)

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
  PermittedSections = ["settings", "search", "colors", "provider",
                       "params", "shortcuts"]
  SettingsKeys = ["current", "notify", "streaming", "sandbox",
                  "sandbox_enabled", "patient_retry", "patient-retry",
                  "sandbox_wall_warn",
                  "tone", "mode", "bash_path", "bash-path",
                  "bash", "auto_update"]
  SearchKeys = ["exa-key", "brave-key", "key", "engine"]
  ColorKeys = ["bright-white", "off-white", "dim-white", "token-bar",
               "private-bar"]
  ProviderKeys = ["name", "url", "key", "model_prefix", "family",
                  "models", "reasoning", "reasonings", "auth",
                  "current_model", "current-model"]
  ProviderParamsKeys = ["temperature", "max-tokens", "max_tokens",
                        "think-back", "think_back",
                        "context-window", "context_window",
                        "allow-private", "allow_private"]
  ParamsScopeKeys = ["provider", "model"]
  ThinkBackValues = ["none", "turn", "all"]
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
  of "params": key in ProviderParamsKeys or key in ParamsScopeKeys
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
         not (ent.section == "params" and ent.key == "model") and
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
    of "params":
      # `provider` and `model` are scope keys (plain strings, `model` may
      # be empty for a provider-wide entry); the rest carry typed values
      # checked here.
      case ent.key
      of "temperature":
        try: discard parseFloat(ent.value.strip)
        except ValueError:
          return &"{path}:{ent.line}: bad value '{ent.value}' for 'temperature' " &
                 "in [params] (expected a number like 0.4)"
      of "max-tokens", "max_tokens", "context-window", "context_window":
        try: discard parseInt(ent.value.strip)
        except ValueError:
          return &"{path}:{ent.line}: bad value '{ent.value}' for '{ent.key}' " &
                 "in [params] (expected a whole number of tokens)"
      of "think-back", "think_back":
        if ent.value.strip.toLowerAscii notin ThinkBackValues:
          return &"{path}:{ent.line}: unknown think-back mode '{ent.value}' " &
                 "(expected one of: none, turn, all)"
      of "allow-private", "allow_private":
        if ent.value.strip.toLowerAscii notin BoolValues:
          return &"{path}:{ent.line}: bad value '{ent.value}' for '{ent.key}' " &
                 "in [params] (expected on or off)"
      else: discard
    of "shortcuts":
      if ent.value.strip != "":
        try:
          discard minline.parseShortcutSpec(ent.value)
        except ValueError:
          return &"{path}:{ent.line}: invalid shortcut value '{ent.value}' for '{ent.key}'"
    else: discard
  ""

proc parseConfigFile*(path: string): (string, seq[ProviderRec], Table[string, string], Table[string, string], string, Table[string, string]) {.raises: [ValueError, IOError, OSError].} =
  ## Streaming parse so that repeated [provider] and [params] sections
  ## accumulate as lists. Returns
  ## `(current, providers, colors, searchKeys, searchEngine, shortcuts)`;
  ## the parsed `[params]` entries land in `activeParams` as a side
  ## effect (same pattern as the settings toggles above), for
  ## `buildProfile` resolution and `writeConfigFile` persistence.
  ## `searchKeys` maps engine name -> key for each `[search] exa-key` /
  ## `brave-key` set (empty table when none). A legacy bare `[search] key`
  ## is accepted and filed under the active engine for backward compat.
  ## `searchEngine` is the optional `[search] engine` value ("" when absent,
  ## meaning the default `exa`). `colors` is the flat
  ## `[colors]` map (raw keys verbatim, including any `-light` suffix); the
  ## caller routes it through `splitColorOverrides` + `applyColorOverrides`.
  ## Raises `ValueError` (message prefixed `path:line:`) on a malformed
  ## file instead of exiting: `writeConfigFile` re-parses the file
  ## mid-session to merge concurrent instances' edits, and a config that
  ## went bad on disk must surface as a caught error there, not kill the
  ## process. Startup callers (`loadStateOrEmpty`, `loadProfile`) turn the
  ## raise into the same `die` the parser used to do inline.
  var current = ""
  var searchKeys: Table[string, string]
  var searchEngine = ""
  var providers: seq[ProviderRec]
  var paramList: seq[ParamsRec]
  var colors: Table[string, string]
  var shortcuts: Table[string, string]
  var section = ""
  var prov: ProviderRec
  var inProvider = false
  var paramRec: ParamsRec
  var inParams = false
  var entries: seq[RawEntry]
  let stream = newFileStream(path, fmRead)
  if stream == nil: raise newException(ValueError, "cannot open " & path)
  var p: CfgParser
  p.open(stream, path)
  proc flushParams() =
    if inParams:
      paramList.add paramRec
      paramRec = ParamsRec()
      inParams = false
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
    of cfgEof: flush(); flushParams(); break
    of cfgSectionStart:
      flush()
      flushParams()
      section = e.section
      if section == "provider": inProvider = true
      if section == "params": inParams = true
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
        of "bash":
          bashSourcePref = v.strip.toLowerAscii
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
        of "current_model", "current-model":
          prov.currentModel = v.strip
        of "auth": prov.auth = v.strip.toLowerAscii
        else: discard
      of "params":
        # Malformed numbers land here as unset; validateConfig (run at
        # the end of this parse) rejects them with path:line before any
        # caller sees the half-parsed section.
        case e.key
        of "provider": paramRec.provider = v.strip
        of "model": paramRec.model = v.strip
        of "temperature":
          try: paramRec.params.temperature = some(parseFloat(v.strip))
          except ValueError: discard
        of "max-tokens", "max_tokens":
          try: paramRec.params.maxTokens = some(parseInt(v.strip))
          except ValueError: discard
        of "think-back", "think_back":
          paramRec.params.thinkBack = some(parseThinkBackMode(v))
        of "context-window", "context_window":
          try: paramRec.params.contextWindow = some(parseInt(v.strip))
          except ValueError: discard
        of "allow-private", "allow_private":
          case v.strip.toLowerAscii
          of "on", "true", "yes", "1": paramRec.params.allowPrivate = some(true)
          of "off", "false", "no", "0": paramRec.params.allowPrivate = some(false)
          else: discard
        else: discard
      of "shortcuts":
        shortcuts[e.key] = v
      else: discard
    of cfgError:
      raise newException(ValueError, &"{path}: {e.msg}")
  p.close
  let verr = validateConfig(path, entries)
  if verr != "": raise newException(ValueError, verr)
  # Migration: older configs only kept one global `current`. Seed the
  # active provider's per-provider selection from it so stickiness works
  # (and persists) from the very next config write, not just after the
  # user re-selects a model by hand.
  block:
    let dot = current.find('.')
    if dot > 0:
      let pname = current[0 ..< dot]
      let mname = current[dot + 1 .. ^1]
      for i, pr in providers:
        if pr.name == pname and providers[i].currentModel == "":
          let idx = pr.findModel(mname)
          if idx >= 0: providers[i].currentModel = pr.models[idx]
          break
  activeParams = paramList
  (current, providers, colors, searchKeys, searchEngine, shortcuts)

func quoteVal(s: string): string =
  result = "\""
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    else: result.add c
  result.add "\""

func sameProvider(a, b: ProviderRec): bool =
  ## Field-by-field equality (ProviderRec has no generated ==). `modelPrefix`
  ## is excluded: it is a transient read-compat field, never written back out.
  a.name == b.name and a.url == b.url and a.key == b.key and
  a.family == b.family and a.auth == b.auth and a.models == b.models and
  a.reasoning == b.reasoning and a.reasonings == b.reasonings and
  a.currentModel == b.currentModel

proc mergeForeignEdits(path: string; current: var string,
                        providers: var seq[ProviderRec]): bool =
  ## Fold edits made by other 3code instances since this one started into
  ## the values about to be written. `writeConfigFile` serializes the whole
  ## in-memory state, so a long-lived instance that writes for an
  ## unrelated reason (`:model`, `:reasoning`, ...) used to revert any
  ## edit another instance persisted in the meantime — the classic
  ## "I edited a provider and the next restart didn't see it" report.
  ##
  ## Baseline-diff, `current` and each provider, keyed by name:
  ## - unchanged since startup (matches baseline AND memory): keep memory;
  ##   if disk differs, another instance touched it — keep disk.
  ## - changed since startup (memory differs from baseline): this
  ##   instance's own edit wins; disk is stale.
  ## - on disk but not in baseline nor memory: another instance added it;
  ##   keep it.
  ## - in baseline but neither in memory nor on disk: another instance
  ##   removed it; stay removed.
  ## Returns false (and the caller skips the write) when the file exists
  ## but cannot be read or parsed: better to leave a broken-but-recoverable
  ## disk copy alone than clobber it with a parse of nothing.
  if not fileExists(path): return true
  # parseConfigFile mutates the settings globals as a side effect; the
  # re-parse here is only to see the disk state, so snapshot and
  # restore them — otherwise a toggle this instance changed in memory
  # (e.g. `:streaming off`) would be reverted by the stale disk value
  # right before the buffer serializes it.
  let (savedNotify, savedStreaming, savedSandbox, savedPatient,
       savedWallWarn, savedColorMode, savedBash, savedBashSrc) =
    (notifyEnabled, streamingEnabled, sandboxEnabled, patientRetryEnabled,
     sandboxWallWarn, colorModePref, bashPathOverride, bashSourcePref)
  let savedParams = activeParams
  let (diskCurrent, diskProviders, _, _, _, _) =
    try: parseConfigFile(path)
    except CatchableError as e:
      stderr.writeLine("3code config: WARNING: " & path &
        " is unreadable, this session's config changes are not saved: " &
        e.msg)
      return false
  notifyEnabled = savedNotify
  streamingEnabled = savedStreaming
  sandboxEnabled = savedSandbox
  patientRetryEnabled = savedPatient
  sandboxWallWarn = savedWallWarn
  colorModePref = savedColorMode
  bashPathOverride = savedBash
  bashSourcePref = savedBashSrc
  activeParams = savedParams
  # Same baseline-diff for the `current` line: an instance that never
  # switched in-session still holds the startup value, so a different
  # non-empty value on disk is another instance's switch and survives.
  if diskCurrent != "" and current == baselineCurrent:
    current = diskCurrent
  var diskByName: Table[string, ProviderRec]
  for pr in diskProviders: diskByName[pr.name] = pr
  var baselineByName: Table[string, ProviderRec]
  for pr in baselineProviders: baselineByName[pr.name] = pr
  var merged: seq[ProviderRec]
  for pr in providers:
    let base = baselineByName.getOrDefault(pr.name)
    if sameProvider(pr, base) and not diskByName.hasKey(pr.name):
      # Untouched here, removed there: stay removed.
      continue
    if sameProvider(pr, base) and diskByName.hasKey(pr.name) and
        not sameProvider(pr, diskByName[pr.name]):
      # Untouched here, edited there: keep the disk version.
      merged.add diskByName[pr.name]
    else:
      # This instance's own edit (or nobody's): memory wins.
      merged.add pr
  # Providers another instance added since startup: in neither baseline
  # nor memory, but on disk. Appended after ours, disk order among them.
  for pr in diskProviders:
    if pr.name notin baselineByName and
        not providers.anyIt(it.name == pr.name):
      merged.add pr
  providers = merged
  true

func normalizedCurrent(current: string): string =
  ## `current` may hold a wire-style model id; persist the normalized
  ## spelling. Only the model part: running the whole "provider.model"
  ## string through normalizeModelName strips everything up to the model's
  ## last `/`, which drops the provider name entirely for ids like
  ## "baseten.zai-org/GLM-4.7" and leaves an unbootable current.
  let curDot = current.find('.')
  if curDot < 0: normalizeModelName(current)
  else: current[0 .. curDot] & normalizeModelName(current[curDot + 1 .. ^1])

proc writeConfigFile*(path: string, current: string,
                     providers: seq[ProviderRec]) =
  createDir(path.parentDir)
  # Models are always persisted in normalized form; the wire ids stay
  # untouched in memory. `current` may name a model too. Twin spellings
  # of one model dedup to the first, so the file self-heals lists that
  # were written before they collapsed.
  var providers = providers
  for pr in providers.mitems:
    pr.models = dedupModels(pr.models.mapIt(normalizeModelName(it)))
  var current = current
  if not mergeForeignEdits(path, current, providers): return
  let cur = normalizedCurrent(current)
  var buf = "[settings]\n"
  buf.add "current = " & quoteVal(cur) & "\n"
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
    if pr.currentModel != "":
      buf.add "current_model = " &
        quoteVal(normalizeModelName(pr.currentModel)) & "\n"
    if pr.reasoning != "":
      buf.add "reasoning = " & quoteVal(pr.reasoning) & "\n"
    if pr.reasonings.len > 0:
      buf.add "reasonings = " & quoteVal(formatModels(pr.reasonings)) & "\n"
  for pm in activeParams:
    buf.add "\n[params]\n"
    buf.add "provider = " & quoteVal(pm.provider) & "\n"
    if pm.model != "":
      buf.add "model = " & quoteVal(pm.model) & "\n"
    if pm.params.temperature.isSome:
      buf.add "temperature = " & quoteVal($pm.params.temperature.get) & "\n"
    if pm.params.maxTokens.isSome:
      buf.add "max-tokens = " & quoteVal($pm.params.maxTokens.get) & "\n"
    if pm.params.thinkBack.isSome:
      buf.add "think-back = " & quoteVal(formatThinkBack(pm.params.thinkBack.get)) & "\n"
    if pm.params.contextWindow.isSome:
      buf.add "context-window = " & quoteVal($pm.params.contextWindow.get) & "\n"
    if pm.params.allowPrivate.isSome:
      buf.add "allow-private = " &
        quoteVal(if pm.params.allowPrivate.get: "true" else: "false") & "\n"
  # Atomic replace (temp + rename, same scheme as drafts and the dir
  # sticky-current): a crash or power-off mid-write never leaves a
  # truncated config, which would otherwise look like "no provider
  # configured" on the next start.
  let tmpPath = path & ".tmp"
  writeFile(tmpPath, buf)
  moveFile(tmpPath, path)

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

proc applyEarlySandboxSettings*(path: string) =
  ## Apply only the two `[settings]` sandbox switches (`sandbox`,
  ## `sandbox_wall_warn`) from a tolerant parse of `path`. The pre-prompt
  ## sandbox warnings print before the full `parseConfigFile` run and
  ## must respect `sandbox_wall_warn = off` on the first print; the full
  ## parse later in startup re-applies everything authoritatively. A
  ## missing or malformed file stays silent here: the full parse owns
  ## the loud error.
  if not fileExists(path): return
  let stream = newFileStream(path, fmRead)
  if stream == nil: return
  var p: CfgParser
  p.open(stream, path)
  var section = ""
  while true:
    var e: CfgEvent
    try: e = p.next
    except CatchableError: break
    case e.kind
    of cfgEof: break
    of cfgSectionStart: section = e.section
    of cfgKeyValuePair, cfgOption:
      if section != "settings": continue
      let v = expandEnvValue(e.value).toLowerAscii
      case e.key
      of "sandbox", "sandbox_enabled":
        case v
        of "on", "true", "yes", "1": sandboxEnabled = true
        of "off", "false", "no", "0": sandboxEnabled = false
        else: discard
      of "sandbox_wall_warn":
        case v
        of "on", "true", "yes", "1": sandboxWallWarn = true
        of "off", "false", "no", "0": sandboxWallWarn = false
        else: discard
      else: discard
    else: discard
  # The handle must be closed, not left to the GC's finalizer: an open
  # FileStream holds the config without FILE_SHARE_DELETE, so the atomic
  # replace in `writeConfigFile` (moveFile over the live path) fails with
  # Access Denied on Windows and kills the process through the unhandled
  # OSError. The finalizer never ran in a short session.
  p.close()

proc loadStateOrEmpty*(path: string): (string, seq[ProviderRec], Table[string, string]) =
  ## Returns `(current, providers, colors)` and updates `activeSearchKey` /
  ## `activeSearchEngine` / `activeSearchKeys` / `activeShortcuts` as a side
  ## effect when the config sets them. `colors` is the flat `[colors]` map
  ## for the caller to route through the cascade. Missing file is benign.
  ## Also records the startup baseline (`baselineCurrent` /
  ## `baselineProviders`) that `writeConfigFile` diffs against to keep
  ## concurrent instances from clobbering each other's edits.
  if not fileExists(path):
    baselineCurrent = ""
    baselineProviders = @[]
    return ("", @[], initTable[string, string]())
  let (current, providers, colors, searchKeys, searchEngine, shortcuts) =
    try: parseConfigFile(path)
    except ValueError as e: die e.msg, ExitConfig
  baselineCurrent = current
  baselineProviders = providers
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

func paramsModelMatches*(spec, model: string): bool =
  ## Same lenient matching as `ProviderRec.findModel`: exact id, short
  ## name (after the last `/`), or normalized spelling. Lets a `[params]`
  ## section say `model = "glm-5.2"` against any wire spelling of it.
  spec == model or shortModel(spec) == shortModel(model) or
    normalizeModelName(spec) == normalizeModelName(model)

proc patchParams(dst: var ModelParams, src: ModelParams) =
  ## Merge the fields `src` sets onto `dst`; unset fields pass through.
  if src.temperature.isSome: dst.temperature = src.temperature
  if src.maxTokens.isSome: dst.maxTokens = src.maxTokens
  if src.thinkBack.isSome: dst.thinkBack = src.thinkBack
  if src.contextWindow.isSome: dst.contextWindow = src.contextWindow
  if src.allowPrivate.isSome: dst.allowPrivate = src.allowPrivate

proc resolveParams*(list: seq[ParamsRec], provider, model: string): ModelParams =
  ## The `[params]` settings that govern this (provider, model), merged
  ## per field: provider-wide entries (`model` empty) apply first, then
  ## model-scoped ones over them, each pass in file order so a later
  ## section wins. A field no matching section sets stays none, which
  ## every lookup treats as "not configured".
  for pass in 0 .. 1:
    for e in list:
      if e.provider != provider: continue
      if pass == 0 and e.model != "": continue
      if pass == 1 and (e.model == "" or
                        not paramsModelMatches(e.model, model)): continue
      patchParams(result, e.params)

proc privateAllowed*(p: Profile): bool =
  ## May this profile run under private mode? An explicit `[params]
  ## allow-private` wins (either way, so `allow-private = false` can also
  ## revoke a curated provider); otherwise the known-good table's curated
  ## flag decides; otherwise false. Empty profiles return true; the
  ## no-provider case has its own bail-out path.
  if p.name == "": return true
  if p.params.allowPrivate.isSome: return p.params.allowPrivate.get
  let dot = p.name.find('.')
  if dot < 0: return false
  knownGoodAllowsPrivate(p.name[0 ..< dot], p.model)

proc privateGateText*(p: Profile): string =
  ## The private-gate refusal. Magenta styling is applied by the caller's
  ## err path (same convention as `experimentalGateText`).
  let dot = p.name.find('.')
  let provider = if dot < 0: p.name else: p.name[0 ..< dot]
  p.name & " is not allow-private (trust it with :private allow " &
    provider & ", or switch to a zero-training provider; :private lists)"

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
      prof.params = resolveParams(activeParams, pr.name, fullModel)
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
  let (current, providers, _, searchKeys, searchEngine, shortcuts) =
    try: parseConfigFile(path)
    except ValueError as e: die e.msg, ExitConfig
  # Single-shot runs (`3code -p ...`, subcommands) go through here instead
  # of loadStateOrEmpty; arm the same merge baseline so their writes don't
  # clobber concurrent edits either.
  baselineCurrent = current
  baselineProviders = providers
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
  prof.params = resolveParams(activeParams, prov.name, fullModel)
  prof

const ProviderCatalog*: seq[(string, string)] = @[
  ("aki",         "https://aki.io/openai/v1"),
  ("anthropic",   "https://api.anthropic.com/v1"),
  ("arcee",       "https://conductor.arcee.ai/v1"),
  ("baseten",     "https://inference.baseten.co/v1"),
  ("cerebras",    "https://api.cerebras.ai/v1"),
  ("cheaperinference", "https://api.cheaperinference.com/v1"),
  ("commandcode", "https://api.commandcode.ai/provider/v1"),
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
  # ("mistralvibe", "https://api.mistral.ai/v1"),  # parked: the Vibe
  # plan shares the one Mistral API key, so plain `mistral` covers it
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
  ("tencent",     "https://tokenhub-intl.tencentcloudmaas.com/v1"),
  ("together",    "https://api.together.xyz/v1"),
  ("together-eu", "https://eu.api.together.xyz/v1"),
  ("venice",      "https://api.venice.ai/api/v1"),
  ("xai",         "https://api.x.ai/v1"),
  ("xiaomi",      "https://api.xiaomimimo.com/v1"),
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

proc looksLikeZaiKey*(s: string): bool =
  ## z.ai keys are ``{id}.{secret}`` with hex halves and no stable prefix,
  ## so the prefix catalog cannot catch them. Shape match instead.
  let dot = s.find('.')
  if dot < 8 or s.len - dot - 1 < 8: return false
  if s.count('.') != 1: return false
  for c in s:
    if c notin {'0'..'9', 'a'..'f', 'A'..'F', '.'}: return false
  true

proc inferProvider*(key: string): string =
  ## Returns catalog provider name, or "" if key prefix is not uniquely identifying.
  when defined(providerStub):
    if key == "stub":
      return "stub"
  for (p, n) in KeyPrefixCatalog:
    if key.startsWith(p): return n
  if looksLikeZaiKey(key): return "zaicode"
  ""

proc looksLikeApiKey*(s: string): bool =
  ## Long single-token entry: a secret whose prefix nobody recognizes
  ## rather than a provider name (short words). Routes the wizard's first
  ## field to the provider-for-key prompt instead of an error.
  if s.len < 16: return false
  for c in s:
    if c in Whitespace: return false
  true

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
