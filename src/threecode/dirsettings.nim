## Directory-specific settings: the `.3code` store, cascading up parents.
##
## Every directory can carry its own settings store: a `.3code` directory
## right in it (the default), or a per-directory directory under the user
## config root (`~/.config/3code/dirs/<mangled-path>/`) when
## `[settings] dirconfig = "user"` says so. The store holds the
## directory's own `config` (an ini whose `[settings]` section overrides
## the user config: `current`, `sandbox = off`, ...), its `sandbox`
## policy file, and the harness mode files (`goal`, `achieved`,
## `goal-cancelled`, `cybernetic`, ...).
##
## Resolution cascades: for a setting, the directory's own store wins,
## then each ancestor's store, nearest first; the user config is the
## floor. A store that does not set a key never blocks a farther one.
## Legacy layouts stay readable: a root-level `.sandbox` policy file, a
## `goal.md` in the project root, and the old
## `~/.local/share/3code/dirs/<mangled>.current` sticky-current file are
## consulted as fallbacks so an upgraded tree keeps working.

import std/[os, options, parsecfg, streams, strutils, tables]
import types, util
from algorithm import reversed

const
  StoreDirName* = ".3code"
    ## The directory-specific store, directly in the project dir.
  StoreConfigFile* = "config"
    ## The store's config override (`[settings]` section).
  DirConfigValues* = ["project", "user"]
    ## Legal `[settings] dirconfig` values.

var dirConfigLocation* = "project"
  ## Where directory-specific settings live: "project" (default) puts
  ## the store at `<dir>/.3code`, "user" puts it at
  ## `userConfigRoot()/dirs/<mangled-dir>`. Read from the user config's
  ## `[settings] dirconfig` before any store lookup.

var dirSandboxOverridden* = false
var dirWallWarnOverridden* = false
  ## True once a directory config set `sandbox` / `sandbox_wall_warn`,
  ## so `writeConfigFile` does not leak the directory's effective value
  ## into the user config as if the user had set it there.
var globalSandboxEnabled* = true
var globalWallWarn* = true
  ## The user-config values before the directory overlay. While an
  ## override is in effect, `writeConfigFile` persists THESE (not the
  ## effective value) so a directory's `sandbox = off` never edits the
  ## user config, and a global `off` is never dropped because a
  ## directory turned the sandbox back on.

# ---------------------------------------------------------------------------
# Store locations
# ---------------------------------------------------------------------------

proc mangleDirPath*(dir: string): string =
  ## Collision-free flat name for `dir` (same scheme as session.nim's
  ## `mangleCwd`: escape `_` to `__`, then separators to `_`, cap + digest
  ## past NAME_MAX), used as the per-directory directory name under the
  ## user config root.
  var s = dir.replace('\\', '/')
  if s.startsWith("/"): s = s[1 ..< s.len]
  s = s.replace("_", "__")
  s = s.replace("/", "_")
  when defined(windows):
    s = s.replace(":", "_")
  if s.len == 0: s = "root"
  if s.len > util.MangledNameCap:
    s = s[0 ..< util.MangledNameCap - 17] & "-" & fnv1aHex(s)
  s

proc storeDirFor*(dir: string): string =
  ## The settings store directory for `dir` (which need not exist).
  if dirConfigLocation == "user":
    userConfigRoot() / "dirs" / mangleDirPath(dir)
  else:
    dir / StoreDirName

proc storeFileFor*(dir, name: string): string =
  ## Path of `name` (e.g. "config", "sandbox", "goal") in `dir`'s store.
  storeDirFor(dir) / name

proc ancestorsNearestFirst*(cwd: string): seq[string] =
  ## `cwd` and every ancestor, nearest first. Stops at the filesystem
  ## root; a relative `cwd` degenerates to just itself.
  var d = cwd
  result.add d
  while true:
    let (head, tail) = splitPath(d)
    if tail.len == 0 or head == d: break
    result.add head
    d = head

proc cascadeStoreFile*(cwd, name: string): string =
  ## The nearest existing `<store>/name` walking cwd upward; "" if no
  ## ancestor store carries one. Read-side companion of `storeFileFor`.
  for d in ancestorsNearestFirst(cwd):
    let p = storeFileFor(d, name)
    if fileExists(p): return p
  ""

# ---------------------------------------------------------------------------
# The store's config override
# ---------------------------------------------------------------------------

proc readStoreSettings*(storeDir: string): Table[string, string] =
  ## The `[settings]` map from a store's `config` file, raw values.
  ## Missing or malformed file reads empty: a store that carries only a
  ## sandbox policy or goal file is still a valid store.
  let path = storeDir / StoreConfigFile
  if not fileExists(path): return result
  let stream = newFileStream(path, fmRead)
  if stream == nil: return result
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
      if section == "settings": result[e.key] = e.value
    else: discard
  p.close()

proc cascadeConfigValue*(cwd, key: string): string =
  ## Nearest-wins `[settings] key` from the store cascade; "" when no
  ## ancestor store sets it. The user config's own value is NOT in this
  ## cascade — callers apply it first and treat this as the override.
  for d in ancestorsNearestFirst(cwd):
    let t = readStoreSettings(storeDirFor(d))
    if t.hasKey(key) and t[key].strip != "":
      return t[key].strip
  ""

proc applyStoreBooleans*(storeDir: string) =
  ## Apply one store's `sandbox` / `sandbox_wall_warn` switches to the
  ## process globals. Called nearest-last so nearer stores win.
  let t = readStoreSettings(storeDir)
  template boolean(key: string): Option[bool] =
    let v = t.getOrDefault(key, "").strip.toLowerAscii
    case v
    of "on", "true", "yes", "1": some(true)
    of "off", "false", "no", "0": some(false)
    else: none(bool)
  for key in ["sandbox", "sandbox_enabled"]:
    let b = boolean(key)
    if b.isSome:
      sandboxEnabled = b.get
      dirSandboxOverridden = true
  let w = boolean("sandbox_wall_warn")
  if w.isSome:
    sandboxWallWarn = w.get
    dirWallWarnOverridden = true

proc applyDirConfig*(cwd: string) =
  ## Overlay the store cascade's settings onto the globals, farthest
  ## store first so the nearest directory wins per key. Idempotent; runs
  ## at startup before the sandbox arms and again after the full config
  ## parse (which re-applies the user config's own switches).
  dirSandboxOverridden = false
  dirWallWarnOverridden = false
  globalSandboxEnabled = sandboxEnabled
  globalWallWarn = sandboxWallWarn
  var existing: seq[string]
  for d in ancestorsNearestFirst(cwd):
    let s = storeDirFor(d)
    if dirExists(s): existing.add s
  for s in existing.reversed:
    applyStoreBooleans(s)

# ---------------------------------------------------------------------------
# Sticky current provider
# ---------------------------------------------------------------------------

proc legacyDirCurrentPath*(cwd: string): string =
  ## The pre-store sticky-current file (`<data>/dirs/<mangled>.current`).
  userDataRoot() / "dirs" / (mangleDirPath(cwd) & ".current")

proc legacyDirCurrentFor*(cwd: string): string =
  ## The legacy sticky current for exactly `cwd` (never an ancestor):
  ## that is all the old format ever recorded.
  let path = legacyDirCurrentPath(cwd)
  if fileExists(path): readFile(path).strip else: ""

proc dirCurrentFor*(cwd: string): string =
  ## The sticky `provider.model` for this directory: the nearest store
  ## whose config sets `current`, else the legacy `.current` file.
  let v = cascadeConfigValue(cwd, "current")
  if v != "": return v
  legacyDirCurrentFor(cwd)

proc saveDirCurrentStore*(cwd, current: string) =
  ## Record `current` in `cwd`'s OWN store (never an ancestor's), in the
  ## `config` file's `[settings]` section, preserving every other line.
  ## Falls back to the legacy `.current` file when the store cannot be
  ## created (read-only tree, unwritable config root).
  let path = storeFileFor(cwd, StoreConfigFile)
  try:
    createDir(path.parentDir)
    var lines: seq[string]
    if fileExists(path):
      lines = readFile(path).splitLines
      if lines.len > 0 and lines[^1].len == 0: lines.setLen(lines.len - 1)
    var outLines: seq[string]
    var inSettings = false
    var sawSettings = false
    var replaced = false
    for line in lines:
      let t = line.strip
      if t.startsWith('[') and t.endsWith(']'):
        inSettings = t[1 ..< t.len - 1].strip.toLowerAscii == "settings"
        if inSettings: sawSettings = true
      if inSettings and not replaced:
        let (k, v) = block:
          let eq = t.find('=')
          if eq < 0: ("", "")
          else: (t[0 ..< eq].strip, t[eq + 1 ..^ 1].strip)
        if k.toLowerAscii == "current":
          outLines.add "current = \"" & current & "\""
          replaced = true
          continue
      outLines.add line
    if not replaced:
      if not sawSettings:
        outLines.add "[settings]"
      outLines.add "current = \"" & current & "\""
    let tmp = path & ".tmp"
    writeFile(tmp, outLines.join("\n") & "\n")
    moveFile(tmp, path)
  except CatchableError:
    let legacy = legacyDirCurrentPath(cwd)
    try:
      createDir(legacy.parentDir)
      let tmp = legacy & ".tmp"
      writeFile(tmp, current & "\n")
      moveFile(tmp, legacy)
    except CatchableError:
      discard
