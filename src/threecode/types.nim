import std/[tables, times]

const
  ExitUsage* = 2
  ExitConfig* = 3
  ExitApi* = 5

type
  ActionKind* = enum akBash, akRead, akWrite, akPatch, akApplyPatch
  Action* = object
    kind*: ActionKind
    path*: string
    body*: string
    stdin*: string  ## bash-only: piped to the command's stdin
    edits*: seq[(string, string)]
    offset*: int
    limit*: int
  Profile* = object
    ## Terminology: `model` is the broad name we drive prompt+tools selection
    ## on ("glm", "qwen", "gpt-oss"). `variant` is the concrete API identifier
    ## sent on the wire (e.g. "openai/gpt-oss-120b" — what providers call
    ## "model"). `variantPrefix` is prepended to the variant to form that
    ## wire value when a provider namespaces its variants.
    name*, url*, key*, variantPrefix*, variant*: string
    model*: string  ## "glm" / "qwen" / "gpt-oss" — selects the (prompt, tools)
                    ## tuple. Set by `resolveModel` from the known-good table
                    ## or the per-provider `model = ...` experimental override.
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
