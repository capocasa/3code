.. title:: 3code - plan v2: guaranteed before-bytes for every session mutation

## The requirement, restated

Every mutation the session makes — tool writes *and* opaque shell runs
(`./myscript.bash`, builds, `tar xf`, `python rewrite.py`) — must yield a
real before/after diff. The shipped design detects those mutations but
cannot diff them: by the time the post-bash re-walk sees a moved path,
the original bytes are gone, and the "original not captured" marker is a
flaw with a name, not a feature. Deletions currently render name-only,
creations are fine (empty before is the truth), and in-place rewrites
have no before at all.

## The constraint that decides everything

Before-bytes can only exist if one of three things happened:

1. **The bytes were copied before the mutation** — an eager copy, made
   without knowing what will be touched.
2. **The write was intercepted before it landed** — kernel or
   interposition, at the moment of `open`/`write`/`unlink`.
3. **The write was isolated onto a layer** — the mutation hits an
   overlay, the original stays underneath.

Every candidate approach is one of these. The current design is a fourth
thing — *post-hoc detection* — which is why it can name but not diff.

## Approaches

### A1. Shadow copy at arm (eager, plain copy)

At mode-arm, copy the walked tree (same exclusions as the manifest:
`.git`, `node_modules`, build caches, dot-dirs) into a shadow under
`.3code/snapshot/` — already inside the skip list. The manifest stays
exactly as is (the detector); the fold changes only in where it reads
before-bytes: from the shadow instead of from thin air.

- Correctness: separate inodes, so in-place truncate/`>` writes, rename
  replaces, and deletions all leave the original intact. Deletions gain
  real minus-diffs; a `st_ino` recorded in the manifest matches
  rename-vs-delete+create.
- Cost: one `O(tree bytes)` copy per arm, disk not RAM. Source trees
  after exclusions are typically single-digit MB — tens of ms warm.
  Tiered by a budget: over budget → fall back to today's marker for
  that path (or the whole tree), documented, rare.
- Portability: plain file APIs everywhere. Edge ledger: case-insensitive
  path collisions (macOS/Windows), files locked by other processes
  (Windows), non-regular files (skip), permission bits (best effort).
- This answers the round-one question honestly: yes, a *guaranteed*
  diff for arbitrary shell work requires an entire copy of the (walked)
  tree — once, at arm, on disk, budgeted. Everything else is a way to
  avoid paying that, bought with platform dependence.

### A2. Hardlink farm at arm

`O(tree inodes)`, no data copy — and broken: `echo x > f` truncates and
writes *in place*, clobbering the shared inode, so the most common
shell idiom destroys its own "snapshot". Reject.

### A3. Reflink/clonefile farm

`FICLONE`/`clonefile()` give instant true COW on btrfs/XFS/APFS and
silently fall back to a full copy elsewhere. An accelerator for A1's
cost, not a foundation — the fallback *is* A1.

### B1. fanotify permission events (`FAN_OPEN_PERM`)

Genuine interception: block the open, copy the original, allow. Perfect
before-bytes, no arm-time copy. But: Linux-only, needs
privileges/unprivileged-fanotify support, and interacts with the
existing sandwall sandbox policy. A Linux fast path at best — the
project ships on Windows and macOS.

### B2. ptrace syscall stops

Same perfection, worse: 2–10x syscall slowdown (compile-heavy turns),
thread group complexity, Linux-only, hostile to sandboxing. Reject.

### B3. LD_PRELOAD / DLL interposition

No static/setuid binaries, macOS SIP fights it, Windows injection is
its own career. Research-grade. Reject.

### B4. inotify — the negative result

Events fire *after* the write (`IN_MODIFY` at write time,
`IN_CLOSE_WRITE` at close); queues coalesce and overflow. A watcher can
never pre-copy. Its only legitimate role is replacing the fold's stat
walk with event-driven detection — orthogonal to before-bytes, and the
walk measured at 5–35 ms, so not worth it now.

### C1. overlayfs in a user namespace

The real filesystem COW: run *everything* (shell and tool writes) with
the tree as `lowerdir`, capture `upperdir`; the diff is a layer compare.
Perfect and cheap per-write — but unprivileged-userns availability
varies, there is no macOS/Windows story, and routing the harness's own
writes through the mount changes the execution model end to end. Revisit
only if A1's arm cost ever hurts; it is once-per-session, so it won't.

### C2. The overlay question on macOS and Windows, checked

Neither has a per-directory union mount a user process can create. What
exists instead, per OS:

- **macOS**: APFS local snapshots (`tmutil localsnapshot`) are true
  volume-level COW baselines — instant, no data copy, the perfect
  before-store — but reading one back means mounting it (`mount_apfs -s
  …`), which is root/TCC territory on current macOS, and the snapshot
  is volume-scoped with a purge timer. FUSE routes exist — macFUSE
  (kext, dying) and FUSE-T (kext-less, loopback NFS server, signed
  installer) — but `fuse-overlayfs` is Linux/libfuse-only, so a union
  layer means porting one onto FUSE-T *and* taxing every file operation
  with a userspace NFS hop. The clean-out is Virtualization.framework:
  a Linux VM with real overlayfs — which is exactly how Docker Desktop
  does overlays on a Mac.
- **Windows**: VSS shadow copies are the snapshot equivalent — admin
  -gated, volume-scoped. ReFS block cloning (Dev Drive) is a real
  per-file reflink, instant shadow copies, but only on ReFS volumes —
  not the default system drive. WinFsp is a solid signed userspace-FS
  framework you could *build* an overlay on (containerd's Windows
  layer story uses read-only CimFS layers and even they punted on
  mounting those); ProjFS (VFS for Git) projects reads, it does not
  intercept writes. WSL2 gives real overlayfs inside a VM.

The pattern: Linux hands out per-directory kernel COW for free; macOS
and Windows offer it only volume-scoped and privileged (APFS snapshot,
VSS), behind a framework you must feed an implementation into
(FUSE-T/WinFsp), or inside a VM. No platform offers the one thing this
plan wants — an unprivileged, per-directory, kernel-COW overlay —
except Linux.

Consequence for the ladder: every kernel facility above is just a
cheaper way to build the *before-store*. The settled tiering: per-file
reflink clones where the filesystem offers them — `clonefile` on
APFS, `FICLONE` on btrfs/XFS, ReFS block cloning — all unprivileged
and instant; kernel-assisted copy (`copy_file_range` → `sendfile` →
read/write) as the FS-independent default, covering ext4, f2fs, vfat,
exFAT, FUSE and therefore Termux; VSS-via-the-existing-elevation
reserved for NTFS on Windows; honesty markers as the documented floor.
Every tier keeps the same shape — manifest detects, a before-store
diffs — only the before-store's construction cost changes.

Settled (see `docs/snapshot-store-plan.md`): goal mode copies the
walked worktree — minus gitignored content — into `.3code/snapshot/`
at arm and diffs against it at check. Plain files, no git dependence,
no privilege on the shipping path; reflink clones and the VSS service
are optional accelerators only.

### C3. Volume snapshots (LVM/ZFS/btrfs/VSS), FUSE virtualization

Privileges, volume-level granularity, or a heavyweight dependency and an
IO tax on every operation. Reject.

## The shape that follows

- **Arm** = manifest walk (unchanged, detector) + shadow copy (new,
  before-store), budget-tiered, both already mode-gated and cleared on
  disarm.
- **Fold** = unchanged walk/compare, but before-bytes come from the
  shadow; deletions diff from the shadow's bytes; inode match renders
  renames as renames.
- **Renderer must be fixed regardless**: with real befores, both sides
  of a pair can be cap-sized, and today's `lcsOps` is an `O(n·m)` table
  (measured: 2.0 GB peak for a 520 KB pair). Myers `O((n+m)·D)` or
  Hirschberg linear-space LCS, plus an input-size guard that drops to
  the existing name-only ladder.
- **Later, optional**: Linux fast path via B1 to skip the arm copy;
  shadow as a disk-backed change log (RAM win). Not now.

## Open questions before any implementation

1. Shadow budget (per-file cap alignment with `FoldFileCap`? total MB?
   tier policy — per-path fallback vs whole-tree fallback).
2. Rename semantics in the render (`rename a → b` vs delete+create).
3. Re-arm mid-session (mode file newer): settled as incremental —
   reuse store entries whose `(mtime, size, inode)` are unchanged,
   copy only the delta (near-free re-arms after the first).
4. Windows specifics: locked-file and case-collision policy.
5. VSS shadow-copy device read-back requires the SYSTEM context —
   confirmed; materialization happens in the helper service, not the
   requesting process (see the security review items).
