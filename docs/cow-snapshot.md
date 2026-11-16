.. title:: 3code - the git-independent working-tree snapshot (COW change log)

## Where the git reliance lives and what replaces it

Goal mode's satisfaction check needs one thing above all: *what actually
changed in the working tree this session*. Today that answer comes from two
feeds, and only one of them is ours.

### The two feeds

**The session change log** (ours, git-independent). Every harness tool
executor funnels through `recordChange` (`src/threecode/actions.nim:311`):
the **first** touch of a path stores its original content, later touches
overwrite only the latest, and check time renders one net diff per mutated
path via `buildSessionDiff` (`src/threecode/goal.nim:935`). That is
copy-on-write in the plain userspace sense — the "copy" happens lazily, at
the moment of first mutation, and only for paths that actually change. No
reflink, no APFS/btrfs/ZFS ioctl, no hardlinks, no volume layout
assumptions: it is `readFile` + a table. Filesystem-independent and
cross-platform by construction, because it never asks the filesystem to do
the copy-on-write — the process does.

**The working-tree diff** (git's, temporary). `buildGoalDiff`
(`src/threecode/goal.nim:888`) shells out to `git status --porcelain`,
`git diff HEAD`, and `ls-files --others` to hand the verifier "what git
reports now" as the complement. It is empty outside a git repo, silent when
git is absent (the Windows-no-git case), and it is the piece the changelog
calls "the git-reported complement" — complement, not foundation. The
change log is already documented as "the primary record … git or no git"
(`verifierPrompt`, `src/threecode/goal.nim:971`).

### Why the git feed cannot be the foundation

1. It sees nothing outside a repo — goal mode is supposed to work in any
   directory.
2. It sees the wrong slice inside one: diff-vs-HEAD mixes this session's
   work with the user's pre-existing uncommitted edits.
3. It costs a process spawn per check and depends on a git binary being
   present and sane (the `--no-optional-locks` dance exists precisely
   because hosted git is a fragile dependency).

### The plan, as the code tells it

The end state is that the change log stops being *per-tool-action* and
becomes *per-tree-state*:

- **Arming takes a manifest.** When a mode arms (or a session resumes),
   walk the working tree once (`walkDir`-style stat walk: path, mtime,
   size — the same signature `fileSig` already uses) and keep it as the
   turn-0 snapshot. Cheap: no content copies, just stat metadata. This is
   the snapshot feature the goal file names — cross-platform,
   filesystem-independent, because it is a userspace manifest, not a
   volume-level snapshot.
- **Copy-on-write stays the capture rule.** No content is stored at
   snapshot time. A path's original bytes are captured exactly when a
   mutation is detected — first writer copies. This is the existing
   `recordChange` contract, unchanged; the manifest just makes detection
   complete instead of per-command.
- **Bash stops being a heuristic.** Today bash mutations are caught by
   `bashMutationPath` (`src/threecode/shell.nim:72`): a tokenizer that
   recognizes `>`, `sed -i`, `tee`, `cp/mv`, `rm`, `touch` … and returns
   **one** path, so `python rewrite.py`, a build, or `tar xf` land in no
   change log at all — invisible unless git happens to be watching. After
   a bash run, re-walk and diff the manifest: any path whose signature
   moved gets its before-bytes pulled from the snapshot copy (or, if the
   mutation pre-dated the manifest, recorded as new) and enters the change
   log like any write tool's target. "Even works on bash" means exactly
   this: detection by tree state, not by parsing the command line.
- **Check time renders from the change log; git becomes optional
   garnish.** `buildSessionDiff` is already the primary feed. Once the
   manifest walk exists, `buildGoalDiff` degrades from "requires git" to
   "uses git when present" and disappears silently when not — the
   `verifierPrompt` composition already tolerates an empty diff.

### What already exists (the hard parts are done)

- The COW primitive and its net-per-path table: `recordChange`,
   `ReadCache.changes` (`src/threecode/types.nim:339`).
- The native unified-diff renderer, no external `diff` binary — an
   in-process LCS (`computeDiff`, `src/threecode/actions.nim:319`), with
   binary-content suppression via `isBinaryContent`.
- The caps and degradation ladder that keep the feed token-safe:
   `GoalDiffCapBytes` 8000, `SessionDiffPerPathCap` 4000,
   `GoalDiffMaxUntracked` 24, name-only lines past the caps
   (`src/threecode/goal.nim:52-56`, `930-960`).
- Content-aware work-happened detection (`turnDidWork`,
   `src/threecode/goal.nim:837`) and the change-count turn baseline
   (`changeCountStart`).
- Tests over each seam: `tests/core/test_session_diff.nim`,
   `tests/core/test_goal.nim`, `tests/shell/test_shell.nim`.

### What remains to complete it

1. The manifest snapshot at arm/resume (stat walk + exclusions: `.git`,
   `node_modules`, build outputs, dot-directories the harness already
   ignores elsewhere).
2. The post-bash re-walk that folds detected mutations into the change
   log, retiring the single-path `bashMutationPath` limit (the read-cache
   invalidation role it also serves can ride the same walk).
3. `buildGoalDiff`'s demotion to best-effort complement, and the
   exclusion/cap rules for manifest diffing (unchanged content never
   stored; oversize paths degrade to name-only lines, as today).

Each step lands inside the existing change log, so the verifier prompt,
the mode registry, and every cap already in place need no changes — which
is the point of the design: the snapshot is not a new subsystem, it is the
session change log finishing growing up.

## Landed

The plan above shipped, with the one amendment the goal text demanded:
**git is not a complement anymore — it is gone from the check entirely.**

- `src/threecode/snap.nim` is the manifest: `armManifest` (the stat walk),
  `syncManifest` (the turn-boundary arm/disarm — a mode file newer than
  the arming re-arms, so retire-and-rearm cycles never keep a stale
  baseline), and `foldManifest` (the post-bash re-walk that folds moved,
  new, and gone paths into the change log).
- The turn loop arms it: turn start syncs (`turns.nim`), the mid-turn
  kickoff arms fresh, and `actions.nim` folds after every bash run —
  all gated on an active mode, so outside goal mode nothing walks,
  nothing reads, nothing diffs.
- `buildGoalDiff` (the git porcelain/diff/ls-files feed) is deleted;
  `verifierPrompt` carries the change log alone, and the preamble names
  it. A session inside a git repo now gets exactly the prompt a session
  outside one gets.
- Honesty markers: `ReadCache.shellTouched` marks paths first seen
  mutated by an opaque shell run — they render `changed via shell
  (original not captured)` with the current content, deletions render
  name-only, and nothing fabricates a before-state.
- Budgets: 1MB per file, 4MB per bash run, 20000 manifest entries;
  `.git`, `node_modules`, and build caches never enter the walk.
- Tests: `tests/core/test_session_diff.nim` (fold, gating, deletion,
  oversize, skip dirs, sync), `tests/core/test_goal.nim` and
  `tests/core/test_modes.nim` (the prompt carries the change log and
  never a git feed).
