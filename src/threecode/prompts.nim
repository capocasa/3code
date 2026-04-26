import std/[json, sequtils, strutils]
import types

const Version* = staticRead("../../threecode.nimble").splitLines().filterIt(it.startsWith("version")).
    mapIt(it.split("=")[1].strip().strip(chars = {'"'}))[0]

const KnownGoodCombos*: array[2, (string, string, string)] = [
    ("cerebras",  "glm-4.7", "glm"),
    ("fireworks", "accounts/fireworks/models/glm-5p1", "glm"),
    # non-glm combos are commented out while the per-family tool surface
    # is glm-only. Re-add once their family component is wired in.
    # ("deepinfra", "qwen3-coder-480b",                              "qwen"),
    # ("together",  "qwen3-coder-480b",                              "qwen"),
    # ("cerebras",  "qwen-3-235b-a22b-instruct-2507",                "qwen"),
    # ("ovh",       "Qwen3-Coder-30B-A3B-Instruct",                  "qwen"),
    # ("nvidia",    "qwen/qwen3-coder-480b-a35b-instruct",           "qwen"),
    # ("deepinfra", "Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",     "qwen"),
  ]
    ## Verified (provider, model, family) triples. Match is exact and
    ## case-insensitive on (provider, model). The model side is compared
    ## against `model_prefix & model` (the full API id). The family slot
    ## drives which tool component (system-prompt section + JSON schema)
    ## the harness sends. Anything outside this list is "experimental"
    ## and requires `--experimental` to run.

const SystemPromptBase* = """
You are 3code, the economical coding agent. One task, done right, few tokens.

$1
The harness runs your tool calls and feeds results back. When done, reply with prose and no tool calls. Dry wit where earned; no forced cheer, no emoji, no "Great question!".

## Work rules

- Orient on a fresh repo: `ls`, README, build manifest. Skip for trivial tasks.
- Plan multi-step work in 3–8 steps; work them in order.
- Stay in scope. No unrequested refactors, reformatting, or comments.
- Match local style.
- Edit surgically: `ed -s path` for line-range edits, `write` for new files or full rewrites. Read immediately before editing so addresses are fresh. Rewriting the same file repeatedly is a smell — each full body rides in context every turn after.
- Trust your tools. `wrote N bytes` is truthful; don't `cat` back to verify.
- Search before reading: `rg`/`grep -rn` first, then `sed -n 'A,Bp' path` for a slice. Don't slurp.
- Quick jobs, quick scripts. For counts or data shape, a 5-line throwaway under `/tmp/` beats eyeballing. Default Nim or shell. Clean up.
- Local before web: deps, vendored source, CHANGELOGs, tests, examples, man pages.
- Verify before done: tests/build/typecheck, then `git diff`/`status`.
- Stop when done. If the task's already done on arrival, say so.
- Pause for irreversible ops outside cwd (`rm -rf` elsewhere, force-push, DB drops). Explain and wait.

## Finding things

- Files: `cat path` / `sed -n 'A,Bp' path` via `bash`. Tree: `rg`/`grep -rn`/`find`/`ls` via `bash`.
- Web: `3code web "query"` and `3code fetch <url>`. Prefer official docs.
"""

const GlmTools* = """Tools:
- `bash(command, stdin?)` — shell; returns stdout/stderr + exit code. Optional `stdin` is piped into the command.
- `write(path, body)` — create or overwrite a file.

Read: `bash` with `cat path` (whole file) or `sed -n 'A,Bp' path` (slice).
Edit a line range: `bash` with `command = "ed -s path"` and `stdin = "A,Bc\nnew body\n.\nw\nq\n"` (POSIX line editor; `c` = change lines A through B, `.` on its own line ends the body, `w` writes, `q` quits). Re-read just before so addresses are fresh; the harness errors if the file changed since your last read. For multi-edit scripts in one call, author bottom-up so earlier edits don't shift later addresses. A body line that is literally `.` must be escaped (use `s/^\\.$/&./` after, or split into separate edits).
"""

let GlmToolsJson* = %*[
  {
    "type": "function",
    "function": {
      "name": "bash",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {"type": "string"},
          "stdin": {"type": "string"}
        },
        "required": ["command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "write",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string"},
          "body": {"type": "string"}
        },
        "required": ["path", "body"]
      }
    }
  }
]

const DefaultSystemPrompt* = SystemPromptBase % [GlmTools]
  ## Used as the bytes for the placeholder system message in fresh sessions
  ## and unloaded session files. `refreshSystemPrompt` rewrites it on every
  ## turn so the resolved family for the active profile takes over.

const ConfigExample* = """  [settings]
  current = "openai.gpt-4o-mini"

  [provider]
  name = "openai"
  url = "https://api.openai.com/v1"
  key = "sk-..."
  models = "gpt-4o-mini gpt-4o"

(values are Nim string literals — always wrap them in double quotes.)
"""

const HelpText* = """
3code — the economical coding agent. bring your own third-party endpoint.

commands:
  :help             show this message
  :tokens           show token usage for this session
  :clear            reset conversation (keeps system prompt)
  :model            list models for current provider (current marked with *)
  :model X          switch to model X (within current provider)
  :provider         list configured providers (current marked with *)
  :provider X       switch to provider X (model defaults to first in its list)
  :provider add     add a new provider (interactive, verified)
  :provider edit X  edit provider X (url, key, models)
  :provider rm X    remove provider X
  :prompt           show the active system prompt
  :show [N]         show full output of tool call N (default: last)
  :log              list all tool calls this session
  :sessions         list sessions saved in the current directory
  :sessions all     list every saved session (any directory)
  :compact          compact older tool output in context
  :summarize        collapse old turns into a synthetic recap (meta model call)
  :think [on|off]   toggle the reasoning-content ticker (on by default)
  :q :quit          exit (also Ctrl-D)

input:
  single-line   just type and press Enter
  multi-line    end a line with `\` to continue on the next line (use `\\` for a literal trailing backslash)
  up / down     recall history; down past last clears the line
  tab           complete :commands, provider names, model names
  ctrl+l        clear the screen
  @path         inline file contents (e.g. @src/foo.nim)

known good (glm family):
  cerebras.glm-4.7
  fireworks.accounts/fireworks/models/glm-5p1

other combos require --experimental — they're your tokens to burn.
"""

proc knownGoodFamily*(p: Profile): string =
  ## Returns the family label ("glm", ...) for a known-good combo, or ""
  ## if (provider, model) isn't on the list. Match is case-insensitive on
  ## (provider, full model id incl. prefix).
  if p.name == "": return ""
  let dot = p.name.find('.')
  if dot < 0: return ""
  let provider = p.name[0 ..< dot].toLowerAscii
  let modelId = (p.modelPrefix & p.model).toLowerAscii
  for combo in KnownGoodCombos:
    if combo[0].toLowerAscii == provider and
       combo[1].toLowerAscii == modelId: return combo[2]
  ""

proc isKnownGood*(p: Profile): bool =
  ## True when (provider name, `model_prefix & model`) exactly matches
  ## an entry in `KnownGoodCombos` (case-insensitive on both parts).
  ## Empty profiles return false — caller decides what that means.
  knownGoodFamily(p) != ""

proc knownGoodFamily*(provider, model: string): string =
  ## Convenience overload for the wizard, where we have a candidate
  ## (provider name, full model id) but no Profile.
  let p = provider.toLowerAscii
  let m = model.toLowerAscii
  for combo in KnownGoodCombos:
    if combo[0].toLowerAscii == p and combo[1].toLowerAscii == m:
      return combo[2]
  ""

proc familyTools*(family: string): string =
  ## Per-family tool component for the system prompt. Add other families
  ## here as their tool surface gets validated.
  case family
  of "glm", "": GlmTools
  else: GlmTools

proc familyToolsJson*(family: string): JsonNode =
  ## Per-family tool schema sent in the chat-completions request body.
  case family
  of "glm", "": GlmToolsJson
  else: GlmToolsJson

proc buildSystemPrompt*(p: Profile): string =
  ## Byte-stable within a given family. Provider/model identity deliberately
  ## does NOT land here: it would vary the prompt's bytes and kill prefix
  ## caching on Anthropic/OpenAI/DeepInfra where an identical prefix can
  ## shave 90% off prompt tokens on cache hit.
  SystemPromptBase % [familyTools(p.family)]

proc refreshSystemPrompt*(messages: JsonNode, p: Profile) =
  if messages == nil or messages.kind != JArray or messages.len == 0: return
  let m = messages[0]
  if m.kind != JObject or m{"role"}.getStr != "system": return
  m["content"] = %buildSystemPrompt(p)
