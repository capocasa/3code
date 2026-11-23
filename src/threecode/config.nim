## Config file parsing and provider/profile resolution.
##
## The config file is a sequence of `[provider]` sections and an optional
## `[settings]` section (see `docs/config.example` for the
## format). `parseConfigFile` turns it into a list of `ProviderRec` values;
## `buildProfile` resolves a provider.model string to a `Profile` ready for
## API calls.
##
## Known-good validation lives here: a profile must correspond to a
## `KnownGoodCombos` entry unless `experimentalEnabled` is true. Tab-completion
## and `:model` cycling walk the wizard-entered model order: the first model
## the user entered is the default and cycling follows config order.

import std/[options, os, parsecfg, sequtils, sets, streams, strformat, strutils, tables, terminal, uri]
from algorithm import sorted
import plugins
when defined(posix):
  import std/posix except SocketHandle
when defined(windows):
  import std/winlean
import types, prompts, util, auth_openai, modelname, minline
import dirsettings
import runtime

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
var providerOrigins*: Table[string, seq[string]]
  ## Provider name -> every layer file that defined it, in read order
  ## (the last entry defined the version in `activeProviders`).
  ## `writeConfigFile` consults this so a definition that came ONLY from
  ## a non-target layer (a lower `-c` file, the project layer) is never
  ## copied into the write target; a name the target itself defines
  ## keeps its own entry there, and names missing from the table are
  ## in-session additions. Populated by the layered read
  ## (`tryLoadStateLayers`); empty in single-file loads, which filter
  ## nothing.
var activeParams*: seq[ParamsRec]
  ## Every `[params]` section from the active config, in file order. Kept
  ## so `writeConfigFile` can persist them and `buildProfile` can resolve
  ## the entry matching the current (provider, model).
var activeConfigWarnings*: seq[string]
  ## Unknown-key notices from the last `parseConfigFile` run. Startup
  ## callers print them once; the mid-session re-parse in `writeConfigFile`
  ## refreshes them silently — repeating the same file's warning under the
  ## live TUI would be noise, not news.
var activeSearchKey*: string = ""
  ## The key for the *active* search engine, resolved at config load from
  ## the engine-specific `[search] exa-key` / `brave-key`. Keyless by
  ## default: exa and parallel work without a key, brave requires one.

var activeSearchKeys*: Table[string, string]
  ## All configured search keys, keyed by engine name (`exa`, `brave`).
  ## Mirrors what was read from `[search] exa-key` / `brave-key`. The
  ## `activeSearchKey` is derived from this for the active engine; this map
  ## is kept so a future engine switch doesn't require a config re-read.

var activeSearchEngine*: string = "exa"
  ## Active search engine: "exa" (default), "parallel", or "brave". Set via
  ## `[search] engine = "..."`. No automatic failover — the chosen engine is
  ## used as-is, and a missing key is an error only if that engine needs one
  ## (brave does; exa and parallel are keyless by default).

var activeShortcuts*: Table[string, string]
  ## [shortcuts] map loaded from the active config, exposed so minline can
  ## apply the user's bindings at startup and after config reloads.

var activeExtraConf*: seq[tuple[section, key, value: string]]
  ## Raw lines of the runtime knobs — the `[test]` harness section and
  ## the `[settings]`/`[plugins]` keys `runtime.nim` consumes — exactly as
  ## the config file carried them. `writeConfigFile` round-trips them so a
  ## mid-session write does not silently drop the harness's frame
  ## handshake or a user's `allow_root` line; nothing in the session
  ## mutates them.

proc stashRuntime(section, key, value: string) =
  ## Feed one config line into the runtime store and the round-trip
  ## capture. `[plugins]` keys get a `plugin_` prefix in the store so
  ## they cannot collide with a same-named `[settings]` key.
  runtime.put(if section == "plugins": "plugin_" & key else: key, value)
  activeExtraConf.add (section, key, value)

var bashPathOverride*: string
  ## Windows-only. `[settings]` `bash_path = "..."` overrides bash
  ## detection in `streamexec.resolveBash` for users with bash at a
  ## non-standard location. Empty on POSIX (where the login shell,
  ## then bash, then zsh is used; there is no sh fallback — shPath
  ## halts when none is found).

var bashSourcePref*: string
  ## All OS. `[settings]` `bash = "..."`: "auto" (default) keeps
  ## the normal detection order; any other value is a full path to the
  ## shell to use, overriding detection. Same shape as `bash_path`, but
  ## honored on every OS.

var userSettingsRaw* = initTable[string, string]()
  ## The user config's own `[settings]` lines, canonical key -> raw
  ## value as written (pre env-expansion), captured by the last
  ## `parseConfigFile` run. `writeConfigFile` consults these while a
  ## directory store overlay is in effect (`storeOverlayKeys`) so a
  ## store's value is never serialized into the user config; absent
  ## means the compiled default, and the line is simply omitted.

var storeOverlayKeys* = initHashSet[string]()
  ## Canonical `[settings]` keys a directory store overlay currently
  ## supplies (see `applyDirSettingsOverlay`). While a key is in here
  ## its effective value came from a store, not the user config;
  ## `writeConfigFile` persists the `userSettingsRaw` line instead.
  ## An in-session setting command removes its key via `claimSetting`:
  ## the user just spoke, and this session's write must record it.

var verifierExplicitSeen* = false
  ## True once a `verifier = on|off` line was applied this parse (from
  ## the user config or a store overlay): a selected `verifier_model`
  ## defaults to enabled, and only an explicit `verifier` line may say
  ## otherwise. The parse-time twin of parseConfigFile's old local.

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
    let fdText = runtime.get("frame_fd")
    if fdText.len > 0:
      try:
        let fd = cint(parseInt(fdText))
        var ch = 'f'
        discard posix.write(fd, addr ch, 1)
        let ackText = runtime.get("frame_ack_fd")
        if ackText.len > 0:
          let ackFd = cint(parseInt(ackText))
          var ack: array[1, char]
          discard posix.read(ackFd, addr ack[0], 1)
      except CatchableError:
        discard
  elif defined(windows):
    # Same handshake on named pipes; see turns.nim's twin.
    let hText = runtime.get("frame_fd")
    if hText.len > 0:
      try:
        let h = openTestPipe(hText, childWrites = true)
        var ch = 'f'
        var written: int32 = 0
        discard writeFile(h, addr ch, 1, addr written, nil)
        let ackText = runtime.get("frame_ack_fd")
        if ackText.len > 0:
          let ackH = openTestPipe(ackText, childWrites = false)
          var ack: array[1, char]
          var got: int32 = 0
          discard readFile(ackH, addr ack[0], 1, addr got, nil)
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
  ## when switching providers. Verification-class models never appear:
  ## decision models cannot run a turn, so ordinary lists skip them
  ## (`:verifier` is their only surface).
  for m in prov.models:
    if isDecisionModel(m): continue
    result.add m

proc firstModel*(prov: ProviderRec): string =
  ## First model in wizard-entered order: the default when switching
  ## providers or booting with a model-less `current`. Decision models
  ## are skipped (see `orderedModels`): the default must be a model that
  ## can actually run a turn.
  let m = orderedModels(prov)
  if m.len > 0: m[0] else: ""

proc rememberedModel*(prov: ProviderRec): string =
  ## The model `:provider <name>` lands on: the provider's persisted
  ## selection when it still resolves against its models list, else the
  ## first wizard-entered model. Stale entries (model since removed in an
  ## edit) fall back silently — and so does a remembered decision model,
  ## which is verifier-only and cannot carry ordinary turns.
  if prov.currentModel != "":
    let i = prov.findModel(prov.currentModel)
    if i >= 0 and not isDecisionModel(prov.models[i]):
      return prov.models[i]
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

proc providerAllowed*(name: string): bool =
  ## Whether `name` may run turns in this session: always true while
  ## `limitproviders` is empty (the default), else exact membership.
  ## Gates profile resolution, `:provider`/`:model` picks, completion
  ## and the verifier pool — never the provider management verbs.
  providerWhitelist.len == 0 or name in providerWhitelist

proc selectableProviders*(): seq[ProviderRec] =
  ## `activeProviders` narrowed to the `limitproviders` whitelist: the
  ## list every pick surface offers. Management ops (`:provider
  ## add|edit|rm`, the CLI, config writes) keep the full list, so a
  ## limited directory never loses the providers it cannot run.
  if providerWhitelist.len == 0: return activeProviders
  for pr in activeProviders:
    if providerAllowed(pr.name): result.add pr

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

func canonicalSettingsKey*(key: string): string =
  ## The one spelling per `[settings]` key: aliases (`sandbox_enabled`,
  ## `max-timeout`, the legacy `mode`) collapse onto the canonical form
  ## so overlay bookkeeping (`userSettingsRaw`, `storeOverlayKeys`)
  ## cannot be split by a spelling choice, whatever file wrote it.
  case key
  of "sandbox_enabled": "sandbox"
  of "patient-retry": "patient_retry"
  of "max-timeout": "max_timeout"
  of "force-timeout": "force_timeout"
  of "banner-lines": "banner_lines"
  of "verifier-model": "verifier_model"
  of "bash-path": "bash_path"
  of "allow_empty_prompt": "allow-empty-prompt"
  of "system_command_prefixes": "system-command-prefixes"
  of "user-agent": "user_agent"
  of "limit-providers", "limit_providers": "limitproviders"
  of "mode": "tone"
  else: key

proc applySettingsValue*(key, raw: string) =
  ## Apply one `[settings]` key/value to the process globals — the single
  ## dialect shared by `parseConfigFile`, the plugin-default bootstrap and
  ## the directory store overlay (`applyDirSettingsOverlay`), so every
  ## source behaves identically. `raw` is the value as written. Two keys
  ## are owned elsewhere and not handled here: `current` (a profile pointer each
  ## caller resolves its own way) and `dirconfig` (store placement is a
  ## user-config decision alone — a store can never relocate the stores,
  ## or it would grant itself authority).
  let v = raw
  case key
  of "notify":
    case v.toLowerAscii
    of "on", "true", "yes", "1": notifyEnabled = true
    of "off", "false", "no", "0": notifyEnabled = false
    else: discard
  of "tab-title":
    # Same boolean dialect as `notify`. Default on; an explicit `off`
    # keeps 3code off the terminal tab title entirely.
    case v.toLowerAscii
    of "on", "true", "yes", "1": tabTitleEnabled = true
    of "off", "false", "no", "0": tabTitleEnabled = false
    else: discard
  of "streaming":
    # Same boolean dialect as `notify`. Default is on (set in types.nim);
    # an explicit `off` opts into the reliable request/response path.
    case v.toLowerAscii
    of "on", "true", "yes", "1": streamingEnabled = true
    of "off", "false", "no", "0": streamingEnabled = false
    else: discard
  of "verifier":
    # Explicit enable/disable of the selected verifier model. Absent
    # means "on while a model is selected" so the common config
    # carries only the selection.
    verifierExplicitSeen = true
    case v.toLowerAscii
    of "on", "true", "yes", "1": verifierEnabled = true
    of "off", "false", "no", "0": verifierEnabled = false
    else: discard
  of "verifier_model", "verifier-model":
    if v.strip != "": verifierModelSpec = v.strip
  of "sandbox", "sandbox_enabled":
    # Same boolean dialect as `notify`/`streaming`. Default on; an
    # explicit `off` disables sandbox enforcement entirely (bash runs
    # unconfined, in-process checks pass through).
    case v.toLowerAscii
    of "on", "true", "yes", "1": sandboxEnabled = true
    of "off", "false", "no", "0": sandboxEnabled = false
    else: discard
  of "computer":
    # Same boolean dialect. Session-scoped in spirit: this line exists
    # so tests and scripted runs can arm computer use; the :computer
    # toggle never writes it back. Inert unless compiled with
    # -d:computerUse (computerUseBuild, the release kill-switch).
    case v.toLowerAscii
    of "on", "true", "yes", "1":
      if computerUseBuild: computerUseEnabled = true
    of "off", "false", "no", "0": computerUseEnabled = false
    else: discard
  of "allow-empty-prompt", "allow_empty_prompt":
    # Same boolean dialect. Default on; an explicit `off` makes an
    # empty submit a no-op again (the pre-continuation behavior).
    case v.toLowerAscii
    of "on", "true", "yes", "1": allowEmptyPromptEnabled = true
    of "off", "false", "no", "0": allowEmptyPromptEnabled = false
    else: discard
  of "patient_retry", "patient-retry":
    # Same boolean dialect. Default on; an explicit `off` makes
    # retryable failures surface after the initial ramp-up (~1min)
    # instead of entering the long patient hold.
    case v.toLowerAscii
    of "on", "true", "yes", "1": patientRetryEnabled = true
    of "off", "false", "no", "0": patientRetryEnabled = false
    else: discard
  of "browserfetch":
    # Same boolean dialect, default off (types.nim): opting in keeps
    # a shared headless Chrome around for JS-shell web fetches.
    # Inert unless compiled with -d:browserFetch
    # (browserFetchBuild, the kill-switch).
    case v.toLowerAscii
    of "on", "true", "yes", "1":
      if browserFetchBuild: browserFetchEnabled = true
    of "off", "false", "no", "0": browserFetchEnabled = false
    else: discard
  of "sandbox_wall_warn":
    # Silences only the Windows "wall not set up" warning; the
    # fence itself is unaffected.
    case v.toLowerAscii
    of "on", "true", "yes", "1": sandboxWallWarn = true
    of "off", "false", "no", "0": sandboxWallWarn = false
    else: discard
  of "max_timeout", "max-timeout":
    # Whole seconds. Schema validation already rejected non-numbers,
    # so a parse failure here is unreachable in practice.
    try: maxTimeoutSetting = v.strip.parseInt
    except ValueError: discard
  of "force_timeout", "force-timeout":
    try: forceTimeoutSetting = v.strip.parseInt
    except ValueError: discard
  of "banner_lines", "banner-lines":
    try: bannerLinesSetting = v.strip.parseInt
    except ValueError: discard
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
  of "user_agent", "user-agent":
    # The `$vars` in the template belong to modelUserAgent's expansion,
    # not to any environment lookup.
    userAgentTemplate = raw
  of "system-command-prefixes", "system_command_prefixes":
    # Each non-whitespace character is one prefix; assignment (not
    # accumulation), so a later line replaces the inherited set.
    # An empty value is a schema error validateConfig reports with
    # path:line; keep the last good set here so a broken line
    # cannot strip command entry mid-parse.
    let norm = normalizeCommandPrefixes(v)
    if norm != "": commandPrefixes = norm
  of "limitproviders", "limit-providers", "limit_providers":
    # Comma- (or whitespace-) separated provider names; assignment, not
    # accumulation. Any name is legal — a whitelist may pre-list a
    # provider before it is configured. Empty value means no limit and
    # is a schema error (validateConfig), reached here only via a
    # plugin default.
    providerWhitelist = @[]
    for part in v.split({',', ' ', '\t'}):
      let n = part.strip
      if n.len > 0: providerWhitelist.add n
  of "allow_root", "trace_file", "debug_log", "force_sync_output",
     "termdbg", "ask_timeout_ms", "google_project":
    # Runtime knobs served by the runtime.nim store. Applied here, never
    # recorded: only `parseConfigFile` captures the file's own line for
    # the `writeConfigFile` round-trip, so a store overlay's value can
    # cascade into the store without leaking into the user config.
    runtime.put(key, v)
  else: discard

type
  RawEntry* = tuple[section, key, value: string, line: int]
    ## A key/value pair as written, with the line it
    ## appeared on. Collected during the streaming parse so `validateConfig`
    ## can report `path:line:` for a bad section/key/value without re-reading.

const
  PermittedSections = ["settings", "search", "colors", "provider",
                       "params", "shortcuts", "plugins", "test"]
  SettingsKeys = ["current", "notify", "streaming", "sandbox",
                  "sandbox_enabled", "patient_retry", "patient-retry",
                  "sandbox_wall_warn", "max_timeout", "max-timeout",
                  "force_timeout", "force-timeout",
                  "banner_lines", "banner-lines",
                  "browserfetch",
                  "tone", "mode", "bash_path", "bash-path",
                  "bash", "auto-update", "tab-title",
                  "allow-empty-prompt", "allow_empty_prompt",
                  "verifier", "verifier_model", "verifier-model",
                  "computer", "user_agent", "user-agent",
                  "dirconfig",
                  "system-command-prefixes", "system_command_prefixes",
                  "limitproviders", "limit-providers",
                  "limit_providers",
                  "allow_root", "trace_file", "debug_log",
                  "force_sync_output", "termdbg", "ask_timeout_ms",
                  "google_project"]
  SearchKeys = ["exa-key", "brave-key", "key", "engine"]
  ColorKeys = ["bright-white", "off-white", "dim-white", "token-bar",
               "private-bar"]
  ProviderKeys = ["name", "url", "key", "model_prefix", "family",
                  "models", "reasoning", "reasonings", "auth",
                  "current_model", "current-model"]
  ProviderParamsKeys = ["temperature", "max-tokens", "max_tokens",
                        "think-back", "think_back",
                        "context-window", "context_window",
                        "allow-private", "allow_private", "vision"]
  ParamsScopeKeys = ["provider", "model"]
  PluginKeys = ["disable", "tools", "debug", "lib", "sync_ms", "tool_ms"]
  TestKeys = ["frame_fd", "frame_ack_fd", "ticker_fd", "ticker_ack_fd",
              "api_continue_fd", "gui_live", "stub_responses",
              "http_stub_responses", "stub_sandbox",
              "stub_verify_delay_ms", "screenshot_src", "geometry_audit"]
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
  of "plugins": key in PluginKeys
  of "test": key in TestKeys
  of "shortcuts": key in minline.ShortcutNames
  else: false

proc validateConfig*(path: string; entries: seq[RawEntry]): string =
  ## Reject unknown sections, bad enum values, and empty values. Returns
  ## the first violation as a `path:line:` message, or "" when the config
  ## is schema-clean. The caller decides how to surface it
  ## (`parseConfigFile` passes it to `die` with `ExitConfig`). Unknown keys
  ## are NOT violations: they are skipped here and reported as warnings by
  ## `configWarnings`, so a config written by a newer 3code still boots.
  ## Empty `current`/`key`/`url`/`models` are tolerated here — those are
  ## structural gaps `loadProfile` already diagnoses with its own messages;
  ## this pass is about the schema, not provider completeness.
  for ent in entries:
    if ent.section notin PermittedSections:
      return &"{path}:{ent.line}: unknown section [{ent.section}]"
    if not permittedKey(ent.section, ent.key):
      # Warned-and-ignored (see configWarnings); skipping also keeps the
      # empty-value/value checks below off keys nothing reads anyway.
      continue
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
    of "plugins":
      if ent.key in ["tools", "debug"] and
          ent.value.strip.toLowerAscii notin BoolValues:
        return &"{path}:{ent.line}: bad value '{ent.value}' for '{ent.key}' " &
               "(expected on/off/true/false/yes/no/1/0)"
    of "settings":
      if ent.key in ["notify", "streaming", "sandbox", "sandbox_enabled",
                      "patient_retry", "patient-retry",
          "sandbox_wall_warn", "auto-update", "tab-title", "verifier",
          "allow-empty-prompt", "allow_empty_prompt"] and
          ent.value.strip.toLowerAscii notin BoolValues:
        return &"{path}:{ent.line}: bad value '{ent.value}' for '{ent.key}' " &
               "(expected on/off/true/false/yes/no/1/0)"
      if ent.key in ["verifier_model", "verifier-model"]:
        let v = ent.value.strip
        let dot = v.find('.')
        if dot <= 0 or dot == v.len - 1:
          return &"{path}:{ent.line}: bad value '{v}' for '{ent.key}' " &
                 "in [settings] (expected provider.model, e.g. " &
                 "openrouter.typesafe/jev-latest)"
      if ent.key in ["max_timeout", "max-timeout",
                     "force_timeout", "force-timeout"]:
        try: discard parseInt(ent.value.strip)
        except ValueError:
          return &"{path}:{ent.line}: bad value '{ent.value}' for '{ent.key}' " &
                 "in [settings] (expected a whole number of seconds)"
      if ent.key in ["banner_lines", "banner-lines"]:
        try:
          if parseInt(ent.value.strip) < 1:
            raise newException(ValueError, "")
        except ValueError:
          return &"{path}:{ent.line}: bad value '{ent.value}' for '{ent.key}' " &
                 "in [settings] (expected a whole number of lines, 1 or more)"
      if ent.key in ["tone", "mode"] and
          ent.value.strip.toLowerAscii notin ColorModes:
        return &"{path}:{ent.line}: unknown tone '{ent.value}' " &
               "(expected one of: auto, dark, light)"
      if ent.key == "dirconfig" and
          ent.value.strip.toLowerAscii notin DirConfigValues:
        return &"{path}:{ent.line}: bad value '{ent.value}' for 'dirconfig' " &
               "in [settings] (expected one of: project, user)"
      if ent.key == "ask_timeout_ms":
        try: discard parseInt(ent.value.strip)
        except ValueError:
          return &"{path}:{ent.line}: bad value '{ent.value}' for '{ent.key}' " &
                 "(expected a whole number of milliseconds)"
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
      of "allow-private", "allow_private", "vision":
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

proc configWarnings*(path: string; entries: seq[RawEntry]): seq[string] =
  ## Every unknown key in a known section, as `path:line:` lines. These are
  ## warnings, not errors: each key is ignored and the rest of the config
  ## loads. Unknown sections stay fatal (`validateConfig`). Collected per
  ## `parseConfigFile` run into `activeConfigWarnings`; startup callers
  ## print them once.
  for ent in entries:
    if ent.section in PermittedSections and
        not permittedKey(ent.section, ent.key):
      result.add &"{path}:{ent.line}: unknown key '{ent.key}' in [{ent.section}] (ignored)"

proc applyPluginConfigDefaults() =
  ## Set every `[settings]` global a plugin registered a default for,
  ## immediately before the user's own entries parse over them. The
  ## precedence ladder is: compiled default < plugin default < the
  ## user's config line < a CLI flag (flags apply after every parse).
  ## Called at every parse start, so the mid-session re-parse in
  ## writeConfigFile lands on the same values the session started with.
  ## Key set and value dialect mirror plugins.nim's registration-time
  ## validation (pluginDefaultCheck); a key that slips past one side is
  ## ignored by the other, never fatal.
  for d in plugins.pluginConfigDefaultsAll():
    if d.section != "settings": continue
    let v = d.value.strip
    case d.key
    of "notify": notifyEnabled = v.toLowerAscii in ["on", "true", "yes", "1"]
    of "streaming": streamingEnabled = v.toLowerAscii in ["on", "true", "yes", "1"]
    of "sandbox", "sandbox_enabled":
      sandboxEnabled = v.toLowerAscii in ["on", "true", "yes", "1"]
    of "patient_retry", "patient-retry":
      patientRetryEnabled = v.toLowerAscii in ["on", "true", "yes", "1"]
    of "sandbox_wall_warn":
      sandboxWallWarn = v.toLowerAscii in ["on", "true", "yes", "1"]
    of "browserfetch":
      browserFetchEnabled = v.toLowerAscii in ["on", "true", "yes", "1"]
    of "allow-empty-prompt", "allow_empty_prompt":
      allowEmptyPromptEnabled = v.toLowerAscii in ["on", "true", "yes", "1"]
    of "tab-title":
      tabTitleEnabled = v.toLowerAscii in ["on", "true", "yes", "1"]
    of "computer":
      if computerUseBuild:
        computerUseEnabled = v.toLowerAscii in ["on", "true", "yes", "1"]
    of "max_timeout", "max-timeout":
      try: maxTimeoutSetting = v.parseInt
      except ValueError: discard
    of "force_timeout", "force-timeout":
      try: forceTimeoutSetting = v.parseInt
      except ValueError: discard
    of "banner_lines", "banner-lines":
      try: bannerLinesSetting = v.parseInt
      except ValueError: discard
    of "tone", "mode":
      case v.toLowerAscii
      of "auto": colorModePref = cmAuto
      of "dark": colorModePref = cmDark
      of "light": colorModePref = cmLight
      else: discard
    of "bash": bashSourcePref = v
    of "bash_path", "bash-path": bashPathOverride = v
    of "user_agent", "user-agent": userAgentTemplate = v
    else: discard

proc parseConfigFile*(path: string, isProjectStore = false): (string, seq[ProviderRec], Table[string, string], Table[string, string], string, Table[string, string]) {.raises: [ValueError, IOError, OSError].} =
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
  ##
  ## `isProjectStore` marks the discovered `.3code/config` layer: its
  ## security switches (`sandbox`, `sandbox_wall_warn`) and `dirconfig`
  ## are NOT applied here. That file is repository-controlled, and those
  ## keys belong to `dirsettings.applyDirConfig`, the monotonic overlay
  ## that lets a project store tighten security but never weaken it (and
  ## never relocate the stores). Everything else in the file layers
  ## normally.
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
  verifierExplicitSeen = false
  # Reset every overlay-sourceable global the file may not carry, so a
  # re-parse cannot inherit a store overlay's value as if the user had
  # set it (the overlay re-applies its own keys afterwards).
  providerWhitelist = @[]
  userSettingsRaw.clear()
  activeExtraConf = @[]
  applyPluginConfigDefaults()
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
         prov.name.toLowerAscii in
           ["supergrok", "chatgpt", "claudecode", "geminicli"]:
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
      let v = e.value
      case section
      of "colors":
        colors[e.key] = v
      of "plugins":
        case e.key
        of "disable":
          pluginsDisabledNames = @[]
          for part in v.split(','):
            let n = part.strip
            if n.len > 0: pluginsDisabledNames.add n
        of "tools":
          case v.toLowerAscii
          of "on", "true", "yes", "1": pluginsToolsEnabled = true
          of "off", "false", "no", "0": pluginsToolsEnabled = false
          else: discard
        of "debug":
          case v.toLowerAscii
          of "on", "true", "yes", "1": pluginTraceOn = true
          of "off", "false", "no", "0": pluginTraceOn = false
          else: discard
        of "lib":
          pluginsLibOverride = v
        of "sync_ms", "tool_ms":
          stashRuntime("plugins", e.key, v)
        else: discard
      of "settings":
        # Shared dialect with the plugin defaults and the directory store
        # overlay (applySettingsValue); `current` and `dirconfig` are the
        # two keys with caller-specific owners and are applied inline.
        # The raw line is recorded (canonical key) so writeConfigFile can
        # serialize the user config's own value while a store overlay is
        # in effect.
        case e.key
        of "current": current = v
        of "dirconfig":
          # A repository-controlled file may not relocate the stores:
          # authority over which files are user-owned follows this
          # switch, so only the user config (or an explicit -c layer)
          # may set it.
          if not isProjectStore:
            let dv = v.strip.toLowerAscii
            if dv in DirConfigValues: dirsettings.dirConfigLocation = dv
        # Runtime knobs ride the runtime.nim store; the file's own line
        # is captured for the writeConfigFile round-trip (a store
        # overlay's value cascades through applySettingsValue without
        # being captured, so it never leaks into the user config).
        # `allow_root` is the one authority-bearing knob: a
        # repository-controlled project layer may not silence the root
        # refusal, the same authority rule `sandbox` follows below.
        of "allow_root":
          if not isProjectStore: stashRuntime("settings", e.key, v)
        of "trace_file", "debug_log", "force_sync_output",
           "termdbg", "ask_timeout_ms", "google_project":
          stashRuntime("settings", e.key, v)
        # The project layer's security switches belong to
        # dirsettings.applyDirConfig, the monotonic clamp (a repo store
        # may tighten, never weaken): applying them here would let a
        # repository-controlled file weaken an enabled sandbox.
        of "sandbox", "sandbox_enabled", "sandbox_wall_warn":
          if not isProjectStore:
            userSettingsRaw[canonicalSettingsKey(e.key)] = e.value
            applySettingsValue(e.key, e.value)
        else:
          userSettingsRaw[canonicalSettingsKey(e.key)] = e.value
          applySettingsValue(e.key, e.value)
      of "test":
        # Harness hooks (see runtime.nim). Values ride verbatim: the fd
        # keys are integers on POSIX and pipe names on Windows.
        stashRuntime("test", e.key, v)
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
        of "vision":
          case v.strip.toLowerAscii
          of "on", "true", "yes", "1": paramRec.params.vision = some(true)
          of "off", "false", "no", "0": paramRec.params.vision = some(false)
          else: discard
        else: discard
      of "shortcuts":
        # Unknown command names are dropped (configWarnings reports them):
        # `applyShortcuts` merges whatever lands here into the dispatch
        # tables, and a bogus command bound to a real key spec would
        # shadow the genuine binding on that key.
        if e.key in minline.ShortcutNames: shortcuts[e.key] = v
      else: discard
    of cfgError:
      raise newException(ValueError, &"{path}: {e.msg}")
  p.close
  # A selected verifier model is an enabled one unless the file says
  # otherwise explicitly (`verifier = off`), whatever the key order.
  if verifierModelSpec != "" and not verifierExplicitSeen:
    verifierEnabled = true
  activeConfigWarnings = configWarnings(path, entries)
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

proc buildProfile*(current: string, providers: seq[ProviderRec],
                   wanted: string): Profile
  ## Forward decl: the floor-keep check below resolves the disk current
  ## through the same path a startup boot would.

proc mergeForeignEdits(path: string; current: var string,
                        providers: var seq[ProviderRec]): bool =
  ## Fold edits made by other 3code instances since this one started into
  ## the values about to be written. `writeConfigFile` serializes the whole
  ## in-memory state, so a long-lived instance that writes for an
  ## unrelated reason (`:model`, `:reasoning`, ...) used to revert any
  ## edit another instance persisted in the meantime — the classic
  ## "I edited a provider and the next restart didn't see it" report.
  ##
  ## Baseline-diff for each provider, keyed by name:
  ## - unchanged since startup (matches baseline AND memory): keep memory;
  ##   if disk differs, another instance touched it — keep disk.
  ## - changed since startup (memory differs from baseline): this
  ##   instance's own edit wins; disk is stale.
  ## - on disk but not in baseline nor memory: another instance added it;
  ##   keep it.
  ## - in baseline but neither in memory nor on disk: another instance
  ##   removed it; stay removed.
  ## The `current` line keeps the disk floor while it resolves (see the
  ## comment at the check below).
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
       savedWallWarn, savedMaxTimeout, savedForceTimeout, savedColorMode,
       savedBash, savedBashSrc, savedTabTitle, savedVerifierOn,
       savedVerifierSpec, savedUserAgent, savedBannerLines,
       savedDirConfig, savedCommandPrefixes, savedWhitelist) =
    (notifyEnabled, streamingEnabled, sandboxEnabled, patientRetryEnabled,
     sandboxWallWarn, maxTimeoutSetting, forceTimeoutSetting, colorModePref,
     bashPathOverride, bashSourcePref, tabTitleEnabled, verifierEnabled,
     verifierModelSpec, userAgentTemplate, bannerLinesSetting,
     dirsettings.dirConfigLocation, commandPrefixes, providerWhitelist)
  let savedParams = activeParams
  let savedWarnings = activeConfigWarnings
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
  maxTimeoutSetting = savedMaxTimeout
  forceTimeoutSetting = savedForceTimeout
  bannerLinesSetting = savedBannerLines
  colorModePref = savedColorMode
  bashPathOverride = savedBash
  bashSourcePref = savedBashSrc
  tabTitleEnabled = savedTabTitle
  verifierEnabled = savedVerifierOn
  verifierModelSpec = savedVerifierSpec
  userAgentTemplate = savedUserAgent
  dirsettings.dirConfigLocation = savedDirConfig
  commandPrefixes = savedCommandPrefixes
  providerWhitelist = savedWhitelist
  activeParams = savedParams
  activeConfigWarnings = savedWarnings
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
  # The `current` line keeps the disk value while it still resolves
  # against the providers about to be written. Every automatic write
  # carries some directory's current (its sticky, a store switch, a
  # provider-list flush), and none of them may author the global floor:
  # a `:provider` switch sticks in that directory's store and the floor
  # stays for directories without one — otherwise the global kept moving
  # to whichever directory wrote last. A floor that no longer resolves
  # (its provider was removed or edited past recognition) is repaired
  # with the caller's value so store-less directories keep a usable
  # default. The merged list is the right yardstick: the floor's
  # provider may be one only another instance has (added since
  # startup). Fresh configs (no disk file) never reach this point.
  if diskCurrent != "" and
     buildProfile(diskCurrent, providers, "").name.len > 0:
    current = diskCurrent
  true

func normalizedCurrent(current: string; providers: seq[ProviderRec]): string =
  ## `current` may hold a wire-style model id; persist the normalized
  ## spelling when the pair is curated (the known-good table repairs
  ## the wire id back at load time). Custom providers keep the id
  ## verbatim: the normalizer is lossy for ids it can't round-trip
  ## (`qwen3.6:latest` -> `qwen-3.6:latest`), and with no table entry
  ## nothing maps it back, so the mangled id would 404 on the wire.
  ## Only the model part is normalized: running the whole
  ## "provider.model" string through normalizeModelName strips
  ## everything up to the model's last `/`, which drops the provider
  ## name entirely for ids like "baseten.zai-org/GLM-4.7".
  let curDot = current.find('.')
  if curDot < 0: return current
  let provName = current[0 ..< curDot]
  let model = current[curDot + 1 .. ^1]
  for pr in providers:
    if pr.name == provName and
       knownGoodWireModel(pr.name, model) == "":
      return current
  provName & "." & normalizeModelName(model)

proc claimSetting*(key: string) =
  ## An in-session command just set this `[settings]` key by hand
  ## (`:streaming off`, `:verifier on`, ...): drop the store-overlay
  ## bookkeeping so the next `writeConfigFile` serializes the live
  ## global — the user's explicit choice — instead of the user
  ## config's pre-overlay line. The store's value re-applies on the
  ## next startup, the same contract `:sandbox on|off` follows.
  storeOverlayKeys.excl(canonicalSettingsKey(key))

proc userSettingBool(key: string; eff, default: bool): bool =
  ## The value `writeConfigFile` should serialize for `key`: the live
  ## global, unless a store overlay supplies the key — then the user
  ## config's own line, or the compiled default when it has none (and
  ## the line is omitted). Values outside the boolean dialect keep the
  ## default, exactly like the parse-time application.
  if canonicalSettingsKey(key) notin storeOverlayKeys: return eff
  let raw = userSettingsRaw.getOrDefault(canonicalSettingsKey(key), "")
  case raw.strip.toLowerAscii
  of "on", "true", "yes", "1": true
  of "off", "false", "no", "0": false
  else: default

proc userSettingInt(key: string; eff, default: int): int =
  ## Integer twin of `userSettingBool`; unparsable user lines keep the
  ## default (schema validation already rejects them at parse time).
  if canonicalSettingsKey(key) notin storeOverlayKeys: return eff
  let raw = userSettingsRaw.getOrDefault(canonicalSettingsKey(key), "")
  try: parseInt(raw.strip)
  except ValueError: default

proc userSettingStr(key, eff, default: string): string =
  ## String twin: the written line round-trips the user's own spelling
  ## (including `$var` templates).
  if canonicalSettingsKey(key) notin storeOverlayKeys: return eff
  let raw = userSettingsRaw.getOrDefault(canonicalSettingsKey(key), "")
  if raw.strip == "": default else: raw

proc userSettingTone(eff: ColorMode): ColorMode =
  ## `tone` twin; the legacy `mode` spelling reads the same canonical
  ## slot (`userSettingsRaw` keys are canonical).
  if "tone" notin storeOverlayKeys: return eff
  let raw = userSettingsRaw.getOrDefault("tone", "")
  case raw.strip.toLowerAscii
  of "dark": cmDark
  of "light", "bright": cmLight
  else: cmAuto

proc userSettingPrefixes(eff: string): string =
  ## `system-command-prefixes` twin, normalized like the parse (each
  ## non-whitespace character one prefix).
  if "system-command-prefixes" notin storeOverlayKeys: return eff
  let norm = normalizeCommandPrefixes(
    userSettingsRaw.getOrDefault("system-command-prefixes", ""))
  if norm != "": norm else: ":"

proc writeConfigFile*(path: string, current: string,
                     providers: seq[ProviderRec]) =
  createDir(path.parentDir)
  # Models are persisted in normalized form when the pair is curated
  # (the known-good table repairs the wire id back at load time); the
  # wire ids stay untouched in memory. `current` may name a model too.
  # Twin spellings of one model dedup to the first, so the file
  # self-heals lists that were written before they collapsed.
  # Experimental/custom providers keep the id verbatim: the normalizer
  # is lossy for ids it can't round-trip (`qwen3.6:latest` ->
  # `qwen-3.6:latest`), and with no table entry nothing maps it back,
  # so the mangled id would go on the wire and 404.
  var providers = providers
  # Layer-origin filter: a definition that exists only in other layers
  # (a lower `-c` file, the project `.3code/config`) stays in those
  # files — copying it into the target would fork the definition and,
  # for the project layer, leak repo-pinned settings into the user
  # config. A name the target itself defines survives the filter so the
  # disk-keep rule in `mergeForeignEdits` can preserve the target's own
  # version (the merged view may carry a higher layer's edits). The
  # layer files themselves are never written by this path.
  var persisted: seq[ProviderRec]
  for pr in providers:
    let defs = providerOrigins.getOrDefault(pr.name, @[])
    if defs.len == 0 or path in defs:
      persisted.add pr
  providers = persisted
  for pr in providers.mitems:
    pr.models = dedupModels(pr.models.mapIt(
      if knownGoodWireModel(pr.name, it) != "": normalizeModelName(it) else: it))
  var current = current
  if not mergeForeignEdits(path, current, providers): return
  # A current naming a provider that is not being persisted (it lives in
  # another layer) must not land in the target: it would never resolve
  # there and the next layer-less start would fall into the wizard.
  # Empty is safe — resolution falls back to the first provider. Only a
  # genuinely layered session (some provider came from another file)
  # rewrites it away; single-file sessions keep the old verbatim write.
  var foreignLayer = false
  for _, defs in providerOrigins:
    for o in defs:
      if o != path: foreignLayer = true
  if foreignLayer and current != "" and
      buildProfile(current, providers, "").name == "":
    current = ""
  let cur = normalizedCurrent(current, providers)
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
  # the defaults in types.nim. While a directory store overlay supplies a
  # key, the serialized value is the user config's own line (or the default
  # when it has none) so the store's value never leaks into this file.
  if not userSettingBool("streaming", streamingEnabled, true):
    buf.add "streaming = \"off\"\n"
  if not userSettingBool("notify", notifyEnabled, true):
    buf.add "notify = \"off\"\n"
  if not userSettingBool("tab-title", tabTitleEnabled, true):
    buf.add "tab-title = \"off\"\n"
  # A store's security switch must not edit the user config: while an
  # override is in effect (a user-owned store weakened the value, or a
  # project store tightened it), persist the user config's own value
  # instead of the effective one.
  let effSandbox =
    if dirsettings.dirSandboxOverridden: dirsettings.globalSandboxEnabled
    else: sandboxEnabled
  let effWallWarn =
    if dirsettings.dirWallWarnOverridden: dirsettings.globalWallWarn
    else: sandboxWallWarn
  if not effSandbox:
    buf.add "sandbox = \"off\"\n"
  if not userSettingBool("patient_retry", patientRetryEnabled, true):
    buf.add "patient_retry = \"off\"\n"
  if not userSettingBool("allow-empty-prompt", allowEmptyPromptEnabled, true):
    buf.add "allow-empty-prompt = \"off\"\n"
  when browserFetchBuild:
    if userSettingBool("browserfetch", browserFetchEnabled, false):
      buf.add "browserfetch = \"on\"\n"
  if not effWallWarn:
    buf.add "sandbox_wall_warn = \"off\"\n"
  # The store location is a user-config decision; persist it whenever it
  # is not the default so a re-written config keeps the user's choice.
  if dirsettings.dirConfigLocation != "project":
    buf.add "dirconfig = " & quoteVal(dirsettings.dirConfigLocation) & "\n"
  # Same non-default rule for the command prefix set: a rewrite must not
  # silently strip the characters that introduce commands.
  let wPrefixes = userSettingPrefixes(commandPrefixes)
  if wPrefixes != ":":
    buf.add "system-command-prefixes = " & quoteVal(wPrefixes) & "\n"
  # Bare number, not a quoted literal: the reader parseInts the raw value.
  let wMaxTimeout = userSettingInt("max_timeout", maxTimeoutSetting, 0)
  if wMaxTimeout > 0 and wMaxTimeout != MaxBashTimeout:
    buf.add "max_timeout = " & $wMaxTimeout & "\n"
  let wForceTimeout = userSettingInt("force_timeout", forceTimeoutSetting, 0)
  if wForceTimeout > 0:
    buf.add "force_timeout = " & $wForceTimeout & "\n"
  # Verifier selection persists as its own key; the on/off state rides
  # along only when it disagrees with the default (selected = enabled),
  # so an untouched config stays clean either way.
  let wVModel = userSettingStr("verifier_model", verifierModelSpec, "")
  if wVModel != "":
    buf.add "verifier_model = " & quoteVal(wVModel) & "\n"
    if not userSettingBool("verifier", verifierEnabled, true):
      buf.add "verifier = " & quoteVal("off") & "\n"
  # Same bare-number shape; the default (1) keeps a clean config.
  let wBannerLines = userSettingInt("banner_lines", bannerLinesSetting, 1)
  if wBannerLines != 1:
    buf.add "banner_lines = " & $wBannerLines & "\n"
  # Persist the colour tone only when it differs from `auto` (the default).
  let wTone = userSettingTone(colorModePref)
  if wTone != cmAuto:
    let label = if wTone == cmDark: "dark" else: "light"
    buf.add "tone = " & quoteVal(label) & "\n"
  # Same non-default rule: the compiled `3code $version` UA is not written.
  let wUserAgent = userSettingStr("user_agent", userAgentTemplate, "")
  if wUserAgent != "":
    buf.add "user_agent = " & quoteVal(wUserAgent) & "\n"
  if activeShortcuts.len > 0:
    buf.add "\n[shortcuts]\n"
    for cmd, spec in activeShortcuts:
      buf.add cmd & " = " & quoteVal(spec) & "\n"
  # Round-trip the runtime-knob lines ([test] harness hooks, the
  # [settings]/[plugins] keys runtime.nim serves) as written, so a
  # mid-session save keeps the frame handshake alive.
  if activeExtraConf.len > 0:
    var lastSection = ""
    for (sec, key, val) in activeExtraConf:
      if sec != lastSection:
        buf.add "\n[" & sec & "]\n"
        lastSection = sec
      buf.add key & " = " & quoteVal(val) & "\n"
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
      # Same curated/verbatim rule as the models list: normalized when
      # the known-good table can repair the wire id back at load time,
      # verbatim for custom providers whose id the normalizer cannot
      # round-trip.
      let cm =
        if knownGoodWireModel(pr.name, pr.currentModel) != "":
          normalizeModelName(pr.currentModel)
        else: pr.currentModel
      buf.add "current_model = " & quoteVal(cm) & "\n"
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
    if pm.params.vision.isSome:
      buf.add "vision = " &
        quoteVal(if pm.params.vision.get: "true" else: "false") & "\n"
  # Atomic replace (temp + rename, same scheme as drafts and the dir
  # sticky-current): a crash or power-off mid-write never leaves a
  # truncated config, which would otherwise look like "no provider
  # configured" on the next start.
  let tmpPath = path & ".tmp"
  writeFile(tmpPath, buf)
  moveFile(tmpPath, path)

var configLayers*: seq[string]
  ## The explicit `-c FILE` / `-C FILE` operands, in command-line
  ## order. Managed exclusively through `addConfigLayer` /
  ## `clearConfigLayers` / `applyConfigFlags` so every parser (main
  ## getopt, the plugin pre-scan, the provider subcommand, headless,
  ## rpc, acp) lands on one stack.
var configCleared*: bool
  ## Any `-C` was seen: the implicit layers (user global, project)
  ## are off for this run; only layers added after the clear are read.
var projectLayer*: string = ""
  ## The discovered `.3code/config` (nearest ancestor of the working
  ## directory), applied last in the read stack. Empty when none was
  ## found or a `-C` cleared it.

proc addConfigLayer*(path: string) =
  ## `-c FILE`: append one layer. The user global drops out as soon as
  ## any explicit layer exists (single-`-c` replace semantics survive).
  if path != "": configLayers.add path

proc clearConfigLayers*(path: string) =
  ## `-C [FILE]`: reset the stack — implicit layers included — then add
  ## `path` as the first layer when given. A bare clear yields the
  ## empty stack (the first-run state).
  configCleared = true
  configLayers = @[]
  if path != "": configLayers.add path

proc configReadPaths*(): seq[string] =
  ## The files to read, lowest layer first; a key set by a later file
  ## wins. Any explicit `-c` replaces the user global; the project layer
  ## always applies last unless a `-C` cleared the implicit stack.
  if configCleared: return configLayers
  if configLayers.len == 0:
    result.add userConfigRoot() / "config"
  else:
    result = configLayers
  if projectLayer != "": result.add projectLayer

proc configPath*(): string =
  ## The WRITE target: the last explicit `-c`/`-C` layer, else the user
  ## global. Reads must not use this — `configReadPaths()` is the read
  ## side (a `-C` run writes the user global while reading nothing).
  if configLayers.len > 0: configLayers[^1]
  else: userConfigRoot() / "config"

proc configCarriesUserContent(path: string): bool =
  ## False only for a config whose every key sits in `[test]`: the tty
  ## harness injects its IPC channel into an otherwise empty config file,
  ## and that must not make a fresh install look configured. An empty or
  ## comments-only file still counts: it exists because someone wrote it.
  var section = ""
  var sawTestKey = false
  let raw = try: readFile(path)
            except OSError: return true
  for line in raw.splitLines:
    let t = line.strip
    if t.len == 0 or t[0] in {';', '#'}: continue
    if t.startsWith('[') and t.endsWith(']'):
      section = t[1 ..< t.len - 1].strip.toLowerAscii
    elif section != "test":
      return true
    else:
      sawTestKey = true
  not sawTestKey

proc firstExistingConfigFile*(): string =
  ## The config file to name when one exists but nothing in it runs: the
  ## first read layer with user content, else the write target (also
  ## under `-C`, which reads none but must not make an existing config
  ## look like a first run). "" when there is no config file anywhere,
  ## which is the only state that counts as a first run.
  for p in configReadPaths():
    if fileExists(p) and configCarriesUserContent(p): return p
  let target = configPath()
  if fileExists(target) and configCarriesUserContent(target): return target
  ""

proc discoverProjectConfig*(startDir: string): string =
  ## The nearest `.3code/config` walking up from `startDir` to the
  ## filesystem root: the project-local config layer, "" when no
  ## ancestor carries one. No git-root bounding in v1 — the walk is
  ## the whole contract. A `-C` in effect skips the walk entirely
  ## (the project layer is implicit, and a clear clears the implicit
  ## stack).
  if configCleared: return ""
  var d = startDir
  if d == "": return ""
  while true:
    let p = d / dirsettings.StoreDirName / dirsettings.StoreConfigFile
    if fileExists(p): return p
    let (head, tail) = splitPath(d)
    if tail.len == 0 or head == d: return ""
    d = head

proc scanConfigFlags*(args: seq[string]): tuple[layers: seq[string],
    cleared: bool] =
  ## Pure argv scan for the config flags, mirroring the option table's
  ## value shapes: `-c FILE`, `--config FILE`, `--config=FILE`, attached
  ## `-cFILE` / `-c=FILE` / `-c:FILE`, and the same forms for
  ## `-C`/`--config-clear` where the operand is optional (a following
  ## token is the operand unless it starts with `-`). Stops at `--`:
  ## everything after it is prompt text, not flags. Short clusters walk
  ## the same letters `expandAttachedValues` + parseopt do: the first
  ## value-taking letter owns the rest of the token, so `-mc v` sets a
  ## model (not a config layer) exactly like the real parser.
  let valueOpts = {'m', 's', 'r', 'C'} + plugins.pluginCliValueShorts()
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--": break
    if a.len >= 2 and a[0] == '-' and a[1] != '-':
      # Short cluster: walk to the first value-taking letter. Booleans
      # before it pass through; the letter found owns the rest.
      var j = 1
      var hit = false
      while j < a.len:
        if a[j] in valueOpts or a[j] == 'c':
          hit = true
          break
        inc j
      if hit and (a[j] == 'c' or a[j] == 'C'):
        var rest = if j + 1 <= a.len - 1: a[j + 1 .. ^1] else: ""
        if rest.len > 0 and rest[0] in {'=', ':'}: rest = rest[1 .. ^1]
        if a[j] == 'c':
          if rest != "":
            result.layers.add rest
          elif i + 1 < args.len:
            result.layers.add args[i + 1]
            inc i
        else:
          # The clear resets everything accumulated so far, implicit
          # layers included; its operand (if any) starts a fresh stack.
          result.cleared = true
          result.layers = @[]
          if rest != "":
            result.layers.add rest
          elif i + 1 < args.len and args[i + 1].len > 0 and
              args[i + 1][0] != '-':
            result.layers.add args[i + 1]
            inc i
        inc i
        continue
    elif a == "--config":
      if i + 1 < args.len:
        result.layers.add args[i + 1]
        inc i
    elif a.startsWith("--config="):
      result.layers.add a[9 .. ^1]
    elif a == "--config-clear":
      result.cleared = true
      result.layers = @[]
      if i + 1 < args.len and args[i + 1].len > 0 and args[i + 1][0] != '-':
        result.layers.add args[i + 1]
        inc i
    elif a.startsWith("--config-clear="):
      result.cleared = true
      result.layers = @[]
      if a[15 .. ^1] != "": result.layers.add a[15 .. ^1]
    inc i

proc applyConfigFlags*(args: seq[string]) =
  ## Set the layer stack from a full argv. Idempotent: the stack is
  ## rebuilt from the scan every time, so the main entry point can run
  ## it once up front (before any subcommand dispatch) and every later
  ## parser only consumes the tokens without touching the state.
  let s = scanConfigFlags(args)
  configLayers = s.layers
  configCleared = s.cleared

proc resolveSearchKey*(engine: string; keys: Table[string, string]): string =
  ## The engine-specific `[search] exa-key` / `brave-key`. Returns "" when
  ## none is set, which is fine for the keyless engines (exa, parallel) and
  ## surfaces as a runtime error for brave.
  if keys.hasKey(engine): keys[engine]
  else: ""

proc startupTraceFileTarget*(): string =
  ## The `[settings] trace_file` value from the resolved config path, for
  ## -d:startupTrace builds whose first milestone fires before the full
  ## config load. "" (stderr) when the file or the key is absent.
  if not fileExists(configPath()): return ""
  try:
    let stream = newFileStream(configPath(), fmRead)
    if stream == nil: return ""
    var p: CfgParser
    p.open(stream, configPath())
    var section = ""
    while true:
      let e = p.next
      case e.kind
      of cfgEof: break
      of cfgSectionStart: section = e.section
      of cfgKeyValuePair, cfgOption:
        if section == "settings" and e.key == "trace_file":
          result = e.value.strip
          break
      else: discard
    p.close()
  except CatchableError:
    result = ""

proc applyEarlySandboxSettings*(path: string) =
  ## Apply only the two `[settings]` sandbox switches (`sandbox`,
  ## `sandbox_wall_warn`) and the store-location switch (`dirconfig`)
  ## from a tolerant parse of `path`. The pre-prompt
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
      let v = e.value.toLowerAscii
      if e.key == "dirconfig" and v in DirConfigValues:
        dirsettings.dirConfigLocation = v
        continue
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

proc applyDirSettingsOverlay*(cwd: string) =
  ## The full directory overlay over the user config parse: the two
  ## security switches through `dirsettings.applyDirConfig` (project
  ## stores may only tighten them, never weaken), and every other
  ## `[settings]` key nearest-store-wins over the user config's value —
  ## the cascade every setting follows: compiled default < user config
  ## (`~/.config/3code/config`) < the nearest directory store
  ## (`./.3code/config`, or its twin under the config root when the
  ## user config says `dirconfig = "user"`). `current` is owned by the
  ## sticky-current resolver and `dirconfig` by the user config; neither
  ## cascades from a store. Each applied key is registered in
  ## `storeOverlayKeys` so `writeConfigFile` persists the user config's
  ## own line, never the store's value. Idempotent; startup runs it
  ## after the full parse, exactly once the parse has re-applied the
  ## user config's own switches. Marks already recorded by the layered
  ## read (a lower `-c` file, the project layer) survive the rebuild:
  ## this overlay clears nothing, it only adds the store's keys on top.
  dirsettings.applyDirConfig(cwd)
  let savedLayerMarks = storeOverlayKeys
  storeOverlayKeys.clear()
  let t = dirsettings.cascadeStoreSettings(cwd)
  # Sorted for determinism: alias spellings of one key (`mode`/`tone`)
  # in different stores apply in a fixed order, the canonical spelling
  # last, matching the file-order rule the user config follows.
  for k in sorted(toSeq(t.keys)):
    if k in ["current", "dirconfig", "sandbox", "sandbox_enabled",
             "sandbox_wall_warn"]: continue
    applySettingsValue(k, t[k])
    storeOverlayKeys.incl(canonicalSettingsKey(k))
  storeOverlayKeys.incl(savedLayerMarks)
  # Same selected-verifier default as the parse: a store that sets
  # `verifier_model` enables it unless some `verifier` line (user
  # config or store) said otherwise.
  if verifierModelSpec != "" and not verifierExplicitSeen:
    verifierEnabled = true

proc tryLoadStateOrEmpty*(path: string): tuple[current: string,
    providers: seq[ProviderRec], colors: Table[string, string], err: string] =
  ## Tolerant twin of `loadStateOrEmpty` for callers that must not die on
  ## a malformed config (3code-app's settings server, embedding the
  ## provider ops). Identical side effects and results; a parse failure
  ## comes back as `err` (with current/providers/colors empty) instead of
  ## `die`.
  if not fileExists(path):
    baselineCurrent = ""
    baselineProviders = @[]
    return ("", @[], initTable[string, string](), "")
  let (current, providers, colors, searchKeys, searchEngine, shortcuts) =
    try: parseConfigFile(path)
    except ValueError as e:
      return ("", @[], initTable[string, string](), e.msg)
  baselineCurrent = current
  baselineProviders = providers
  # Also refresh the active globals: interactive callers do this
  # themselves with the returned tuple (threecode.nim), but a
  # non-interactive host that loads and edits through providerops in
  # one step needs the loader to leave the globals consistent on its
  # own — providerops' ops read and write `activeCurrent` /
  # `activeProviders`.
  activeCurrent = current
  activeProviders = providers
  if searchEngine != "": activeSearchEngine = searchEngine
  activeSearchKeys = searchKeys
  activeSearchKey = resolveSearchKey(activeSearchEngine, activeSearchKeys)
  activeShortcuts = shortcuts
  minline.configuredShortcuts = activeShortcuts
  (current, providers, colors, "")

proc printConfigWarnings*() =
  ## Startup-only surface for `activeConfigWarnings`: one stderr line per
  ## unknown key, prefixed to read as a warning rather than the `die`
  ## format the real errors use.
  for w in activeConfigWarnings:
    stderr.writeLine("3code: warning: " & w)

proc loadStateOrEmpty*(path: string): (string, seq[ProviderRec], Table[string, string]) =
  ## Returns `(current, providers, colors)` and updates `activeSearchKey` /
  ## `activeSearchEngine` / `activeSearchKeys` / `activeShortcuts` as a side
  ## effect when the config sets them. `colors` is the flat `[colors]` map
  ## for the caller to route through the cascade. Missing file is benign.
  ## Also records the startup baseline (`baselineCurrent` /
  ## `baselineProviders`) that `writeConfigFile` diffs against to keep
  ## concurrent instances from clobbering each other's edits.
  let (current, providers, colors, err) = tryLoadStateOrEmpty(path)
  if err != "": die err, ExitConfig
  printConfigWarnings()
  (current, providers, colors)

var currentOriginLayer* = ""
  ## The file that contributed the active `current`, for diagnostics
  ## that must name a layer (the "current but no [provider]" die names
  ## the offending file, not the write target).
proc patchParams(dst: var ModelParams, src: ModelParams)
  ## Forward decl: the layered read merges `[params]` scopes with the
  ## same per-field patch the profile resolver uses (definition below).

proc tryLoadStateLayers*(paths: seq[string]): tuple[current: string,
    providers: seq[ProviderRec], colors: Table[string, string], err: string] =
  ## Layered read of `paths`, lowest first. Merge rules, later layer
  ## winning per key:
  ## - `[settings]` scalars: applied per key by the sequential parses
  ##   (`parseConfigFile` only touches keys a file sets).
  ## - `current`: the highest layer that sets it.
  ## - `[provider]` blocks: by name; a later same-name block replaces the
  ##   earlier one EXCEPT that a missing `key`/`url` is inherited from the
  ##   namesake below — API keys stay out of committed project files
  ##   without duplicating provider definitions.
  ## - `[params]`: by (provider, model) scope, per key.
  ## - `[search]` / `[colors]` / `[shortcuts]`: per key.
  ## Each file runs the full `validateConfig`, so a malformed layer dies
  ## (or returns err here) naming its own `path:line`. Missing files are
  ## skipped, not layers that blank out the ones below them.
  var current = ""
  var providers: seq[ProviderRec]
  var colors: Table[string, string]
  var searchKeys: Table[string, string]
  var searchEngine = ""
  var shortcuts: Table[string, string]
  var params: seq[ParamsRec]
  var origins: Table[string, seq[string]]
  var warnings: seq[string]
  currentOriginLayer = ""
  # Write bookkeeping across the stack: after the loop `userSettingsRaw`
  # must hold the WRITE TARGET's own [settings] lines and
  # `storeOverlayKeys` every key a non-target layer (a lower `-c` file,
  # the project layer) supplies, so `writeConfigFile` persists the
  # target's own value, never a foreign layer's — the dir-store
  # no-leak rule generalized to the whole stack. `activeExtraConf`
  # round-trips only the target's runtime-knob lines for the same
  # reason. `configPath()` is the target because it is the only file
  # this stack ever writes.
  let target = configPath()
  var targetSettings = initTable[string, string]()
  var targetExtra: seq[tuple[section, key, value: string]] = @[]
  storeOverlayKeys.clear()
  for p in paths:
    if not fileExists(p): continue
    let isProject = p != "" and p == projectLayer
    let (cur, provs, cols, skeys, sengine, scuts) =
      try: parseConfigFile(p, isProject)
      except CatchableError as e:
        return ("", @[], initTable[string, string](), e.msg)
    if p == target:
      targetSettings = userSettingsRaw
      targetExtra = activeExtraConf
    else:
      for k in keys(userSettingsRaw): storeOverlayKeys.incl(k)
    if cur != "":
      current = cur
      currentOriginLayer = p
    var fresh: seq[ProviderRec]
    for np in provs:
      origins.mgetOrPut(np.name, @[]).add p
      block merge:
        for i in 0 ..< providers.len:
          if providers[i].name != np.name: continue
          var m = np
          if m.url == "": m.url = providers[i].url
          if m.key == "" and m.auth != "oauth": m.key = providers[i].key
          providers[i] = m
          break merge
        fresh.add np
    providers.add fresh
    for k, v in cols: colors[k] = v
    for k, v in skeys: searchKeys[k] = v
    if sengine != "": searchEngine = sengine
    for k, v in scuts: shortcuts[k] = v
    for e in activeParams:
      block paramsMerge:
        for i in 0 ..< params.len:
          if params[i].provider == e.provider and params[i].model == e.model:
            patchParams(params[i].params, e.params)
            break paramsMerge
        params.add e
    warnings.add activeConfigWarnings
  activeConfigWarnings = warnings
  userSettingsRaw = targetSettings
  activeExtraConf = targetExtra
  baselineCurrent = current
  baselineProviders = providers
  providerOrigins = origins
  activeCurrent = current
  activeProviders = providers
  if searchEngine != "": activeSearchEngine = searchEngine
  activeSearchKeys = searchKeys
  activeSearchKey = resolveSearchKey(activeSearchEngine, activeSearchKeys)
  activeShortcuts = shortcuts
  minline.configuredShortcuts = activeShortcuts
  activeParams = params
  (current, providers, colors, "")

proc tryLoadStackOrEmpty*(): tuple[current: string,
    providers: seq[ProviderRec], colors: Table[string, string], err: string] =
  ## The startup stack read: `tryLoadStateLayers` over `configReadPaths()`.
  tryLoadStateLayers(configReadPaths())

proc loadStackOrEmpty*(): (string, seq[ProviderRec], Table[string, string]) =
  ## Dying twin of `tryLoadStackOrEmpty` for the full startup read; same
  ## per-file semantics as `loadStateOrEmpty` (a malformed layer dies with
  ## its own `path:line` message; every layer's warnings print once).
  let (current, providers, colors, err) = tryLoadStackOrEmpty()
  if err != "": die err, ExitConfig
  printConfigWarnings()
  (current, providers, colors)

proc resolveFamily*(prov: ProviderRec, prof: Profile): string =
  ## Family is resolved at profile-build time:
  ## 1. KnownGoodCombos hardcode (always wins; ignores config and -x)
  ## 2. provider-level `family = ...` — only honored under --experimental
  ## 3. google/geminicli default → "gemini": every model they serve is
  ##    Gemini, so a not-yet-curated id (a brand-new launch before it gets
  ##    a KnownGoodCombos row) rides the right preamble and wire knobs
  ##    under --experimental instead of the glm default
  ## 4. default → "glm"
  let kg = knownGoodFamily(prof)
  if kg != "": return kg
  if experimentalEnabled and prov.family.strip != "":
    return prov.family.strip.toLowerAscii
  if canonicalKnownGoodProvider(prov.name) == "google": return "gemini"
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
  if src.vision.isSome: dst.vision = src.vision

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

proc visionCapable*(p: Profile): bool =
  ## May this profile receive image content? An explicit `[params] vision`
  ## wins (either way, so `vision = false` can also revoke a curated
  ## combo); otherwise the known-good table's curated flag; otherwise
  ## false. Empty profiles return false.
  if p.name == "": return false
  if p.params.vision.isSome: return p.params.vision.get
  let dot = p.name.find('.')
  if dot < 0: return false
  knownGoodVision(p.name[0 ..< dot], p.model)

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
      prof.vision = visionCapable(prof)
      return prof
  Profile()

proc firstUsableProfile*(current: string;
                         providers: seq[ProviderRec]): Profile =
  ## The last-resort rung of profile resolution: the current provider's
  ## first runnable model when it still has one, else the first provider
  ## in config order that builds. Empty when no configured provider is
  ## usable (no url, no key, no models), which is the caller's diagnosis
  ## to make, never a reason to pretend this is a first run.
  let dot = current.find('.')
  let cur = if dot < 0: current else: current[0 ..< dot]
  for pr in providers:
    if pr.name != cur: continue
    result = buildProfile(pr.name, providers, "")
    if result.name.len > 0: return
  for pr in providers:
    result = buildProfile(pr.name, providers, "")
    if result.name.len > 0: return
  result = Profile()

proc availableVerifiers*(providers: seq[ProviderRec]): seq[string] =
  ## The curated verification-class models whose provider section is
  ## configured, as `provider.model` specs in config order. This is the
  ## `:verifier list` offering and the pool `:verifier on` auto-picks
  ## from — the one place these models are ever listed. Providers the
  ## `limitproviders` whitelist excludes are skipped: a verifier runs
  ## turns of its own, so it follows the same limit.
  for pr in providers:
    if not providerAllowed(pr.name): continue
    for c in VerifierCombos:
      if canonicalKnownGoodProvider(pr.name) == c.provider.toLowerAscii:
        result.add pr.name & "." & c.model

# ---------------------------------------------------------------------------
# Most-used provider: the usage ledger
# ---------------------------------------------------------------------------

proc usageLedgerPath*(): string =
  ## The provider-usage ledger: one `provider.model count` line per
  ## distinct current, highest count first. A heuristic that feeds the
  ## no-`current` default (see `mostUsedCurrent`), never a gate: a
  ## missing or corrupt file reads empty and the fallback chain simply
  ## continues.
  userDataRoot() / "provider-usage"

proc readProviderUsage*(): seq[(string, int)] =
  ## Ledger entries in file order (highest count first as written).
  ## Malformed lines are skipped, not fatal — the file is app-managed
  ## state, and a bad line must not take the default down with it.
  let path = usageLedgerPath()
  if not fileExists(path): return
  for line in readFile(path).splitLines:
    let t = line.strip
    if t.len == 0: continue
    let sp = t.rfind(' ')
    if sp <= 0 or sp == t.len - 1: continue
    try:
      result.add (t[0 ..< sp], parseInt(t[sp + 1 .. ^1]))
    except ValueError: continue

proc bumpProviderUsage*(current: string) =
  ## Count one session started on `current`. Read-modify-write with a
  ## tmp+rename: two instances bumping at once can lose a count, which
  ## costs nothing — the ledger only ranks. The rewrite keeps entries
  ## ordered by count, ties keeping their prior order, so an entry only
  ## moves up by being used MORE, and `mostUsedCurrent` is a straight
  ## first-resolvable-wins scan over the file.
  if current == "": return
  var entries = readProviderUsage()
  var bumped = false
  for i, e in entries:
    if e[0] == current:
      entries[i][1] += 1
      bumped = true
      break
  if not bumped:
    entries.add (current, 1)
  # Stable insertion sort by count, descending. The ledger is small
  # (distinct currents actually run, dozens at most), and staying
  # import-free beats pulling in algorithm for one sort.
  for i in 1 ..< entries.len:
    let e = entries[i]
    var j = i - 1
    while j >= 0 and entries[j][1] < e[1]:
      entries[j + 1] = entries[j]
      dec j
    entries[j + 1] = e
  try:
    createDir(usageLedgerPath().parentDir)
    var outText = ""
    for e in entries:
      outText.add e[0] & " " & $e[1] & "\n"
    let tmp = usageLedgerPath() & ".tmp"
    writeFile(tmp, outText)
    moveFile(tmp, usageLedgerPath())
  except CatchableError: discard

proc mostUsedCurrent*(providers: seq[ProviderRec]): string =
  ## The default for a config that sets no `current` (and a directory
  ## with no store entry): the ledger's highest-count entry that still
  ## resolves against `providers` — the provider the user actually
  ## runs, ahead of the first `[provider]` section's first model.
  ## Stale entries (provider removed, model gone from its list) are
  ## skipped, so deleting a provider demotes it from the default too.
  ## "" when the ledger is empty or nothing in it resolves; callers
  ## then keep the first-section floor.
  for e in readProviderUsage():
    if buildProfile(e[0], providers, "").name.len > 0:
      return e[0]
  ""

proc resolveDefaultCurrent*(cwd, configCurrent: string;
                            providers: seq[ProviderRec]): string =
  ## The startup provider ladder in one place, shared by the CLI main
  ## and library session init:
  ##
  ## 1. the directory cascade — the nearest `.3code/config` store from
  ##    `cwd` up that sets `current` (so a project root's pick holds in
  ##    every subdirectory), when it still resolves;
  ## 2. the config file's own `current`, verbatim (a stale value is the
  ##    caller's diagnosis to make, not this ladder's to rewrite);
  ## 3. the usage ledger's most-used provider (`mostUsedCurrent`), the
  ##    smarter floor for a config that names nothing;
  ## 4. "" — buildProfile's first-[provider]-section floor.
  ##
  ## `configCurrent` is what the loaded config said; the return value is
  ## what the session should run on. Explicit beats automatic at every
  ## rung: a store entry or a config line always wins over the ledger.
  let dirCurrent = dirsettings.dirCurrentFor(cwd)
  if dirCurrent != "" and
     buildProfile(dirCurrent, providers, "").name.len > 0:
    return dirCurrent
  if configCurrent == "" and providers.len > 0:
    return mostUsedCurrent(providers)
  configCurrent

proc buildVerifierProfile*(spec: string,
    providers: seq[ProviderRec]): tuple[prof: Profile, err: string] =
  ## Resolve a `provider.model` verifier spec into a Profile for the
  ## goal check. Never exits: an unbuildable verifier is either the
  ## `:verifier` refusal message or the goal check's silent fallback to
  ## the session model. A verification-class model resolves from
  ## `VerifierCombos`, NOT the provider's `models` list — decision models
  ## never run ordinary turns, so they are not listed there — while an
  ## ordinary model must be in the list to serve as the verifier.
  if providers.len == 0:
    return (Profile(), "no provider configured")
  let dot = spec.find('.')
  if dot <= 0 or dot == spec.len - 1:
    return (Profile(), &"expected provider.model, got '{spec}'")
  let name = spec[0 ..< dot]
  let model = spec[dot + 1 .. ^1]
  for pr in providers:
    if pr.name != name: continue
    if not providerAllowed(pr.name):
      return (Profile(), &"provider '{name}' is not allowed here " &
        "(limitproviders)")
    if pr.url == "":
      return (Profile(), &"provider '{name}': url not set")
    if pr.key == "" and pr.auth != "oauth":
      return (Profile(), &"provider '{name}': key not set")
    let wire = verifierWireModel(pr.name, model)
    let fullModel =
      if wire != "": wire
      else:
        let i = pr.findModel(model)
        if i < 0:
          return (Profile(), &"provider '{name}': '{model}' is neither a " &
            "verifier model nor in its model list")
        pr.models[i]
    var prof = Profile(name: pr.name & "." & fullModel, url: pr.url,
                       key: pr.key, model: fullModel)
    # Decision models have no family branch to resolve into: they never
    # see a system prompt or tool roster, only the question set.
    prof.family =
      if isDecisionModel(fullModel): "jev" else: resolveFamily(pr, prof)
    let (_, ver, vrt) = knownGoodTags(pr.name, fullModel)
    prof.version = ver
    prof.variant = vrt
    prof.reasoning = resolveReasoning(pr, prof)
    prof.params = resolveParams(activeParams, pr.name, fullModel)
    prof.vision = visionCapable(prof)
    return (prof, "")
  (Profile(), &"provider '{name}' is not configured")

proc resolveVerifierSpec*(target: string,
    providers: seq[ProviderRec]): tuple[spec: string, err: string] =
  ## What the user typed at `:verifier <target>` becomes: a dotted spec
  ## validates as-is; a bare name first matches a curated verification-
  ## class model on any configured provider, then an ordinary model on
  ## the current provider (a cheap chat model is a legitimate verifier).
  ## The dotted reading needs the head to name a configured provider:
  ## model ids carry dots of their own (`glm-5.3`), and a bare id must
  ## fall through to the name matching, not split into provider/model.
  let dot = target.find('.')
  if dot > 0 and providers.anyIt(it.name == target[0 ..< dot]):
    let (prof, err) = buildVerifierProfile(target, providers)
    if err != "": return ("", err)
    return (prof.name, "")
  for spec in availableVerifiers(providers):
    if spec.split('.', 1)[1] == target or
        aliasExpansion(spec.split('.', 1)[1]) == aliasExpansion(target):
      return (spec, "")
  let prov = currentProvider()
  let i = prov.findModel(target)
  if i >= 0: return (prov.name & "." & prov.models[i], "")
  (&"", &"unknown verifier: {target} (verifier list: " &
    availableVerifiers(providers).join(" ") & ")")

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
  printConfigWarnings()
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
  prof.vision = visionCapable(prof)
  prof

const ProviderCatalog*: seq[(string, string)] = @[
  ("aihubmix",    "https://aihubmix.com/v1"),
  ("aki",         "https://aki.io/openai/v1"),
  ("alibabatoken", "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"),
  ("alibabatoken-cn", "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"),
  ("anthropic",   "https://api.anthropic.com/v1"),
  ("arcee",       "https://conductor.arcee.ai/v1"),
  ("baseten",     "https://inference.baseten.co/v1"),
  ("cerebras",    "https://api.cerebras.ai/v1"),
  ("cheaperinference", "https://api.cheaperinference.com/v1"),
  ("commandcode", "https://api.commandcode.ai/provider/v1"),
  ("cortecs",     "https://api.cortecs.ai/v1"),
  ("darkbloom",   "https://api.darkbloom.dev/v1"),
  ("deepinfra",   "https://api.deepinfra.com/v1/openai"),
  ("deepseek",    "https://api.deepseek.com/v1"),
  ("engy",        "https://api.engy.ai/v1"),
  ("fireworks",   "https://api.fireworks.ai/inference/v1"),
  ("friendli",    "https://api.friendli.ai/serverless/v1"),
  ("google",      "https://generativelanguage.googleapis.com/v1beta/openai"),
  ("greenpt",     "https://api.greenpt.ai/v1"),
  ("groq",        "https://api.groq.com/openai/v1"),
  ("hetzner",     "https://inference.hetzner.com/api/v1"),
  ("huggingface", "https://router.huggingface.co/v1"),
  ("hyperbolic",  "https://api.hyperbolic.xyz/v1"),
  ("inceptron",   "https://api.inceptron.io/v1"),
  ("inkling-local", "http://localhost:8000/v1"),
  ("jarvislabs",  "https://models.jarvislabs.net/v1"),
  ("kimi",        "https://api.moonshot.ai/v1"),
  ("kimicode",    "https://api.kimi.com/coding/v1"),
  ("kolibri",     "http://localhost:8000/v1"),
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
  ("neuralwatt",  "https://api.neuralwatt.com/v1"),
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
  ("relace",      "https://models.relace.ai/v1"),
  ("sambanova",   "https://api.sambanova.ai/v1"),
  ("scaleway",    "https://api.scaleway.ai/v1"),
  ("tencent",     "https://tokenhub-intl.tencentcloudmaas.com/v1"),
  ("tesseracted", "https://api.tesseracted.com/v1"),
  ("together",    "https://api.together.xyz/v1"),
  ("together-eu", "https://eu.api.together.xyz/v1"),
  ("venice",      "https://api.venice.ai/api/v1"),
  ("vercel",      "https://ai-gateway.vercel.sh/v1"),
  ("volccode",    "https://ark.cn-beijing.volces.com/api/coding/v3"),
  ("xai",         "https://api.x.ai/v1"),
  ("xiaomi",      "https://api.xiaomimimo.com/v1"),
  ("zai",         "https://api.z.ai/api/paas/v4"),
  ("zaicode",     "https://api.z.ai/api/coding/paas/v4"),
]
  ## Routers stay out when they only re-sell providers we already list
  ## (the many OpenRouter clones models.dev catalogues); a router earns a
  ## catalog entry when it adds something the direct list lacks, like
  ## vercel's below-list pricing, cortecs' EU-sovereign upstreams, or
  ## aihubmix's free coding tiers. Anything narrower belongs in user
  ## config, not in the catalog.

proc catalogUrl*(name: string): string =
  when defined(providerStub):
    if name == "stub":
      return "stub://provider"
  for (n, u) in ProviderCatalog:
    if n == name: return u
  ""

const KeyPrefixCatalog*: seq[(string, string)] = @[
  ("vck_",       "vercel"),
  ("sk-gateway-", "aihubmix"),
  ("sk-ant-",  "anthropic"),
  ("sk-or-",   "openrouter"),
  ("sk-proj-", "openai"),
  ("gsk_",     "groq"),
  ("xai-",     "xai"),
  ("pplx-",    "perplexity"),
  ("nvapi-",   "nvidia"),
  ("fw_",      "fireworks"),
  ("csk-",     "cerebras"),
  ("sk-db-",   "darkbloom"),
  ("ir_live_", "cheaperinference"),
  ("tl_live_", "tesseracted"),
  ("tgp_",     "together"),
  ("rlc-",     "relace"),
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

proc echoMasksAsKey*(s: string): bool =
  ## Echo-time masking for the wizard's multipurpose first field
  ## (provider name, url, or key). Known key prefixes and the z.ai shape
  ## mask from the first typed character; an unrecognized entry masks once
  ## it outgrows the longest catalog provider name (``cheaperinference``,
  ## 16 chars) plus margin, so a prefixless secret never echoes in full.
  ## Urls stay visible: the field accepts them under --experimental and
  ## they are not secrets. Uses the real prefix catalog, not
  ## ``inferProvider`` (whose providerStub special case would mask the
  ## stub provider name in test builds).
  if s.startsWith("http://") or s.startsWith("https://"): return false
  for (p, _) in KeyPrefixCatalog:
    if s.startsWith(p): return true
  if looksLikeZaiKey(s): return true
  if s.len <= 20: return false
  for c in s:
    if c in Whitespace: return false
  true

proc defaultNameFromUrl*(url: string): string =
  let host = parseUri(url).hostname
  if host == "": return ""
  # Provider names live inside `provider.model` dot-joined ids everywhere
  # (config `current`, Profile.name, providerOf's find('.')), so a name
  # containing a dot breaks the split. Dotted-quad hosts therefore mangle
  # to a dash form (127.0.0.1 -> "ip-127-0-0-1", not "0").
  if host.split('.').len == 4 and host.allCharsInSet({'0'..'9', '.'}):
    return "ip-" & host.replace('.', '-')
  let labels = host.split('.')
  if labels.len >= 2: labels[^2]
  else: labels[0]

proc curatedFor*(provider: string): seq[string] =
  ## Full model ids from KnownGoodCombos for the given provider name.
  ## Verification-class models are not curated here: they live in
  ## `VerifierCombos` and `:verifier`, never in the turn-model catalog.
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
