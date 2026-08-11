## Known-good combo harvester.
##
## Walks configured providers, fetches their live model lists via
## GET /models, and prints `KnownGoodCombos`-style entries for every
## listed model whose underlying model already exists on another
## provider in the registry. Parameters (family, version, variant,
## reasoning, temperature, maxTokens, xmlToolCalls, contextWindow) are
## copied from the existing entry, so the printed tuples can be pasted
## into `KnownGoodCombos` in src/threecode/prompts.nim after review.
##
## Model ids vary wildly between providers (`zai-org/GLM-5.2` vs
## `z-ai/glm-5.2` vs `glm-5.2` vs `openai-gpt-oss-120b`), so matching
## is by normalized short id: lowercase basename with non-alphanumerics
## stripped (`zaiorgglm52`). Version variants keep their dots so
## `glm-4.7` and `glm-47` never collide.
##
## Usage:
##   nim c -r tools/harvest_models.nim venice              # one provider
##   nim c -r tools/harvest_models.nim --all               # every configured provider
##   nim c -r tools/harvest_models.nim --url:URL --key:K --name:x  # ad hoc
##   nim c -r tools/harvest_models.nim venice --update-models      # write config
##
## Config is read from ~/.config/3code/config (override with
## --config:PATH). Providers without an API key are skipped with a
## note. `--update-models` rewrites the provider's `models` line in the
## config with the full fetched list.

import std/[algorithm, httpclient, json, os, parseopt, parsecfg, sets,
            streams, strutils, tables]
import threecode/config as tconfig
import threecode/prompts
import threecode/util

type
  ProviderConf = object
    name, url, key: string
    models: seq[string]

proc die(msg: string) {.noreturn.} =
  stderr.writeLine "harvest_models: " & msg
  quit 1

proc configPath(): string =
  getHomeDir() / ".config" / "3code" / "config"

proc readProviders(path: string): seq[ProviderConf] =
  ## Minimal parsecfg pass: needs only name/url/key/models from each
  ## [provider] section, so it ignores the strict schema in config.nim.
  if not fileExists(path):
    die "config not found: " & path
  var cur: ProviderConf
  var inProvider = false
  let f = newFileStream(path, fmRead)
  if f == nil: die "cannot read " & path
  var p: CfgParser
  open(p, f, path)
  while true:
    let e = next(p)
    case e.kind
    of cfgEof: break
    of cfgSectionStart:
      if inProvider and cur.name != "": result.add cur
      cur = ProviderConf()
      inProvider = e.section == "provider"
    of cfgKeyValuePair:
      if not inProvider: continue
      case e.key
      of "name": cur.name = e.value
      of "url": cur.url = e.value
      of "key": cur.key = e.value
      of "models": cur.models = e.value.splitWhitespace()
      else: discard
    else: discard
  close(p)
  if inProvider and cur.name != "": result.add cur

proc fetchModels(url, key: string): seq[string] =
  ## Model ids from GET /models. Unreachable or erroring endpoints return
  ## an empty seq with a note on stderr, so --all keeps going past dead
  ## local providers.
  let client = newHttpClient(timeout = 30_000, userAgent = "3code-harvest",
                             sslContext = bundledSslContext())
  defer: client.close()
  if key != "":
    client.headers["Authorization"] = "Bearer " & key
  let resp = try: client.get(url & "/models")
             except CatchableError as e:
               stderr.writeLine "#   GET /models failed: " & e.msg
               return @[]
  if resp.code.int != 200:
    stderr.writeLine "#   GET /models: HTTP " & $resp.code.int & " — " &
        resp.body[0 ..< min(160, resp.body.len)]
    return @[]
  let j = try: parseJson(resp.body)
          except CatchableError:
            stderr.writeLine "#   /models returned non-JSON"
            return @[]
  let arr = if j.kind == JArray: j
            elif "data" in j and j["data"].kind == JArray: j["data"]
            else:
              stderr.writeLine "#   unexpected /models response shape"
              return @[]
  for item in arr:
    if item.kind == JString: result.add item.getStr
    elif item.kind == JObject and "id" in item: result.add item["id"].getStr

# --- model id normalization -------------------------------------------------

const VersionMarkers = ["pro", "mini", "nano", "flash", "turbo", "air",
  "lite", "max", "plus", "free", "latest", "fast", "preview", "instruct",
  "thinking", "coder", "highspeed"]

proc shortId(id: string): string =
  ## Bare model id: basename minus provider/owner prefixes, with dots
  ## kept (version separators matter) and dashes between name segments
  ## preserved. `zai-org/GLM-5.2` and `z-ai/glm-5-2` both become
  ## `glm-5.2`; `openai-gpt-oss-120b` becomes `gpt-oss-120b`.
  var s = id
  let slash = s.rfind('/')
  if slash >= 0: s = s[slash + 1 .. ^1]
  s = s.toLowerAscii
  # venice flattens "org/model" to "org-model"; strip known owner prefixes
  for p in ["accounts-fireworks-models-", "zai-org-", "z-ai-", "openai-",
            "deepseek-ai-", "moonshotai-", "minimaxai-", "tencent-",
            "google-", "nvidia-", "alibaba-", "x-ai-", "xai-", "meta-",
            "inclusionai-", "thinkingmachines-", "xiaomi-", "tee-"]:
    if s.startsWith(p):
      s = s[p.len .. ^1]
      break
  s

proc norm(s: string): string =
  ## Aggressive comparison key: alphanumerics only.
  for c in s.toLowerAscii:
    if c in {'a'..'z', '0'..'9'}: result.add c

proc isVersionVariant(a, b: string): bool =
  ## True when a and b are the same id up to dots vs dashes in the
  ## version part: `glm-4.7` vs `glm-47`, `kimi-k2.6` vs `kimi-k2-6`.
  let x = a.replace("-", "").replace(".", "")
  let y = b.replace("-", "").replace(".", "")
  x == y

proc buildRegistryIndex(): Table[string, seq[int]] =
  ## normalized shortId -> indices into KnownGoodCombos, excluding the
  ## target provider's own entries (matched at harvest time).
  for i, c in KnownGoodCombos:
    let k = norm(shortId(c.model))
    result.mgetOrPut(k, @[]).add i

proc findExisting(index: Table[string, seq[int]], id, prov: string): seq[int] =
  ## Registry indices for entries matching this model id on other
  ## providers. Exact normalized match first, then version-variant match.
  let s = shortId(id)
  let k = norm(s)
  if k in index:
    for i in index[k]:
      if KnownGoodCombos[i].provider != prov: result.add i
  if result.len == 0:
    # version-variant scan: same normalized id, differs only in ./- around
    # the version digits
    for key, idxs in index:
      var cand = ""
      for i in idxs:
        if KnownGoodCombos[i].provider == prov: continue
        cand = shortId(KnownGoodCombos[i].model)
        if isVersionVariant(s, cand):
          result.add i
      if result.len > 0: break

proc fmtFloat(f: float): string =
  if f == f.int.float: $f.int & ".0" else: $f

proc fmtTokens(n: int): string =
  let s = $n
  var groups: seq[string]
  var i = s.len
  while i > 3:
    groups.insert s[i-3 ..< i]
    i -= 3
  groups.insert s[0 ..< i]
  groups.join("_")

proc renderEntry(prov, id: string, src: KnownGoodCombo): string =
  "(\"$1\", \"$2\", \"$3\", \"$4\", \"$5\", \"$6\", $7, $8, $9, $10)," % [
    prov, id, src.family, src.version, src.variant, src.reasoning,
    fmtFloat(src.temperature), $src.maxTokens, $src.xmlToolCalls,
    fmtTokens(src.contextWindow)]

proc syncRegistry(path: string, live: Table[string, seq[string]]): string =
  ## Returns the registry const block rewritten against the live model
  ## lists. Entries whose provider was queried keep only models the
  ## provider still lists (matched case-insensitively); models the
  ## provider lists but the registry lacks are appended using params
  ## from the same model on another provider. Entries for providers
  ## that weren't queried are kept verbatim. Duplicate (provider,
  ## model) rows collapse to the first occurrence. Comment lines
  ## between entries are kept only when at least one following entry
  ## survives.
  let text = readFile(path)
  let head = "const KnownGoodCombos*: seq[KnownGoodCombo] = @["
  let start = text.find(head)
  if start < 0: die "registry const not found in " & path
  let tail = "\n  ]"
  let close = text.find(tail, start)
  if close < 0: die "registry closing bracket not found"
  let body = text[start + head.len ..< close]
  var liveNorm: Table[string, HashSet[string]]
  for prov, ids in live:
    var s: HashSet[string]
    for id in ids: s.incl id.toLowerAscii
    liveNorm[prov] = s
  var kept: seq[string]  # rendered lines, comments included
  var seenKey: HashSet[string]
  var pendingComments: seq[string]
  var dropped, added = 0
  template flushComments() =
    for c in pendingComments: kept.add c
    pendingComments.setLen 0
  for raw in body.splitLines():
    let line = raw.strip()
    if line == "" or line.startsWith("#"):
      pendingComments.add raw
      continue
    if not line.startsWith("("):
      pendingComments.add raw
      continue
    # parse the tuple back into fields; ids can contain any char but '"'
    var fields: seq[string]
    var cur = ""
    var inStr = false
    var i = 1  # skip '('
    let src = line
    while i < src.len and (src[i] != ')' or inStr):
      let c = src[i]
      if c == '"': inStr = not inStr; cur.add c
      elif c == ',' and not inStr: fields.add cur.strip(); cur = ""
      else: cur.add c
      inc i
    if cur.strip() != "": fields.add cur.strip()
    if fields.len != 10:
      pendingComments.add raw  # unparseable: keep verbatim
      continue
    proc unq(s: string): string =
      if s.len >= 2 and s[0] == '"': s[1 .. ^2] else: s
    let e: KnownGoodCombo = (provider: unq(fields[0]), model: unq(fields[1]),
      family: unq(fields[2]), version: unq(fields[3]), variant: unq(fields[4]),
      reasoning: unq(fields[5]), temperature: parseFloat(fields[6]),
      maxTokens: parseInt(fields[7].replace("_", "")),
      xmlToolCalls: fields[8] == "true",
      contextWindow: parseInt(fields[9].replace("_", "")))
    let key = e.provider.toLowerAscii & "\0" & e.model.toLowerAscii
    if key in seenKey:
      inc dropped
      continue
    seenKey.incl key
    if e.provider in liveNorm and
       e.model.toLowerAscii notin liveNorm[e.provider]:
      stderr.writeLine "# drop " & e.provider & " " & e.model & " (no longer listed)"
      inc dropped
      continue
    flushComments()
    kept.add "    " & renderEntry(e.provider, e.model, e)
  # additions: live models of queried providers with no surviving entry.
  # Param source prefers a provider that wasn't itself just queried
  # (its entry might be slated for removal); falls back to any hit.
  let index = buildRegistryIndex()
  for prov, ids in live:
    for id in ids.sorted():
      let key = prov.toLowerAscii & "\0" & id.toLowerAscii
      if key in seenKey: continue
      let hits = findExisting(index, id, prov)
      var params: KnownGoodCombo
      var found = false
      for h in hits:
        if KnownGoodCombos[h].provider in live: continue
        params = KnownGoodCombos[h]; found = true; break
      if not found and hits.len > 0:
        params = KnownGoodCombos[hits[0]]; found = true
      if not found: continue
      seenKey.incl key
      inc added
      stderr.writeLine "# add " & prov & " " & id
      kept.add "    " & renderEntry(prov, id, params)
  var res = text[0 ..< start + head.len]
  for line in kept:
    res.add (if line.strip().startsWith("("): "\n" & line
             else: "\n" & line)
  res.add "\n  ]" & text[close + tail.len .. ^1]
  stderr.writeLine "# registry: " & $seenKey.len & " combos (" & $added &
                   " added, " & $dropped & " dropped)"
  res

proc updateModelsLine(path, provName: string, models: seq[string]) =
  ## Rewrites the `models` key of the matching [provider] section in the
  ## config. Name-only match (first section wins).
  let lines = readFile(path).splitLines()
  var outLines: seq[string]
  var inTarget = false
  var done = false
  for i, line in lines:
    let t = line.strip()
    if t == "[provider]":
      inTarget = false
      if i + 1 < lines.len:
        # peek for name on following lines until next section
        var j = i + 1
        while j < lines.len and not lines[j].strip().startsWith("["):
          let kv = lines[j].strip()
          if kv.startsWith("name") and kv.contains('='):
            let v = kv.split('=', 1)[1].strip().strip(chars = {'"', ' '})
            if v == provName and not done:
              inTarget = true
            break
          inc j
    if inTarget and t.startsWith("models") and t.contains('='):
      outLines.add "models = \"" & models.join(" ") & "\""
      inTarget = false
      done = true
      continue
    outLines.add line
  if not done:
    die "no [provider] section named \"" & provName & "\" with a models key"
  writeFile(path, outLines.join("\n") & "\n")

# --- main --------------------------------------------------------------------

var targetName = ""
var adhocUrl, adhocKey = ""
var all = false
var doUpdate = false
var doSync = false
var cfgFile = configPath()
const PromptsPath = "src/threecode/prompts.nim"

for kind, key, val in getopt():
  case kind
  of cmdArgument: targetName = key
  of cmdLongOption, cmdShortOption:
    case key
    of "all": all = true
    of "update-models": doUpdate = true
    of "sync": doSync = true
    of "url": adhocUrl = val
    of "key": adhocKey = val
    of "name": discard  # targetName from argument
    of "config": cfgFile = val
    else: die "unknown option --" & key
  of cmdEnd: discard

if doSync and adhocUrl != "":
  die "--sync requires providers from config (use --all or a name)"

if not all and targetName == "" and adhocUrl == "":
  die "usage: harvest_models <provider> | --all | --url:U --key:K [--update-models]"

var targets: seq[ProviderConf]
if adhocUrl != "":
  targets.add ProviderConf(name: (if targetName != "": targetName else: "adhoc"),
                           url: adhocUrl, key: adhocKey)
else:
  let provs = readProviders(cfgFile)
  if all:
    for p in provs: targets.add p
  else:
    for p in provs:
      if p.name == targetName: targets.add p; break
    if targets.len == 0:
      # fall back to catalog URL when configured under a different shape
      let u = catalogUrl(targetName)
      if u != "":
        targets.add ProviderConf(name: targetName, url: u)
      else:
        die "provider \"" & targetName & "\" not in " & cfgFile

let index = buildRegistryIndex()

var seen: HashSet[string]
var seenProv: HashSet[string]
var entries: seq[string]
var liveModels: Table[string, seq[string]]
for t in targets:
  if t.key == "" and adhocUrl == "":
    stderr.writeLine "# " & t.name & ": no key in config, skipped"
    continue
  if t.url == "":
    stderr.writeLine "# " & t.name & ": no url, skipped"
    continue
  if t.name in seenProv:
    stderr.writeLine "# " & t.name & ": duplicate config section, skipped"
    continue
  seenProv.incl t.name
  let models = fetchModels(t.url, t.key)
  if models.len == 0:
    stderr.writeLine "# " & t.name & ": no models, skipped"
    continue
  liveModels[t.name] = models
  stderr.writeLine "# " & t.name & ": " & $models.len & " models listed"
  if doUpdate or doSync:
    updateModelsLine(cfgFile, t.name, models)
    stderr.writeLine "# " & t.name & ": models line updated in " & cfgFile
  var matched, skipped = 0
  for id in models.sorted():
    let hits = findExisting(index, id, t.name)
    if hits.len == 0:
      inc skipped
      continue
    # among matching sources prefer the one with the largest context
    # window: it's the best-documented variant of the model
    var best = hits[0]
    for h in hits:
      if KnownGoodCombos[h].contextWindow > KnownGoodCombos[best].contextWindow:
        best = h
    let src = KnownGoodCombos[best]
    let line = renderEntry(t.name, id, src)
    if line in seen: continue
    seen.incl line
    entries.add line
    inc matched
  stderr.writeLine "# " & t.name & ": " & $matched & " matched, " &
                   $skipped & " without known-good counterpart"

if doSync:
  writeFile(PromptsPath, syncRegistry(PromptsPath, liveModels))
  stderr.writeLine "# " & PromptsPath & " rewritten"
else:
  for e in entries:
    echo e
  stderr.writeLine "# " & $entries.len & " candidate entries"
