#[ The 3code plugin C ABI.
##
## Shared verbatim between the host (`import threecode/pluginabi` in
## plugins.nim) and plugin libraries (`include threecode/pluginabi` as
## the first line of a plugin; see plugin_sdk.nim). Plain C types only
## (`cstring`, `int32`, raw pointers): each dynlib carries its own
## runtime, so no Nim object, string, or ref ever crosses the boundary.
##
## Contract, in full:
##
## * Every pointer the host passes is valid ONLY for the duration of
##   the call. Plugins retain nothing.
## * `TcStr` fields are read-only views into host memory.
## * `TcMutStr` fields are host-allocated buffers the plugin may edit
##   in place: grow `len` up to `cap`, never past. An over-cap write
##   is dropped and logged by the host. The host sizes `cap` from the
##   payload (see plugins.nim), so ordinary edits fit.
## * Nothing allocated on one side is ever freed by the other.
## * All hooks run on the host's single plugin thread, strictly one at
##   a time, in plugin load order. Sync hooks have a deadline; a slow
##   plugin is served its default outcome and eventually demoted.
## * Every struct starts with `abi` (host ABI version) and
##   `structSize` (the host's sizeof). Plugins should treat a larger
##   host struct as trailing unknown bytes and only reject a
##   `structSize` smaller than the one they were compiled against.
]##

const TcAbiVersion* = 1.cint
  ## Bump on any incompatible change to a struct layout or hook
  ## signature. Additive trailing fields only bump nothing (size
  ## negotiation absorbs them).

const
  tcAllow* = 0.cint     ## proceed unchanged
  tcVeto* = 1.cint      ## skip the call; `message` is the tool result
  tcRewrite* = 2.cint   ## `args` were rewritten in place; proceed
  tcTakeover* = 3.cint  ## skip execution; `message` is the whole result
  tcWrap* = 4.cint      ## run the original between `message` (pre) and `post`

const
  taeUser* = 0.cint       ## agent event: the user prompt a turn started with
  taeDelta* = 1.cint      ## agent event: streamed assistant text chunk
  taeReasoning* = 2.cint  ## agent event: streamed reasoning chunk
  taeTool* = 3.cint       ## agent event: committed tool result / line
  taeRetry* = 4.cint      ## agent event: provider retry notice
  taeNotice* = 5.cint     ## agent event: harness notice (steer, compact, usage)
  taeDone* = 6.cint       ## agent event: model call finished (usage fields)
  taeError* = 7.cint      ## agent event: turn failed (`text` is the message)

type
  TcStr* = object
    ## Read-only byte view. `data` is not NUL-terminated.
    data*: cstring
    len*: int32

  TcMutStr* = object
    ## In-place editable host buffer, `len <= cap` at all times.
    data*: cstring
    len*: int32
    cap*: int32

  TcServices* = object
    ## Host callables, legal only from a hook or init call on the
    ## plugin thread (except `log`, safe anywhere).
    ##
    ## Trailing entries are later additions: a plugin compiled against
    ## a newer pluginabi than the running host must not call them (the
    ## host's allocation ends where the old struct did), so keep the
    ## pluginabi you compile with no newer than the 3code that loads
    ## you. Older plugins on a newer host are safe and simply never
    ## see the new slots.
    log*: proc (s: ptr TcState; msg: cstring; len: int32) {.cdecl, gcsafe.}
    registerTool*: proc (s: ptr TcState; name, description, schemaJson: cstring;
                         timeoutMs: int32): cint {.cdecl, gcsafe.}
      ## Legal only inside `tc_register_tools`. `schemaJson` is an
      ## OpenAI function-tool definition. `timeoutMs` caps one exec
      ## (0 = the host default). Returns 0 on success.
    registerCliCommand*: proc (s: ptr TcState; name, help: cstring): cint {.
        cdecl, gcsafe.}
      ## Legal only inside `tc_register_cli`. Adds a `3code <name>`
      ## subcommand dispatched to `tc_cli_command`. Returns 0 on
      ## success, 1 outside registration, 2 for a bad name, 3 for a
      ## builtin subcommand name, 4 for a duplicate.
    registerCliOption*: proc (s: ptr TcState; longName, shortName, help: cstring;
                              takesValue: cint): cint {.cdecl, gcsafe.}
      ## Legal only inside `tc_register_cli`. Adds a `--longName`
      ## option (plus `-shortName` when non-empty) accepted by the
      ## main option parser and delivered to `tc_on_cli_options`.
      ## Same return codes; 2 also covers a bad short name.
    overrideDefault*: proc (s: ptr TcState; section, key, value: cstring): cint {.
                              cdecl, gcsafe.}
      ## Legal only inside `tc_register_config`. Overrides the DEFAULT
      ## of a `[section]` config key: applied when the user's own
      ## config file does not set it, ignored when it does. `section`
      ## is "settings" today; `key` is the plain spelling. Returns 0
      ## on success, 1 outside registration, 2 for a key plugins
      ## cannot default, 3 for a bad value.
    agentOpen*: proc (s: ptr TcState; optsJson: cstring; optsLen: int32): cint {.
                              cdecl, gcsafe.}
      ## In-process agent (frontend only): open the process's one
      ## AgentSession. `optsJson` is `{"model": ..., "cwd": ...,
      ## "resume": true, "resumeId": ..., "sessionPath": ...,
      ## "experimental": bool}` (all keys optional). 0 ok, 1 already
      ## open, 2 busy, 3 open failed (see `agentLastError`).
    agentClose*: proc (s: ptr TcState): cint {.cdecl, gcsafe.}
      ## Persist and release the session (waits for a running turn).
    agentStart*: proc (s: ptr TcState; prompt: cstring; promptLen: int32): cint {.
                              cdecl, gcsafe.}
      ## Kick a turn on a host worker thread; returns at once. Empty
      ## prompt continues the conversation. 0 started, 1 busy, 2 no
      ## session. Events land via `agentPollEvent`.
    agentCancel*: proc (s: ptr TcState): cint {.cdecl, gcsafe.}
      ## Interrupt the in-flight turn. 0 interrupted, 1 idle.
    agentBusy*: proc (s: ptr TcState): cint {.cdecl, gcsafe.}
      ## 1 while a turn (started by `agentStart`) is running, else 0.
    agentCommand*: proc (s: ptr TcState; cmd: cstring; cmdLen: int32;
                         output: ptr TcMutStr): cint {.cdecl, gcsafe.}
      ## Run a colon command (`:tokens`, `:model ...`) and fill
      ## `output`. 0 ok, 1 busy, 2 no session, 3 command refused.
    agentScrollback*: proc (s: ptr TcState; output: ptr TcMutStr): cint {.
                              cdecl, gcsafe.}
      ## Stored conversation as JSON array text `[{"role": ...,
      ## "content": ...}]`, plain text, tools stripped. Same codes as
      ## `agentCommand`.
    agentLastError*: proc (s: ptr TcState): cstring {.cdecl, gcsafe.}
      ## The last agent service failure message, or "". A view; copy it.
    agentPollEvent*: proc (s: ptr TcState; ev: ptr TcAgentEvent): cint {.
                              cdecl, gcsafe.}
      ## Pop one event into the caller-owned `ev` block (zeroed first).
      ## 1 delivered, 0 queue empty. Poll from the frontend loop.

  TcState* = object
    ## Per-plugin context, host-owned, stable address for the process
    ## lifetime. Passed as the first argument to every call.
    abi*: cint
    structSize*: cint
    pluginName*: cstring
    userData*: pointer     ## plugin-owned; set it in tc_init
    cancelled*: int32      ## host sets 1 on user interrupt while a
                           ## plugin call is in flight; long-running
                           ## tool execs should poll this
    services*: ptr TcServices

  TcPromptEvent* = object
    abi*, structSize*: cint
    prompt*: TcMutStr
    cwd*: TcStr
    sessionPath*: TcStr
    provider*: TcStr
    model*: TcStr

  TcSysPromptEvent* = object
    abi*, structSize*: cint
    prompt*: TcMutStr
    provider*: TcStr
    model*: TcStr
    family*: TcStr

  TcToolPreEvent* = object
    abi*, structSize*: cint
    name*: TcStr
    args*: TcMutStr        ## the tool arguments object, JSON text
    callId*: TcStr
    family*: TcStr
    verdict*: cint         ## out: one of the tc* verdicts (plugin sets)
    message*: TcMutStr     ## out: veto note / takeover result / wrap pre
    post*: TcMutStr        ## out: wrap post text
    code*: int32           ## out: takeover exit code

  TcToolResultEvent* = object
    abi*, structSize*: cint
    name*: TcStr
    args*: TcStr
    output*: TcMutStr
    code*: ptr int32
    elapsedMs*: int32
    diff*: TcStr

  TcToolExecEvent* = object
    abi*, structSize*: cint
    name*: TcStr
    args*: TcStr           ## arguments object, JSON text
    output*: TcMutStr      ## out: the whole tool result
    code*: int32           ## out: exit code

  TcTurnEvent* = object
    abi*, structSize*: cint
    turn*: int32
    promptTokens*: int32
    cwd*: TcStr

  TcTurnEndEvent* = object
    abi*, structSize*: cint
    turn*: int32
    promptTokens*: int32
    completionTokens*: int32
    reasoningTokens*: int32
    elapsedMs*: int32
    interrupted*: int32
    sessionPath*: TcStr

  TcRetryEvent* = object
    abi*, structSize*: cint
    provider*: TcStr
    model*: TcStr
    status*: int32
    category*: TcStr
    backoffS*: int32
    attempt*: int32

  TcSessionEvent* = object
    abi*, structSize*: cint
    sessionPath*: TcStr
    cwd*: TcStr
    provider*: TcStr
    model*: TcStr
    resumed*: int32
    messages*: int32

  TcCompactEvent* = object
    abi*, structSize*: cint
    before*: int32
    after*: int32
    summary*: TcStr

  TcFileWriteEvent* = object
    abi*, structSize*: cint
    path*: TcStr           ## project-relative when possible
    bytes*: int32
    kind*: int32           ## 0 write, 1 patch, 2 apply_patch

  TcCliCommandEvent* = object
    abi*, structSize*: cint
    name*: TcStr
    args*: TcStr           ## JSON array text of the arguments that
                           ## followed the subcommand, verbatim
    output*: TcMutStr      ## out: everything the command prints
    code*: int32           ## out: process exit code

  TcCliOptionsEvent* = object
    abi*, structSize*: cint
    options*: TcStr        ## JSON object text: option name -> value
                           ## string, or true for value-less flags

  TcFrontendEvent* = object
    abi*, structSize*: cint
    cwd*: TcStr            ## process working directory
    argv*: TcStr           ## JSON array text of the full command line,
                           ## verbatim (the plugin parses what it wants)

  TcAgentEvent* = object
    ## One queued agent event, copied out by `agentPollEvent`. `text`
    ## is a view into host memory valid ONLY for that call; copy it
    ## (tcView) before returning.
    abi*, structSize*: cint
    kind*: cint            ## one of the tae* kinds
    text*: TcStr
    promptTokens*: int32
    completionTokens*: int32
    reasoningTokens*: int32
    elapsedMs*: int32

# Hook proc shapes. Void hooks return nothing; verdict hooks return a
# cint the host also reads back from `ev.verdict` (the return value
# wins when they disagree).
type
  TcInitFn* = proc (s: ptr TcState): cint {.cdecl, gcsafe.}
  TcVoidFn* = proc (s: ptr TcState; ev: pointer) {.cdecl, gcsafe.}
  TcIntFn* = proc (s: ptr TcState; ev: pointer): cint {.cdecl, gcsafe.}
  TcVersionFn* = proc (): cint {.cdecl, gcsafe.}

# -- helpers shared by host and plugin SDK (no imports needed) ------

var tcCurrentState* {.threadvar.}: ptr TcState
  ## Plugin side only: the state pointer of the call in flight, set by
  ## the SDK wrappers before each hook runs. Long work polls
  ## `tcCancelled(tcCurrentState)`.

proc tcView*(m: TcStr | TcMutStr): string {.inline.} =
  ## Byte copy of a view/mutstr as a Nim string. The ONLY conversion
  ## that allocates; call it when you actually need the bytes.
  if m.data == nil or m.len <= 0: return ""
  result = newString(m.len.int)
  if m.len.int > 0:
    copyMem(addr result[0], m.data, m.len.int)

proc tcAssign*(m: var TcMutStr; s: cstring; n: int32) {.inline.} =
  ## Copy `n` bytes into a mutable buffer. Silent no-op when the
  ## content does not fit `cap` (the host logs and drops the edit).
  if m.data == nil or n > m.cap or n < 0: return
  if n > 0: copyMem(m.data, s, n.int)
  m.len = n

proc tcAssignStr*(m: var TcMutStr; s: string) {.inline.} =
  if s.len == 0:
    if m.data != nil: m.len = 0
  else:
    tcAssign(m, cast[cstring](addr s[0]), s.len.int32)

proc tcCancelled*(s: ptr TcState): bool {.inline.} =
  s != nil and s.cancelled != 0

proc registerTool*(s: ptr TcState; name, description, schemaJson: string;
                   timeoutMs: int32 = 0): bool {.inline.} =
  ## SDK convenience: forward to `services.registerTool` (legal only
  ## inside `tc_register_tools`). Method syntax `s.registerTool(...)`
  ## works via UFCS on the ptr.
  if s == nil or s.services == nil: return false
  proc grab(src: string): cstring =
    if src.len == 0: cstring"" else: cast[cstring](addr src[0])
  s.services.registerTool(s, grab(name), grab(description),
                          grab(schemaJson), timeoutMs) == 0

proc registerCliCommand*(s: ptr TcState; name, help: string): bool {.inline.} =
  ## SDK convenience for `services.registerCliCommand` (legal only
  ## inside `tc_register_cli`).
  if s == nil or s.services == nil: return false
  proc grab(src: string): cstring =
    if src.len == 0: cstring"" else: cast[cstring](addr src[0])
  s.services.registerCliCommand(s, grab(name), grab(help)) == 0

proc overrideDefault*(s: ptr TcState; section, key, value: string): bool {.
    inline.} =
  ## SDK convenience for `services.overrideDefault` (legal only
  ## inside `registerConfig`). False when the host refused the key or
  ## value — check `:plugins`, refusals are listed there.
  if s == nil or s.services == nil: return false
  proc grab(src: string): cstring =
    if src.len == 0: cstring"" else: cast[cstring](addr src[0])
  s.services.overrideDefault(s, grab(section), grab(key), grab(value)) == 0

proc agentOpen*(s: ptr TcState; optsJson: string): cint {.inline.} =
  ## SDK conveniences for the in-process agent services (legal only
  ## from `frontend` on the host's frontend thread).
  if s == nil or s.services == nil: return 3.cint
  if optsJson.len == 0:
    s.services.agentOpen(s, nil, 0)
  else:
    s.services.agentOpen(s, cast[cstring](addr optsJson[0]),
                         optsJson.len.int32)

proc agentStart*(s: ptr TcState; prompt: string): cint {.inline.} =
  if s == nil or s.services == nil: return 2.cint
  if prompt.len == 0:
    s.services.agentStart(s, nil, 0)
  else:
    s.services.agentStart(s, cast[cstring](addr prompt[0]), prompt.len.int32)

proc agentCommand*(s: ptr TcState; cmd: string; output: var TcMutStr): cint {.
    inline.} =
  if s == nil or s.services == nil or cmd.len == 0: return 2.cint
  s.services.agentCommand(s, cast[cstring](addr cmd[0]), cmd.len.int32,
                          addr output)

proc agentPollEvent*(s: ptr TcState; ev: var TcAgentEvent): cint {.inline.} =
  if s == nil or s.services == nil: return 0.cint
  s.services.agentPollEvent(s, addr ev)

proc agentLastErrorStr*(s: ptr TcState): string {.inline.} =
  ## Copy of the last agent service failure (empty when none). The
  ## raw service returns a transient cstring view; this is the one to
  ## keep.
  if s == nil or s.services == nil: return ""
  let cs = s.services.agentLastError(s)
  if cs == nil: "" else: $cs

proc agentClose*(s: ptr TcState): cint {.inline.} =
  if s == nil or s.services == nil: return 1.cint
  s.services.agentClose(s)

proc agentCancel*(s: ptr TcState): cint {.inline.} =
  if s == nil or s.services == nil: return 1.cint
  s.services.agentCancel(s)

proc agentBusy*(s: ptr TcState): cint {.inline.} =
  if s == nil or s.services == nil: return 0.cint
  s.services.agentBusy(s)

proc agentScrollback*(s: ptr TcState; output: var TcMutStr): cint {.inline.} =
  if s == nil or s.services == nil: return 2.cint
  s.services.agentScrollback(s, addr output)

proc registerCliOption*(s: ptr TcState; longName: string; shortName: char;
                        help: string; takesValue = true): bool {.inline.} =
  ## SDK convenience for `services.registerCliOption` (legal only
  ## inside `tc_register_cli`). Pass shortName '\0' for none.
  if s == nil or s.services == nil: return false
  proc grab(src: string): cstring =
    if src.len == 0: cstring"" else: cast[cstring](addr src[0])
  let sh = if shortName == '\0': "" else: $shortName
  s.services.registerCliOption(s, grab(longName), grab(sh), grab(help),
                               (if takesValue: 1 else: 0).cint) == 0
