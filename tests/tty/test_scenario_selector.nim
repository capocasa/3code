discard """
  action: run
  disabled: "win"
"""
import std/[unittest, osproc, strutils]

suite "scenario selector CLI":
  test "lists stable exact names and rejects typos before compilation":
    let listed = execCmdEx("sh tools/tty_scenarios.sh --list")
    check listed.exitCode == 0
    check "simple one-turn prompt and reply" in listed.output
    let invalid = execCmdEx("sh tools/tty_scenarios.sh 'not a scenario'")
    check invalid.exitCode == 2
    check "Unknown scenario:" in invalid.output
    check "CC:" notin invalid.output
