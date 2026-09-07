#!/bin/sh
# Shared testament selection; never approximate its metadata with nim c -r.
set -u
command -v testament >/dev/null 2>&1 || {
  echo 'ERROR: testament is required (ships with Nim).' >&2
  exit 127
}
mode=${1:-all}
[ $# -eq 0 ] || shift
rc=0
case $mode in
  all) testament --print --megatest:off all || rc=$? ;;
  files)
    for file do
      testament --print --megatest:off r "$file" || rc=1
    done ;;
  categories)
    pids=''
    for category do
      testament --print --megatest:off cat "$category" &
      pids="$pids $!"
    done
    for pid in $pids; do wait "$pid" || rc=1; done ;;
  *) echo "Unknown test selection mode: $mode" >&2; exit 2 ;;
esac
exit "$rc"
