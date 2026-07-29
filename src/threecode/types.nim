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
var sandboxEnabled*: bool = true
  ## When true, every tool call is confined to the filesystem sandbox
  ## (the cascaded `.3code/sandbox` policy). When false, bash runs
  ## unconfined and the in-process read/write/patch checks pass through.
  ## Default on, preserving the historical sandboxed behavior. Toggled
  ## at runtime via `:sandbox on/off`, persisted in `[settings]`.
var sandboxWallWarn*: bool = true
  ## When true, a policy with host rules on Windows without the wall
  ## setup (`3code wall setup-windows`) prints a one-time warning that
  ## bash runs unfenced. Default on; `[settings] sandbox_wall_warn =
  ## off` silences it.

type
  ColorMode* = enum
    cmAuto,   ## detect from the terminal (OSC 11 background query)
    cmDark,   ## force dark palette
    cmLight   ## force light/bright-background palette

var colorMode*: ColorMode = cmDark
  ## Resolved active colour mode (always `cmDark` or `cmLight` after
  ## startup; `cmAuto` is only ever a request, resolved to one of the
  ## two before any colored output). Set in `threecode.main` from the
  ## `[settings] mode` config key (default `auto`) then detection.
  ## Drives the white-family palette resolved in `util.applyPalette`.

var colorModePref*: ColorMode = cmAuto
  ## The raw `[settings] mode` request. `cmAuto` means detect; `cmDark`/
  ## `cmLight` force a palette. Read during config parse, honored in
  ## `main` before palette application.

const
  ExitUsage* = 2
  ExitConfig* = 3
  ExitApi* = 5
  DefaultBashTimeout* = 120   ## seconds; used when the model omits `timeout`
  MaxBashTimeout* = 600       ## seconds; hard ceiling regardless of model request

proc maxBashTimeoutSecs*(): int =
  ## The current ceiling a `timeout` request is clamped to. Reads
  ## `THREECODE_MAX_TIMEOUT` at call time so the ceiling can be raised
  ## at runtime without a rebuild; defaults to `MaxBashTimeout`.
  try: getEnv("THREECODE_MAX_TIMEOUT").parseInt
  except CatchableError: MaxBashTimeout

proc bashTimeoutSecs*(req: int): int =
  ## Resolve the run cap (seconds) from a model-requested value.
  ## Missing/zero/negative → default; any value above the ceiling
  ## is clamped to it.
  let v = if req > 0: req else: DefaultBashTimeout
  let cap = maxBashTimeoutSecs()
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
    reasoningTokens*: int  # tokens consumed by internal reasoning
                            # (completion_tokens_details.reasoning_tokens).
                            # High + empty content = budget starved.
  ToolRecord* = object
    banner*: string
    output*: string
    code*: int
    kind*: ActionKind
    plan*: seq[PlanItem]
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
    ## Base for all model/API failures. `callModel`'s retry loop and the
    ## turn loop catch this so every failure mode is handled uniformly.
  HttpError* = object of ApiError
    ## The server returned a response carrying an HTTP status code (any
    ## non-success code: 4xx client errors, 5xx server errors, etc.). The
    ## `code` field exposes it for programmatic handling; `msg` already
    ## carries the formatted detail including the `(code N)` suffix.
    code*: int
  NetworkHealthError* = object of ApiError
    ## Transport-level failure with no HTTP response: the network-quiet
    ## watchdog fired (the provider sent nothing for `QuietTooLongMs` and
    ## the cached socket was shut down), or the connect/read failed with a
    ## bare transport error. `callModel`'s retry loop catches it and treats
    ## it as a retryable server error, identical to a 5xx.
  ParseIssue* = object
    ## A syntax problem the text-mode parser surfaced on a fenced block
    ## (unterminated fence, orphan code-fence, malformed SEARCH/REPLACE).
    ## `line` is 1-indexed into the assistant reply.
    line*: int
    msg*: string
  InputEventKind* = enum
    ieNone
    ieLine       ## user submitted a prompt line (idle or buffered during turn)
    ieCommand    ## user submitted a colon :command during turn
    ieInterrupt  ## ESC / Ctrl-C pressed during turn
    ieQuit       ## Ctrl-D on empty line; exit the REPL

  InputEvent* = object
    kind*: InputEventKind
    text*: string
    echoRows*: int

  InputState* = object
    ## Shared between the main thread and the buffered prompt thread during
    ## model/tool turns.
    turnActive*: bool
    shutdown*: bool
    eventQueue*: seq[InputEvent]

  WizardReadRequest* = object
    ## Main thread → input thread: run one `readLineWith` for the modal
    ## wizard with this prompt, return the result. The input thread is
    ## the only place that owns stdin and the termios raw mode, so the
    ## wizard plugs in here instead of running its own `editor.readLine`
    ## on the main thread (which would race the input thread's
    ## `posix.read` on the same fd and corrupt the editor's hook
    ## closures).
    prompt*: string
    hidechars*: bool
    noHistory*: bool

  WizardReadResultKind* = enum
    wrSubmitted  ## user pressed Enter; `text` holds the line
    wrCancelled  ## ESC / Ctrl-C; main thread raises InputCancelled
    wrEof        ## stdin closed; main thread raises EOFError

  WizardReadResponse* = object
    kind*: WizardReadResultKind
    text*: string

const
  InterruptedByUserMsg* = "interrupted by user"
  NetworkQuietPrefix* = "network quiet for"
    # Marker prefix the transport writes into `StreamOutcome.errMsg` when the
    # network-quiet watchdog fires. `callModel` checks this to raise a
    # `NetworkHealthError` and route it through the server-retry path.
  EmptyReplyMsg* = "empty reply - no content, no tool calls"
    # Canonical message the transport writes into `StreamOutcome.errMsg` when
    # a 200 OK arrives with no content, no tool_calls, and no finish_reason:
    # a transport anomaly, not a budget-starved empty turn. `callModel`'s
    # retry loop promotes any 200 OK that produced no assistant message to a
    # `NetworkHealthError` so it backs off and resends, instead of surfacing
    # a dead-end `HttpError (code 200)` on the first attempt. This constant
    # is the string the transport sites write; `isEmptyReplyMsg` identifies
    # it for display and tests.

proc isInterruptedMsg*(msg: string): bool =
  msg == InterruptedByUserMsg

proc isNetworkQuietMsg*(msg: string): bool =
  msg.startsWith(NetworkQuietPrefix)

proc isEmptyReplyMsg*(msg: string): bool =
  msg == EmptyReplyMsg

proc die*(msg: string, code = 1) {.noreturn.} =
  # Leading newline: mid-turn deaths (unknown family, etc.) fire while the
  # cursor sits at the end of the just-submitted prompt line, which has no
  # trailing newline. Without this, the error appends to the prompt on the
  # same row. At startup the cursor is at col 0, so the extra line is inert.
  stderr.write "\n3code: " & msg & "\n"
  quit code
