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
import types, prompts, util

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
  ## Matches by full model id or by short name (everything after the last
  ## `/`). Short-name matching handles `:variant <name>` from users who
  ## type the bare model name and old `current = provider.shortname` config
  ## values that haven't been rewritten yet.
  for i, m in p.models:
    if m == name or shortModel(m) == name: return i
  -1

var activeCurrent*: string
var activeProviders*: seq[ProviderRec]
var activeSearchKey*: string = ""
  ## Optional search API key resolved at config load. Set via
  ## `[search] key = "..."`. The env var honored depends on the engine:
  ## `EXA_API_KEY`, `PARALLEL_API_KEY`, or `BRAVE_API_KEY`. Keyless by
  ## default (Exa and Parallel both have a free anonymous tier); the key
  ## is only persisted back to disk when non-empty.

const SearchEngineEnv*: array[3, (string, string)] = [
  ("exa", "EXA_API_KEY"),
  ("parallel", "PARALLEL_API_KEY"),
  ("brave", "BRAVE_API_KEY")
]
  ## Maps each engine name to the env var that supplies its key. Used by
  ## `loadStateOrEmpty` / `loadProfile` to fall back to the environment
  ## when `[search] key` is unset.

var activeSearchEngine*: string = "exa"
  ## Active search engine: "exa" (default), "parallel", or "brave". Set via
  ## `[search] engine = "..."`. No automatic failover — the chosen engine is
  ## used as-is, and a missing key is an error only if that engine needs one
  ## (brave does; exa and parallel are keyless by default).

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

proc explainExperimentalGate*(p: Profile) =
  let dot = p.name.find('.')
  let display =
    if dot < 0: p.name
    else: p.name[0 ..< dot] & " " & p.name[dot+1 .. ^1]
  stdout.styledWriteLine fgMagenta,
    display,
    " is experimental (start 3code with --experimental to use anyway, not recommended)",
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
  let p = prov.name.toLowerAscii
  for combo in KnownGoodCombos:
    if combo.provider.toLowerAscii == p:
      for m in prov.models:
        if m == combo.model:
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
      if pr.url == "" or pr.key == "": continue
      if pr.name.toLowerAscii != combo.provider.toLowerAscii: continue
      for m in pr.models:
        if m == combo.model:
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

proc parseConfigFile*(path: string): (string, seq[ProviderRec], Table[string, string], string, string) =
  ## Streaming parse so that repeated [provider] sections accumulate as a list.
  ## Returns `(current, providers, colors, searchKey, searchEngine)`.
  ## `searchKey` is the optional `[search] key` value ("" when absent or
  ## keyless); `searchEngine` is the optional `[search] engine` value
  ## ("" when absent, meaning the default `exa`). `colors` is the flat
  ## `[colors]` map (raw keys verbatim, including any `-light` suffix); the
  ## caller routes it through `splitColorOverrides` + `applyColorOverrides`.
  var current = ""
  var searchKey = ""
  var searchEngine = ""
  var providers: seq[ProviderRec]
  var colors: Table[string, string]
  var section = ""
  var prov: ProviderRec
  var inProvider = false
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
        of "mode":
          # `auto` detects the background (default); `dark`/`bright` force a
          # palette. `light` is accepted as an alias for `bright`.
          case v.strip.toLowerAscii
          of "auto": colorModePref = cmAuto
          of "dark": colorModePref = cmDark
          of "bright", "light": colorModePref = cmLight
          else: discard
        of "bash_path", "bash-path":
          bashPathOverride = v
        else: discard
      of "search":
        case e.key
        of "key": searchKey = v
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
        else: discard
      else: discard
    of cfgError:
      die &"{path}: {e.msg}", ExitConfig
  p.close
  (current, providers, colors, searchKey, searchEngine)

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
  var buf = "[settings]\n"
  buf.add "current = " & quoteVal(current) & "\n"
  if activeSearchKey != "" or activeSearchEngine != "exa":
    buf.add "\n[search]\n"
    if activeSearchEngine != "exa":
      buf.add "engine = " & quoteVal(activeSearchEngine) & "\n"
    if activeSearchKey != "":
      buf.add "key = " & quoteVal(activeSearchKey) & "\n"
  # Persist the streaming/notify toggles only when off — on is the default,
  # so a user who never changes them keeps a clean config. This also matches
  # the defaults in types.nim.
  if not streamingEnabled:
    buf.add "streaming = \"off\"\n"
  if not notifyEnabled:
    buf.add "notify = \"off\"\n"
  # Persist the colour mode only when it differs from `auto` (the default).
  if colorModePref != cmAuto:
    let label = if colorModePref == cmDark: "dark" else: "bright"
    buf.add "mode = " & quoteVal(label) & "\n"
  for pr in providers:
    buf.add "\n[provider]\n"
    buf.add "name = " & quoteVal(pr.name) & "\n"
    buf.add "url = " & quoteVal(pr.url) & "\n"
    buf.add "key = " & quoteVal(pr.key) & "\n"
    if pr.family != "":
      buf.add "family = " & quoteVal(pr.family) & "\n"
    buf.add "models = " & quoteVal(formatModels(pr.models)) & "\n"
    if pr.reasoning != "":
      buf.add "reasoning = " & quoteVal(pr.reasoning) & "\n"
    if pr.reasonings.len > 0:
      buf.add "reasonings = " & quoteVal(formatModels(pr.reasonings)) & "\n"
  writeFile(path, buf)

proc configPath*(): string =
  getConfigDir() / "3code" / "config"

proc resolveSearchKey*(engine, configuredKey: string): string =
  ## `[search] key` wins; otherwise the env var for the active engine is
  ## consulted (`EXA_API_KEY` / `PARALLEL_API_KEY` / `BRAVE_API_KEY`).
  ## Returns "" when neither is set, which is fine for the keyless engines
  ## (exa, parallel) and surfaces as a runtime error for brave.
  if configuredKey != "": return configuredKey
  for (name, envVar) in SearchEngineEnv:
    if name == engine and existsEnv(envVar):
      return getEnv(envVar)
  ""

proc loadStateOrEmpty*(path: string): (string, seq[ProviderRec], Table[string, string]) =
  ## Returns `(current, providers, colors)` and updates `activeSearchKey` /
  ## `activeSearchEngine` as a side effect when the config sets them.
  ## `colors` is the flat `[colors]` map for the caller to route through the
  ## cascade. Missing file is benign.
  if not fileExists(path): return ("", @[], initTable[string, string]())
  let (current, providers, colors, searchKey, searchEngine) = parseConfigFile(path)
  if searchEngine != "": activeSearchEngine = searchEngine
  activeSearchKey = resolveSearchKey(activeSearchEngine, searchKey)
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
      if pr.url == "" or pr.key == "" or pr.models.len == 0:
        return Profile()
      let fullModel =
        if model == "": firstModel(pr)
        else:
          let i = pr.findModel(model)
          if i < 0: return Profile()
          pr.models[i]
      if fullModel == "": return Profile()
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
  let (current, providers, _, searchKey, searchEngine) = parseConfigFile(path)
  if searchEngine != "": activeSearchEngine = searchEngine
  activeSearchKey = resolveSearchKey(activeSearchEngine, searchKey)
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
  if prov.key == "": die &"provider '{name}': key not set in {path}", ExitConfig
  if prov.models.len == 0: die &"provider '{name}': models not set in {path}", ExitConfig
  let fullModel =
    if model == "": firstModel(prov)
    else:
      let i = prov.findModel(model)
      if i < 0:
        die &"provider '{name}': model '{model}' not in models list ({prov.models.join(\", \")})", ExitConfig
      prov.models[i]
  if fullModel == "":
    die &"provider '{name}': models list is empty", ExitConfig
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
  ("anthropic",   "https://api.anthropic.com/v1"),
  ("arcee",       "https://conductor.arcee.ai/v1"),
  ("baseten",     "https://inference.baseten.co/v1"),
  ("cerebras",    "https://api.cerebras.ai/v1"),
  ("deepinfra",   "https://api.deepinfra.com/v1/openai"),
  ("deepseek",    "https://api.deepseek.com/v1"),
  ("fireworks",   "https://api.fireworks.ai/inference/v1"),
  ("friendli",    "https://api.friendli.ai/serverless/v1"),
  ("google",      "https://generativelanguage.googleapis.com/v1beta/openai"),
  ("groq",        "https://api.groq.com/openai/v1"),
  ("huggingface", "https://router.huggingface.co/v1"),
  ("hyperbolic",  "https://api.hyperbolic.xyz/v1"),
  ("inceptron",   "https://api.inceptron.io/v1"),
  ("kimi",        "https://api.moonshot.ai/v1"),
  ("kimicode",    "https://api.kimi.com/coding/v1"),
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
  ("tgp_",     "together"),
  ("AIza",     "google"),
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
  let p = provider.toLowerAscii
  for c in KnownGoodCombos:
    if c[0].toLowerAscii == p: result.add c[1]
