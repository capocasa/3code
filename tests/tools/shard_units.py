#!/usr/bin/env python3
"""Split a set of named test units into n duration-balanced shards and
print the units shard i owns, longest first.

Used by ci_tests.sh for CORE_SHARD: the non-tty suite is a set of units
(the config fold, each core fold group, each pooled test file) whose wall
seconds live in tests/tools/core_times.txt. Longest-processing-time
balancing, as in parallel_tty.py's --shard: walk the units from slowest to
fastest and append each to the shard with the least load so far. Every
unit lands in exactly one shard, so the shards together are the suite.

Usage: shard_units.py i/n UNIT...
  UNIT is a name: `config`, `core:<group>`, or a test file path.
  Unknown units count as UNKNOWN_SECS.
"""
import os
import re
import sys

TIMES_LIST = os.path.join(os.getcwd(), "tests", "tools", "core_times.txt")
UNKNOWN_SECS = 20.0


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


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    m = re.fullmatch(r"([1-9][0-9]*)/([1-9][0-9]*)", argv[1])
    if not m or int(m.group(1)) > int(m.group(2)):
        sys.exit("shard_units: wants i/n with 1 <= i <= n, got " + argv[1])
    index, count = int(m.group(1)), int(m.group(2))
    units = argv[2:]
    times = read_times(TIMES_LIST)
    secs = lambda u: times.get(u, UNKNOWN_SECS)
    loads = [0.0] * count
    shards = [[] for _ in range(count)]
    for u in sorted(units, key=lambda u: (-secs(u), u)):
        i = min(range(count), key=lambda k: (loads[k], k))
        loads[i] += secs(u)
        shards[i].append(u)
    for u in sorted(shards[index - 1], key=lambda u: (-secs(u), u)):
        print(u)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
