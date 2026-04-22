# 3code — project state

Repo:    https://github.com/capocasa/3code
Binary:  ~/.nimble/bin/3code  (installed via `nimble install`)
Source:  ~250-line single-file agent at src/threecode.nim

## Shipped (v0.1.0)

- OpenAI-compat chat completions: `<url>/chat/completions`, `Authorization: Bearer <key>`
- Config at `~/.config/3code/config`, INI-style via std/parsecfg
- `[profile]` sections; `-p <name>` to switch, `[3code] profile = ...` sets default
- Exits 3 with an example config when unconfigured
- ASCII welcome shows profile + model
- Aider-style parser:
  - ```bash```  — shell
  - `path\n```...```` — full-file write
  - SEARCH/REPLACE markers inside a path-block — patch
- 10 parser/runner unit tests, green

## Workarounds

- parsecfg treats `:` as a key/value separator, so URL/key values must use
  Nim raw-string syntax: `url = r"https://..."`. Documented in README,
  config.example, and the in-binary `ConfigExample` constant.

## Not done yet

- No real API smoke test — nothing has actually called a model; verified only
  that the config gate, welcome screen, parser, and tests work.
- No streaming; no Ctrl-C interrupt mid-turn.
- Not submitted to nim-lang/packages. Internal package name is `threecode`,
  binary `3code` (namedBin mapping). Submit when ready.
- No CI workflow.
- Context grows unboundedly across a session — no compaction.
- Known parser hole: model emitting triple backticks inside a file breaks
  fence matching. Documented as a limitation.

## Files

    threecode.nimble      package manifest, namedBin maps threecode -> 3code
    src/threecode.nim     everything
    tests/test_parser.nim parser + runner tests
    config.nims           adds src/ to path so tests can import threecode
    config.example        commented example for ~/.config/3code/config
    README.md             usage + limitations
    .gitignore            /3code, tests/test_* (binaries), nimcache/

## Useful commands

    nimble build          build ./3code
    nimble test           run parser tests
    nimble install        install as ~/.nimble/bin/3code
    3code                 interactive
    3code "task..."       one-shot
    3code -p groq "..."   pick profile
