## Working-tree manifest: the goal-mode tree snapshot behind the session
## change log.
##
## The change log (`ReadCache.changes`) is copy-on-write in plain
## userspace: a path's original bytes are captured at the first
## *observed* mutation, never up front, so nothing assumes reflinks,
## APFS/btrfs/ZFS, or hardlinks — the process does the copying, on any
## filesystem. What the per-tool recorders cannot see is a mutation with
## no harness-visible target (`python rewrite.py`, a build, `tar xf`):
## the command-line scraper (`shell.bashMutationPath`) catches at most
## one scripted path per command. The manifest closes that hole by tree
## state instead of command text: arming walks the project once and
## keeps (mtime, size) per path — a snapshot with no content copies —
## and a re-walk after every bash run folds every signature that moved
## into the change log like any write tool's target.
##
## Detection by signature cannot recover bytes that were overwritten
## before the first observation, so a shell-mutated path is marked
## (`shellTouched`) and renders with an honest "original not captured"
## header instead of a fabricated before-state; paths the harness tools
## did observe keep their true originals, and a later opaque mutation
## only refreshes the latest content on top of them. The converse trade:
## a pure `touch` (mtime moves, bytes do not) records like a rewrite,
## because signature equality is the only cheap truth the tree offers.
##
## Everything here is armed only while a harness mode runs
## (`syncManifest` from the turn loop): no mode, no walk, no reads —
## the diffing cost belongs to goal mode, not to the shell. Outside a
## mode the change log behaves exactly as before.

import std/[algorithm, os, sets, tables, times]
import types

const
  ManifestMaxEntries* = 20000
    ## Walk budget: the manifest stops recording (and the walk stops)
    ## past this many paths. A tree this size is already far past what
    ## the capped feeds can render; the degradation is documented, not
    ## silent — folds past the budget surface as "content not captured".
  ManifestSkipDirs* = [".git", ".hg", ".svn", ".3code", "node_modules",
    "__pycache__", "target", "nimcache", ".nimcache"]
    ## Name-matched at any depth: version-control internals, dependency
    ## trees, and build caches whose churn would drown the change log.
    ## Directory names only; dot-*files* like `.gitignore` are content.
  FoldFileCap* = 1024 * 1024
    ## Per-path content ceiling for the fold: bigger mutations record a
    ## name-only entry instead of holding bytes that would never render.
  FoldBudgetCap* = 4 * 1024 * 1024
    ## Total content the fold reads per bash run, so one command that
    ## rewrites the world cannot balloon memory.

proc localSig(path: string): (Time, int) =
  ## (mtime, size); (Time(), -1) on stat failure, which callers treat
  ## as "unreadable, skip" rather than as a real signature. Mirrors
  ## actions.fileSig's shape but is local: actions imports this module
  ## for the fold, so the dependency only points one way.
  try: (getLastModificationTime(path), getFileSize(path).int)
  except CatchableError: (Time(), -1)

proc walkTree(root: string): Table[string, (Time, int)] =
  var stack = @[root]
  while stack.len > 0:
    let d = stack.pop()
    for kind, p in walkDir(d, checkDir = false):
      if result.len >= ManifestMaxEntries: return
      case kind
      of pcDir:
        if p.lastPathPart in ManifestSkipDirs: continue
        stack.add p
      of pcFile:
        let sig = localSig(p)
        if sig[1] >= 0: result[p] = sig
      else: discard  # symlinks and specials: never followed or recorded

proc armManifest*(cache: ReadCache; root: string): bool =
  ## The snapshot: one stat walk of `root`, stored as the fold baseline.
  ## No content is read or copied — the copy-on-write capture stays with
  ## the change log's first-touch rule. `false` (and no arming) when the
  ## root cannot be walked.
  if cache == nil: return false
  let base = absolutePath(root)
  if not dirExists(base): return false
  cache.manifest = walkTree(base)
  cache.manifestRoot = base
  cache.manifestArmed = true
  cache.manifestTime = getTime()
  true

proc syncManifest*(cache: ReadCache; root, modeFile: string;
                   modeActive: bool) =
  ## The turn-boundary arming gate, called once per turn start: disarm
  ## when no mode is active, arm when one is and the baseline is stale —
  ## never armed yet, or armed before the mode file was last written (a
  ## retire-and-rearm without a turn in between must not keep the old
  ## baseline). This is what keeps every diffing cost inside an active
  ## mode.
  if cache == nil: return
  if not modeActive or not fileExists(modeFile):
    if cache.manifestArmed:
      cache.manifestArmed = false
      cache.manifest.clear()
      cache.manifestRoot = ""
    return
  var stale = not cache.manifestArmed
  if not stale:
    let m = localSig(modeFile)
    if m[1] < 0 or m[0] > cache.manifestTime: stale = true
  if stale: discard armManifest(cache, root)

proc foldManifest*(cache: ReadCache) =
  ## Post-bash re-walk: compare the tree against the last observation
  ## and fold every moved, new, or gone path into the change log —
  ## detection by tree state, not by parsing the command line, so
  ## `python rewrite.py` records like `write` would. Paths already
  ## tracked keep their first-touch original (`before`); a shell-mutated
  ## path first seen here has no recoverable original and is marked
  ## `shellTouched` so the render says so instead of inventing one.
  ## The walk becomes the new baseline on the way out, so each fold
  ## reports only what changed since the last one.
  if cache == nil or not cache.manifestArmed: return
  if not dirExists(cache.manifestRoot): return
  let now = walkTree(cache.manifestRoot)
  var moved, gone: seq[string]
  for p in now.keys:
    if p in cache.manifest and cache.manifest[p] == now[p]: continue
    moved.add p
  for p in cache.manifest.keys:
    if p notin now: gone.add p
  moved.sort
  gone.sort
  var budget = FoldBudgetCap
  for p in moved:
    let size = now[p][1]
    if p in cache.changes:
      # Executor-tracked (write/patch/earlier observed bash target):
      # refresh the latest bytes; the true first-touch original stands.
      if size <= FoldFileCap and size <= budget:
        try:
          cache.changes[p].after = readFile(p)
          budget -= size
        except CatchableError: discard
      continue
    if size > FoldFileCap or size > budget:
      # Name-only: never silent, never a memory balloon.
      cache.shellTouched.incl p
      cache.changes[p] = ("", "")
      continue
    try:
      cache.changes[p] = ("", readFile(p))
      budget -= size
      if p in cache.manifest: cache.shellTouched.incl p
    except CatchableError:
      cache.shellTouched.incl p
      cache.changes[p] = ("", "")
  for p in gone:
    if p in cache.changes:
      cache.changes[p].after = ""
    else:
      cache.shellTouched.incl p
      cache.changes[p] = ("", "")
  cache.manifest = now
