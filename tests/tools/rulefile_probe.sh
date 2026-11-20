#!/bin/sh
# Rule-file slot enforcement probe: drives `3code sandbox` directly over
# every slot shape the policy cascade can load and asserts each write
# is denied while reads and ordinary writes keep working. Needs a host
# that allows unprivileged user namespaces and mount_setattr; a host
# that strips either prints the driver's degrade notice and this exits
# 77 (skip), never 0: a recorded pass always means enforcement ran.
#
# Usage: tests/tools/rulefile_probe.sh [3code-binary]   (default ./3code)
set -u
B=${1:-./3code}
[ -x "$B" ] || { echo "no binary at $B (run build_binary.sh first)" >&2; exit 2; }

R=${TMPDIR:-/tmp}/3code-rulefile-probe.$$
mkdir -p "$R/proj/.3code" || exit 2
cleanup() { rm -rf "$R"; }
trap cleanup EXIT INT TERM

fails=0
skipped=0

# expect_denied LABEL CMD...: runs CMD fenced under `pol`; a degrade
# notice means the host cannot enforce (skip), success of the write or
# a surviving file means failure.
run_fenced() {
  # $1 = policy file, rest = command for sh -c
  pol=$1; shift
  "$B" sandbox --policy "$pol" restrict -- sh -c "$*" 2>&1
}

notice() {
  case "$1" in
    *"read-only rule-file enforcement"*|*"read-only bind for"*) return 0;;
  esac
  return 1
}

expect_denied() {
  label=$1; pol=$2; target=$3; cmd=$4
  out=$(run_fenced "$pol" "$cmd"); rc=$?
  if notice "$out"; then
    echo "SKIP  $label (host cannot enforce: $out)"; skipped=1; return
  fi
  if [ "$rc" -eq 0 ]; then
    echo "FAIL  $label: fenced command succeeded (rc=0)"; fails=$((fails+1)); return
  fi
  echo "PASS  $label: denied (rc=$rc)"
}

main() {
  pol=$R/proj/.sandbox
  printf 'allow %s\n' "$R/proj" > "$pol"

  echo "probe: binary=$B pid=$$ date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "kernel=$(uname -r)"

  expect_denied "edit active legacy .sandbox" "$pol" "$pol" \
    "echo pwn > $pol"
  [ "$(cat "$pol")" = "allow $R/proj" ] ||
    { echo "FAIL  active policy content changed"; fails=$((fails+1)); }

  expect_denied "create .3code/sandbox slot" "$pol" "$R/proj/.3code/sandbox" \
    "echo pwn > $R/proj/.3code/sandbox"
  [ -e "$R/proj/.3code/sandbox" ] &&
    { echo "FAIL  store slot was created"; fails=$((fails+1)); }

  expect_denied "create other file in store dir" "$pol" "$R/proj/.3code/x" \
    "touch $R/proj/.3code/x"

  mkdir -p "$R/anc/.3code"
  expect_denied "create ancestor store slot" "$pol" "$R/anc/.3code/sandbox" \
    "echo pwn > $R/anc/.3code/sandbox"

  printf 'allow %s\n' "$R/proj" > "$R/anc/.3code/sandbox"
  printf 'allow %s\n' "$R/proj" > "$R/anc/.sandbox"
  expect_denied "edit ancestor store slot" "$pol" "$R/anc/.3code/sandbox" \
    "echo pwn > $R/anc/.3code/sandbox"
  expect_denied "edit ancestor legacy slot" "$pol" "$R/anc/.sandbox" \
    "echo pwn > $R/anc/.sandbox"

  mv "$pol" "$R/save_legacy"
  printf 'allow %s\n' "$R/proj" > "$R/proj/.3code/sandbox"
  storepol=$R/proj/.3code/sandbox
  expect_denied "edit active .3code/sandbox" "$storepol" "$storepol" \
    "echo pwn > $storepol"
  expect_denied "rename/unlink active policy away" "$storepol" "$storepol" \
    "mv $storepol $R/proj/escaped"

  # Control: the fence must still read its policy and write the project.
  out=$(run_fenced "$storepol" "cat $storepol"); rc=$?
  if [ $rc -ne 0 ] || [ "$out" != "allow $R/proj" ]; then
    echo "FAIL  fenced policy read: rc=$rc out=[$out]"; fails=$((fails+1))
  else
    echo "PASS  fenced policy read kept"
  fi
  out=$(run_fenced "$storepol" "echo ok > $R/proj/w.txt && cat $R/proj/w.txt"); rc=$?
  if [ $rc -ne 0 ] || [ "$out" != "ok" ]; then
    echo "FAIL  ordinary project write: rc=$rc out=[$out]"; fails=$((fails+1))
  else
    echo "PASS  ordinary project write kept"
  fi
  out=$(run_fenced "$storepol" "id -u"); rc=$?
  if [ $rc -ne 0 ] || [ "$out" != "$(id -u)" ]; then
    echo "FAIL  honest uid inside fence: rc=$rc out=[$out]"; fails=$((fails+1))
  else
    echo "PASS  uid mapping honest inside fence"
  fi

  if [ $fails -gt 0 ]; then echo "RESULT: FAIL ($fails)"; exit 1; fi
  if [ $skipped -gt 0 ]; then echo "RESULT: SKIP (host cannot enforce)"; exit 77; fi
  echo "RESULT: PASS (enforcement verified)"
  exit 0
}

main
