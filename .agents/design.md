# Terminal Rendering Design

This document is the source of truth for the interactive terminal UI. It
overrides the current implementation when the implementation disagrees with it.

## Core Model

`3code` is a regular CLI application with a fat prompt at the end of the
scrollback.

The scrollback must behave like normal terminal scrollback. Model output, tool
output, user echoes, status messages, and final answers are ordinary scrollback
content. If the user scrolls up in the terminal, that content is visible. When
`3code` exits, that content remains visible in the terminal buffer.

The prompt is implemented more like a small TUI, but its position is relative
to the end of the scrollback buffer. It is not a separate full-screen
alternate-screen UI. It is the live bottom chrome attached to normal
scrollback.

## Fat Prompt

The fat prompt consists of these visual regions, from top to bottom:

1. Optional thinking ticker, one line.
2. Token bar, one line.
3. Prompt editor area, one or more lines.

The token bar and prompt editor area reserve real space below the scrollback.
They must never overwrite, hide, or replace scrollback content. The lowest
scrollback line must always be above all required token bar and prompt editor
lines, whether the app is idle, waiting for an API call, running tools, or
accepting buffered input.

The thinking ticker is a first-class fat-prompt row. When visible, it reserves
one row above the token bar. When hidden, that row is kept as an empty line —
the scrollback never moves back down. Scrollback flush against the token bar
never reads well, so the gap the ticker provides is wanted whether or not a
thinking ticker is active. The ticker must never overwrite scrollback content,
the token bar, or any editor row.

The token bar preserves the existing product behavior, even if the current
implementation is replaced:

- during an API call it shows a spinner and API-call timer,
- it always shows context percentage,
- it shows input tokens when greater than zero,
- it shows cache tokens when greater than zero,
- it shows output tokens when greater than zero.

## Prompt Area

The prompt editor area is always active while the application is interactive.
The user can type during API calls, tool calls, token bar updates, and thinking
ticker updates.

The editor area can occupy multiple visual lines because of explicit multiline
input, terminal wrapping, history navigation, prefilled residual text, or a
submit marker. Its reserved height is the current rendered editor height, not a
fixed one-line assumption.

Whenever the editor height grows, the scrollback must move upward to make room.
Whenever the editor height shrinks, the scrollback must move back downward and
reveal the scrollback lines that were displaced. This movement is part of the
fat prompt layout, not an output side effect.

The visible caret belongs only to the prompt editor area. No update outside the
editor may leave a visible caret elsewhere. If the real terminal caret cannot
be made stable under concurrent rendering, the implementation may hide the real
caret and draw a simulated caret inside the editor. The user-facing contract is
that the caret is visually anchored to the editor and typing always affects the
editor.

## Rendering Ownership

Terminal rendering is a shared concurrent system:

- keystrokes redraw the prompt editor,
- token usage and API timers redraw the token bar,
- reasoning updates redraw the thinking ticker,
- API and tool output append to scrollback,
- prompt height changes move the scrollback boundary.

These operations must be concurrent and must not disturb each other.

The implementation must have one owner for terminal layout. Individual features
must not independently issue cursor movement, screen clearing, scroll-region
changes, or footer repaint sequences that can conflict with other features.

Valid render operations are:

- append ordinary content to scrollback,
- set or clear the thinking ticker,
- set the token bar text,
- mutate the editor buffer or cursor,
- recompute and apply fat prompt layout,
- render one atomic frame containing all changed regions.

Invalid render operations are:

- clearing from the prompt row as a way to make room for output,
- replaying tool output to repair a footer,
- painting token bars with relative cursor guesses,
- allowing tool/API output to write into any reserved token bar or editor row,
- leaving the terminal cursor outside the editor after a render tick,
- using a scroll-region change that is not coordinated by the layout owner,
- relying on byte-level timing assumptions between independent writers.

## Frame Ticks

The renderer should group concurrent changes into ticks. A tick is the smallest
observable visual update.

A single tick may include, for example:

- several keystrokes applied to the editor,
- one token bar timer update,
- one thinking ticker update,
- a scrollback boundary change because the editor wrapped to a new line.

The result of a tick is one complete terminal frame. Intermediate partial
states inside a tick must not be visible. If synchronized terminal output is
available, it should be used for atomic frame presentation, but correctness
must come from the renderer model rather than from terminal-specific luck.

## Scrollback Contract

Scrollback is append-only.

The token bar and editor reserve physical visual rows. They are live chrome, not
scrollback content. They must not remain in scrollback after exit unless they
have intentionally been converted into ordinary transcript content, such as a
final token receipt.

When the fat prompt grows, existing scrollback moves up. When it shrinks,
existing scrollback moves down. This movement must preserve line order and must
not duplicate, erase, or reorder content.

Tool output is scrollback content. It must appear once. It must not be replayed,
duplicated, or erased as a side effect of footer repair.

Streaming assistant output is scrollback content. It should appear as response
chunks arrive, preserving the existing markdown handling. Markdown rendering may
buffer internally until it has enough content to render correctly, but the UI
contract remains live streaming rather than only end-of-response rendering.

Streaming bash tool output is also scrollback content, with a live bounded
viewport during command execution. While the command is running, display at most
eight lines of bash output: the bottom seven output lines plus a cutoff hint at
the top when older output is hidden. After the tool completes, the final tool
output is committed once to scrollback. It must not be duplicated by viewport
cleanup or footer repair.

All non-bash tool output is scrollback content and follows the same append-once
rule.

## Transcript Items

The transcript is a sequence of items. Each item starts with a leading marker:

- `❯` for user prompts,
- `●` or another response bullet for LLM responses,
- `$` for bash tool calls,
- `r` for read tool calls,
- `w` for write tool calls,
- `p` for patch tool calls,
- other tool-specific bullets where already established.

Each API call ends with a token receipt representing what that API call
returned. The receipt is ordinary transcript content, not live prompt chrome.
There is no blank line between the last output of the API call and its token
receipt.

Between transcript items there is always exactly one newline. That means:

- one newline between a user prompt and the next LLM response,
- one newline between an LLM response and the next tool item,
- one newline between a tool item and the next LLM response,
- one newline after an API token receipt before the next item,
- one newline between the last transcript item and the top of the fat prompt.

There must not be extra blank rows inserted as a side effect of spinner setup,
tool viewport setup, receipt rendering, or prompt height changes.

## Harness Messages

Harness messages are output from the controller itself, not from the model
or a tool. Examples: `interrupted by user`, cancel confirmations, api retry
notices, and other controller-side status. They are plain text: no bullet,
no indent. They must not compete with the fat prompt for output lines; the
fat prompt owns its rows. A harness message occupies exactly one ordinary
scrollback line and then returns control to the prompt.

Neutral harness messages (interrupts, cancels) are unstyled plain text.
Error/warning-class harness messages (api retry notices, transport errors)
use non-bold magenta to flag the user without competing with transcript
content. In both cases there is no leading bullet and no indentation.

Because harness messages carry no leading marker, they are visually distinct
from transcript items (which always carry a leading bullet). An interrupt
has exactly one response procedure regardless of how many triggers can fire
(Ctrl-C, ESC, other). That procedure emits the harness message once, clears
the interrupt flag, and returns control to the prompt.

Api retry notices come from the transport layer (`api.nim`) but are reported
through a controller-registered hook (`retryNotice`), never written directly
to stderr. They land in scrollback as harness items and are not persisted to
the `.3log` session transcript, like `:commands`: they are controller
feedback, not conversation messages.

## Exit Contract

On normal exit:

- live prompt chrome is removed or converted into final ordinary prompt state,
- scrollback remains readable,
- terminal modes are restored,
- the terminal cursor is visible,
- no hidden scroll region or bracketed-paste mode remains active.

On interrupt or signal exit, terminal restoration has priority over cosmetic
cleanup.

## Testing Strategy

Low-level isolated tests may assert byte sequences. These are appropriate for
pure emitters such as token bar formatting, ANSI helpers, and narrow rendering
utilities.

Functional visual tests must not rely primarily on byte-sequence assertions.
They must record full terminal frames and analyze the resulting screen states.

The existing expect-style PTY language should remain part of the testing
toolkit, but it must grow a video-like frame recorder:

- every screen-changing update is captured as a full frame,
- frames are grouped by render tick when possible,
- unchanged time is compressed,
- every changed visual state is retained,
- output can be written to a plain text artifact with frame separators.

The artifact should be simple enough to inspect by eye. A failing test should
produce a readable sequence of screens, not only raw escape bytes.

## Functional Test Requirements

The main visual flow test should run a brief full interaction using the stub
provider. It should include:

- startup,
- a normal prompt submission,
- an API wait with spinner/token timer updates,
- buffered typing during the API wait,
- multiline buffered input,
- history navigation or prompt edits that change editor height,
- visible thinking ticker updates,
- multiple tool calls,
- tool output while the editor remains active,
- final assistant content,
- the buffered prompt being submitted after the current turn,
- normal exit.

Assertions must cover whole frames, not only selected substrings. They must
detect:

- prompt rows jumping,
- caret appearing outside the editor,
- token bar overwriting scrollback,
- editor rows overwriting scrollback,
- scrollback lines disappearing when prompt height grows,
- scrollback lines failing to return when prompt height shrinks,
- duplicated tool output,
- random full-screen clears,
- stale ticker text,
- stale token bars,
- transient invalid frames between otherwise valid states.

The test output stream should be acceptable for LLM-assisted and human visual
review: a sequence of full-screen text frames separated by clear delimiters.
The implementation should be adjusted until the recorded frame stream conforms
to this document.

## Migration Rule

Existing byte-level functional tests are fair game for removal or replacement
when they encode the old renderer behavior. Keep byte-level tests only for
isolated low-level rendering functions where bytes are the actual API.

The acceptance target is not "does this byte sequence match an old helper." The
acceptance target is "does every recorded frame satisfy the fat prompt and
scrollback contract."
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
