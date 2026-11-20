## The goal-mode snapshot store: the tree manifest plus the arm-time
## before-bytes copy.
##
## Goal mode arms by copying the worktree — every walked path except
## ignored content — into `.3code/snapshot/`, mirroring the walked set
## on the same volume. Detection stays the cheap stat walk (the
## manifest, `(mtime, size, inode)` per path); capture is the plain
## portable copy (no git, no kernel facilities; the platform copy
## syscall gets any clone acceleration for free where the filesystem
## offers it). What this buys: every session mutation — tool writes,
## opaque shell (`python rewrite.py`, builds, `tar xf`), deletions,
## renames — has real before-bytes at fold time, read back from the
## store instead of captured only when a harness tool happened to be
## watching.
##
## The fold re-walks after every bash run and folds moved, new, and
## gone paths into the change log: a moved path's original is its
## arm-time copy; a deletion renders a real minus-diff from the stored
## bytes; a gone path and a created path sharing `(mtime, size, inode)`
## are one rename. The honesty markers (`shellTouched`) survive only
## for paths over the store caps — the documented floor.
##
## Incremental re-arm: entries whose `(mtime, size, inode)` are
## unchanged since the last observation (and never mutated this
## session) keep their copies; only the delta is copied again, so
## re-arms after the first are near-free. Disarm deletes the store
## with the manifest.
##
## Exclusions run through the ignore cascade (`ignore.nim`): global
## defaults, per-directory `.gitignore` files read as plain data, and
## `.3code/ignore` as the override point. Everything here is armed
## only while a harness mode runs (`syncManifest` from the turn loop):
## no mode, no walk, no copy, no diff.

import std/[algorithm, os, sequtils, sets, strutils, tables, times]
import types, ignore, dirsettings

const
  ManifestMaxEntries* = 20000
    ## Walk budget: the manifest stops recording (and the walk stops)
    ## past this many paths. A tree this size is already far past what
    ## the capped feeds can render; the degradation is documented, not
    ## silent — folds past the budget surface as "content not captured".
  FoldFileCap* = 1024 * 1024
    ## Per-path content ceiling for the fold: bigger mutations record a
    ## name-only entry instead of holding bytes that would never render.
  FoldBudgetCap* = 4 * 1024 * 1024
    ## Total content the fold reads per bash run, so one command that
    ## rewrites the world cannot balloon memory.
  SnapshotDirName* = "snapshot"
    ## The store lives in the project's `.3code` store directory, which
    ## the cascade's defaults exclude from every walk — same volume as
    ## the worktree by construction.
  SnapshotFileCap* = FoldFileCap
    ## Per-path store ceiling, aligned with the fold cap: a file over
    ## the render caps was going to degrade to a name-only line anyway —
    ## don't store what won't render.
  SnapshotBudgetCap* = 64 * 1024 * 1024
    ## Total bytes the store copies per arm. Past it, remaining paths
    ## keep detection (the manifest signature) but not before-bytes:
    ## the marker floor.

proc snapshotDir*(root: string): string =
  root / StoreDirName / SnapshotDirName

proc localSig(path: string): ManifestSig =
  ## (mtime, size, inode); size -1 on stat failure, which callers treat
  ## as "unreadable, skip" rather than as a real signature. Mirrors
  ## actions.fileSig's shape but carries the inode (rename identity)
  ## and is local: actions imports this module for the fold, so the
  ## dependency only points one way.
  try:
    let fi = getFileInfo(path)
    (fi.lastWriteTime, fi.size.int, int64(fi.id.file))
  except CatchableError:
    (Time(), -1, 0'i64)

proc readIgnoreFile(path: string): string =
  try:
    if fileExists(path): readFile(path) else: ""
  except CatchableError:
    ""

proc walkTree(root: string): Table[string, ManifestSig] =
  ## The ignore-cascade walk: global defaults, the per-directory
  ## `.gitignore` chain (deepest wins), `.3code/ignore` last. A
  ## directory is pruned only when its evaluation ends ignored AND no
  ## anchored negation from any source could match beneath it; every
  ## surviving file is filtered at record time against the full list.
  let cascade = newCascade(root)
  type DirCtx = tuple[path: string, segs: seq[string],
                    rules: seq[IgnoreRule]]
  var stack: seq[DirCtx] =
    @[(root, @[], parseIgnore(readIgnoreFile(root / ".gitignore"), ""))]
  while stack.len > 0:
    let ctx = stack.pop()
    # skipSpecial: fifos and device nodes must never enter the manifest,
    # because the fold (and the store copy, now) reads what the walk
    # records and opening a fifo read-only blocks until a writer appears -
    # test debris (the still repo's suite leaves one in build/tests) would
    # brick the session with no cancel watcher in sight.
    var fileSegs = ctx.segs  # scratch: one alloc per directory, not per file
    for kind, p in walkDir(ctx.path, checkDir = false, skipSpecial = true):
      if result.len >= ManifestMaxEntries: return
      let name = p.lastPathPart
      case kind
      of pcDir:
        var segs = ctx.segs
        segs.add name
        let rel = segs.join("/")
        let childRules = parseIgnore(readIgnoreFile(p / ".gitignore"), rel)
        if cascade.ignoredSegs(ctx.rules, segs, isDir = true) and
            not cascade.couldReincludeSegs(ctx.rules, childRules, segs):
          continue
        stack.add (p, segs, ctx.rules & childRules)
      of pcFile:
        fileSegs.add name
        let kept = not cascade.ignoredSegs(ctx.rules, fileSegs, isDir = false)
        fileSegs.setLen ctx.segs.len
        if kept:
          let sig = localSig(p)
          if sig.size >= 0: result[p] = sig
      else: discard  # symlinks and specials: never followed or recorded

proc armManifest*(cache: ReadCache; root: string): bool =
  ## Arm the store: one stat walk (the manifest, the detection layer)
  ## plus materialization of the walked set under `.3code/snapshot/`
  ## (the before-bytes layer). Re-arm while still armed copies only the
  ## delta: entries whose signature is unchanged since the last
  ## observation and that were never mutated this session keep their
  ## copies. `false` (and no arming) when the root cannot be walked.
  if cache == nil: return false
  let base = absolutePath(root)
  if not dirExists(base): return false
  let snap = snapshotDir(base)
  var prev: Table[string, ManifestSig]
  if cache.manifestArmed and cache.manifestRoot == base:
    prev = cache.manifest
  else:
    # A fresh arming (first arm, or a different root) builds the store
    # from scratch: bytes left over by a dead session are not a baseline.
    try: removeDir(snap)
    except CatchableError: discard
  cache.manifest = walkTree(base)
  cache.manifestRoot = base
  cache.manifestArmed = true
  cache.manifestTime = getTime()
  var budget = SnapshotBudgetCap
  for p in toSeq(cache.manifest.keys).sorted:
    let sig = cache.manifest[p]
    if sig.size > SnapshotFileCap: continue
    let dst = snap / p.substr(base.len + 1)
    if p in prev and prev[p] == sig and p notin cache.changes:
      try:
        if fileExists(dst) and getFileSize(dst) == sig.size: continue
      except CatchableError: discard
    if sig.size > budget: continue  # marker floor: detection without bytes
    try:
      createDir(dst.parentDir)
      copyFile(p, dst)
      budget -= sig.size
    except CatchableError: discard
  for p in prev.keys:
    if p notin cache.manifest:
      try: removeFile(snap / p.substr(base.len + 1))
      except CatchableError: discard
  true

proc syncManifest*(cache: ReadCache; root, modeFile: string;
                   modeActive: bool) =
  ## The turn-boundary arming gate, called once per turn start: disarm
  ## when no mode is active, arm when one is and the baseline is stale —
  ## never armed yet, or (file modes) armed before the mode file was
  ## last written (a retire-and-rearm without a turn in between must
  ## not keep the old baseline). A transcript mode passes no file:
  ## armed state alone decides, and the fresh baseline comes from the
  ## explicit `armManifest` at the kickoff. This is what keeps every
  ## diffing cost inside an active mode.
  if cache == nil: return
  if not modeActive or (modeFile.len > 0 and not fileExists(modeFile)):
    if cache.manifestArmed:
      # Disarm deletes the snapshot store with the manifest.
      if cache.manifestRoot.len > 0:
        try: removeDir(snapshotDir(cache.manifestRoot))
        except CatchableError: discard
      cache.manifestArmed = false
      cache.manifest.clear()
      cache.manifestRoot = ""
    return
  var stale = not cache.manifestArmed
  if not stale and modeFile.len > 0:
    let m = localSig(modeFile)
    if m.size < 0 or m[0] > cache.manifestTime: stale = true
  if stale: discard armManifest(cache, root)

proc foldManifest*(cache: ReadCache) =
  ## Post-bash re-walk: compare the tree against the last observation
  ## and fold every moved, new, or gone path into the change log —
  ## detection by tree state, not by parsing the command line, so
  ## `python rewrite.py` records like `write` would. Before-bytes come
  ## from the snapshot store: a first-seen shell mutation diffs against
  ## its arm-time copy, a deletion renders a real minus-diff, and a
  ## gone+created pair sharing an inode is one rename. Paths over the
  ## caps keep detection but degrade to the marker floor. The walk
  ## becomes the new baseline on the way out, so each fold reports only
  ## what changed since the last one.
  if cache == nil or not cache.manifestArmed: return
  if not dirExists(cache.manifestRoot): return
  let now = walkTree(cache.manifestRoot)
  let snap = snapshotDir(cache.manifestRoot)
  proc snapPath(p: string): string =
    snap / p.substr(cache.manifestRoot.len + 1)
  proc hasSnap(p: string): bool =
    try: fileExists(snapPath(p))
    except CatchableError: false
  proc snapBytes(p: string): string =
    try: readFile(snapPath(p))
    except CatchableError: ""
  var moved, gone, created: seq[string]
  for p in now.keys:
    if p in cache.manifest and cache.manifest[p] == now[p]: continue
    moved.add p
    if p notin cache.manifest: created.add p
  for p in cache.manifest.keys:
    if p notin now: gone.add p
  moved.sort
  gone.sort
  created.sort
  # Rename matching: a gone path and a created path carrying the same
  # (mtime, size, inode) are one moved inode, not a delete+create pair.
  var renameOf: Table[string, string]
  var taken: HashSet[string]
  for n in created:
    # A destination the bash scraper already recorded as a creation
    # (before == "") can still be the rename's new name; a path with its
    # own recorded original is not.
    if n in cache.changes and cache.changes[n].before.len > 0: continue
    for g in gone:
      if g in taken: continue
      if now[n] == cache.manifest[g]:
        renameOf[n] = g
        taken.incl g
        break
  var budget = FoldBudgetCap
  for p in moved:
    let size = now[p][1]
    if p in renameOf:
      let g = renameOf[p]
      var orig = ""
      var haveOrig = false
      if g in cache.changes:
        orig = cache.changes[g].before
        haveOrig = true
        cache.changes.del(g)
      elif hasSnap(g):
        orig = snapBytes(g)
        haveOrig = true
      var after = ""
      if size <= FoldFileCap and size <= budget:
        try:
          after = readFile(p)
          budget -= size
        except CatchableError: discard
      cache.renamedFrom[p] = g
      if not haveOrig:
        cache.shellTouched.incl p
      cache.changes[p] = (orig, after)
      continue
    if p in cache.changes:
      # Executor-tracked (write/patch/earlier observed bash target):
      # refresh the latest bytes; the true first-touch original stands.
      if size <= FoldFileCap and size <= budget:
        try:
          cache.changes[p].after = readFile(p)
          budget -= size
        except CatchableError: discard
      continue
    let stored = p in cache.manifest  # existed at arm: the store owes bytes
    let orig = if stored and hasSnap(p): snapBytes(p) else: ""
    if size > FoldFileCap or size > budget:
      # Name-only: never silent, never a memory balloon.
      cache.shellTouched.incl p
      cache.changes[p] = (orig, "")
      continue
    var after = ""
    try:
      after = readFile(p)
      budget -= size
    except CatchableError:
      cache.shellTouched.incl p
      cache.changes[p] = (orig, "")
      continue
    if stored and not hasSnap(p):
      # Existed at arm but the store holds no copy (over the caps, or
      # the arm-time copy failed): the marker floor.
      cache.shellTouched.incl p
    cache.changes[p] = (orig, after)
  for p in gone:
    if p in taken: continue
    if p in cache.changes:
      cache.changes[p].after = ""
    elif hasSnap(p):
      # A real deletion: minus-diff from the stored before-bytes.
      cache.changes[p] = (snapBytes(p), "")
    else:
      cache.shellTouched.incl p
      cache.changes[p] = ("", "")
  cache.manifest = now
