import std/[tables, times]

const
  ExitUsage* = 2
  ExitConfig* = 3
  ExitApi* = 5

type
  ActionKind* = enum akBash, akRead, akWrite, akPatch, akApplyPatch, akError
  Action* = object
    kind*: ActionKind
    path*: string
    body*: string
    stdin*: string  ## bash-only: piped to the command's stdin
    edits*: seq[(string, string)]
    offset*: int
    limit*: int
  Profile* = object
    ## `model` is the API model string sent on the wire (e.g.
    ## "openai/gpt-oss-120b"). `modelPrefix` is the path-prefix that's
    ## stored separately in the config so provider namespaces don't get
    ## repeated for every model in the list; it is concatenated to
    ## `model` when forming the wire value. The remaining fields are
    ## metadata pulled out of the known-good table: `family` ("glm" /
    ## "qwen" / "gpt-oss") drives the (prompt, tools) tuple selection;
    ## `version` and `variant` (e.g. "3", "480b") are informational
    ## tags. In experimental mode `family` may also come from the
    ## per-provider `family = ...` config override.
    name*, url*, key*, modelPrefix*, model*: string
    family*, version*, variant*: string
  Usage* = object
    promptTokens*, completionTokens*, totalTokens*, cachedTokens*: int
  ToolRecord* = object
    banner*: string
    output*: string
    code*: int
    kind*: ActionKind
  LoopTracker* = object
    ## Sliding-window per-path saturation detector. `bash` tool calls are
    ## fingerprinted only when they look like a file mutation (`sed -i`,
    ## redirects, `tee`, `cp`/`mv`/`rm`, `git checkout/restore`); read-only
    ## bash is untracked. Reset at the start of each user turn via
    ## `resetLoopTracker`.
    ring*: seq[tuple[fp: string, mut: bool]]  # last K (path, isMutation)
    counts*: CountTable[string]     # all tracked kinds per path → Strike 1
    mutCounts*: CountTable[string]  # writes+patches+sed only per path → Strike 2
    strike*: int             # 0/1/2
    trippedPaths*: seq[string] # paths that have already tripped this strike
    recoveryCmd*: string     # set when Strike 2 fires from a git-recovery hard-trip; "" otherwise
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
    loop*: LoopTracker
    readCache*: ReadCache
  ApiError* = object of CatchableError
  ParseIssue* = object
    ## A syntax problem the text-mode parser surfaced on a fenced block
    ## (unterminated fence, orphan ```, malformed SEARCH/REPLACE).
    ## `line` is 1-indexed into the assistant reply.
    line*: int
    msg*: string

proc die*(msg: string, code = 1) {.noreturn.} =
  stderr.writeLine "3code: " & msg
  quit code
