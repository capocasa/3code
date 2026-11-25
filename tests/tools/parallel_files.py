#!/usr/bin/env python3
"""Run testament one test file at a time, N files concurrently.

`testament cat <category>` compiles and runs its files sequentially. That
serializes the dominant cost (one full source compile per file) and leaves
cores idle for the length of the category. This runner keeps testament's
per-file semantics (spec headers, matrix, disabled) but fans the files out
over a worker pool. Each worker owns its own testament process and nimcache,
so no state is shared between files beyond what the tests themselves touch.

Usage: parallel_files.py [-j N] [--timeout SECS] file...
  -j N         worker count (default: max(1, cpu_count - 1))
  --timeout S  kill a single file after S seconds (0 = no per-file cap)
  --quiet      only print failures and the summary
Exit status is nonzero when any file fails or times out.
"""
import argparse
import os
import signal
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor, as_completed


def run_one(path, timeout, logdir):
    start = time.monotonic()
    log = os.path.join(logdir, os.path.basename(path) + ".log")
    cmd = ["testament", "--print", "--megatest:off", "--backendLogging:off",
           "r", path]
    with open(log, "wb") as out:
        proc = subprocess.Popen(
            cmd, stdout=out, stderr=subprocess.STDOUT,
            start_new_session=True, cwd=os.getcwd())
        try:
            rc = proc.wait(timeout=timeout if timeout > 0 else None)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            rc = -9
            with open(log, "ab") as f:
                f.write(b"\n[parallel_files] killed: per-file timeout\n")
    return path, rc, time.monotonic() - start, log


def tail(path, n=40):
    try:
        with open(path, "rb") as f:
            data = f.read().decode("utf-8", "replace")
    except OSError:
        return ""
    lines = data.replace("\x1b", "").splitlines()
    # Drop ANSI color sequences; the log is for humans.
    import re
    clean = [re.sub(r"\[[0-9;]*m", "", l) for l in lines]
    return "\n".join(clean[-n:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-j", "--jobs", type=int,
                    default=max(1, (os.cpu_count() or 2) - 1))
    ap.add_argument("--timeout", type=int, default=0)
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("files", nargs="+")
    args = ap.parse_args()

    files = [f for f in args.files if os.path.isfile(f)]
    if not files:
        print("no test files given", file=sys.stderr)
        return 2

    failed = []
    logdir = tempfile.mkdtemp(prefix="parallel_files_")
    print(f"parallel_files: {len(files)} files, {args.jobs} workers, "
          f"timeout {args.timeout or 'off'}s, logs {logdir}", flush=True)
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run_one, f, args.timeout, logdir)
                   for f in files]
        done = 0
        for fut in as_completed(futures):
            path, rc, dur, log = fut.result()
            done += 1
            if rc == 0:
                if not args.quiet:
                    print(f"[{done}/{len(files)}] PASS {path} ({dur:.1f}s)",
                          flush=True)
            else:
                failed.append((path, rc, log))
                print(f"[{done}/{len(files)}] FAIL {path} "
                      f"(rc={rc}, {dur:.1f}s)", flush=True)
                print(tail(log), flush=True)

    print(f"parallel_files: {len(files) - len(failed)}/{len(files)} passed",
          flush=True)
    if failed:
        print("failed files:", flush=True)
        for path, rc, _ in failed:
            print(f"  {path} (rc={rc})", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
