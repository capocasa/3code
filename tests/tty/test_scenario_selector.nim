discard """
  action: run
  disabled: "win"
"""
import std/[unittest, osproc, strutils]

suite "scenario selector CLI":
  test "lists stable exact names and rejects typos before compilation":
    let listed = execCmdEx("sh tests/tools/tty_scenarios.sh --list")
    check listed.exitCode == 0
    check "simple one-turn prompt and reply" in listed.output
    check "main visual test" notin listed.output
    let disabled = execCmdEx("sh tests/tools/tty_scenarios.sh 'main visual test'")
    check disabled.exitCode == 2
    let invalid = execCmdEx("sh tests/tools/tty_scenarios.sh 'not a scenario'")
    check invalid.exitCode == 2
    check "Unknown scenario:" in invalid.output
    check "CC:" notin invalid.output
