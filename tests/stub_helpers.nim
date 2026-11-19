## Shared incremental build preparation. config.nims/nimble.paths own dependency
## resolution; no per-test nimble solver or incomplete source-mtime cache.
import std/[os, osproc, sequtils, strtabs, strutils, sha1]

proc nimbleDepFlags*(): string =
  ## Out-of-tree probes must explicitly load the project's dependency paths.
  ## `nimble.paths` is a `nimble setup` artifact: present in a dev tree, but
  ## absent in CI, which installs deps into the default nimble path (found by
  ## name without any flags). Only inject flags when the file is there.
  let paths = getCurrentDir() / "nimble.paths"
  if not fileExists(paths):
    return ""
  for line in readFile(paths).splitLines():
    let arg = line.strip
    if arg.startsWith("--path:\"") and arg.endsWith("\""):
      result.add " " & quoteShell("--path:" & arg[8 ..< arg.len - 1])
    elif arg.len > 0:
      result.add " " & quoteShell(arg)

type ConfPair* = tuple[key, val: string]
  ## One harness-owned config line for a spawned 3code child. The former
  ## env-var knobs travel as config keys now: `test` for the
  ## [test] hooks (stub_responses, gui_live, ...), `settings` and
  ## `plugins` for their respective sections.

proc quoteConfVal*(v: string): string =
  ## INI quoting for merged config values: quote only when the value
  ## would not round-trip bare (empty, surrounding whitespace, quotes,
  ## comment markers, or the `=`/`[` structural characters, or a `:` —
  ## parsecfg's alternative key:value separator, which a bare Windows
  ## drive-letters path trips as "invalid token: :" in the child).
  var bare = v.len > 0 and v.strip == v and "\n" notin v
  for ch in v:
    if ch in {'"', ';', '#', '=', '[', ':'}:
      bare = false
  if bare:
    v
  else:
    "\"" & v.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

proc childConfigFile*(xdgConfigHome: string): string =
  ## The config file a spawned child reads when XDG_CONFIG_HOME is
  ## `xdgConfigHome` (the redirect every isolated test uses).
  xdgConfigHome / "3code" / "config"

proc childConfigFile*(env: StringTableRef): string =
  childConfigFile(env.getOrDefault("XDG_CONFIG_HOME"))

proc mergeChildConf*(path: string; test: openArray[ConfPair] = [];
                     settings: openArray[ConfPair] = [];
                     plugins: openArray[ConfPair] = []) =
  ## Merge harness-owned keys into the config file a spawned child
  ## reads. The [test] section is written per call — its keys are
  ## exclusively the harness's (the fd/pipe channel ids plus whatever
  ## the caller passes as `test`), so one spawn's keys never leak into
  ## the next; `settings`/`plugins` keys replace an existing line of
  ## the same section in place, or join the last section of that name.
  ## Missing parent dirs are created; a missing file is started fresh
  ## (a [test]-only config still boots the provider wizard, so
  ## no-config bootstrap tests keep their shape).
  createDir(parentDir(path))
  type Section = tuple[name: string, lines: seq[string]]
  var sections: seq[Section]
  if fileExists(path):
    for l in readFile(path).splitLines():
      if l.strip.len == 0: continue
      let t = l.strip
      if t.startsWith("[") and t.endsWith("]"):
        sections.add (t[1 ..< t.len - 1], @[])
      elif sections.len == 0:
        sections.add ("", @[l])
      else:
        sections[sections.len - 1].lines.add l
  var testEntries: seq[ConfPair] = @test
  proc applyTo(name: string; entries: openArray[ConfPair]) =
    var pending: seq[ConfPair] = @entries
    for si in 0 ..< sections.len:
      if sections[si].name != name: continue
      for li in 0 ..< sections[si].lines.len:
        let eq = sections[si].lines[li].find('=')
        if eq <= 0: continue
        let key = sections[si].lines[li][0 ..< eq].strip
        for pi in countdown(pending.len - 1, 0):
          if pending[pi].key == key:
            sections[si].lines[li] =
              key & " = " & quoteConfVal(pending[pi].val)
            pending.delete(pi)
      if pending.len == 0: return
    if pending.len == 0: return
    for si in countdown(sections.len - 1, 0):
      if sections[si].name == name:
        for (k, v) in pending:
          sections[si].lines.add k & " = " & quoteConfVal(v)
        return
    var fresh: seq[string]
    for (k, v) in pending:
      fresh.add k & " = " & quoteConfVal(v)
    sections.add (name, fresh)
  applyTo("settings", settings)
  applyTo("plugins", plugins)
  var outp: seq[string]
  for sec in sections:
    if sec.name == "test": continue
    if sec.name != "": outp.add "[" & sec.name & "]"
    for l in sec.lines: outp.add l
  if testEntries.len > 0:
    outp.add "[test]"
    for (k, v) in testEntries:
      outp.add k & " = " & quoteConfVal(v)
  writeFile(path, outp.join("\n") & "\n")

proc buildBinary*(defines, outName: string; forceRebuild = false): string =
  # Different options must never replace a binary another test is using.
  let tag = ($secureHash(defines))[0..15].toLowerAscii
  result = getCurrentDir() / "build" / (outName & "_" & tag)
  when defined(windows): result.add ".exe"
  var cmd = "sh tests/tools/build_binary.sh " & result.quoteShell &
    " src/threecode.nim " & defines
  if forceRebuild: cmd.add " --forceBuild:on"
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, output

proc prebuiltStubPath*(): string =
  ## Cross-compiled runners can inject a prebuilt stub binary when Nim is
  ## absent: the CI workflow copies it in and records its path here
  ## (build/prebuilt-stub) instead of exporting an env var.
  let marker = getCurrentDir() / "build" / "prebuilt-stub"
  if fileExists(marker):
    result = readFile(marker).strip
  else:
    result = ""

proc ensureStubBinary*(extraDefines = "", forceRebuild = false): string =
  ## Prebuilt marker wins (see prebuiltStubPath), else build locally.
  let prebuilt = prebuiltStubPath()
  if prebuilt.len > 0:
    doAssert fileExists(prebuilt), "Missing prebuilt stub: " & prebuilt
    return prebuilt
  buildBinary("-d:ssl -d:providerStub --threads:on " & extraDefines,
    "3code_stub", forceRebuild)
