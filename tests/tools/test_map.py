#!/usr/bin/env python3
"""Map a source file to the tests that cover it.

Most tty tests drive the full binary and never import the module they
cover, so imports alone are not enough. Three signals, each labeled:

  * imports  - tests that import the module directly;
  * covers   - a test carrying `## Covers: <path>` (one path per line);
  * names    - tests whose source mentions the module basename.

Usage: test_map.py PATH...
  PATH is a file under src/ (or tests/ for harness modules).
"""
import os
import re
import sys

ROOT = os.getcwd()


def module_name(path):
    rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
    for prefix in ("src/", "tests/"):
        if rel.startswith(prefix):
            return rel[len(prefix):-4]
    return rel[:-4]


def imports_of(path):
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return set()
    mods = set()
    for m in re.finditer(r'^\s*(?:import|from)\s+([^\n]+)', text, re.M):
        clause = m.group(1)
        if clause.startswith("std/") or clause.startswith("std."):
            continue
        clause = clause.split(' except ')[0]
        for part in clause.split(","):
            part = part.strip().strip('"')
            if part and not part.startswith("std"):
                mods.add(part.rstrip())
    return mods


def walk(root, suffix=".nim"):
    for dirpath, _, names in os.walk(root):
        for n in names:
            if n.endswith(suffix):
                yield os.path.join(dirpath, n)


def covers_lines(path):
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return []
    out = []
    for m in re.finditer(r'^##\s*Covers:\s*(\S+)', text, re.M):
        path = m.group(1).strip().replace("\\", "/")
        out.append(module_name(os.path.join(ROOT, path)))
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    sources = [module_name(p) for p in sys.argv[1:]]
    basenames = {s.rsplit("/", 1)[-1] for s in sources}

    all_src = list(walk(os.path.join(ROOT, "src")))
    all_tests = list(walk(os.path.join(ROOT, "tests")))
    # Only test files, not the helpers under tests/.
    tests = [p for p in all_tests
             if os.path.basename(p).startswith("test_")]

    imports = {p: imports_of(p) for p in all_src + tests}
    covers = {p: covers_lines(p) for p in all_src + tests}

    # The name signal is only meaningful for tty tests: they drive the full
    # binary and import nothing from src, so a module basename in their text
    # is the only cheap link. Short generic names are not signals.
    generic = {"api", "util", "types", "config"}
    by_import, by_cover, by_name = {}, {}, {}
    for t in tests:
        for src in sources:
            if src in imports[t]:
                by_import.setdefault(src, set()).add(t)
            if src in covers[t]:
                by_cover.setdefault(src, set()).add(t)
            base = src.rsplit("/", 1)[-1]
            if base in basenames and base not in generic and \
                    os.sep + "tty" + os.sep in t and \
                    t not in by_import.get(src, set()) and \
                    t not in by_cover.get(src, set()):
                try:
                    text = open(t, encoding="utf-8",
                                errors="replace").read()
                except OSError:
                    continue
                if re.search(r"\b" + re.escape(base) + r"\b", text):
                    by_name.setdefault(src, set()).add(t)

    for src in sources:
        print(src)
        for label, table in (("imports", by_import),
                             ("covers", by_cover),
                             ("names", by_name)):
            found = table.get(src, set())
            for t in sorted(found):
                print(f"  {label:7} {os.path.relpath(t, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
