## Shared types and process-level globals.
##
## All types that cross module boundaries live here to avoid import cycles.
## `experimentalEnabled` is a global because every module that validates a
## profile needs it, and threading it through every call site is noise.

import std/[tables, times]

var experimentalEnabled*: bool = false
  ## Set by `-x`/`--experimental`.
var debugEnabled*: bool = false
  ## Set by `-D`/`--debug`.

const
  ExitUsage* = 2
  ExitConfig* = 3
  ExitApi* = 5

type
  PlanItem* = object
    ## One item in a model-emitted `update_plan` / `todo` list.
    text*: string
    status*: string
  ActionKind* = enum akBash, akRead, akWrite, akPatch, akApplyPatch, akPlan, akWebSearch, akWebFetch, akClear, akError
  Action* = object
    ## The parsed, tool-agnostic representation of a single model tool call.
    ## `runAction` in actions.nim consumes this and produces the tool result.
    kind*: ActionKind
    path*: string
    body*: string
    stdin*: string  ## bash-only: piped to the command's stdin
    edits*: seq[(string, string)]
    plan*: seq[PlanItem]
    offset*: int
    limit*: int
  Profile* = object
    ## `model` is the full wire value sent in the API `model` field
    ## (e.g. "openai/gpt-oss-120b"). Display code shortens it with
    ## `shortModel(model)` (everything after the last `/`). `family`
    ## ("glm" / "qwen" / "gpt-oss") drives (prompt, tools) tuple
    ## selection. `version` and `variant` (e.g. "3", "480b") are
    ## informational tags from KnownGoodCombos. In experimental mode
    ## `family` may also come from the per-provider config override.
    name*, url*, key*, model*: string
    family*, version*, variant*: string
    reasoning*: string  ## reasoning/thinking effort level: "low", "medium",
                        ## "high", or "" when the model has no such knob.
                        ## Mapped to a wire field in `callModel` per family
                        ## (gpt-oss: `reasoning_effort`; glm: `thinking.type`).
  Usage* = object
    promptTokens*, completionTokens*, totalTokens*, cachedTokens*: int
  ToolRecord* = object
    banner*: string
    output*: string
    code*: int
    kind*: ActionKind
  LoopTracker* = object
    ## Sliding-window per-path saturation detector. Only mutations
    ## (write, patch, sed -i, redirects, etc.) and web calls are tracked —
    ## reads are observation and excluded. Reset at the start of each user
    ## turn via `resetLoopTracker`.
    ring*: seq[tuple[fp: string, mut: bool]]  # last K (path, isMutation)
    mutCounts*: CountTable[string]  # writes+patches+sed+web only per path
    strike*: int             # 0/1/2
    trippedPaths*: seq[string] # paths that have already tripped this strike
    recoveryCmd*: string     # set when Strike 2 fires from a git-recovery hard-trip; "" otherwise
    turnCalls*: int          # total tool calls this turn (for budget cap)
  ReadCache* = ref object
    state*: Table[string, (Time, int)]
  Session* = object
    usage*: Usage
    lastPromptTokens*: int
    toolLog*: seq[ToolRecord]
    savePath*: string
    profileName*: string
    created*: string
    cwd*: string
    plan*: seq[PlanItem]
    loop*: LoopTracker
    readCache*: ReadCache
  ApiError* = object of CatchableError
  ParseIssue* = object
    ## A syntax problem the text-mode parser surfaced on a fenced block
    ## (unterminated fence, orphan code-fence, malformed SEARCH/REPLACE).
    ## `line` is 1-indexed into the assistant reply.
    line*: int
    msg*: string
  InputState* = object
    ## Shared between the main thread and the buffered prompt thread during
    ## model/tool turns.
    turnActive*: bool
    shutdown*: bool
    autoSend*: bool
    queuedText*: string
    queuedEchoRows*: int
    cmdWasQuit*: bool

proc die*(msg: string, code = 1) {.noreturn.} =
  stderr.writeLine "3code: " & msg
  quit code
