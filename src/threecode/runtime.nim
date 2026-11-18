## Runtime knobs sourced from the config file.
##
## Everything here used to be an environment variable read via `getEnv`
## at call time. They are config-file keys now — `[settings]` for user-facing knobs,
## `[test]` for the test harness hooks, `[plugins]` for plugin tuning,
## plus the internal `[wall]` file the sandbox parent hands to the
## `sandbox restrict` / `wall connect` children. `parseConfigFile`
## fills the table at load time; leaf modules read it through this
## module so no one needs to import config.nim (and config.nim stays
## import-cycle-free of them).
##
## The store is lock-guarded: the config can re-parse mid-session
## (`writeConfigFile`) on the controller thread while the gui/input
## threads read the frame keys — the old `getEnv` calls were plain C
## reads and race-free, and the lock keeps that property. The
## `{.cast(gcsafe).}` blocks assert what the lock already guarantees.
## The parse overlays file keys on the store (last write wins); a spawned
## child starts with an empty store, so the config file is the sole
## source there, while an embedding host (the library tests) can seed a
## key directly. No environment fallback exists: a key that is in no
## config file and was never `put` is unset.

import std/[locks, parsecfg, streams, strutils]

var storeLock: Lock
var store: seq[tuple[key, value: string]]

storeLock.initLock()

proc put*(key, value: string) {.gcsafe.} =
  ## Record `key = value`. Last write wins, matching the config
  ## parser's last-line-wins semantics for repeated keys.
  {.cast(gcsafe).}:
    storeLock.acquire()
    try:
      for i in countdown(store.len - 1, 0):
        if store[i].key == key:
          store[i] = (key, value)
          return
      store.add (key, value)
    finally:
      storeLock.release()

proc get*(key: string): string {.gcsafe.} =
  {.cast(gcsafe).}:
    result = ""
    storeLock.acquire()
    try:
      for i in countdown(store.len - 1, 0):
        if store[i].key == key:
          result = store[i].value
          break
    finally:
      storeLock.release()

proc has*(key: string): bool {.gcsafe.} =
  ## Unlike `get`, an explicitly empty value still counts as present.
  {.cast(gcsafe).}:
    result = false
    storeLock.acquire()
    try:
      for i in countdown(store.len - 1, 0):
        if store[i].key == key:
          result = true
          break
    finally:
      storeLock.release()

proc on*(key: string): bool {.gcsafe.} =
  ## Boolean dialect shared with the config file: on/true/yes/1.
  get(key).strip.toLowerAscii in ["on", "true", "yes", "1"]

proc num*(key: string; default: int): int {.gcsafe.} =
  let v = get(key).strip
  if v.len == 0: return default
  try: parseInt(v)
  except ValueError: default

proc loadWallConf*(path: string): bool {.gcsafe.} =
  ## Read the internal `[wall]` config file (`port`, `sock`) the
  ## sandbox parent writes for the `sandbox restrict` and
  ## `wall connect` children. Returns false when the file is missing
  ## or unreadable — standalone box use runs without a proxy, the
  ## fail-closed default.
  var p: CfgParser
  let s = newFileStream(path, fmRead)
  if s == nil: return false
  try:
    p.open(s, path)
    while true:
      let e = p.next
      case e.kind
      of cfgEof: break
      of cfgSectionStart:
        if e.section != "wall": break
      of cfgKeyValuePair, cfgOption:
        if e.key == "port": put("wall_port", e.value.strip)
        if e.key == "sock": put("wall_sock", e.value.strip)
      else: discard
    result = true
  except CatchableError:
    result = false
  finally:
    try: p.close()
    except CatchableError: discard
