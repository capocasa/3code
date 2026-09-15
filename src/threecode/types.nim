## Shared types and process-level globals.
##
## All types that cross module boundaries live here to avoid import cycles.
## `experimentalEnabled` is a global because every module that validates a
## profile needs it, and threading it through every call site is noise.

import std/[json, options, os, strutils, tables, times]

var experimentalEnabled*: bool = false
  ## Set by `-x`/`--experimental`.
var privateMode*: bool = false
  ## Private mode: incognito for the agent. Default off, session-only
  ## (never persisted), turned on with `-p`/`--private` or `:private on`.
  ## While on, turns only run on providers/models marked private-allowed
  ## (a `[params] allow-private` setting or a known-good entry curated
  ## for a zero-training provider) and the live token bar repaints in the
  ## private color so the mode is visible on every frame.
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
  ## (the single active policy: repo `.sandbox`, else
  ## `~/.config/3code/sandbox`, else the built-in default). When
  ## false, bash runs unconfined and the in-process read/write/patch
  ## checks pass through.
  ## Default on, preserving the historical sandboxed behavior. Toggled
  ## at runtime via `:sandbox on/off`, persisted in `[settings]`.
var dangerConfirmed*: bool = false
  ## Set only by the `--danger` CLI flag; deliberately never persisted
  ## to `[settings]` or any config file, so it has to be typed again on
  ## every invocation. When the sandbox is meant to be on but the OS
  ## backend cannot actually confine bash (Landlock/Seatbelt probe
  ## failed, or the Windows sandbox user isn't set up), bash is refused
  ## unless this is true; see `bashConfinementBlocked` in sandbox.nim.
var conversationId*: string = ""
  ## Stable per-conversation id published by the session layer
  ## (sessionIdFromPath of the `.3log`). Sent as `x-opencode-session` on
  ## OpenCode Zen/Go requests: the gateway routes/shards by that header
  ## and as of 2026-09-06 rejects headerless requests, so it must be stable
  ## across a conversation's turns but unique per conversation. Empty for
  ## one-shot calls (verify/summarize), which then send a per-call id.

var oneShotSessionIdSeed: string
  ## Memoized timestamp seed so same-microsecond one-shot ids still differ
  ## (a trailing counter). Only touched when no conversation is active.

proc oneShotSessionId*(): string =
  ## Fallback `x-opencode-session` value when no conversation is published
  ## (verify wizard, library one-shots): unique per call, opaque.
  let stamp = now().format("yyyyMMdd'T'HHmmss'.'ffffff")
  if oneShotSessionIdSeed == stamp:
    oneShotSessionIdSeed = stamp & "+"
  else:
    oneShotSessionIdSeed = stamp
  "3code-" & oneShotSessionIdSeed

var patientRetryEnabled*: bool = true
  ## Patient retry. When true, retryable API failures (429, 5xx, network
  ## errors) keep retrying on one shared exponential curve capped at 2048s,
  ## for up to ~64 tries (~36h), so a long-running session rides out a
  ## usage-window limit or a network dropout (the train ride) without
  ## dropping to the prompt. When false, failures surface after the initial
  ## ramp-up (~1min) instead of entering the long patient hold. Default on.
  ## Toggled at runtime via `:retry on/off`, persisted in `[settings]` as
  ## `patient_retry`.
var sandboxWallWarn*: bool = true
  ## When true, a policy with host rules on Windows without the wall
  ## setup (`3code setup`) prints a one-time warning that
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
  ActionKind* = enum akBash, akRead, akWrite, akPatch, akApplyPatch, akPlan, akWebSearch, akWebFetch, akClear, akDMail, akError
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
  ThinkBackMode* = enum
    tbNone         ## strip reasoning_content from all replayed assistant messages
    tbCurrentTurn  ## keep reasoning within the active tool loop, strip at the
                   ## last user turn boundary
    tbAllTurns     ## keep reasoning_content on every replayed assistant message

  ModelParams* = object
    ## Per-provider overrides for the known-good model parameters
    ## (`KnownGoodCombos` in prompts.nim). Read from a
    ## `[params]` config section; every field is an Option so
    ## `none` cleanly means "not configured" and the known-good table
    ## value (or its absence) applies.
    temperature*: Option[float]
    maxTokens*: Option[int]
    thinkBack*: Option[ThinkBackMode]
    contextWindow*: Option[int]
    allowPrivate*: Option[bool]  ## policy flag, never a wire param: true
                                ## trusts this (provider, model) with
                                ## private-mode data. `none` means "not
                                ## configured", deferring to the known-good
                                ## table's curated flag.

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
    params*: ModelParams  ## [params] overrides for this (provider,
                          ## model), resolved at profile-build time.
                          ## Lookups that consult the known-good table
                          ## (generation defaults, think-back, context
                          ## window) patch these over the table values.
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
  PromptState* = object
    system*: JsonNode
    identity*, skills*: string
  Session* = object
    promptState*: PromptState
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

proc providerOf*(p: Profile): string =
  ## Lower-case provider name from `Profile.name` ("nvidia.openai/gpt-oss-120b"
  ## -> "nvidia"). "" when no dot. Lives in types (not api) so both api
  ## and compact can dispatch on it without an import cycle.
  let dot = p.name.find('.')
  if dot < 0: "" else: p.name[0 ..< dot].toLowerAscii

proc responsesApi*(p: Profile): bool =
  ## True when this profile speaks the OpenAI Responses API (/responses
  ## instead of /chat/completions). First-party openai, plus `chatgpt`
  ## (the ChatGPT-subscription twin that posts to the Codex backend);
  ## anthropic may join the same dispatch later.
  let prov = providerOf(p)
  prov == "openai" or prov == "chatgpt"

proc isInterruptedMsg*(msg: string): bool =
  ## Matches the bare `InterruptedByUserMsg` and variants that append
  ## context (e.g. "... during retry backoff"). Every raise of this class
  ## must route through the turn loop's `onTurnInterrupted` path so the
  ## turn-state reset (`inputTurnActive`) always runs; a suffix must not
  ## reclassify it as a generic error.
  msg == InterruptedByUserMsg or msg.startsWith(InterruptedByUserMsg & " ")

proc isNetworkQuietMsg*(msg: string): bool =
  msg.startsWith(NetworkQuietPrefix)

proc isEmptyReplyMsg*(msg: string): bool =
  msg == EmptyReplyMsg

func parseThinkBackMode*(s: string): ThinkBackMode =
  ## Config spelling of `ThinkBackMode`: `none`, `turn`, `all`, the
  ## exact set `validateConfig` admits. Unknown values return tbNone;
  ## config load rejects them before this sees them in practice.
  case s.strip.toLowerAscii
  of "none": tbNone
  of "turn": tbCurrentTurn
  of "all": tbAllTurns
  else: tbNone

func formatThinkBack*(m: ThinkBackMode): string =
  case m
  of tbNone: "none"
  of tbCurrentTurn: "turn"
  of tbAllTurns: "all"

proc die*(msg: string, code = 1) {.noreturn.} =
  # Leading newline: mid-turn deaths (unknown family, etc.) fire while the
  # cursor sits at the end of the just-submitted prompt line, which has no
  # trailing newline. Without this, the error appends to the prompt on the
  # same row. At startup the cursor is at col 0, so the extra line is inert.
  stderr.write "\n3code: " & msg & "\n"
  stderr.flushFile
  when defined(windows):
    # Under the ConPTY tty harness the pseudoconsole host relays the child's
    # output asynchronously. A child that writes and exits immediately races
    # that relay and the final write is dropped (reproduced with a bare
    # `fputs+return`: captured when it sleeps ~20ms first, lost otherwise).
    # Give the relay a bounded window so the harness sees the diagnostic.
    # Only under the test harness; a real console keeps the host alive.
    if getEnv("THREECODE_TEST_FRAME_FD").len > 0:
      sleep(200)
  quit code
