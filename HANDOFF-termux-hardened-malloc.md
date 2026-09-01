# Handoff: 3code dies on Termux with "hardened allocator" error

## Symptom

3code on Termux (Android arm64) aborts under load with:

```
hardened_malloc: fatal allocator error: detected write after free
```

Also seen: `double free (quarantine)`. Exit code 134 (SIGABRT). Reproduces
reliably in a multi-turn, tool-heavy session. Never on Linux/macOS/Windows.

## Device

Reachable via `ssh david` (real Android phone running Termux). Work tree at
`~/3code-test` (a checkout of this repo on the `termux` branch). Config at
`~/.config/3code/config` with many free providers. gdb installed
(`pkg install -y gdb python`). `llvm-addr2line`, `llvm-objdump` present.
`logcat -d -b crash` holds tombstones. NOTE: device goes to sleep and drops
off ssh for tens of minutes; long stress runs must be launched detached
(`setsid script.sh > out 2>&1 < /dev/null &`) and polled.

### Working repro (crashes ORC every time, usually iteration 1)

Needs a working provider key on the device. Set config current to a model
that works on the device's keys (deepseek.deepseek-v4-flash worked; several
nvidia models 404/410, groq TPM-limits, cerebras 402). Then:

```sh
cd ~/3code-test
sed -i 's/^current = .*/current = "deepseek.deepseek-v4-flash"/' ~/.config/3code/config
( sleep 2; for n in $(seq 1 10); do echo "run: seq 1 4000 | tail -2; echo c-$n"; sleep 12; done; echo ":q"; sleep 3 ) \
  | timeout 200 script -qc "./build/BINARY 2>~/r.err" ~/r.log >/dev/null 2>&1
grep -a "hardened" ~/r.err   # => crash
```

`script` is needed for a PTY (the REPL requires a tty; one-shot prompt mode
does not drive a turn). stderr of the child is captured via `2>~/r.err`.

### Getting a symbolized backtrace

Build unstripped with line info:
`nim c -d:release --mm:orc -d:debugInfo -d:lineDir --os:android --cpu:arm64 -d:ssl -d:testPlainHttp -o:build/BIN src/threecode.nim`
Run it under the repro, then:
`logcat -d -b crash | grep "BIN" | grep -oE "pc 0000000000[0-9a-f]+" ` and feed
addresses to `llvm-addr2line -e build/BIN -f -C -p <addr>`.
Or run under gdb for a full all-threads dump:
`printf "set pagination off\nset confirm off\nrun\nthread apply all bt 12\n" > cmds; script -qc "gdb -batch -x cmds --args ./build/BIN" /dev/null`

## Root cause established so far

Android's bionic allocator is hardened_malloc (GrapheneOS-derived). It
quarantines freed chunks and aborts on first touch. The same heap corruption
is present on glibc but tolerated (silent double-free / quiet metadata rot),
which is why only Android dies. The corruption is real, not a false positive.

Crash is always detected in the **fatprompt GUI animation thread**
(`guiLoop`, src/threecode/fatprompt/runtime.nim), at
`getFrameModel()` → `rendering.eqcopy(FrameModel)` → `eqcopy(string)` →
`nimAsgnStrV2` → `allocImpl` → `malloc` → `__emutls_get_address` → abort.
The `__emutls_get_address` frame = Nim's emulated-TLS per-thread GC setup;
the abort fires there because the shared heap is already corrupt (the GUI
thread's copy is the detection point, not necessarily the corruptor).

`frameModelShared` (a `FrameModel` with 4 strings + a `ViewportSnapshot`
with a `seq[string]`) is written by main (`setAnim*`) and copied by the GUI
thread every 80ms tick, both under `frameModelLock`. The GUI thread also
reads the live `inputEditor: ptr LineEditor` (GC'd, mutated by the input
thread) in renderFooter/repaintLiveContent/renderToolViewport.

## Experiments and their results (all on david)

- `--mm:refc`: 6/6 clean. (Rejected: "we don't use refc".)
- `--mm:orc -d:useMalloc`: crashes → not the Nim allocator backend.
- `--mm:arc -d:gcAtomicArc`: crashes at the SAME site. Important: binary
  confirmed to use atomic RC (`__aarch64_ldadd8_acq_rel`), so the abort is a
  genuine write-after-free of a quarantined chunk (stale pointer), NOT a
  refcount-underflow race. atomicArc removes the cycle collector only.
- `--mm:yrc`: not supported by Nim 2.2.6 (device) / 2.2.10 (host). It is the
  threadsafe (atomic-RC) ORC variant; needs a newer Nim.
- Remove gui thread's `Thread[string]` arg (mirror of commit 2a8e63b's
  network-worker-args fix): still crashes. Reverted.
- GUI thread writes only int `elapsed` (no shared-string write-back): still
  crashes. Reverted.
- **`-d:noGuiThread` (GUI thread never started; ensureGuiStarted body wrapped
  in `when not defined(noGuiThread)`): 4/4 heavy runs CLEAN before device
  dropped.** This is the strongest signal: the corruptor is the GUI thread's
  shared-state access, not the network worker or input thread. Caveat: the
  user reports that dropping the GUI thread in production caused "a lot of
  interface blocking" — so "just remove the thread" is NOT acceptable. The
  noGuiThread build was only an isolation experiment (local change copied to
  device, NOT committed; device src/threecode/fatprompt/runtime.nim may still
  hold it — restore from git before building).

Nim docs (mm.html): "ARC/ORC are not threadsafe if ref or other automatically
managed types are accessed across thread boundaries." ORC RC ops are
non-atomic; shared heap means *move isolated subgraphs*, not concurrently
inc/dec the same cell. But see the open question below.

## The open question (user's pushback, unanswered)

The user believes "ORC shared data with locks is fine" and that is the model
the codebase needs. This is *almost* true and the codebase relies on it
everywhere. The precise gap needs to be pinned down: under ORC, does holding
a `Lock` around a copy of a shared struct make the cross-thread access safe,
or is there a specific window (e.g. the dec-ref of the destination's old
string happening after `release`, or reading `inputEditor` with no lock, or
the compiler eliding/reordering RC ops) that breaks it? The atomicArc result
(same WAF with atomic RC) suggests the bug may be a plain logic UAF (a stale
pointer kept somewhere) rather than an RC race at all. That would reconcile
"locks are fine" with the crash: the lock discipline is correct for the
FrameModel but some OTHER shared GC object (inputEditor? apiLiveStream?
fatPromptState? the FrameModel copied OUT and held past the lock?) is read or
freed without the lock.

## What to do next (investigate, then fix keeping shared GC + locks)

1. Confirm the noGuiThread result holds for a full 8/8 run (device was at 4/4
   when it went offline). Restore device src from git first.
2. With the GUI thread confirmed as the corruptor, find WHICH shared GC
   access is unlocked/racy. Candidates in guiLoop's tick:
   - `getFrameModel()` copy: is the copied FrameModel's strings dec-ref'd
     after `release frameModelLock`, racing main's next `setAnim*`?
   - `inputEditor` reads in renderFooter/repaintLiveContent/renderToolViewport:
     is there ANY lock, or does the GUI thread read a LineEditor the input
     thread mutates freely? (grep shows inputEditor used with no editor lock.)
   - `apiLiveStream`, `fatPromptState`, `currentBarLabel`, `barTickStart`.
3. Use gdb hardware watchpoints on `frameModelShared` string fields to catch
   the free that later trips hardened_malloc, and `thread apply all bt` at
   the abort to see the concurrent writer. gdb4.cmds already produced an
   all-threads dump; the main thread was in pthread_create (network worker),
   input thread in poll, quiet/draft threads sleeping.
4. The fix must keep ORC, keep shared GC, keep the GUI thread (no interface
   blocking), and use locks. Likely shape: hold `frameModelLock` (and an
   editor lock) across the ENTIRE read-copy-use region, or route all ORC
   state the GUI needs through a single lock that the writers also hold for
   their whole write+publish, so no inc/dec of a shared cell ever happens
   outside the lock on any thread. Verify against the 8-iteration stress.

## Repo state

Branch `termux`. Working tree clean at the last push. The refc commit and all
fatprompt experiments were reverted. Commit history on the branch is a series
of revert/revert pairs; consider whether to keep or squash before merging to
main. HANDOFF file is this document; delete it when the fix lands.

Relevant source:
- src/threecode/fatprompt/runtime.nim (guiLoop ~760, frameModel* ~298-378,
  ensureGuiStarted ~960, inputEditor ~278)
- src/threecode/fatprompt/rendering.nim (FrameModel ~130, ViewportSnapshot ~118)
- src/threecode/netthread.nim (NetJobState/deltas, ORC constraint comment ~16)
- src/threecode/api.nim (networkWorker ~2284, the 2a8e63b cross-thread comment)
- config.nims (`when defined(android)` block: RUNPATH for openssl)
- .github/workflows/termux.yml (NDK cross build)
