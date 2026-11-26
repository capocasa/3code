#!/usr/bin/env python3
"""Build the tty tests in parallel, then run them one at a time.

With --shard i/n the tests are split into n duration-balanced subsets
(longest-processing-time over tests/tools/tty_times.txt) and only subset i
is built and run; CI runs the subsets as separate jobs, so each runner
still runs one PTY test at a time while the whole category takes a third
of the wall time. Every test of the selection lands in exactly one shard,
so a shard run proves what a full run proves for its subset.

`testament cat tty` compiles and runs each of the 55 tty files sequentially:
one full source compile per file, then the test. The tty tests are
PTY-scheduler-sensitive, so the run phase stays serial, but the compile phase
is pure CPU work and can use every core. This runner precompiles the test
binaries (and the two stub variants) with a worker pool, then executes the
binaries in file order with a per-test cap.

Testament's spec handling is preserved where the tty category uses it:
`disabled: "osx" / "win"` is honored, and a test's exit code is the verdict.
No tty test uses matrix/output/exitCode specs.

Usage: parallel_tty.py [-j N] [--timeout SECS] [--build-only] [--list]
                  [--soak | --include-soak] [--shard i/n]
  -j N             compile workers (default: min(4, max(1, cpu_count - 1)))
  --timeout S      per-test run cap, 0 = off (default 720)
  --build-only     compile and stop
  --list           print the selected files and exit
  --soak           run only the soak tests in tests/tools/tty_soak.txt
  --include-soak   run the soak tests too (the default excludes them)
  --shard i/n      build and run only balanced subset i of n
"""
import argparse
import hashlib
import os
import re
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = os.getcwd()
TTY = os.path.join(ROOT, "tests", "tty")
CACHE = os.path.join(ROOT, "nimcache", "parallel_tty")
NIMFLAGS = ["--hints:on", "-d:testing", "--nimblePath:build/deps/pkgs2"]
SOAK_LIST = os.path.join(ROOT, "tests", "tools", "tty_soak.txt")
TIMES_LIST = os.path.join(ROOT, "tests", "tools", "tty_times.txt")
# A stem missing from tty_times.txt: near the suite median, so an unknown
# test neither starves a shard nor lands all of them on one.
UNKNOWN_SECS = 3.0
# The two stub variants the tty tests build through ensureStubBinary. The
# tag is Nim's `$secureHash(defines)` (sha1, first 16 hex chars, lowercase).
STUB_VARIANTS = [
    ("-d:ssl -d:providerStub --threads:on ",
     "-d:ssl -d:providerStub --threads:on"),
    ("-d:ssl -d:providerStub --threads:on -d:fastStubRetries",
     "-d:ssl -d:providerStub --threads:on -d:fastStubRetries"),
    ("-d:ssl -d:providerStub --threads:on -d:release",
     "-d:ssl -d:providerStub --threads:on -d:release"),
    ("-d:ssl -d:providerStub --threads:on -d:computerUse",
     "-d:ssl -d:providerStub --threads:on -d:computerUse"),
]


def read_stems(path):
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return set()
    return {l.strip() for l in lines
            if l.strip() and not l.lstrip().startswith("#")}


def read_times(path):
    times = {}
    try:
        for line in open(path, encoding="utf-8"):
            parts = line.split()
            if len(parts) == 2 and not parts[0].startswith("#"):
                times[parts[0]] = float(parts[1])
    except (OSError, ValueError):
        pass
    return times


def shard_of(paths, index, count):
    """Subset `index` (1-based) of `count` duration-balanced subsets.

    Longest-processing-time: walk the tests from slowest to fastest and
    append each to the shard with the least load so far. Deterministic, so
    the same selection always splits the same way.
    """
    times = read_times(TIMES_LIST)
    loads = [0.0] * count
    shards = [[] for _ in range(count)]
    for path in sorted(paths, key=lambda p: -times.get(os.path.basename(p)[:-4],
                                                       UNKNOWN_SECS)):
        i = min(range(count), key=lambda k: (loads[k], k))
        loads[i] += times.get(os.path.basename(path)[:-4], UNKNOWN_SECS)
        shards[i].append(path)
    return sorted(shards[index - 1])


def platform():
    if sys.platform == "darwin":
        return "osx"
    if sys.platform.startswith("win"):
        return "win"
    if sys.platform.startswith("linux"):
        return "linux"
    return sys.platform


def disabled_on(path):
    try:
        text = open(path, encoding="utf-8", errors="replace").read(4096)
    except OSError:
        return []
    return re.findall(r'disabled:\s*"([^"]+)"', text)


def source_newer_than(binary, *inputs):
    try:
        bt = os.path.getmtime(binary)
    except OSError:
        return True
    for root in inputs:
        if os.path.isfile(root):
            if os.path.getmtime(root) > bt:
                return True
            continue
        for dirpath, _, names in os.walk(root):
            for n in names:
                if n.endswith(".nim") and os.path.getmtime(
                        os.path.join(dirpath, n)) > bt:
                    return True
    return False


def stub_path(defines):
    tag = hashlib.sha1(defines.encode()).hexdigest()[:16]
    out = os.path.join(ROOT, "build", "3code_stub_" + tag)
    if platform() == "win":
        out += ".exe"
    return out


def compile_one(args):
    kind, name, cmd, log = args
    start = time.monotonic()
    with open(log, "wb") as out:
        proc = subprocess.Popen(cmd, stdout=out, stderr=subprocess.STDOUT,
                                cwd=ROOT, start_new_session=True)
        rc = proc.wait()
    return kind, name, rc, time.monotonic() - start, log


def run_one(binary, timeout, log):
    start = time.monotonic()
    with open(log, "wb") as out:
        proc = subprocess.Popen([binary], stdout=out, stderr=subprocess.STDOUT,
                                cwd=ROOT, start_new_session=True)
        try:
            rc = proc.wait(timeout=timeout if timeout > 0 else None)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            rc = -9
            out.write(b"\n[parallel_tty] killed: per-test timeout\n")
    return rc, time.monotonic() - start, log


def tail(path, n=40):
    try:
        data = open(path, "rb").read().decode("utf-8", "replace")
    except OSError:
        return ""
    lines = [re.sub(r"\[[0-9;]*m", "", l) for l in data.splitlines()]
    return "\n".join(lines[-n:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-j", "--jobs", type=int,
                    default=min(4, max(1, (os.cpu_count() or 2) - 1)))
    ap.add_argument("--timeout", type=int, default=720)
    ap.add_argument("--build-only", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--soak", action="store_true",
                    help="run only the soak tests")
    ap.add_argument("--include-soak", action="store_true",
                    help="run the soak tests too (default: exclude)")
    ap.add_argument("--file", help="run only the stems listed in this file")
    ap.add_argument("--shard", metavar="i/n",
                    help="build and run only subset i of n")
    args = ap.parse_args()
    if args.soak and args.include_soak:
        ap.error("--soak and --include-soak are mutually exclusive")
    shard = None
    if args.shard:
        m = re.fullmatch(r"([1-9][0-9]*)/([1-9][0-9]*)", args.shard)
        if not m or int(m.group(1)) > int(m.group(2)):
            ap.error("--shard wants i/n with 1 <= i <= n, got " + args.shard)
        shard = (int(m.group(1)), int(m.group(2)))

    here = platform()
    files = sorted(f for f in os.listdir(TTY)
                   if f.startswith("test_") and f.endswith(".nim"))
    selected, skipped, tier_skipped = [], [], []
    soak = read_stems(SOAK_LIST)
    only = read_stems(args.file) if args.file else None
    if only is not None:
        known = {f[:-4] for f in files}
        missing = only - known
        if missing:
            ap.error("unknown test stem(s) in " + args.file + ": " +
                     ", ".join(sorted(missing)))
    for f in files:
        path = os.path.join(TTY, f)
        dis = disabled_on(path)
        if here in dis:
            skipped.append((f, ",".join(dis)))
        elif only is not None and f[:-4] not in only:
            continue
        elif args.soak and f[:-4] not in soak:
            tier_skipped.append((f, "non-soak"))
        elif not (args.soak or args.include_soak) and f[:-4] in soak:
            tier_skipped.append((f, "soak"))
        else:
            selected.append(path)
    if shard:
        selected = shard_of(selected, *shard)

    if args.list:
        for p in selected:
            print(p)
        for f, dis in skipped:
            print(f"SKIP {f} (disabled: {dis})")
        for f, why in tier_skipped:
            print(f"SKIP {f} ({why})")
        return 0

    logdir = os.path.join(ROOT, "build", "parallel_tty_logs")
    os.makedirs(logdir, exist_ok=True)
    which = f"shard {shard[0]}/{shard[1]}, " if shard else ""
    print(f"parallel_tty: {which}{len(selected)} files, {len(skipped)} disabled, "
          f"{len(tier_skipped)} other-tier, {args.jobs} compile workers, "
          f"run cap {args.timeout or 'off'}s", flush=True)

    # Compile the two stub variants alongside the test binaries. Different
    # output paths mean different build locks; the build script's up-to-date
    # check turns the second one into a no-op on a warm tree.
    jobs = []
    for defines, flags in STUB_VARIANTS:
        out = stub_path(defines)
        if source_newer_than(out, "src", "tests/testdata/stub"):
            jobs.append(("stub", os.path.basename(out),
                         ["sh", "tests/tools/build_binary.sh", out,
                          "src/threecode.nim"] + flags.split(),
                         os.path.join(logdir, "stub_" + os.path.basename(out) + ".log")))

    for path in selected:
        stem = os.path.basename(path)[:-4]
        binary = os.path.join(TTY, stem)
        if platform() == "win":
            binary += ".exe"
        if source_newer_than(binary, path, "src", "tests/tty_expect.nim",
                             "tests/stub_helpers.nim", "tests/testdata/stub"):
            jobs.append(("test", stem,
                         ["nim", "c"] + NIMFLAGS +
                         ["--nimCache:" + os.path.join(CACHE, stem),
                          "--out:" + binary, path],
                         os.path.join(logdir, stem + ".compile.log")))

    failed = []
    if jobs:
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = [pool.submit(compile_one, j) for j in jobs]
            for i, fut in enumerate(as_completed(futures), 1):
                kind, name, rc, dur, log = fut.result()
                if rc == 0:
                    print(f"[build {i}/{len(jobs)}] OK {kind} {name} "
                          f"({dur:.1f}s)", flush=True)
                else:
                    failed.append((kind, name, log))
                    print(f"[build {i}/{len(jobs)}] FAIL {kind} {name} "
                          f"(rc={rc}, {dur:.1f}s)", flush=True)
                    # Whole log, not a tail: the truncated block loses the
                # deferred-dump sections a test prints after its failure
                # (the settings_midturn config-write trace), and the
                # recovery patterns in ci_tests.sh then find nothing.
                print(tail(log, n=100000), flush=True)

    if args.build_only:
        print(f"parallel_tty: build done, {len(failed)} failed", flush=True)
        return 1 if failed else 0

    run_failed = []
    for i, path in enumerate(selected, 1):
        stem = os.path.basename(path)[:-4]
        binary = os.path.join(TTY, stem)
        if platform() == "win":
            binary += ".exe"
        if not os.path.isfile(binary):
            run_failed.append((stem, "not built"))
            print(f"[run {i}/{len(selected)}] FAIL {stem}: not built", flush=True)
            continue
        log = os.path.join(logdir, stem + ".run.log")
        rc, dur, log = run_one(binary, args.timeout, log)
        if rc == 0:
            print(f"[run {i}/{len(selected)}] PASS {stem} ({dur:.1f}s)",
                  flush=True)
        else:
            run_failed.append((stem, rc))
            print(f"[run {i}/{len(selected)}] FAIL {stem} (rc={rc}, "
                  f"{dur:.1f}s)", flush=True)
            print(tail(log), flush=True)

    print(f"parallel_tty: {which}{len(selected) - len(run_failed)}/{len(selected)} "
          f"passed, {len(skipped)} disabled, {len(tier_skipped)} "
          f"other-tier, {len(failed)} build failures", flush=True)
    if failed:
        print("build failures:", flush=True)
        for kind, name, _ in failed:
            print(f"  {kind} {name}", flush=True)
    if run_failed:
        print("run failures:", flush=True)
        for name, rc in run_failed:
            print(f"  {name} (rc={rc})", flush=True)
    return 1 if failed or run_failed else 0


if __name__ == "__main__":
    sys.exit(main())
