import std/[strutils, unittest]
import threecode/shell

suite "shell: shellTokens":
  test "splits on whitespace":
    check shellTokens("ls -la /tmp") == @["ls", "-la", "/tmp"]

  test "honors double quotes":
    check shellTokens("echo \"hello world\"") == @["echo", "hello world"]

  test "honors single quotes":
    check shellTokens("echo 'hello world'") == @["echo", "hello world"]

  test "backslash-escapes next character":
    check shellTokens("echo hello\\ world") == @["echo", "hello world"]

  test "handles empty string":
    check shellTokens("").len == 0

  test "handles multiple spaces between tokens":
    check shellTokens("a   b") == @["a", "b"]

suite "shell: splitStatements":
  test "splits on semicolons":
    let r = splitStatements("echo a; echo b")
    check r.len == 2
    check r[0].strip == "echo a"
    check r[1].strip == "echo b"

  test "splits on &&":
    let r = splitStatements("make && make test")
    check r.len == 2

  test "splits on ||":
    let r = splitStatements("true || false")
    check r.len == 2

  test "splits on pipe":
    let r = splitStatements("cat file | grep pattern")
    check r.len == 2

  test "does not split inside double quotes":
    let r = splitStatements("echo \"a;b\"")
    check r.len == 1

  test "does not split inside single quotes":
    let r = splitStatements("echo 'a&&b'")
    check r.len == 1

  test "returns one element for no separators":
    let r = splitStatements("echo hello")
    check r.len == 1

suite "shell: bashMutationPath":
  test "detects output redirect":
    check bashMutationPath("echo hi > /tmp/out.txt") == "/tmp/out.txt"

  test "detects append redirect":
    check bashMutationPath("echo hi >> /tmp/out.txt") == "/tmp/out.txt"

  test "detects sed -i":
    check bashMutationPath("sed -i 's/old/new/g' src/file.nim") == "src/file.nim"

  test "detects tee":
    check bashMutationPath("echo hi | tee /tmp/out.txt") == "/tmp/out.txt"

  test "detects cp destination":
    check bashMutationPath("cp a.txt b.txt") == "b.txt"

  test "detects mv destination":
    check bashMutationPath("mv a.txt b.txt") == "b.txt"

  test "detects rm":
    check bashMutationPath("rm /tmp/junk.txt") == "/tmp/junk.txt"

  test "git stash is not flagged":
    check bashMutationPath("git stash") == ""

  test "git stash push is not flagged":
    check bashMutationPath("git stash push") == ""

  test "detects git reset --hard (returns dot)":
    check bashMutationPath("git reset --hard HEAD") == "."

  test "returns empty for read-only commands":
    check bashMutationPath("ls -la") == ""
    check bashMutationPath("cat file.txt") == ""
    check bashMutationPath("git log --oneline") == ""

  test "detects perl -i":
    check bashMutationPath("perl -i -pe 's/old/new/g' file.txt") == "file.txt"

  test "detects git checkout path":
    check bashMutationPath("git checkout src/foo.nim") == "src/foo.nim"

  test "detects touch":
    check bashMutationPath("touch /tmp/newfile") == "/tmp/newfile"

  test "returns empty for compound pipeline where only reads happen":
    check bashMutationPath("cat a.txt | grep x | wc -l") == ""

suite "shell: bashReadPath":
  test "recognizes simple cat":
    let (path, full) = bashReadPath("cat src/main.nim")
    check path == "src/main.nim"
    check full == true

  test "recognizes sed -n":
    let (path, full) = bashReadPath("sed -n '10,20p' file.txt")
    check path == "file.txt"
    check full == false

  test "recognizes head":
    let (path, full) = bashReadPath("head -5 file.txt")
    check path == "file.txt"
    check full == false

  test "recognizes tail":
    let (path, full) = bashReadPath("tail -20 file.txt")
    check path == "file.txt"
    check full == false

  test "returns empty for compound commands":
    let (path, _) = bashReadPath("cat a.txt; echo done")
    check path == ""

  test "returns empty for piped commands":
    let (path, _) = bashReadPath("cat file.txt | grep x")
    check path == ""

  test "returns empty for redirected commands":
    let (path, _) = bashReadPath("cat file.txt > out.txt")
    check path == ""

suite "shell: bashIsRecovery":
  test "detects git checkout path as recovery":
    check bashIsRecovery("git checkout -- src/foo.nim") != ""

  test "does not flag branch checkout":
    check bashIsRecovery("git checkout main") == ""

  test "git stash is not recovery":
    check bashIsRecovery("git stash") == ""

  test "returns empty for normal commands":
    check bashIsRecovery("ls -la") == ""
    check bashIsRecovery("make test") == ""
