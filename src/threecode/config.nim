import std/[os, parsecfg, streams, strformat, strutils, terminal, uri]
import types, prompts

type
  ProviderRec* = object
    ## In-memory mirror of a [provider] section. `model` is the optional
    ## experimental override (broad name like "glm"/"qwen"/"gpt-oss"); only
    ## honored when --experimental is on. Known-good combos ignore it.
    ## `variants` is the list of API ids this provider exposes.
    name*, url*, key*, variantPrefix*, model*: string
    variants*: seq[string]

proc findVariant*(p: ProviderRec, name: string): int =
  for i, v in p.variants:
    if v == name: return i
  -1

var activeCurrent*: string
var activeProviders*: seq[ProviderRec]
var experimentalEnabled*: bool = false
  ## Set by `-x`/`--experimental`. When true, models outside `KnownGoodCombos`
  ## are allowed; otherwise the gate refuses them.

proc gateExperimental*(p: Profile): bool =
  ## True if the profile is allowed to run a turn under current policy:
  ## empty profile (caller handles that), known-good model, or the
  ## `--experimental` override. False otherwise — caller should bail out
  ## and call `explainExperimentalGate` for the user-facing hint.
  p.name == "" or isKnownGood(p) or experimentalEnabled

proc explainExperimentalGate*(p: Profile) =
  let dot = p.name.find('.')
  let display =
    if dot < 0: p.name
    else: p.name[0 ..< dot] & " " & p.name[dot+1 .. ^1]
  stdout.styledWriteLine fgMagenta,
    "  ", display,
    " is experimental (start 3code with --experimental to use anyway, not recommended)",
    resetStyle

proc hasKnownGoodVariant*(prov: ProviderRec): bool =
  for v in prov.variants:
    if knownGoodModel(prov.name, prov.variantPrefix & v) != "": return true
  false

proc firstKnownGoodCombo*(providers: seq[ProviderRec]): string =
  ## Returns "<provider>.<variant>" of the first (provider, variant) pair across
  ## `providers` that hits a `KnownGoodCombos` entry, or "" if none. Lets a
  ## non-experimental startup recover when the persisted `current` points at
  ## an experimental combo.
  for pr in providers:
    if pr.url == "" or pr.key == "": continue
    for v in pr.variants:
      if knownGoodModel(pr.name, pr.variantPrefix & v) != "":
        return pr.name & "." & v
  ""

proc currentProvider*(): ProviderRec =
  let dot = activeCurrent.find('.')
  let name = if dot < 0: activeCurrent else: activeCurrent[0 ..< dot]
  for pr in activeProviders:
    if pr.name == name: return pr
  ProviderRec()

proc splitVariants*(s: string): seq[string] =
  ## Whitespace- (and comma-) separated list of bare variant names. Model
  ## lives elsewhere — KnownGoodCombos hardcodes it; the [provider]
  ## `model = ...` key supplies an experimental override.
  for raw in s.splitWhitespace:
    let v = raw.strip(chars = {',', ' '})
    if v.len > 0: result.add v

proc formatVariants*(variants: seq[string]): string = variants.join(" ")

proc expandEnvValue(s: string): string =
  ## Expand a leading `$VAR` reference (after any surrounding whitespace) to
  ## the value of the environment variable. Plain values pass through
  ## unchanged.
  let t = s.strip
  if t.len > 1 and t[0] == '$':
    return getEnv(t[1 .. ^1])
  s

proc parseConfigFile*(path: string): (string, seq[ProviderRec]) =
  ## Streaming parse so that repeated [provider] sections accumulate as a list.
  var current = ""
  var providers: seq[ProviderRec]
  var section = ""
  var prov: ProviderRec
  var inProvider = false
  let stream = newFileStream(path, fmRead)
  if stream == nil: die &"cannot open {path}", ExitConfig
  var p: CfgParser
  p.open(stream, path)
  proc flush() =
    if inProvider:
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
      of "settings":
        if e.key == "current": current = v
      of "provider":
        case e.key
        of "name": prov.name = v
        of "url": prov.url = v.strip(chars = {'/', ' '})
        of "key": prov.key = v
        of "variant_prefix": prov.variantPrefix = v
        of "model": prov.model = v
        of "variants": prov.variants = splitVariants(v)
        else: discard
      else: discard
    of cfgError:
      die &"{path}: {e.msg}", ExitConfig
  p.close
  (current, providers)

proc quoteVal(s: string): string =
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
  for pr in providers:
    buf.add "\n[provider]\n"
    buf.add "name = " & quoteVal(pr.name) & "\n"
    buf.add "url = " & quoteVal(pr.url) & "\n"
    buf.add "key = " & quoteVal(pr.key) & "\n"
    if pr.variantPrefix != "":
      buf.add "variant_prefix = " & quoteVal(pr.variantPrefix) & "\n"
    if pr.model != "":
      buf.add "model = " & quoteVal(pr.model) & "\n"
    buf.add "variants = " & quoteVal(formatVariants(pr.variants)) & "\n"
  writeFile(path, buf)

proc configPath*(): string =
  getConfigDir() / "3code" / "config"

proc loadStateOrEmpty*(path: string): (string, seq[ProviderRec]) =
  if not fileExists(path): return ("", @[])
  parseConfigFile(path)

proc resolveModel*(prov: ProviderRec, prof: Profile): string =
  ## Model is resolved at profile-build time:
  ## 1. KnownGoodCombos hardcode (always wins; ignores config and -x)
  ## 2. provider-level `model = ...` — only honored under --experimental
  ## 3. default → "glm"
  let kg = knownGoodModel(prof)
  if kg != "": return kg
  if experimentalEnabled and prov.model.strip != "":
    return prov.model.strip.toLowerAscii
  "glm"

proc buildProfile*(current: string, providers: seq[ProviderRec],
                  wanted: string): Profile =
  ## Resolve a Profile from in-memory state; empty Profile on failure.
  if providers.len == 0: return Profile()
  var pick = wanted
  if pick == "": pick = current
  if pick == "": pick = providers[0].name
  let dot = pick.find('.')
  let name = if dot < 0: pick else: pick[0 ..< dot]
  var variant = if dot < 0: "" else: pick[dot + 1 .. ^1]
  for pr in providers:
    if pr.name == name:
      if pr.url == "" or pr.key == "" or pr.variants.len == 0:
        return Profile()
      if variant == "":
        variant = pr.variants[0]
      if pr.findVariant(variant) < 0:
        return Profile()
      var prof = Profile(name: pr.name & "." & variant, url: pr.url,
                         key: pr.key, variantPrefix: pr.variantPrefix,
                         variant: variant)
      prof.model = resolveModel(pr, prof)
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
  let (current, providers) = parseConfigFile(path)
  if providers.len == 0:
    die &"no [provider] section in {path}", ExitConfig
  var pick = wanted
  if pick == "": pick = current
  if pick == "": pick = providers[0].name
  if pick == "":
    die &"no current provider set in {path} and first [provider] has no name", ExitConfig
  let dot = pick.find('.')
  let name = if dot < 0: pick else: pick[0 ..< dot]
  var variant = if dot < 0: "" else: pick[dot + 1 .. ^1]
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
  if prov.variants.len == 0: die &"provider '{name}': variants not set in {path}", ExitConfig
  if variant == "":
    variant = prov.variants[0]
  if prov.findVariant(variant) < 0:
    die &"provider '{name}': variant '{variant}' not in variants list ({prov.variants.join(\", \")})", ExitConfig
  var prof = Profile(name: prov.name & "." & variant, url: prov.url, key: prov.key,
                     variantPrefix: prov.variantPrefix, variant: variant)
  prof.model = resolveModel(prov, prof)
  if wanted == "" and not experimentalEnabled and not isKnownGood(prof):
    let fallback = firstKnownGoodCombo(providers)
    if fallback != "":
      let alt = buildProfile(fallback, providers, "")
      if alt.name != "": return alt
  prof

const ProviderCatalog*: seq[(string, string)] = @[
  ("anthropic",   "https://api.anthropic.com/v1"),
  ("baseten",     "https://inference.baseten.co/v1"),
  ("cerebras",    "https://api.cerebras.ai/v1"),
  ("deepinfra",   "https://api.deepinfra.com/v1/openai"),
  ("deepseek",    "https://api.deepseek.com/v1"),
  ("fireworks",   "https://api.fireworks.ai/inference/v1"),
  ("friendli",    "https://api.friendli.ai/serverless/v1"),
  ("google",      "https://generativelanguage.googleapis.com/v1beta/openai"),
  ("groq",        "https://api.groq.com/openai/v1"),
  ("hyperbolic",  "https://api.hyperbolic.xyz/v1"),
  ("mistral",     "https://api.mistral.ai/v1"),
  ("moonshot",    "https://api.moonshot.ai/v1"),
  ("moonshot-cn", "https://api.moonshot.cn/v1"),
  ("nebius",      "https://api.tokenfactory.nebius.com/v1"),
  ("nvidia",      "https://integrate.api.nvidia.com/v1"),
  ("openai",      "https://api.openai.com/v1"),
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
  ("zai-coding",  "https://api.z.ai/api/coding/paas/v4"),
]

proc catalogUrl*(name: string): string =
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
  for (p, n) in KeyPrefixCatalog:
    if key.startsWith(p): return n
  ""

proc defaultNameFromUrl*(url: string): string =
  let host = parseUri(url).hostname
  if host == "": return ""
  let labels = host.split('.')
  if labels.len >= 2: labels[^2]
  else: labels[0]

proc commonVariantPrefix*(models: seq[string]): string =
  if models.len < 2: return ""
  var prefix = models[0]
  for m in models[1 .. ^1]:
    var i = 0
    while i < prefix.len and i < m.len and prefix[i] == m[i]:
      inc i
    prefix = prefix[0 ..< i]
    if prefix.len == 0: return ""
  let slash = prefix.rfind('/')
  if slash < 0: "" else: prefix[0 .. slash]

proc curatedFor*(provider: string): (string, seq[string]) =
  ## Returns (commonPrefix, modelsWithoutPrefix) from KnownGoodCombos
  ## for the given provider name.
  var fullIds: seq[string]
  let p = provider.toLowerAscii
  for c in KnownGoodCombos:
    if c[0].toLowerAscii == p: fullIds.add c[1]
  let prefix = commonVariantPrefix(fullIds)
  var stripped: seq[string]
  for m in fullIds:
    if prefix != "" and m.startsWith(prefix): stripped.add m[prefix.len .. ^1]
    else: stripped.add m
  (prefix, stripped)
