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
    log*: proc (s: ptr TcState; msg: cstring; len: int32) {.cdecl, gcsafe.}
    registerTool*: proc (s: ptr TcState; name, description, schemaJson: cstring;
                         timeoutMs: int32): cint {.cdecl, gcsafe.}
      ## Legal only inside `tc_register_tools`. `schemaJson` is an
      ## OpenAI function-tool definition. `timeoutMs` caps one exec
      ## (0 = the host default). Returns 0 on success.

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
