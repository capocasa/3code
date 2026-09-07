#!/bin/sh
# Select existing unittest scenarios without building one executable per case.
set -eu
cd "$(dirname "$0")/.."
source=tests/tty/test_tty_functional.nim
names=$(sed -n 's/^  test "\(.*\)":$/\1/p' "$source")
case ${1:---list} in
  --list) printf '%s\n' "$names"; exit 0 ;;
  --stress) shift; set -- 'shakedown: one session exercises the full REPL contract' "$@" ;;
esac
[ "$#" -gt 0 ] || { echo 'Select an exact scenario name or --stress' >&2; exit 2; }
for name do
  printf '%s\n' "$names" | grep -Fx -- "$name" >/dev/null || {
    echo "Unknown scenario: $name (use --list)" >&2; exit 2;
  }
done
out=${TTY_SCENARIO_BINARY:-testdata/output/tty-functional}
start=$(date +%s)
sh tools/build_binary.sh "$out" "$source"
printf 'scenario build_seconds=%s revision=%s binary=' "$(( $(date +%s) - start ))" "$(git rev-parse --short HEAD)"
cksum "$out"
rc=0
for name do
  start=$(date +%s)
  "$out" "$name" || rc=1
  printf 'scenario=%s run_seconds=%s\n' "$name" "$(( $(date +%s) - start ))"
done
exit "$rc"
