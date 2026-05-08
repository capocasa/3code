# Impl 3: shell.nim pure-function tests

**New file:** `tests/test_shell.nim`
**Module:** `threecode/shell`
**Procs covered:** shellTokens, splitStatements, bashMutationPath, bashReadPath, bashIsRecovery — all 5 exported procs.

## Approach

All 5 procs are pure string-processing functions — no filesystem, no network, no state. Feed crafted strings and assert on outputs. Each proc handles quoting/escaping differently, so test edge cases around single quotes, double quotes, backslash escapes, and pipeline splitting.

## Imports

```nim
import std/[unittest]
import threecode/shell
```

## Test cases

### Suite: "shell: shellTokens"

1. **"splits on whitespace"**
   ```nim
   check shellTokens("ls -la /tmp") == @["ls", "-la", "/tmp"]
   ```

2. **"honors double quotes"**
   ```nim
   check shellTokens("echo \"hello world\"") == @["echo", "hello world"]
   ```

3. **"honors single quotes"**
   ```nim
   check shellTokens("echo 'hello world'") == @["echo", "hello world"]
   ```

4. **"backslash-escapes next character"**
   ```nim
   check shellTokens("echo hello\\ world") == @["echo", "hello world"]
   ```

5. **"handles empty string"**
   ```nim
   check shellTokens("").len == 0
   ```

6. **"handles multiple spaces between tokens"**
   ```nim
   check shellTokens("a   b") == @["a", "b"]
   ```

### Suite: "shell: splitStatements"

7. **"splits on semicolons"**
   ```nim
   let r = splitStatements("echo a; echo b")
   check r.len == 2
   check r[0].strip == "echo a"
   check r[1].strip == "echo b"
   ```

8. **"splits on &&"**
   ```nim
   let r = splitStatements("make && make test")
   check r.len == 2
   ```

9. **"splits on ||"**
   ```nim
   let r = splitStatements("true || false")
   check r.len == 2
   ```

10. **"splits on pipe"**
    ```nim
    let r = splitStatements("cat file | grep pattern")
    check r.len == 2
    ```

11. **"does not split inside double quotes"**
    ```nim
    let r = splitStatements("echo \"a;b\"")
    check r.len == 1
    ```

12. **"does not split inside single quotes"**
    ```nim
    let r = splitStatements("echo 'a&&b'")
    check r.len == 1
    ```

13. **"returns one element for no separators"**
    ```nim
    let r = splitStatements("echo hello")
    check r.len == 1
    ```

### Suite: "shell: bashMutationPath"

14. **"detects output redirect"**
    ```nim
    check bashMutationPath("echo hi > /tmp/out.txt") == "/tmp/out.txt"
    ```

15. **"detects append redirect"**
    ```nim
    check bashMutationPath("echo hi >> /tmp/out.txt") == "/tmp/out.txt"
    ```

16. **"detects sed -i"**
    ```nim
    check bashMutationPath("sed -i 's/old/new/g' src/file.nim") == "src/file.nim"
    ```

17. **"detects tee"**
    ```nim
    check bashMutationPath("echo hi | tee /tmp/out.txt") == "/tmp/out.txt"
    ```

18. **"detects cp destination"**
    ```nim
    check bashMutationPath("cp a.txt b.txt") == "b.txt"
    ```

19. **"detects mv destination"**
    ```nim
    check bashMutationPath("mv a.txt b.txt") == "b.txt"
    ```

20. **"detects rm"**
    ```nim
    check bashMutationPath("rm /tmp/junk.txt") == "/tmp/junk.txt"
    ```

21. **"detects git stash (returns dot)"**
    ```nim
    check bashMutationPath("git stash") == "."
    ```

22. **"detects git stash push (returns dot)"**
    ```nim
    check bashMutationPath("git stash push") == "."
    ```

23. **"detects git reset --hard (returns dot)"**
    ```nim
    check bashMutationPath("git reset --hard HEAD") == "."
    ```

24. **"returns empty for read-only commands"**
    ```nim
    check bashMutationPath("ls -la") == ""
    check bashMutationPath("cat file.txt") == ""
    check bashMutationPath("git log --oneline") == ""
    ```

25. **"detects perl -i"**
    ```nim
    check bashMutationPath("perl -pi -e 's/old/new/g' file.txt") == "file.txt"
    ```

26. **"detects git checkout path"**
    ```nim
    check bashMutationPath("git checkout src/foo.nim") == "src/foo.nim"
    ```

27. **"detects touch"**
    ```nim
    check bashMutationPath("touch /tmp/newfile") == "/tmp/newfile"
    ```

28. **"returns empty for compound pipeline where only reads happen"**
    ```nim
    check bashMutationPath("cat a.txt | grep x | wc -l") == ""
    ```

### Suite: "shell: bashReadPath"

29. **"recognizes simple cat"**
    ```nim
    let (path, full) = bashReadPath("cat src/main.nim")
    check path == "src/main.nim"
    check full == true
    ```

30. **"recognizes sed -n"**
    ```nim
    let (path, full) = bashReadPath("sed -n '10,20p' file.txt")
    check path == "file.txt"
    check full == false
    ```

31. **"recognizes head"**
    ```nim
    let (path, full) = bashReadPath("head -5 file.txt")
    check path == "file.txt"
    check full == false
    ```

32. **"recognizes tail"**
    ```nim
    let (path, full) = bashReadPath("tail -20 file.txt")
    check path == "file.txt"
    check full == false
    ```

33. **"returns empty for compound commands"**
    ```nim
    let (path, _) = bashReadPath("cat a.txt; echo done")
    check path == ""
    ```

34. **"returns empty for piped commands"**
    ```nim
    let (path, _) = bashReadPath("cat file.txt | grep x")
    check path == ""
    ```

35. **"returns empty for redirected commands"**
    ```nim
    let (path, _) = bashReadPath("cat file.txt > out.txt")
    check path == ""
    ```

### Suite: "shell: bashIsRecovery"

Read the full source (lines 217–263) to understand what patterns trigger recovery detection. The proc returns the offending sub-command string when detected, `""` otherwise.

36. **"detects git checkout path as recovery"**
    ```nim
    check bashIsRecovery("git checkout -- src/foo.nim") != ""
    ```

37. **"does not flag branch checkout"**
    ```nim
    check bashIsRecovery("git checkout main") == ""
    ```

38. **"detects git stash as recovery"**
    ```nim
    check bashIsRecovery("git stash") != ""
    ```

39. **"returns empty for normal commands"**
    ```nim
    check bashIsRecovery("ls -la") == ""
    check bashIsRecovery("make test") == ""
    ```

## Notes

- Read the full source of `bashMutationPath` carefully — it handles many edge cases like `>file` (no space), `>>file`, `2>` (skip), `ed`/`ex` line editors, `git restore`, `git clean` patterns.
- `bashIsRecovery` distinguishes path-based `git checkout` (recovery) from branch-based `git checkout main` (not recovery). The exact heuristic should be read from source before writing tests.
- `bashReadPath` only returns a path for *simple, single-statement* read commands — compound, piped, or redirected commands return `("", false)`.
