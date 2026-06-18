# Controller And Transcript Design

This document describes the target runtime architecture for the interactive
terminal flow. It complements `.agents/design.md`, which remains the source of
truth for the visual contract.

The key rule: the controller owns the transcript history. Every visible
scrollback item is added through one controller-level path. Lower modules may
format item bodies or manage volatile terminal chrome, but they must not
independently decide transcript spacing, prompt echo behavior, or item order.

## Terms

- **History**: ordinary terminal scrollback. It remains visible when scrolling
  upward and after exit.
- **Item**: one semantic entry in history. Examples: user prompt, assistant
  response, bash tool output, read/write/patch tool result, token receipt,
  status note.
- **Fat prompt**: volatile live chrome at the bottom of history: editor, token
  bar, optional thinking ticker.
- **Viewport**: volatile live display for bounded streaming output, currently
  used by bash tools.
- **Controller**: the orchestration layer that receives semantic events and
  commits items to history in order.

## Core Flow

The controller receives events:

- user submitted prompt,
- API call started,
- assistant content arrived,
- API usage receipt arrived,
- tool call started,
- tool stream line arrived,
- tool call completed,
- buffered/autosend prompt became ready,
- turn completed or interrupted.

For each event, the controller decides whether to:

- mutate model/session state,
- update fat-prompt state,
- open/feed/close a live viewport,
- append one or more items to history,
- start, continue, or stop a turn.

No lower module should append a history item on its own initiative. If a lower
module observes data, it should return it or invoke a controller-registered
handler. The controller decides when that data becomes history.

## History Item Contract

History is a sequence of trimmed items separated by exactly one blank row.

Formatters return item bodies:

- no leading blank rows,
- no trailing blank rows,
- no ownership of inter-item spacing,
- no token receipt side effects,
- no fat-prompt repainting.

The controller-level history append helper owns:

- trimming item bodies,
- inserting exactly one separator between items,
- inserting no separator between an API response and its token receipt,
- converting the live token bar into a receipt when appropriate,
- clearing stale pending receipt state,
- asking fat prompt/terminal code to preserve or remove live editor chrome.

In debug mode, this helper may optionally emit a visible or logged separator
marker so spacing bugs can be traced to the item boundary. That marker must be
debug-only and must not appear in normal output.

## User Prompt And Autosend

Normal prompt submission and autosend submission must use the same controller
path.

The only difference is where the submitted text comes from:

- normal prompt: the foreground editor returns a complete line/body,
- autosend prompt: the live editor records completed text while a turn is still
  running, then the controller drains it after the current turn boundary.

Once drained, both are just `UserPrompt` items:

1. controller reads the final submitted text,
2. controller adds the user message to conversation state,
3. controller refreshes the system prompt,
4. controller appends a user-prompt item to history,
5. controller starts or resumes the turn.

Autosend must not have its own prompt renderer, spacing policy, or cursor
contract. It should store enough turn data to resume through the normal path.

If the user continues typing after the autosend marker, the buffered state must
promote the visible editor text into the final submitted text before the
controller drains it. No newline inserted by the editor may be removed by
autosend cleanup.

## Assistant Streaming

Assistant streaming has two layers:

- the API client parses SSE and reports deltas,
- the controller decides how deltas affect history and fat-prompt state.

When live assistant text is streamed into history, the controller still owns the
event sequence and final receipt placement. Markdown rendering may buffer partial
content until it can safely format it, but it must not decide transcript item
spacing.

When live assistant streaming is suppressed because the editor/fat prompt needs
stability, the controller appends the completed assistant response as one item
at the end of the API call.

## Tool Streaming

Streaming bash output is a scoped controller operation:

1. controller receives a bash tool call,
2. controller creates/enters a live viewport object,
3. controller feeds output lines to the viewport while the process runs,
4. controller closes/erases the viewport when the process completes,
5. controller appends the final tool item to history through the same history
   append helper.

The viewport is volatile. It is not history. It may show a bounded tail of live
output, but final tool output must be committed once, and only once, as a
history item.

Non-bash tools skip the viewport and append their result item directly through
the same history append helper.

## API Boundary

`api.nim` must be transport/protocol code:

- build requests,
- send HTTP,
- parse SSE,
- parse provider usage/tool-call fields,
- report protocol events to handlers registered by the controller.

`api.nim` must not:

- import display/fatprompt/terminal/minline,
- write view escape sequences,
- append history items,
- decide token receipt placement,
- decide prompt or item spacing.

## Module Map

`src/threecode.nim` - **C**

Entry point and outer interactive controller. It parses CLI args, initializes
session/profile/editor state, owns the foreground REPL, drains buffered prompts,
and kicks off turns. Target role: top-level controller and history append policy.

`src/threecode/turns.nim` - **C**

Inner turn controller. It calls the model, handles assistant responses, dispatches
tool calls, updates session state, applies loop/compaction decisions, and tells
the history emitter which items to append. Target role: all turn-level semantic
event ordering.

`src/threecode/api.nim` - **M**

Provider transport and protocol model. It builds requests, parses SSE, extracts
usage/content/tool-call data, and exposes hooks/events. It must not contain view
code.

`src/threecode/session.nim` - **M**

Conversation/session persistence model: `.3log` paths, save/load, replay source
data.

`src/threecode/types.nim` - **M**

Shared domain types and simple data containers.

`src/threecode/prompts.nim` - **M**

System prompt and provider-family tool schema data.

`src/threecode/actions.nim` - **M/C**

Maps tool-call data to executable actions and contains action semantics. It is
model-like for action data, controller-like where it chooses execution behavior.
It should not write terminal history directly.

`src/threecode/streamexec.nim` - **M/C**

Process execution and streaming output source. It owns subprocess mechanics and
reports lines/results upward. It should not own transcript formatting.

`src/threecode/compact.nim` - **M/C**

Conversation compaction/summarization logic. Model-like for message transforms,
controller-like where it invokes model calls for summarization. It should report
status to the controller rather than append terminal items itself.

`src/threecode/loop.nim` - **M**

Loop guard state and decisions.

`src/threecode/config.nim` - **M**

Configuration/profile loading and validation data.

`src/threecode/fatprompt.nim` - **V**

Facade for fat-prompt view modules. It should expose a coherent prompt/chrome API
to controllers.

`src/threecode/fatprompt/rendering.nim` - **V**

Pure-ish formatting and byte construction for fat prompt chrome and item body
formatters. It may format a user prompt body, token bar label, or prompt frame.
It must not decide when an item is appended to history.

`src/threecode/fatprompt/runtime.nim` - **V/C**

Live fat-prompt runtime: input thread, spinner/ticker state, editor reservation,
API stream hook adapters, and terminal preservation around transcript appends.
It is view-controller glue. Target direction: keep terminal mechanics here, move
semantic history ordering upward into `threecode.nim`/`turns.nim`.

`src/threecode/terminal.nim` - **V**

Thin serialized terminal mechanics layer. It owns terminal locks, synchronized
writes, cursor movement primitives, footer clearing/restoring, and scroll-region
mechanics. It must not know semantic item types.

`src/threecode/toolstream.nim` - **V**

Live bounded viewport for streaming bash output. It is volatile view state, not
history. The controller owns its lifetime.

`src/threecode/display.nim` - **V**

Transcript/body formatting helpers and replay formatting. Target direction:
format item bodies only; remove controller decisions and hidden spacing where
possible.

`src/threecode/minline.nim` - **V**

Line editor view/input primitive. It owns editor buffer rendering and key
handling, not transcript history.

`src/threecode/ui.nim` - **C/V**

Command handling and provider setup UI. It is controller-like for REPL commands
and view-like for command output. Target direction: return command events/results
to the controller when command output must become history.

`src/threecode/util.nim` - **M/V helpers**

Shared utility functions, color constants, and formatting helpers. It should not
own control flow.

`src/threecode/shell.nim`, `src/threecode/web.nim`, `src/threecode/update.nim` -
**M/C**

Support subsystems. They may perform work and return results, but history
emission should route through the controller.

## Migration Targets

1. Introduce a controller-owned history append helper.
2. Convert user prompt emission to use that helper for both foreground and
   autosend prompts.
3. Convert assistant final response emission to use the helper.
4. Convert tool result emission to use the helper.
5. Make token receipt emission a controller-owned item-adjacent operation.
6. Remove buffered-only prompt emitters and old cursor-relative prompt replay.
7. Keep fat prompt responsible for live chrome preservation, not item ordering.

The end state is that visual bugs involving missing newlines, duplicated token
bars, cut-off autosent prompts, or receipt/prompt overlap can be traced to one
history append path instead of several independent byte emitters.
