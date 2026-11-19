.. title:: 3code - goal-mode snapshot: the settled design

## The decision

Goal mode arms by **copying the worktree** — every walked path except
gitignored content — into a snapshot under `.3code/snapshot/`, and the
satisfaction check **diffs the worktree against that snapshot**. Full
plain-file copy, no git dependence, no kernel facilities required. The
reflink/clone accelerators and the VSS helper are optional speed
optimizations under this decision, never prerequisites.

What this buys: every session mutation — tool writes, opaque shell
(`./myscript.bash`, builds, `tar xf`), deletions — has real
before-bytes. The honesty markers survive only for over-budget paths
and mutations that pre-date arm. Diffing happens only while goal mode
is armed; the existing arm gate already enforces that no mode means no
walk, no copy, no diff.

**No git, anywhere.** Nothing invokes a git binary, nothing reads or
writes inside `.git/`, and no `.gitignore` is ever modified. The only
git artifacts consumed are `.gitignore` *files* — read as plain
pattern lists in the cascade below. Side effect, accepted: `.3code/`
shows as untracked noise in `git status` inside repos (it already
does today); users who mind add it to their own ignore — we never act
inside git's namespace on their behalf.

## The diff engine: `nimdiff`

The snapshot store and every other diff in the binary use `nimdiff`
(`~/p/nimdiff`, created from `computeDiff` in a separate session and
swapped in): a Myers O((n+m)·D) linear-space engine linked into the
binary — `import nimdiff`, zero forks, zero git. `computeDiff` in
`src/threecode/actions.nim` is a thin wrapper over it so no call site
changed; `lcsOps` and the in-tree renderer are deleted — one engine,
not two. 3code's binary classifier (ANSI-aware, 512-byte scan) stays
at the wrapper boundary; nimdiff's rule is git's NUL-only one, which
would let control-character soup through.

The input-size guard that shipped with the store (256 KB combined /
5000 lines, degrade to name-only) retired with the swap: it guarded
the O(n·m) DP table's measured 2.0 GB peak on a 520 KB pair, a
hazard the linear-space engine does not have. The session feed's own
per-path and total caps still bound what reaches the verifier.

**Landed as described above** — byte-for-byte compatible
`computeDiff(before, after, label)` output under the frozen contract
(unified `---`/`+++`/`@@` hunks with 3 context lines, `+`/`-`/` `
prefixes, binary-suppression header, empty string for equal inputs;
`tests/core/test_session_diff.nim` and the green/red painter are the
acceptance surface), `threecode.nimble` carries `requires "nimdiff
>= 0.1.0"` with the revision pinned in `nimble.lock` (git URL, the
`sandwall`/`streamhttp` pattern), and the Myers/Hirschberg brief met
its target: milliseconds and kilobytes where the DP was 810 ms and
2.0 GB.

Scope guard, held: no directory diffing (the fold maps paths, the
engine diffs contents), no patience/histogram heuristics, no external
tools.

## Semantics

- **Arm** (mode armed / session resume): manifest stat walk (the
  detector, unchanged) + snapshot materialization (the before-store).
- **Snapshot layout:** mirrors the walked set under `.3code/snapshot/`
  — outside the walk (`.3code/` is itself in the ignore cascade's
  defaults) and same-volume by construction, so the reflink
  accelerators always apply.
- **Check:** fold compares worktree against the manifest; for every
  moved path, before-bytes come from the snapshot. Creations diff
  against empty (the truth); deletions render real minus-diffs from
  snapshot bytes; an inode recorded at arm matches
  rename-vs-delete+create.
- **Disarm:** delete the snapshot with the manifest.
- **Incremental re-arm:** entries whose `(mtime, size, inode)` are
  unchanged are reused; only the delta is copied — near-free re-arms
  after the first.

## Exclusions: the ignore cascade

All sources use gitignore syntax, concatenated in this order — with
gitignore's last-match-wins rule, a later source overrides an earlier
one, and `!` negation in a later source re-includes what an earlier
one excluded:

1. **`~/p/nimignore`** — the global defaults file, the successor of
   the hard-coded `ManifestSkipDirs` (same content as patterns:
   `.git/`, `.hg/`, `node_modules/`, `__pycache__/`, `target/`,
   `nimcache/`, `.nimcache/`, `.3code/`). An embedded copy ships as
   the fallback when the file is absent; the file, when present,
   replaces the defaults wholesale.
2. **`.gitignore`** — per-directory, git's own order (deepest wins),
   honoring the common subset in-harness: comments, blank lines,
   name/glob patterns, trailing-`/` dirs, leading-`/` anchors, `!`
   negation.
3. **`.3code/ignore`** — same syntax, concatenated **after** the
   gitignore: the override point. `!node_modules/` there keeps the
   directory out of commits but pulls it into the snapshot; extra
   patterns there exclude more without touching the user's
   `.gitignore`.

Two implementation notes:

- **No pruning on plain ignores.** Git cannot re-include a file whose
  parent directory is excluded because it never descends there — our
  walker must not inherit that limitation, or `!node_modules/` in
  `.3code/ignore` would be dead syntax. Rule: a directory is pruned
  from the walk only when it is ignored by a non-negated match **and**
  no `!` pattern from any source could match beneath it. Paths are
  filtered at record time against the full concatenated list.
- **One evaluator, ever.** The in-harness parser is the single source
  of truth for the cascade — no external ignore evaluator of any
  kind, git included; `.gitignore` files are read as data, nothing
  more.

**Known trade, unchanged but now addressable:** ignore-based exclusion
can hide *outputs* the verifier needs — a goal like "make the build
emit X" where `X` lands in an ignored `build/`. The escape hatch is
the cascade itself: `!build/X` (or broader) in `.3code/ignore`
re-includes it for the snapshot while commits stay clean.

## Costs and budgets

- Walk (measured): 5.5 ms / 1,657 paths on this repo; 31 ms at the
  20,000-entry cap.
- Copy: `O(bytes)` of the walked set, once per arm — single-digit MB
  source trees cost tens of ms warm; accelerators make it
  metadata-only where the filesystem offers them.
- Budgets: per-file store cap aligned with `FoldFileCap` (a file over
  the render caps was going to degrade to name-only anyway — don't
  store what won't render); total store budget with per-path
  degradation, markers as the floor.
- **Renderer prerequisite, ships first:** `computeDiff`'s `O(n·m)`
  table needs an input-size guard and a linear-space algorithm
  (Myers/Hirschberg) — measured 2.0 GB peak RSS for a 520 KB
  before/after pair, reachable today via `patch` on large files.

## Accelerators (optional, opportunistic — probe once at arm)

All produce the same artifact — a plain-file snapshot; any probe
failure falls through silently to the portable copy.

- **macOS/APFS:** `clonefile(2)` — separate inode, shared blocks, COW
  on write to either side; survives in-place `>` writers (hardlinks do
  not — that's why hardlink farms stay rejected).
- **Linux btrfs/XFS:** `FICLONE` — same semantics.
- **Windows ReFS/Dev Drive:** `FSCTL_DUPLICATE_EXTENTS_TO_FILE` or
  `CopyFile2` block cloning.
- **Windows NTFS (optional, privileged):** VSS helper service installed
  by the existing `3code setup` elevation — volatile no-writers shadow
  → materialize → delete; reads locked files; skipped entirely when
  setup was never run. The only privileged tier, and pure optimization.
- **Any filesystem:** `copy_file_range` → `sendfile` → read/write —
  kernel-assisted, page-cache speed; covers ext4, f2fs, vfat/exFAT,
  FUSE views, Termux. This is the default and the floor.

**FAT-family caveat:** FAT32 write timestamps have 2-second granularity
(exFAT 10 ms), so a same-size rewrite inside one tick can escape
`(mtime, size)` detection. Git's racy-clean technique closes it: hash
at arm, re-hash only the small suspect set at fold. Until then the
failure mode is a missed entry, never a wrong diff.

## Landing order

1. Input-size guard in `computeDiff` (in-tree, a condition and a
   fallback string — the measured hazard is reachable via `patch`
   today and via real before-bytes once the store lands).
2. Snapshot store: arm-time materializer (portable copy ladder),
   budgets, incremental re-arm, the ignore cascade (`~/p/nimignore`
   defaults, `.gitignore`, `.3code/ignore` overrides).
3. Fold reads before-bytes from the snapshot; deletions and renames
   render real diffs; markers become the documented floor.
4. Accelerators behind capability probes (`clonefile`, `FICLONE`,
   ReFS block clone).
5. Optional: the Windows VSS helper service.
6. Later, separate session: `nimdiff` at `~/p/nimdiff` replaces the
   in-tree engine under the frozen contract (Myers linear-space),
   `computeDiff` becomes a wrapper, `lcsOps` is deleted.

## Rejected alternatives (recorded)

- **Git temp-index baseline** (`git add -A` into a temp index +
  `write-tree`, diff the arm tree): measured 87 ms arm / 8 ms check on
  this repo and fixes the HEAD-mixing flaw — but makes goal mode
  dependent on a repo and a git binary, reversing the session's no-git
  directive. Rejected for repo-independence; full detail earlier in
  this doc's history and `docs/cow-diff-plan.md`.
- **Kernel interception, overlays, volume snapshots, FUSE:** rejected
  in `docs/cow-diff-plan.md` — privilege walls, platform gaps, or
  execution-model changes. Unchanged under this decision.
- **Hardlink farms:** in-place writers clobber the shared inode —
  silently partial coverage.

## Shipped

Landing order 1–3 landed (`src/threecode/ignore.nim`, `snap.nim`,
`actions.nim`; tests in `tests/core/test_ignore.nim` and
`test_session_diff.nim`). One amendment, found while implementing the
pruning rule: a bare-name negation (`!keep.log` — no slash anywhere)
names no subtree, so honoring it under the literal "no `!` pattern
could match beneath" test would un-prune every ignored directory in
the tree, `.git/` included, the moment anyone re-includes a directory
by name (the plan's own `!node_modules/` example). Bare-name
negations therefore never block pruning — they keep git's behavior
under an already-pruned directory — while slash-named negations
(`!build/output.txt`, `!build/**`) keep the no-pruning guarantee the
plan was written for. `!node_modules/` itself is unaffected: it wins
by last-match on the directory, no pruning question arises.

The evaluator was differentially tested against `git check-ignore
--no-index` over a 247-case grid (names, dir-only, anchors, globs,
classes, `**`, negations): every case agrees except the designed
divergence — a re-inclusion beneath an ignored directory, which git
refuses to even look at.

Tier 6 landed too (`nimdiff` swap, see above): `computeDiff` is a
wrapper, `lcsOps` and the in-tree renderer are deleted, and the
step-1 input caps retired with the DP table they guarded — the caps
test in `test_session_diff.nim` now asserts real hunks on the same
over-cap pairs. Tiers 4–5 stay future work as planned; the portable
copy already rides `copyFile`, which uses the platform clone syscall
where one exists (macOS `copyfile(3)`), and measured 105 ms to arm
this repo
(7.7 MB walked set, 397 paths after the cascade) with 37 ms
no-change folds; incremental re-arms copy only the delta.
