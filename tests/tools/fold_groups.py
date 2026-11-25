#!/usr/bin/env python3
"""Fold a test category into a few domain groups: N compiles -> a few.

Every `tests/<cat>/test_*.nim` is a unittest module that pays its own Nim
frontend + C compile + link pass. Folding imports several modules into one
generated binary, which runs them in import order (equivalent to
concatenating the files), so each group pays one compile instead of one per
file. Groups run in separate processes: a group that passes alone keeps
process isolation from the other groups, which is what makes the fold safe
where a single all-core binary was not.

The spec lives in `tests/tools/<cat>_groups.txt`:

    # comment
    session: test_session test_session_diff ...
    solo: test_build_provenance

A group line is `<name>: <module>...`, import order = the order written.
`solo:` lists files that stay per-file in the pool; the tool refuses to run
if a test file is in no group, in two groups, or named but missing, so a new
test cannot silently lose coverage.

Self-exec tests (they call getAppFilename() and dispatch on argv, e.g.
test_session's --allocate/--lock* workers) must be the FIRST module of their
group: the spawned child is this same binary and must reach its argv check
before any other module's tests run.

Validation: `--baseline` runs every non-solo file as its own one-module
group (same flags, same runner, per-file isolation) and writes the (suite,
test) names each file executes to JSON. A grouped run with `--compare` then
reports every name that the fold lost or added. `--json` writes the grouped
run's names.

Usage: fold_groups.py [options] CATEGORY
  --list          print groups and solo files, then exit
  --list-solo     print solo file paths, one per line (for the file pool)
  --build-only    compile the group binaries and stop
  --only G        build and run just group G
  --baseline      one group per file; write per-file test names to --json
  --compare FILE  compare this run's names against a --baseline JSON
  --json PATH     write per-group test names/counts to PATH
  -j N            compile workers (default: max(1, min(4, cpu_count - 1)))
  --timeout S     run cap per group, 0 = off (default 720)
Exit status is nonzero if a compile or a group run fails, or a compare finds
a difference.
"""
import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = os.getcwd()
TEST_LINE = re.compile(r"^\s+\[(OK|FAILED|SKIPPED)\]\s+(.*)$")
SUITE_LINE = re.compile(r"^\[Suite\]\s+(.*)$")


def spec_path(cat):
    return os.path.join(ROOT, "tests", "tools", f"{cat}_groups.txt")


def parse_spec(path):
    """Return (groups, solo): groups is [(name, [module...])], in file order."""
    groups, solo, seen = [], [], {}
    with open(path, encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            if ":" not in line:
                raise SystemExit(f"{path}:{lineno}: expected 'name: module...'")
            name, rest = line.split(":", 1)
            name, mods = name.strip(), rest.split()
            if not name or not mods:
                raise SystemExit(f"{path}:{lineno}: empty group name or module list")
            if name == "solo":
                solo.extend(mods)
                continue
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                raise SystemExit(f"{path}:{lineno}: '{name}' is not a valid "
                                 "binary/module name")
            if any(g[0] == name for g in groups):
                raise SystemExit(f"{path}:{lineno}: group '{name}' listed twice")
            groups.append((name, mods))
            for m in mods:
                if m in seen:
                    raise SystemExit(f"{path}:{lineno}: '{m}' is in two "
                                     f"groups ('{seen[m]}' and '{name}')")
                seen[m] = name
    return groups, solo


def category_files(cat):
    catdir = os.path.join(ROOT, "tests", cat)
    return sorted(f[:-4] for f in os.listdir(catdir)
                  if f.startswith("test_") and f.endswith(".nim"))


def validate(cat, groups, solo):
    files = category_files(cat)
    known = set(files)
    listed = {}
    for name, mods in groups:
        for m in mods:
            if m in listed:
                raise SystemExit(f"fold_groups: {m} is in groups "
                                 f"'{listed[m]}' and '{name}'")
            listed[m] = name
    for m in solo:
        if m in listed:
            raise SystemExit(f"fold_groups: {m} is both grouped and solo")
        listed[m] = "solo"
    unknown = sorted(set(listed) - known)
    if unknown:
        raise SystemExit("fold_groups: not test files in tests/" + cat +
                         ": " + " ".join(unknown))
    missing = sorted(known - set(listed))
    if missing:
        raise SystemExit("fold_groups: test files in no group and not solo "
                         "(add them to " + spec_path(cat) + "): " +
                         " ".join(missing))
    return files


def group_source(cat, group, mods):
    path = os.path.join(ROOT, "build", f"fold_{cat}_{group}.nim")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("# Generated by tests/tools/fold_groups.py; do not edit.\n")
        for m in mods:
            f.write(f"import {cat}/{m}\n")
    return path


def binary_path(cat, group):
    p = os.path.join(ROOT, "build", f"fold_{cat}_{group}")
    return p + ".exe" if sys.platform.startswith("win") else p


def compile_group(cat, group, mods):
    src = group_source(cat, group, mods)
    binary = binary_path(cat, group)
    cache = os.path.join(ROOT, "build", f"fold_{cat}_{group}_cache")
    log = os.path.join(ROOT, "build", f"fold_{cat}_{group}.build.log")
    cmd = ["nim", "c", "--hints:on", "-d:testing",
           "--nimblePath:build/deps/pkgs2", "--path:src", "--path:tests",
           "--nimcache:" + cache, "--out:" + binary, src]
    start = time.monotonic()
    with open(log, "wb") as out:
        rc = subprocess.call(cmd, cwd=ROOT, stdout=out, stderr=subprocess.STDOUT)
    return group, rc, time.monotonic() - start, log


def parse_names(log):
    """[(suite, test, status)] from a unittest run's output."""
    names, suite = [], ""
    try:
        with open(log, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.rstrip("\n")
                m = SUITE_LINE.match(line)
                if m:
                    suite = m.group(1).strip()
                    continue
                m = TEST_LINE.match(line)
                if m:
                    names.append((suite, m.group(2).strip(), m.group(1)))
    except OSError:
        pass
    return names


def run_group(cat, group, timeout):
    binary = binary_path(cat, group)
    log = os.path.join(ROOT, "build", f"fold_{cat}_{group}.run.log")
    start = time.monotonic()
    with open(log, "wb") as out:
        proc = subprocess.Popen([binary], cwd=ROOT, stdout=out,
                                stderr=subprocess.STDOUT,
                                start_new_session=True)
        timed_out = False
        try:
            rc = proc.wait(timeout=timeout if timeout > 0 else None)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            rc, timed_out = -9, True
    dur = time.monotonic() - start
    names = parse_names(log)
    failed = [n for n in names if n[2] == "FAILED"]
    return {"cat": cat, "group": group, "rc": rc, "timeout": timed_out,
            "seconds": dur, "names": names, "failed": len(failed),
            "skipped": sum(1 for n in names if n[2] == "SKIPPED"),
            "tests": len(names), "log": log}


def report_run(result, quiet=False):
    # Testament's PASS:/FAIL: shape so ci_tests.sh's summary and annotation
    # greps see the folded groups; the tool's own summary stays separate.
    ok = result["rc"] == 0 and not result["timeout"]
    verdict = ("PASS:" if ok else "FAIL:")
    why = "" if ok else (" timed out" if result["timeout"]
                         else f" rc={result['rc']}")
    print(f"{verdict} fold_{result['cat']}_{result['group']}{why}: "
          f"{result['tests']} tests, {result['failed']} failed, "
          f"{result['skipped']} skipped, {result['seconds']:.1f}s",
          flush=True)
    if not ok and not quiet:
        # Whole log: a truncated block loses the `Test "..."` header and the
        # assertion that name the break, which is all the attribution a
        # folded binary has.
        try:
            sys.stdout.write(open(result["log"], encoding="utf-8",
                                   errors="replace").read())
        except OSError:
            pass
        sys.stdout.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("category")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--list-solo", action="store_true")
    ap.add_argument("--build-only", action="store_true")
    ap.add_argument("--only")
    ap.add_argument("--baseline", action="store_true")
    ap.add_argument("--compare")
    ap.add_argument("--json")
    ap.add_argument("-j", "--jobs", type=int,
                    default=max(1, min(4, (os.cpu_count() or 2) - 1)))
    ap.add_argument("--timeout", type=int, default=720)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    cat = args.category.strip("/")
    if not cat or "/" in cat or cat in (".", ".."):
        ap.error("category is a name under tests/, not a path")
    spec = spec_path(cat)
    if not os.path.isfile(spec):
        raise SystemExit(f"fold_groups: no spec at {spec}")
    groups, solo = parse_spec(spec)
    files = validate(cat, groups, solo)

    if args.list:
        for name, mods in groups:
            print(f"{name}: {' '.join(mods)}")
        if solo:
            print(f"solo: {' '.join(solo)}")
        return 0
    if args.list_solo:
        for m in solo:
            print(os.path.join("tests", cat, m + ".nim"))
        return 0

    if args.baseline:
        # One group per non-solo file: the per-file baseline, through the
        # same compile flags and runner as the fold, so the comparison is
        # apples to apples.
        groups = [(m, [m]) for m in files if m not in solo]
    elif args.only:
        selected = [g for g in groups if g[0] == args.only]
        if not selected:
            raise SystemExit(f"fold_groups: no group '{args.only}' in {spec}")
        groups = selected

    print(f"fold_groups: {cat}: {len(groups)} groups, "
          f"{sum(len(m) for _, m in groups)} modules, {args.jobs} compile "
          f"workers, timeout {args.timeout or 'off'}s", flush=True)
    results = []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(compile_group, cat, g, mods)
                   for g, mods in groups]
        for fut in as_completed(futures):
            group, rc, dur, log = fut.result()
            if rc != 0:
                print(f"fold_groups: {group}: BUILD FAIL ({dur:.1f}s)",
                      flush=True)
                try:
                    sys.stdout.write(open(log, encoding="utf-8",
                                           errors="replace").read())
                except OSError:
                    pass
                results.append({"group": group, "rc": rc, "timeout": False,
                                "seconds": dur, "names": [], "failed": 0,
                                "skipped": 0, "tests": 0, "log": log,
                                "build_failed": True})
            else:
                print(f"fold_groups: {group}: built ({dur:.1f}s)", flush=True)
    # A build failure is fatal: running a stale binary would report the
    # previous source's tests as if they were this one's.
    if any(r.get("build_failed") for r in results):
        return 1
    if args.build_only:
        return 0

    # Compile output is unordered (pool); run in spec order so a run log
    # reads in the order the spec declares.
    results = []
    for g, _ in groups:
        r = run_group(cat, g, args.timeout)
        results.append(r)
        report_run(r, args.quiet)

    total = sum(r["tests"] for r in results)
    failed = sum(r["failed"] for r in results)
    skipped = sum(r["skipped"] for r in results)
    bad = sum(1 for r in results if r["rc"] != 0 or r["timeout"])
    print(f"fold_groups: {cat}: {total} tests, {failed} failed, "
          f"{skipped} skipped, {bad} group(s) not passing", flush=True)

    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump({r["group"]: {"tests": r["tests"],
                                    "failed": r["failed"],
                                    "skipped": r["skipped"],
                                    "names": [list(n) for n in r["names"]]}
                       for r in results}, f, indent=1)
        print(f"fold_groups: wrote {args.json}", flush=True)

    rc = 1 if (bad or failed) else 0
    if args.compare:
        rc |= compare(args.compare, groups, results, files)
    return rc


def compare(baseline_path, groups, results, files):
    baseline = json.load(open(baseline_path, encoding="utf-8"))
    base_names = {}
    base_status = {}
    for f in files:
        if f not in baseline:
            continue
        for suite, test, status in baseline[f]["names"]:
            base_names.setdefault(f, set()).add((suite, test))
            base_status[(f, suite, test)] = status
    diffs = 0
    for (g, mods), r in zip(groups, results):
        expected = set()
        for m in mods:
            expected |= base_names.get(m, set())
        actual = {(s, t) for s, t, _ in r["names"]}
        missing, extra = expected - actual, actual - expected
        # Status is reported but does not fail the compare: a group's own
        # exit status already fails the run, and an environment-dependent
        # skip (a user policy file present on this box) is not a lost test.
        status = {(s, t): st for s, t, st in r["names"]}
        flips = []
        for f in mods:
            for s, t in base_names.get(f, set()):
                was, now = base_status.get((f, s, t)), status.get((s, t))
                if was and now and was != now:
                    flips.append((was, now, f, s, t))
        if missing or extra:
            diffs += 1
            print(f"fold_groups: {g}: compare differs "
                  f"({len(missing)} missing, {len(extra)} extra)",
                  flush=True)
            for s, t in sorted(missing):
                print(f"  missing: [{s}] {t}", flush=True)
            for s, t in sorted(extra):
                print(f"  extra:   [{s}] {t}", flush=True)
        else:
            print(f"fold_groups: {g}: compare matches baseline "
                  f"({len(actual)} names, {len(flips)} status flips)",
                  flush=True)
        for was, now, f, s, t in flips:
            print(f"  status: {was}->{now}: {f}: [{s}] {t}", flush=True)
    print(f"fold_groups: compare: {diffs} group(s) differ", flush=True)
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main())
