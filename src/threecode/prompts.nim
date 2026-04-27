import std/[json, sequtils, strutils]
import types

const Version* = staticRead("../../threecode.nimble").splitLines().filterIt(it.startsWith("version")).
    mapIt(it.split("=")[1].strip().strip(chars = {'"'}))[0]

const KnownGoodCombos*: array[7, (string, string, string)] = [
    ("cerebras",  "zai-glm-4.7",                                    "glm"),
    ("fireworks", "accounts/fireworks/models/glm-5p1",               "glm"),
    ("cerebras",  "qwen-3-235b-a22b-instruct-2507",                  "qwen"),
    ("deepinfra", "Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",       "qwen"),
    ("nvidia",    "qwen/qwen3-coder-480b-a35b-instruct",             "qwen"),
    ("nvidia",    "openai/gpt-oss-120b",                             "gpt-oss"),
    ("nvidia",    "openai/gpt-oss-20b",                              "gpt-oss"),
  ]
    ## (provider, variant, model) triples. Model drives the (prompt, tools)
    ## branch; it must be set explicitly here — no guessing from the variant
    ## string. Anything outside this list requires --experimental to run.

# ---------------------------------------------------------------------------
# Per-model (prompt, tools) pairs.
#
# Each model pairs the system prompt prose with the JSON tool schema sent on
# the wire. The tool surface is chosen to match what the model was trained on,
# not to fit a uniform shape — gpt-oss gets Codex's `shell` + `apply_patch`,
# qwen and glm keep our `bash`/`write`/`patch` triple (sessions show they're
# fluent with it). Adding a new model means adding a new tuple here.
# ---------------------------------------------------------------------------

const Preamble = """
You are 3code, the economical coding agent. One task, done right, few tokens.

{{credit}}

{{tools}}
The harness runs your tool calls and feeds results back. When done, reply with prose and no tool calls. Dry wit where earned; no forced cheer, no emoji, no "Great question!".

## Work rules

- Orient on a fresh repo: `ls`, README, build manifest. Skip for trivial tasks.
- Plan multi-step work in 3–8 steps; work them in order.
- Stay in scope. No unrequested refactors, reformatting, or comments.
- Match local style.
- Edit surgically: targeted edits for small changes, full rewrites for new files or large reshapes. Read before editing so context lines / search blocks are fresh. Rewriting the same file repeatedly is a smell — each full body rides in context every turn after.
- Trust your tools. `wrote N bytes` is truthful; don't `cat` back to verify.
- Search before reading: `rg`/`grep -rn` first, then `sed -n 'A,Bp' path` for a slice. Don't slurp.
- Quick jobs, quick scripts. For counts or data shape, a 5-line throwaway under `/tmp/` beats eyeballing. Default Nim or shell. Clean up.
- Local before web: deps, vendored source, CHANGELOGs, tests, examples, man pages.
- Verify before done: tests/build/typecheck, then `git diff`/`status`.
- Stop when done. If the task's already done on arrival, say so.
- Pause for irreversible ops outside cwd (`rm -rf` elsewhere, force-push, DB drops). Explain and wait.

## Finding things

- Files: `cat path` / `sed -n 'A,Bp' path` via shell. Tree: `rg`/`grep -rn`/`find`/`ls` via shell.
- Web: `3code web "query"` and `3code fetch <url>`. Prefer official docs.
"""

const GlmToolsProse = """Tools:
- `bash(command, stdin?)` — shell; returns stdout/stderr + exit code. Optional `stdin` is piped into the command.
- `write(path, body)` — create or overwrite a file.
- `patch(path, edits)` — targeted edits; `edits` is an array of `{search, replace}` objects; each `search` must match exactly once.

Read: `bash` with `cat path` (whole file) or `sed -n 'A,Bp' path` (slice).
Edit: `patch` for surgical changes (include enough context in `search` to be unambiguous); `write` for new files or full rewrites. Read immediately before patching so search blocks are fresh — the harness errors if the file changed since your last read.
"""

const QwenToolsProse = """Tools:
- `bash(command, stdin?)` — shell; returns stdout/stderr + exit code. Optional `stdin` is piped into the command.
- `write(path, body)` — create or overwrite a file.
- `patch(path, edits)` — targeted edits; `edits` is an array of `{search, replace}` objects; each `search` must match exactly once.

Read: default to `cat path`. Read the raw file with your eyes; don't try to extract the answer with `grep`/`cut`/`awk` pipelines — they're brittle on whitespace and quoting and they hide context. Only use `sed -n 'A,Bp' path` when the file is too large to cat. If a command returns empty or surprising output, NEVER guess the answer — re-run with `cat` and read it.
Edit: `patch` for surgical changes (include enough context in `search` to be unambiguous); `write` for new files or full rewrites under ~150 lines. Read immediately before patching so search blocks are fresh — the harness errors if the file changed since your last read.
"""

const GptOssToolsProse = """Tools:
- `shell({cmd: ["bash", "-lc", "..."]})` — execute a shell command. Returns stdout/stderr + exit code.
- `apply_patch({input: "*** Begin Patch\n...\n*** End Patch"})` — V4A diff. Inside, use `*** Update File: path` (existing files), `*** Add File: path` (new files), or `*** Delete File: path`. For updates, hunks start with `@@`; line prefixes are ` ` (context, kept), `-` (removed), `+` (added). Include 2–3 unchanged lines around each change so the hunk anchors uniquely.

Read: `shell` with `cat path` or `sed -n 'A,Bp' path`.
Edit: `apply_patch` for everything — updates, new files, deletes. Read the file immediately before patching so the context lines match exactly.
"""

let glmAndQwenTools = %*[
  {
    "type": "function",
    "function": {
      "name": "bash",
      "description": "Run a shell command; returns stdout, stderr, and exit code.",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {"type": "string", "description": "Shell command to run."},
          "stdin": {"type": "string", "description": "Optional text piped to the command's stdin."}
        },
        "required": ["command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "write",
      "description": "Create or overwrite a file with the given content.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "File path relative to cwd."},
          "body": {"type": "string", "description": "Full file content."}
        },
        "required": ["path", "body"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "patch",
      "description": "Apply targeted search-and-replace edits to an existing file.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "File path relative to cwd."},
          "edits": {
            "type": "array",
            "description": "List of edits; each search string must match exactly once.",
            "items": {
              "type": "object",
              "properties": {
                "search": {"type": "string", "description": "Exact text to find."},
                "replace": {"type": "string", "description": "Text to substitute."}
              },
              "required": ["search", "replace"]
            }
          }
        },
        "required": ["path", "edits"]
      }
    }
  }
]

let gptOssTools = %*[
  {
    "type": "function",
    "function": {
      "name": "shell",
      "description": "Run a shell command. Returns stdout, stderr, and exit code.",
      "parameters": {
        "type": "object",
        "properties": {
          "cmd": {
            "type": "array",
            "items": {"type": "string"},
            "description": "Argv array — typically [\"bash\", \"-lc\", \"<command line>\"]."
          }
        },
        "required": ["cmd"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "apply_patch",
      "description": "Apply a V4A diff (Codex format). Wrap operations in *** Begin Patch ... *** End Patch.",
      "parameters": {
        "type": "object",
        "properties": {
          "input": {
            "type": "string",
            "description": "V4A patch text starting with '*** Begin Patch' and ending with '*** End Patch'."
          }
        },
        "required": ["input"]
      }
    }
  }
]

let
  glmSetup = (prompt: Preamble.replace("{{tools}}", GlmToolsProse), tools: glmAndQwenTools)
  qwenSetup = (prompt: Preamble.replace("{{tools}}", QwenToolsProse), tools: glmAndQwenTools)
  gptOssSetup = (prompt: Preamble.replace("{{tools}}", GptOssToolsProse), tools: gptOssTools)

proc setup*(p: Profile): tuple[prompt: string, tools: JsonNode] =
  ## (prompt, tools) for the active model. Unknown model dies — every
  ## entry in `KnownGoodCombos` and every experimental override must
  ## name a model handled here.
  case p.model
  of "glm": glmSetup
  of "qwen": qwenSetup
  of "gpt-oss": gptOssSetup
  else: die "unknown model: '" & p.model & "' (no prompt/tools tuple)"

let DefaultSystemPrompt* = glmSetup.prompt.replace(
    "{{credit}}",
    "Credit where it's due — to whoever trained the weights driving you and the lab serving them.")
  ## Bytes for the placeholder system message in fresh sessions and unloaded
  ## session files. `refreshSystemPrompt` rewrites it on every turn so the
  ## resolved profile (model, lab, variant) takes over.

const ConfigExample* = """  [settings]
  current = "openai.gpt-4o-mini"

  [provider]
  name = "openai"
  url = "https://api.openai.com/v1"
  key = "sk-..."
  variants = "gpt-4o-mini gpt-4o"

(values are Nim string literals — always wrap them in double quotes.)
"""

const HelpText* = """
3code — the economical coding agent. bring your own third-party endpoint.

commands:
  :help             show this message
  :tokens           show token usage for this session
  :clear            reset conversation (keeps system prompt)
  :variant          list variants for current provider (current marked with *)
  :variant X        switch to variant X (within current provider)
  :provider         list configured providers (current marked with *)
  :provider X       switch to provider X (variant defaults to first in its list)
  :provider add     add a new provider (interactive, verified)
  :provider edit X  edit provider X (url, key, variants)
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
  tab           complete :commands, provider names, variant names
  ctrl+l        clear the screen
  @path         inline file contents (e.g. @src/foo.nim)

known good (glm):
  cerebras.zai-glm-4.7
  fireworks.glm-5p1
known good (qwen):
  cerebras.qwen-3-235b-a22b-instruct-2507
  nvidia.qwen/qwen3-coder-480b-a35b-instruct
known good (gpt-oss):
  nvidia.openai/gpt-oss-120b
  nvidia.openai/gpt-oss-20b

other combos require --experimental — they're your tokens to burn.
"""

proc knownGoodModel*(p: Profile): string =
  ## Returns the model label ("glm", ...) for a known-good combo, or ""
  ## if (provider, variant) isn't on the list. Match is case-insensitive on
  ## (provider, full variant id incl. prefix).
  if p.name == "": return ""
  let dot = p.name.find('.')
  if dot < 0: return ""
  let provider = p.name[0 ..< dot].toLowerAscii
  let variant = (p.variantPrefix & p.variant).toLowerAscii
  for combo in KnownGoodCombos:
    if combo[0].toLowerAscii == provider and
       combo[1].toLowerAscii == variant: return combo[2]
  ""

proc isKnownGood*(p: Profile): bool =
  ## True when (provider name, `variantPrefix & variant`) exactly matches
  ## an entry in `KnownGoodCombos` (case-insensitive on both parts).
  ## Empty profiles return false — caller decides what that means.
  knownGoodModel(p) != ""

proc knownGoodModel*(provider, variant: string): string =
  ## Convenience overload for the wizard, where we have a candidate
  ## (provider name, full variant id) but no Profile.
  let p = provider.toLowerAscii
  let v = variant.toLowerAscii
  for combo in KnownGoodCombos:
    if combo[0].toLowerAscii == p and combo[1].toLowerAscii == v:
      return combo[2]
  ""

proc displayModel(model: string): string =
  case model.toLowerAscii
  of "glm": "GLM"
  of "qwen": "Qwen"
  of "gpt-oss": "GPT-OSS"
  of "deepseek": "DeepSeek"
  of "kimi", "moonshot": "Kimi"
  of "llama": "Llama"
  of "mistral": "Mistral"
  of "gemma": "Gemma"
  else: model

proc buildCredit*(p: Profile): string =
  ## Dynamic attribution line: model + serving provider, derived from
  ## the active profile. Bytes change with (provider, model, variant),
  ## not within a session — prefix caching survives as long as the user
  ## doesn't `:provider`/`:model` switch mid-session.
  let dot = p.name.find('.')
  let provider = if dot < 0: p.name else: p.name[0 ..< dot]
  let variant = p.variantPrefix & p.variant
  let mdl = displayModel(p.model)
  if provider != "" and mdl != "":
    "Credit where it's due: you're a " & mdl & " model (" & variant &
      "), served via " & provider & "."
  elif provider != "" and variant != "":
    "Credit where it's due: you're " & variant & ", served via " & provider & "."
  else:
    "Credit where it's due — to whoever trained the weights driving you and the lab serving them."

proc buildSystemPrompt*(p: Profile): string =
  ## Bytes are stable within a (provider, model, variant) triple — that's
  ## what the prompt now embeds for credit. Within a session that's constant,
  ## so prefix caching on Anthropic/OpenAI/DeepInfra still applies; switching
  ## model or provider mid-session will invalidate the cache.
  setup(p).prompt.replace("{{credit}}", buildCredit(p))

proc refreshSystemPrompt*(messages: JsonNode, p: Profile) =
  if messages == nil or messages.kind != JArray or messages.len == 0: return
  let m = messages[0]
  if m.kind != JObject or m{"role"}.getStr != "system": return
  m["content"] = %buildSystemPrompt(p)
