## Normalized model names for config files and user input.
##
## Providers spell the same model a dozen ways: `zai-org/GLM-5.3-Flash`,
## `zai-glm-5-3-flash`, `glm-5p3-flash`, `GLM-5.3-Flash`. The wire id
## stays untouched; the normalized form is what 3code shows, matches,
## and writes back to the config file. Format:
##
##   family[-version][-designator][-qualifier...][:suffix]
##
## `family` is required and must be in `ModelFamilies`; everything else
## is optional. The version is the leading run of numeric tokens after
## the family, dot-joined (`5-3` and `5p3` both become `5.3`; a single
## digit drops the dash: `hy3`, `kimi3`, `deepseek4`). The designator is
## the first non-numeric token (`flash`, `pro`, `sol`, `preview`); the
## rest are qualifiers (`a3b`, `0731`, `vision-exp`), kept as-is but
## lowercased. The suffix is the `:free` tail. Author prefixes
## (`zai-org/`, `accounts/fireworks/models/`) are stripped.

import std/[sequtils, strutils]

const ModelFamilies* = [
  "gpt-oss", "glm", "qwen", "deepseek", "kimi", "minimax", "grok", "gpt",
  "mimo", "inkling", "laguna", "hy", "ling", "longcat", "0xalpha",
  "nemotron",
]
  ## Hard list of model families, mirroring the families in
  ## `KnownGoodCombos` and `systemPromptFor`. `gpt-oss` is listed before
  ## `gpt` so the longer family wins.

const ModelAliases* = [
  ("k3", "kimi-3"),
  ("kimi-for-coding", "kimi-2.7-code"),
  ("kimi-for-coding-highspeed", "kimi-2.7-code-highspeed"),
  ("o1", "gpt-o1"),
  ("o1-mini", "gpt-o1-mini"),
  ("o3", "gpt-o3"),
  ("o3-mini", "gpt-o3-mini"),
  ("o4-mini", "gpt-o4-mini"),
  ("ox-alpha", "0xalpha-1"),
  ("x-preview-f", "0xalpha-1-f"),
]
  ## Bare names that don't carry their family on the surface. Matched
  ## against the slash-stripped, suffix-stripped name (exact, or as a
  ## dash-prefix) before family detection.

type
  ModelName* = object
    family*: string      ## from `ModelFamilies`, always lowercase
    version*: string     ## "5.3", "3", "2.4t"; "" when absent
    designator*: string  ## "flash", "pro", "sol", "preview"; "" when absent
    qualifiers*: seq[string]  ## "a3b", "0731", "vision-exp", "latest"
    suffix*: string      ## ":free" tail without the colon; "" when absent

func normalizeVersion*(v: string): string =
  ## `5p3` / `5-3` / `5_3` -> `5.3`; `3` stays `3`; `2.4t` stays `2.4t`.
  var s = v.toLowerAscii
  if s.len > 1 and s[0] == 'v' and s[1] in {'0'..'9'}: s = s[1 .. ^1]
  var outp = ""
  for c in s:
    case c
    of 'p', '-', '_', '.', ' ': outp.add '.'
    else: outp.add c
  while ".." in outp:
    outp = outp.replace("..", ".")
  outp.strip(chars = {'.'})

func format*(m: ModelName): string =
  ## Canonical string form: `family-version-designator-qualifiers:suffix`.
  ## The dash before the version is dropped when the version is a single
  ## digit (`hy3`, not `hy-3`).
  result = m.family
  if m.version != "":
    if m.version.len > 1 or m.version[0] notin {'0'..'9'}:
      result.add "-"
    result.add m.version
  if m.designator != "":
    result.add "-" & m.designator
  for q in m.qualifiers:
    result.add "-" & q
  if m.suffix != "":
    result.add ":" & m.suffix

func normalizeModelName*(name: string): string =
  ## Full model id or bare name to canonical form. Unparseable input
  ## (no known family) is returned lowercased and unchanged.
  var s = name.strip.toLowerAscii
  # Author/org prefix: everything up to the last slash.
  let slash = s.rfind('/')
  if slash >= 0: s = s[slash + 1 .. ^1]
  # Suffix: everything after the first `:`.
  var suffix = ""
  let colon = s.find(':')
  if colon >= 0:
    suffix = s[colon + 1 .. ^1]
    s = s[0 ..< colon]
  # Aliases resolve before family detection.
  for (a, expansion) in ModelAliases:
    if s == a:
      s = expansion
      break
    if s.startsWith(a & "-"):
      s = expansion & s[a.len .. ^1]
      break
  # Family: exact, dash-prefix, or glued (`qwen3.8`, `hy3`).
  var fam = ""
  var rest = ""
  for f in ModelFamilies:
    if s == f:
      fam = f
      break
    let pfx = f & "-"
    if s.startsWith(pfx):
      fam = f
      rest = s[pfx.len .. ^1]
      break
    if s.startsWith(f) and s.len > f.len and s[f.len] in {'0'..'9', 'v'}:
      fam = f
      rest = s[f.len .. ^1]
      break
  if fam == "":
    # Vendor-prefixed without slash: `zai-glm-5-3-flash`,
    # `deepseek-ai-deepseek-v4-pro`. Find the family marker mid-string.
    for f in ModelFamilies:
      let marker = "-" & f & "-"
      let idx = s.find(marker)
      if idx >= 0:
        fam = f
        rest = s[idx + marker.len .. ^1]
        break
      if s.endsWith("-" & f):
        fam = f
        rest = ""
        break
  if fam == "":
    return name.strip.toLowerAscii  # unknown: keep as-is (lowercased)
  # A single-letter version marker rides on the first token (`k2p6`,
  # `m2.7`, `v4`); strip it so the digits parse as a version.
  if rest.len > 1 and rest[0] in {'k', 'm', 'v'} and rest[1] in {'0'..'9'}:
    rest = rest[1 .. ^1]
  var toks = rest.split('-').filterIt(it != "")
  # Version: the leading run of numeric tokens, dot-joined. `5` + `3`
  # (from `glm-5-3-flash`) merges to `5.3`; the run ends at the first
  # token that isn't purely numeric (`35b`, `2.4t`).
  var version = ""
  while toks.len > 0 and toks[0].len > 0 and
        toks[0].allIt(it in {'0'..'9', '.', 'p'}):
    let t = normalizeVersion(toks[0])
    version = if version == "": t else: version & "." & t
    toks = toks[1 .. ^1]
  # Designator: the first non-numeric token after the version. A version
  # spelled after the designator (`laguna-s-2.1`, `grok-build-0.1`) stays
  # where it is: reordering would mangle product names.
  var designator = ""
  if toks.len > 0 and not (toks[0].len > 0 and toks[0][0] in {'0'..'9'}):
    designator = toks[0]
    toks = toks[1 .. ^1]
  format(ModelName(family: fam, version: version, designator: designator,
                   qualifiers: toks, suffix: suffix))
