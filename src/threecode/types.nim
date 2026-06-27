## Shared types and process-level globals.
##
## All types that cross module boundaries live here to avoid import cycles.
## `experimentalEnabled` is a global because every module that validates a
## profile needs it, and threading it through every call site is noise.

import std/[os, strutils, tables, times]

var experimentalEnabled*: bool = false
  ## Set by `-x`/`--experimental`.
var debugEnabled*: bool = false
  ## Set by `-D`/`--debug`.
var streamingEnabled*: bool = true
  ## Whether model calls use SSE streaming (`"stream": true`) or a single
  ## request/response. Default on for live output. The non-streaming path is
  ## the reliable fallback when a provider's SSE transport is flaky (empty
  ## 200 replies, ticker dying mid-response — the streamhttp TLS-read race).
  ## Toggled at runtime via `:streaming on/off`, persisted in `[settings]`.
var notifyEnabled*: bool = true
  ## When true, a native desktop notification fires when a turn ends.
  ## Default on. Toggled at runtime via `:notify on/off`, persisted in
  ## `[settings]`; an explicit `off` opts out.

const
  ExitUsage* = 2
  ExitConfig* = 3
  ExitApi* = 5
  DefaultBashTimeout* = 120   ## seconds; used when the model omits `timeout`
  MaxBashTimeout* = 600       ## seconds; hard ceiling regardless of model request

proc bashTimeoutSecs*(req: int): int =
  ## Resolve the run cap (seconds) from a model-requested value.
  ## Missing/zero/negative → default; any value above `MaxBashTimeout`
  ## is clamped to it. Read at call time so `THREECODE_MAX_TIMEOUT` can
  ## raise the ceiling at runtime without a rebuild.
  let cap =
    try: getEnv("THREECODE_MAX_TIMEOUT").parseInt
    except CatchableError: MaxBashTimeout
  let v = if req > 0: req else: DefaultBashTimeout
  if v > cap: cap else: v

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
    timeoutSecs*: int  ## bash-only: model-requested run cap in seconds; 0 = default
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
    queuedPrompts*: seq[tuple[text: string, echoRows: int]]
    queuedCommand*: string
    queuedCommandRows*: int
    cmdWasQuit*: bool

proc die*(msg: string, code = 1) {.noreturn.} =
  stderr.writeLine "3code: " & msg
  quit code
