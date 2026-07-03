import std/unittest
import threecode/shell

suite "shell: bashMutationPath edge cases":
  test "does not flag git status":
    check bashMutationPath("git status") == ""

  test "does not flag git diff":
    check bashMutationPath("git diff") == ""

  test "does not flag git log":
    check bashMutationPath("git log --oneline -5") == ""

  test "git clean -fd is not flagged (git left alone)":
    check bashMutationPath("git clean -fd") == ""

  test "detects awk redirect":
    check bashMutationPath("awk '{print $1}' file.txt > out.txt") == "out.txt"

  test "does not flag echo alone":
    check bashMutationPath("echo hello") == ""

  test "detects first redirect in chained command":
    check bashMutationPath("echo a > first.txt > second.txt") == "first.txt"

  # install command is not tracked by bashMutationPath
  test "detects truncate via redirect":
    check bashMutationPath("> file.txt") == "file.txt"

suite "shell: bashReadPath edge cases":
  test "returns empty for echo":
    let (path, _) = bashReadPath("echo hello")
    check path == ""

  test "returns empty for cd":
    let (path, _) = bashReadPath("cd /tmp")
    check path == ""

  test "returns empty for compound with pipe":
    let (path, _) = bashReadPath("wc -l file.txt | grep 100")
    check path == ""

suite "shell: splitStatements edge cases":
  test "handles empty string":
    check splitStatements("").len == 1  # returns one empty element

  test "handles backslash in quotes":
    let r = splitStatements("echo \"a\\;b\"")
    check r.len == 1

suite "shell: shellTokens edge cases":
  test "handles unclosed quote gracefully":
    let toks = shellTokens("echo 'unclosed")
    check toks.len == 2

  test "handles only whitespace":
    check shellTokens("   ").len == 0

  test "handles escaped space":
    check shellTokens("echo hello\\ world") == @["echo", "hello world"]
