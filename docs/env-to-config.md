# Environment variables → config file: the audit record

3code reads **no environment variables of its own** — every knob the
binary, its installers, and its test tooling used to take from the
environment is a config-file key or a CLI argument now. This page
records the audit (the greps and their output as of this change) and
maps every removed variable to its replacement.

## The recorded grep

Scope: everything except `CHANGELOG.md` (history names the removed
variables by design — every entry predating this change does too).

```
$ grep -rnE '(getEnv|existsEnv|putEnv|delEnv)\("(THREECODE_|WALL_)' \
    --include='*.nim' --include='*.sh' --include='*.ps1' --include='*.yml' \
    --include='*.nims' --include='*.nimble' src/ tests/ docs/ install/ .github/ \
    README.md config.nims threecode.nimble
(no matches — zero env reads and zero env writes of 3code's own variables)

$ grep -rn 'THREECODE_\|WALL_PROXY' \
    --include='*.nim' --include='*.sh' --include='*.ps1' --include='*.yml' \
    --include='*.nims' --include='*.nimble' --include='*.example' \
    src/ tests/ docs/ install/ .github/ README.md config.nims threecode.nimble
(no matches — not even the names survive outside the changelog history)

$ # full inventory of remaining env-API use in src/ and the included
$ # test stub — every name is OS-standard or a foreign tool's own knob:
$ grep -rhoE '(getEnv|existsEnv|putEnv|delEnv)\("[^"]+"' --include='*.nim' src/ tests/testdata/ \
    | sed -E 's/.*\("//' | sort -u
APPDATA DISPLAY DYLD_LIBRARY_PATH EDITOR GIT_SSH_COMMAND HOME LOCALAPPDATA
LOGNAME PATH PREFIX PATHEXT PROGRAMFILES PROGRAMFILES(X86) ProgramData
ProgramFiles SystemRoot TERM TEMP TMP TMPDIR TC_FIXTURE_LOG TC_FIXTURE_MODE
USER USERPROFILE VISUAL WAYLAND_DISPLAY windir XDG_CONFIG_HOME XDG_DATA_HOME
```

## What was replaced

Served by `src/threecode/runtime.nim` (a lock-guarded store that
`parseConfigFile` fills; `writeConfigFile` round-trips the keys):

| Old variable | New home |
| --- | --- |
| `THREECODE_ALLOW_ROOT` | `[settings] allow_root = on` |
| `THREECODE_DEBUG_LOG` | `[settings] debug_log = <path>` |
| `THREECODE_TRACE_FILE` | `[settings] trace_file = <path>` |
| `THREECODE_TERMDBG` | `[settings] termdbg = <path>` |
| `THREECODE_FORCE_SYNC_OUTPUT` | `[settings] force_sync_output = on` |
| `THREECODE_ASK_TIMEOUT_MS` | `[settings] ask_timeout_ms = <ms>` |
| `GOOGLE_CLOUD_PROJECT` | `[settings] google_project = <id>` |
| `THREECODE_PLUGIN_SYNC_MS` | `[plugins] sync_ms = <ms>` |
| `THREECODE_PLUGIN_TOOL_MS` | `[plugins] tool_ms = <ms>` |
| `THREECODE_STUB_RESPONSES` | `[test] stub_responses = <path>` |
| `THREECODE_HTTP_STUB_RESPONSES` | `[test] http_stub_responses = <path>` |
| `THREECODE_STUB_SANDBOX` | `[test] stub_sandbox = on` |
| `THREECODE_STUB_VERIFY_DELAY_MS` | `[test] stub_verify_delay_ms = <ms>` |
| `THREECODE_SCREENSHOT_SRC` | `[test] screenshot_src = <path>` |
| `THREECODE_GEOMETRY_AUDIT` | `[test] geometry_audit = <path>` |
| `THREECODE_TEST_GUI_LIVE` | `[test] gui_live = on` |
| `THREECODE_TEST_FRAME_FD` / `_ACK_FD` | `[test] frame_fd` / `frame_ack_fd` |
| `THREECODE_TEST_TICKER_FD` / `_ACK_FD` | `[test] ticker_fd` / `ticker_ack_fd` |
| `THREECODE_TEST_API_CONTINUE_FD` | `[test] api_continue_fd` |
| `WALL_PROXY_PORT` / `WALL_PROXY_SOCK` | internal `[wall]` file, handed to the `sandbox restrict` / `wall connect` children as `--config FILE` (in-process store on Windows) |
| `EXA_API_KEY` / `BRAVE_API_KEY` fallback | removed — `[search] exa-key` / `brave-key` only |
| `$VAR` expansion of config values | removed — values are verbatim |
| `THREECODE_TTY_ONLY` (scenario filter) | CLI argument to the tty-functional binary |
| `THREECODE_REGEN_GOLDEN` | `--regen-golden` argument |
| `THREECODE_BUILD_LOCK_TIMEOUT` | `build_binary.sh --lock-timeout=<s>` |
| `THREECODE_TEST_NIMFLAGS` | `build/test-nimflags` file (CI writes it) |
| `THREECODE_TEST_STUB_BINARY` | `build/prebuilt-stub` file (CI writes it) |
| `THREECODE_INSTALL_DIR` | `sh install --dir=<dir>` / `install.ps1 -InstallDir` |
| `THREECODE_ALLOW_ROOT` (installer) | `sh install --allow-root` (passes through `curl … \| sh -s --`) |
| `THREECODE_RELEASE_BASE` | `sh install --release-base=<url>` / `install.ps1 -ReleaseBase` |
| `THREECODE_ALLOW_UNVERIFIED` | `sh install --allow-unverified` / `install.ps1 -AllowUnverified` |
| `THREECODE_STUB_STREAM`, `THREECODE_WALKUP_LOG` (dead) | deleted |
| `tests/testdata/stub/stub/` (stale duplicates) | deleted |

No env fallback, no migration path: a key absent from the config file
is unset.

## What is deliberately still the environment

Only OS-standard variables, consumed — never configured — by 3code:

- `XDG_CONFIG_HOME` / `XDG_DATA_HOME`: locating the config/data roots
  before a config file can be read (discovery, not a knob).
- `PATH`, `HOME`, `TMPDIR`, `TERM`, `DISPLAY`/`WAYLAND_DISPLAY`,
  `EDITOR`/`VISUAL`, the Windows profile variables: process plumbing
  every program consumes.
- `http_proxy`/`https_proxy`/`ALL_PROXY`/`GIT_SSH_COMMAND`: exported
  *for the sandboxed grandchildren* (curl, git, ssh) — read by those
  tools, not by 3code.
