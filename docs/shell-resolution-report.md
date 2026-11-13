# Shell resolution for the bash tool: investigation and change

## Part 1: how bad is /bin/sh for the model?

**Severe — a language-contract violation, not a tuning issue.**

The tool is named `bash` and every family prompt teaches bash semantics
(`src/threecode/prompts.nim`, tools sections), so models emit bash-only
constructs constantly: `PIPESTATUS`, `[[ ]]`, here-strings (`<<<`),
process substitution (`<(...)`), `local -a`, `mapfile`, `&>`.

Under `/bin/sh` — dash on Debian/Ubuntu, ash/busybox on Alpine — those
constructs fail in ways that actively mislead:

| Construct | dash's answer | What the model does |
|---|---|---|
| `${PIPESTATUS[0]}` | `Bad substitution` (syntax error, whole script dies) | Rewrites working code, suspects the pipeline |
| `[[ -f x ]]` | `[[ not found` (tries to exec it) | Concludes the file check "is broken" |
| `<<< heredoc` | `Syntax error` | Abandons the approach entirely |
| `local -a arr` | OK-ish, but `arr+=()` fails | Silent mid-script failure |

The failure mode is worse than an error: the model receives a
confusing failure for code it has every reason (per its own prompt) to
believe is valid, so it burns turns retrying, "fixing" correct code, or
misdiagnosing the environment as broken. That is flail-detector
territory and corrupted-workaround territory. The repo's own comment on
`shPath()` cites community thread 15 as the real-world incident that
triggered the bash-first fix (commit `b0225cdb`, merged as `f2e63f49`).

External corroboration: OpenAI Codex hit the same class of problem and
converged on the same answer — bash with path fallbacks
(openai/codex PR #26538 adds `/usr/bin/bash` to the fallback list), and
issue #3916 (users wanting their login shell's environment) was solved
with an environment snapshot, not by running the login shell itself.

## Part 2: the change

`shPath()` (`src/threecode/streamexec.nim`) now resolves, in order:

1. `bash_path` / `bash` config override (unchanged; wins on every OS)
2. **`$SHELL`** — the shell 3code was started in — when it names a
   *working POSIX shell*:
   - probed with a real `echo` one-liner (`shellUsable`), so a dead
     binary (removed brew formula, `chsh` without install) falls
     through instead of breaking every command;
   - non-POSIX login shells (fish, nushell, elvish, xonsh, csh/tcsh,
     powershell) are skipped (`posixShellFamily`): they parse a
     different language than the prompts teach, so honoring them would
     break the contract *worse* than sh did.
3. **bash** — PATH, then `/bin/bash`, `/usr/bin/bash`,
   `/usr/local/bin/bash`, `/opt/homebrew/bin/bash`
4. **zsh** — PATH, then the standard locations
5. sh — last resort (Termux `$PREFIX/bin/sh`, Alpine busybox), unchanged

Resolution is memoized per thread (`cachedPosixShell`); the sandboxed
box child execs the same resolved shell, so fenced and unfenced runs
stay byte-identical.

### Why the POSIX guard (and not "any login shell")

The tool's contract is POSIX/bash syntax. fish and nushell are not even
POSIX-compatible; running the tool through them would reproduce the
original bug in a worse form. The guard keeps the user's shell when it
speaks the language the prompts teach, and falls back otherwise.

## Verification

- New suite `streamexec: posix shell resolution` (4 tests): `$SHELL`
  honored; non-POSIX skipped → bash; dead `$SHELL` → bash; end-to-end
  exec through the resolved shell. All pass.
- End-to-end probes (compiled against the real `streamexec`):
  `SHELL=/bin/bash` → tool runs bash 5.3.20 (`BASH_VERSION` set,
  `ZSH_VERSION` empty); `SHELL=/usr/bin/fish` and a dead path → bash;
  a fake zsh on `$SHELL` is picked and executes; the sandboxed leg runs
  the same shell with `PIPESTATUS` intact.
- Full file: `testament r tests/stream/test_streamexec.nim` →
  **PASS, 53 OK / 0 FAILED / 1 SKIPPED** (the parity test
  probe-and-skips on hosts without unprivileged user namespaces —
  this container — where the Linux bind-mask leg degrades with a notice
  that would break byte-equality for reasons unrelated to the
  interpreter; the skip guard now probes exactly that shape, matching
  the suite's documented posture for hosts where a leg cannot engage).
- The parity failure was confirmed pre-existing: identical failure on
  a pristine HEAD worktree (`2a3fdff4`) with the binary built there.
- No regressions elsewhere: shell category 4/4; config category's one
  failure (dirsettings policy slot) reproduces identically on stashed
  HEAD — ambient config-dir state on this box, unrelated.

## Files changed

- `src/threecode/streamexec.nim` — the resolution order, probe, guard
- `tests/stream/test_streamexec.nim` — resolution suite + parity skip guard
- `src/threecode/config.nim`, `docs/config.example` — stale doc comments
- `CHANGELOG.md` — entry
