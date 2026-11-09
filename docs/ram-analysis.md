.. title:: 3code - RAM usage analysis


October 30, 2026. Measurements from the `ram` worktree at `54cddeda`
(release config, `-d:release --opt:size`, ORC, Nim 2.4.0), Linux 6.x,
glibc. Reproducible with `tests/tty/probe_ram.nim` (new) and
`tests/api/test_memory_leak.nim` (extended to print its numbers).

## The short version

A 3code session costs about **10 MB resident at boot** and grows with
the history it keeps in memory, roughly **160 kB per turn** before
compaction. Auto-summarization bounds the history, and measured RSS
slope after warmup is **16 kB over 90 turns** in the 120-turn
threaded-transport regression (`test_memory_leak`, issue #35), i.e.
flat. Real working sessions on this box sit between 20 MB and 205 MB
depending on how much conversation and tool output they carry.

The big `VSZ` numbers in `top` (300-500 MB) are **not** memory usage:
two glibc thread arenas each reserve 64 MB of address space
(`PROT_NONE`, zero pages touched), plus an 8 MB thread stack
reservation, plus the usual library mappings. RSS is the number that
costs anything.

## Live sessions (the "why is 3code using X" table)

Sampled from `/proc/<pid>/status` of real sessions on this machine,
real providers, October 30 around 12:52:

| PID | Uptime | Threads | VSZ | RSS |
| --- | --- | ---: | ---: | ---: |
| 892149 | ~1.4 h | 3 | 303 MB | 20 MB |
| 860922 | ~2 h | 4 | 355 MB | 62 MB |
| 961863 | ~1.3 h | 6 | 346 MB | 63 MB |
| 1071766 | ~1.2 h | 4 | 520 MB | 156 MB |
| 885992 | ~1.5 h | 4 | 515 MB | 205 MB |

All five were **flat over a 2-minute re-sample**: the big ones had
grown during active turns (long conversations, tool output, streaming
buffers) and were steady once idle. Idle drift over 75 s in the
controlled probe below was exactly zero kB.

A debugger note for anyone reproducing this: `gdb -p` on a foreign
3code fails under `ptrace_scope=1` (siblings cannot trace siblings),
and distro glibc strips `malloc_stats`/`malloc_info` from the exported
symbol table, so they are not debugger-callable either. The census
below comes from `/proc/<pid>/smaps` of a self-spawned child, which an
ancestor may read.

## Controlled probe: boot, idle, turns, paste, resume

`tests/tty/probe_ram.nim` drives the real binary (built with
`-d:providerStub`, so the model is canned but the full UI, editor,
render, thread, and session machinery is live) through a PTY and
samples `/proc/<pid>` at each stage. 119x40 terminal, 40 turns, one
8 kB paste, then exit and `-r` resume of the same session:

| Stage | RSS | VSZ | Threads |
| --- | ---: | ---: | ---: |
| boot, prompt ready | 9.7 MB | 21.8 MB | 2 |
| after 75 s idle | 9.7 MB | 21.8 MB | 2 |
| turn 5 | 14.1 MB | 164.2 MB | 3 |
| turn 40 | 16.0 MB | 165.7 MB | 3 |
| 8 kB paste in editor | 18.6 MB | 168.3 MB | 3 |
| paste submitted | 18.7 MB | 168.3 MB | 3 |
| resume, 14 kB `.3log` | 10.0 MB | 22.3 MB | 2 |

Reading the table:

- **The first five turns retain ~4.4 MB** (message history, rendered
  rows, receipts) and add one thread (the network worker); VSZ jumps
  ~142 MB at that point because glibc sizes the worker's arena
  reservation then, not at boot. RSS barely moves.
- **Turns retain history**: about 160 kB/turn with the stub's ~3.7 kB
  replies (messages, rendered rows, receipts). Auto-compaction bounds
  it: a longer variant of the same probe hit auto-summarization around
  turn 55 ("context at 10.0k/12.0k"), holding a ~27 MB plateau at that
  point (that run preloads all 300 canned responses into memory, so
  several MB of the plateau is fixture overhead).
- **A paste costs about 2.7 MB of editor state for 8 kB** (+0.1 MB more
  on submit), freed again on submit.
- **Resume is cheap**: a fresh process re-rendering a 14 kB transcript
  lands 0.3 MB above a fresh boot.

## 120-turn leak regression (issue #35)

`tests/api/test_memory_leak.nim` runs 120 real threaded-transport
turns against a local HTTP server with usage numbers chosen to trip
auto-summarization every ~10 turns, then asserts the RSS slope from
turn 30 to the end stays under 5 MB. It now prints its measurement:

```
rss warmup 17192kB end 17208kB slope 16kB over 90 turns
```

This is the guard for the three leak classes that once made RSS grow
forever on long sessions (per-summarizer SSL context leak, worker
thread ORC leaks, cycle-table strands). 0.2 kB/turn of drift is
allocator noise, not a leak.

## Where the memory actually lives (census)

`smaps` of the probe child mid-session (turn 20, RSS 15.7 MB), largest
resident mappings:

| kB RSS | Mapping |
| ---: | --- |
| 5352 | anonymous rw (Nim ORC heap: message history, rendered rows) |
| 1920 | `3code` binary text (release, `--opt:size`, 4.9 MB on disk) |
| 1536 | `libcrypto.so.3` text |
| 1392 | `libc.so.6` text |
| 696 | anonymous rw (second arena / stream buffers) |
| 580+324+240 | `3code` binary rodata + relocated data |

And the largest **virtual** reservations, which are the VSZ story:

| kB Size | kB RSS | Mapping |
| ---: | ---: | --- |
| 65404 | 0 | `---p` anonymous (glibc arena reservation, thread 2) |
| 65404 | 0 | `---p` anonymous (glibc arena reservation, thread 3) |
| 8192 | 84 | `rw-p` anonymous (thread stack) |

So VSZ 165 MB decomposes as: 2 x 64 MB arena fences + 8 MB stack +
heap + ~15 MB of libraries. glibc reserves each non-main arena as one
64 MB `PROT_NONE` region and commits pages inside it only as that
thread mallocs. Nothing can be "freed" here; if VSZ bothers you,
`MALLOC_ARENA_MAX=2` caps the count (at some lock contention cost),
but RSS is unaffected.

## Paste cost (the one real problem found)

Feeding a large single-line paste into the editor and submitting it is
**superlinear in wall time, though flat in memory**. Timed with
30 ms-drain PTY feeding (1.8 kB pieces), stub provider, otherwise
idle session:

| Paste | Feed time | Submit-to-reply | RSS after |
| ---: | ---: | ---: | ---: |
| 1 kB | 1.0 s | 0.25 s | +0.8 MB |
| 2 kB | 2.1 s | 0.25 s | +1.3 MB |
| 4 kB | 3.2 s | 0.25 s | +3.4 MB |
| 8 kB | 5.2 s | 0.25 s | +3.5 MB |
| 16 kB | 10.7 s | 2.0 s | +3.8 MB |
| 24 kB | 15.0 s | 12.1 s | +4.1 MB |
| 32 kB | 22.4 s | > 180 s, still not done | +3.3 MB |

Feed cost grows smoothly (~0.7 s/kB, the editor reflowing the growing
line per piece). Submit cost falls off a cliff instead: 8 kB answers
in a quarter second, 24 kB in twelve seconds, and a 32 kB single-line
paste was still grinding its scrollback echo commit after three
minutes (about 12% of one core, mostly parked in ticker repaints
between bursts; RSS flat at 14.4 MB the whole time). Whatever wraps
and commits the echoed prompt row is worse than quadratic in line
length. Memory stays bounded; a big paste into 3code will not OOM you,
but anything past a few tens of kB on one line will pin the render
path for minutes. That is the one finding here worth a follow-up issue.

## Reproducing

```
# stub binary + probe (release config)
nim c --skipParentCfg --noNimblePath -d:release --opt:size \
  -p:src -p:tests -d:ssl -d:testPlainHttp -d:providerStub --threads:on \
  <dep paths> -o:/tmp/3code_stub src/threecode.nim
nim c --skipParentCfg --noNimblePath -p:src -p:tests -d:ssl \
  -d:testPlainHttp <dep paths> -o:/tmp/probe_ram tests/tty/probe_ram.nim
/tmp/probe_ram /tmp/3code_stub [turns=40] [idle-secs=75]

# leak regression (prints its slope now)
nim c -r tests/api/test_memory_leak.nim
```

Caveats: the stub provider replaces the network with canned in-process
responses, so per-turn RSS deltas exclude real TLS/stream buffers (the
live-session table above covers that side qualitatively). All numbers
are one box, one run each; treat single-digit-kB differences as noise.
