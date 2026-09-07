#!/bin/sh
# Functions shared with runner ownership regressions. No process-name kills.
etime_secs() {
  printf '%s\n' "$1" | awk -F '[-:]' '{
    n = NF; s = $n + 0
    if (n > 1) s += $(n-1) * 60
    if (n > 2) s += $(n-2) * 3600
    if (n > 3) s += $(n-3) * 86400
    print s
  }'
}

descendants() (
  for child in $(pgrep -P "$1" 2>/dev/null); do
    descendants "$child"
    printf '%s\n' "$child"
  done
)

kill_tree() {
  # Snapshot before killing parents so children cannot escape by reparenting.
  owned=$(descendants "$1")
  for pid in $owned "$1"; do kill -KILL "$pid" 2>/dev/null || :; done
}
