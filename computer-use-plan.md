# Computer Use in 3code — implementation plan

Goal: 3code gains *vision* — the model can see images (user-attached, files in
the repo, screenshots it takes) and drive mouse/keyboard from a session, with
3code's token economy intact: zero system-prompt growth when idle, images
delivered only when used. Computer use is one consumer of the general image
pipeline; `@image` attach and `read`-an-image are the other two.

## 1. What ZCode actually does (verified, not docs-claims)

Source: `zcode-app-cli` 3.11.2-22 (npm latest, extracted to `~/3/zcode/pkg`;
the user install at `~/.local/lib/node_modules/zcode-app-cli` is 3.8.1-15,
which predates Computer Use). Evidence gathered by running the CLI against a
mock OpenAI-compatible endpoint and by speaking MCP to the plugin server
directly (`tools/list`).

### Architecture

- Computer Use is a builtin plugin: `computer-use@zcode-plugins-official`,
  version 0.5.14, MIT. Two components:
  - an MCP stdio server (`dist/mcp/server.js`, Node + koffi FFI + sharp for
    raster work) exposing **30 tools**: observe/resolve (list_apps,
    open_application, list_windows, get_app_state, screenshot, zoom,
    list_displays, switch_display, cursor_position), pointer (left_click,
    double/triple/right/middle_click, scroll, left_click_drag, mouse_move,
    left_mouse_down/up), text/keyboard (type, set_value, select_text, key,
    hold_key), semantic (perform_action), runtime (request_access,
    stop_computer_control, wait, read/write_clipboard).
  - a skill (`skills/computer-use/SKILL.md`, 8,720 chars) teaching the
    observe→act→verify loop and the rules below.
- **Accessibility-tree-first, pixels as fallback.** `get_app_state` returns a
  filtered a11y tree; element actions (`{"type":"element","state_id","index"}`
  targets) are the primary path: semantic, precise, and background-safe (no
  focus steal). Pixel `{"type":"coordinate","x","y"}` targets are allowed only
  against the latest returned raster; the server binds the raster to native
  coordinates itself. No normalized 0-999 box_2d on the wire here — that was
  the older GLM-V action space.
- Hard-gated by the desktop app. The MCP server only spawns with broker
  credentials (`ZCODE_CUA_PERMISSION_BROKER_SOCKET/TOKEN`,
  `ZCODE_CUA_PLUGIN_AUTHORITY`), which only the ZCode desktop injects. Verified
  headless: `plugins enable computer-use` changes **nothing** on the wire (see
  measurements). Subagents are denied CUA outright
  (`SUBAGENT_COMPUTER_USE_UNAVAILABLE`).
- Safety rules baked into the skill: `action_sent=true` may already have
  happened, never blind-replay; default result is an action receipt, not a
  fresh observation; fail-closed on permission/stale-frame refusals; macOS
  file-panel recovery dance; kill switch `stop_computer_control`.
- The runtime also speaks Anthropic-native computer tool types
  (`computer_20250124`, `computer_20251124`) with beta headers when a
  provider supports them — that path exists but is not what the CUA plugin
  uses.

### Does it increase system prompt size? NO — measured

Headless CLI, plugin enabled vs disabled, identical `-p "..."` run, mock
endpoint capture:

| item | plugin off | plugin on |
|---|---|---|
| system message | 8,747 chars | 8,747 chars (byte-identical) |
| skills `<system-reminder>` (user msg) | 5,466 chars | 5,466 chars, no computer-use entry (broker absent → dormant) |
| tools array | 19 tools / 35,293 chars | 19 tools / 35,293 chars |

When actually active (desktop with broker), the cost lands **outside** the
system prompt:

- +30 MCP tool schemas on every request: **61,879 chars ≈ 15.5K tokens**
  (measured via `tools/list`; largest: open_application 7,238,
  left_click_drag 4,278, type 3,758, get_app_state 3,512).
- +1 line (~300 chars) in the skills system-reminder.
- +SKILL.md body (8,720 chars) injected into the conversation on invocation,
  once.

Skills are surfaced as a user-message `<system-reminder>` list, loaded on
demand via the `Skill` tool — progressive disclosure, same pattern as Claude
Code. The system prompt itself never grows.

### Takeaway for 3code

ZCode's design confirms the shape we want: no standing prompt cost, deferred
activation, tool schemas only while live. But 30 tools at 15.5K tokens is the
opposite of 3code's economy, and the a11y-first machinery (koffi FFI, broker,
window ids) is a desktop-app-scale investment. 3code should ship the pixel
path only, one tool, and let the bash tool remain the escape hatch
(xdotool etc. already work for blind actions; what's missing is *eyes*).

## 2. Design

### CLI-first: one tool for eyes, `shot` for hands

The model is not trained on MCP — MCP is client-side packaging; the model
only ever sees flattened function schemas (verified: ZCode's CUA tools reach
the wire as plain OpenAI tools). GLM's CUA training pattern is screenshot-in,
structured-action-out. So computer use needs exactly one thing bash cannot
do — return an image into the conversation — and everything else can be a
command line the model already knows.

**Core tool: `screenshot()`** (only new tool, ~500 chars schema). Captures,
re-encodes, delivers one image block. No action enum, no coordinate params.

**Hands: a `shot` companion CLI** the harness writes into the session (a
single self-contained script, prepended to PATH for the bash tool). Every
subcommand takes coordinates in the space of the LAST DELIVERED raster and
the wrapper owns the native transform — ZCode's frame-binding contract as a
shell tool:

```
shot click 640 360        # left click at delivered-raster coords
shot doubleclick|rightclick|middleclick X Y
shot drag 100 100 400 400
shot type "hello world"   # types into current focus
shot key ctrl+s | shot key enter
shot scroll up 3 | shot scroll down 5
shot title                # active window title + native geometry + scale
```

- The wrapper reads the last capture's scale factor from a state file the
  `screenshot` tool writes (session dir); stale-state (no capture yet, or
  screen resolution changed) is a loud error telling the model to call
  `screenshot()` first. This is the frame-registry idea, one file.
- Implementation: bash + xdotool on X11, bash + cliclick/osascript on macOS
  — no FFI, no Node, no MCP server.
- The model drives blind actions with raw `xdotool` too if it wants (it
  knows xdotool well from coding-agent training); `shot` exists purely so
  vision-derived coordinates never need scale math.
- Kill switch stays social: Esc interrupts the turn; the skill doc says to
  stop when the task is done. No `done` action needed since there is no
  control session to stop.

### Eyes: image blocks, provider-safe — the general capability

3code has no image pipeline today (`api.nim` message content is strings
everywhere; prompts.nim even says "a terminal model cannot by itself inspect
an image"). One wire change serves three entry points:

- **User attach**: `@path.png` in the prompt. `inlineAtFiles` (ui.nim)
  already resolves @files; an image file + vision profile attaches as an
  image block instead of inlining bytes as text (today's behavior for a
  PNG is capped garbage). Non-vision profile: plain error.
- **Model reads an image**: `read` on an image path returns a text receipt
  ("image 1920x1080, shown below") and the image rides the following user
  message. No new tool; same per-family gating as everything else.
- **Screenshots**: the capture path below. Same delivery.

Plan:

- After the tool-call batch is paired (or immediately for user attach),
  emit a **user message** whose content is an array:
  `[{"type":"text","text":"screenshot 1920x1080 -> 1280x720 (shot 7)"},
  {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,..."}}]`.
  The tool message itself stays text ("captured, shown below"). This works on
  every OpenAI-compatible provider (tool-message image content does not),
  and is the standard pattern of the OpenAI-compat CUA world (browser-use,
  trycua, OSWorld-style loops); Anthropic/OpenAI-native harnesses put the
  image inside the tool result — a mapping detail if we ever add an
  Anthropic-protocol transport.
- Responses-API path (`responsesInput`): translate that user message into
  `input_text` + `input_image` items.
- Encode **JPEG, quality 85** (ZCode ships q75 with a byte budget; q85 buys
  back small-glyph fidelity for text-dense screens), chroma 4:2:0, in a
  **190 KB base64 budget** with the same shrink ladder ZCode uses: quality
  −15 steps to a floor of 40, then downscale ×0.8 (min edge 320) until it
  fits. PNG behind a `fidelity` flag for when the model reports unreadable
  text. No new Nim deps: capture via platform tool, resize with
  `import -resize`/`sips -Z`, base64 via `std/base64`; the delivered size
  always lands in the state file for `shot` to map back.
- Prompt-cache note: each screenshot is a new user message, which is the
  natural cache-append point anyway; nothing before it changes.

### Activation and cost discipline

- Off by default. `:computer` toggles; also `--computer` flag and a config
  line for tests. On activation:
  - the `screenshot` tool is appended to the offered tools for subsequent
    requests in this session (tools array change = one-time cache bust,
    accepted and logged in the transcript),
  - a one-time user system-note (~1.5K chars, the 3code-flavored skill
    text: observe→act→verify, never replay a sent action, coordinate
    discipline, `done` to stop) is appended — the dmail pattern, not a
    system-prompt edit,
  - the standing cost before first activation is **one skills-catalog
    line** (`computer-use.md` in the builtin skills dir), ~80 chars.
- Vision gating: the tool is only offered when the active profile's model is
  vision-capable. Add a `vision: bool` to the knownGood table entries (or a
  companion set of model ids); seed with glm-5.3-flash entries and the
  deepseek flash-vis entries. Non-vision profile + `:computer` → clear error
  naming vision-capable models.
- Flail detector already covers doom loops; screenshot result tokens make
  loops expensive, so add `screenshot` to the streak fingerprint trimming.
  Cap consecutive screenshots without an intervening action at 3 per turn
  with an injected note (ZCode's SKILL makes the same point prose-only).

### Backend: `src/threecode/screen.nim`

Platform procs behind one interface, external binaries probed at activation
(and named in the error if missing):

| capability | X11 (phase 1) | macOS (phase 1) | Wayland (phase 2) | Windows (phase 3) |
|---|---|---|---|---|
| capture | `import`/`maim`/`scrot` (first found) | `screencapture -x` | `grim` | PowerShell .NET |
| pointer | `xdotool` | `cliclick` (or osascript) | `ydotool`/`wtype` | .NET SendInput |
| keyboard | `xdotool type/key` | `cliclick`/osascript | `wtype` | .NET SendInput |
| window title | `xdotool getactivewindow getwindowname` | `osascript` | wlr foreign-toplevel | .NET |

The dev machine is X11 with xdotool + import (per `.agents/osx-testing.md`
the macOS path needs the stefani VM for verification; do not claim it green
without that). Every action echoes a transcript banner (`• click (340,512) →
firefox — file.md`) so the user always sees what the agent did to their
desktop.

### Safety

- No sandbox for these actions — controlling the desktop is the point; say
  so in the activation banner.
- Session-scoped only: activation never persists into the session file as
  auto-on; resume restores the transcript but the tool stays off until
  `:computer` again.
- Esc/Ctrl-C already interrupts the turn (signals.nim); document as the
  panic button. `computer(action="done")` for the model.

### Persistence

Screenshots go to `<session-dir>/shots/NNN.png`; the message stores the path
plus a sha1. On resume, images are dropped and replaced by a one-line note
("shot 7 omitted: stale") — matches 3code's discard-stale-context stance and
keeps session files small (no base64 in JSONL).

## 3. Implementation phases

Phase 0 — the image pipeline (general capability, no behavior change to
existing sessions)
1. `api.nim`: user messages with content arrays (text + image_url blocks)
   on the chat wire and the Responses translation (`input_text` +
   `input_image`); unit-test both shapes against `tests/mock_server.nim`.
2. `prompts.nim`: knownGood table gains a vision flag; glm-5.3-flash and
   deepseek flash-vis entries seeded.
3. `ui.nim`: `@image` attach — `inlineAtFiles` branches on image
   extensions when the profile is vision-capable; the user message becomes
   a content array. Non-vision: explicit error text in-message.
4. `actions.nim`: `read` on an image path (vision profile) returns the
   receipt; `turns.nim` appends the image user-message. `akScreenshot` joins
   `ActionKind` here (no extra fields needed).
5. Encode-under-budget helper (JPEG q85, ≤1280 long edge, 190KB base64
   budget, shrink ladder, PNG fidelity flag) — shared by all three sources.
6. Build + full test suite green; mock-server test proves a `read
   logo.png` round trip delivers an image block on the next request.
   Commit. This phase alone ships "3code can see" and is useful without
   computer use.

Phase 1 — X11 backend + tool loop
7. `screen.nim`: capture via the shared encode helper, state file (native
   geometry, delivered geometry, scale), `shot` script generation. Probe
   binaries at activation; string errors, no exceptions across the boundary.
8. `actions.nim`: `screenshotAction` parse + `runAction` branch executing via
   screen.nim **outside the wall proxy** (same exemption as web_fetch — a
   capture must reach the real X server). The `shot` script itself runs as
   an ordinary bash tool call; the wall proxy must allow it (xdotool needs
   DISPLAY, which the sandbox already passes for GUI-adjacent commands —
   verify, else exempt `shot` like web_fetch).
9. `turns.nim`: screenshot tool result pairing + image user-message (same
   code path phase 0 built for `read`); transcript banner per capture.
10. `ui.nim`: `:computer` command (on/off/status), config line, `--computer`.
11. Tests: unit (coordinate mapping, state staleness), tty visual (banner,
    activation note, `:computer` echo), and one mock-server end-to-end:
    model calls screenshot → assert request N+1 contains an image_url
    block. Commit.

Phase 2 — model-facing polish
12. Activation system-note text (port the load-bearing rules from ZCode's
    SKILL.md: no replay after a sent action, observe→act→verify, coordinate
    discipline — coords are always delivered-raster pixels, `shot` maps,
    never do scale math) + the `shot` cheat sheet.
13. Consecutive-screenshot cap + flail integration.
14. Skills-catalog line + builtin `computer-use.md` skill doc.
15. Real-model shakedown on GLM-5.3-flash: vision first (@image attach +
    `read` on an image: reproduce a UI from a reference screenshot), then
    the docs' closed-loop
    recipe (open an app, inspect, recreate, compare) in an xterm session;
    screenshot the xterm per `.agents` ground rules (real window, non-empty
    capture) — a green ttty frame alone proves nothing here, the subject is
    a GUI. Verify the model actually prefers `shot click` over raw xdotool
    with vision coords; if it fights the wrapper, reconsider a single
    `computer` tool with an action enum (fallback design, previous revision
    of this plan).

Phase 3 — platforms
16. macOS via stefani VM (screencapture + cliclick), verified there.
17. Wayland (grim + ydotool), Windows last (.NET), each with its own probe
    and visual test.

## 4. Token budget summary (per session, GLM-5.3-flash pricing)

| state | cost |
|---|---|
| idle, never activated | ~80 chars (skills line) |
| at activation, once | ~1.5K chars note + `screenshot` tool schema ~500 chars per request |
| each screenshot | image tokens (≤1280px JPEG in a 190KB budget; ≈ 1-2K tokens by GLM vision patching) + ~40 chars text |
| each action | one bash call the size of the command itself |

Compare ZCode: 15.5K tokens of schemas per request once active. Our whole
tool surface is 1/30th of that.

## 5. Open questions

- Does Z.ai's OpenAI-compatible endpoint accept `image_url` in *user*
  messages during tool loops reliably at scale? (Docs say yes for content
  blocks generally; verify with a real 5.3-flash run in phase 2 before
  polishing.)
- JPEG q85 vs q75 on text-dense screens — measure glyph readability at
  1280px on both before settling; the fidelity/PNG flag is the escape hatch.
- Whether to offer `zoom` (sub-rect re-delivery) — cheap via the same
  capture path with a crop flag; skip until the model asks for it in the
  field.
- Wall proxy interaction: does the sandbox pass DISPLAY to bash so `shot`
  works unprivileged, or does it need the web_fetch exemption pattern?
  ANSWERED (phase 1): DISPLAY passes through the sandboxed bash child and
  the X socket under /tmp is reachable — verified by the PTY test, whose
  stale-frame error text came from xdotool's live getdisplaygeometry
  running inside the sandbox. No exemption needed for `shot`; the capture
  itself runs in-process (the web_fetch standing exemption).

## Appendix: phase 1-3 shakedown record (2026-09-09)

Phases 1-3 landed on branch `vision` (X11 backend only). What was verified
without live keys, and what still needs a real model.

**Verified, unit** (`tests/core/test_screen.nim`, `shot` executed against a
stubbed xdotool — no X server in the loop): delivered→native mapping
(`click 640 360` at 1920x1080/1280x720 → `mousemove 960 540 click 1`),
rounding, edge clamping, button mapping (1/2/3, doubleclick repeat), drag
mapping both endpoints, `type`/`key`/`scroll` passthrough, `title`
geometry+scale; stale-frame contract (missing state file, resolution
change, missing xdotool — all loud errors naming `screenshot()`), unknown
subcommand vocabulary. Receipt/banner round trip; capture seam
(`THREECODE_SCREENSHOT_SRC`) delivers indexed files that never overwrite
and binds state; fidelity flag delivers PNG.

**Verified, real screen** (manual run on this machine, X11 + scrot +
xdotool): `ensureComputerUse` probe passes, capture falls through the
present-but-broken `import` to `scrot` (attempt-based fallback works),
1920x1080 → delivered 1280x720 JPEG, state `native=1920x1080
delivered=1280x720`.

**Verified, stub-provider e2e** (`tests/api/test_vision_screenshot.nim`):
config `computer = on` arms on the first turn (activation note enters the
conversation, `shot` materializes, schema joins `activeTools` only when
armed+vision-capable+probed); model `screenshot` → text receipt, no
base64 anywhere; follow-up user message carries an `image_url` block that
embeds the byte-identical delivered file; frame state written; 3-capture
consecutive cap injects the note and skips execution; gating errors
(not-enabled, non-vision).

**Verified through the real binary in a PTY**
(`tests/tty/test_computer_shot.nim`): the scripted model calls
`screenshot` (seam) — `· shot 16x12 -> 16x12` banner renders — then drives
`shot` through the REAL sandboxed bash tool: the child reads+execs the
script and state under the temp dir, DISPLAY passthrough works (the
stale-frame error came from live `xdotool getdisplaygeometry` inside the
sandbox). Sweep after phase 1: 62 PASS, 0 FAIL (core api config shell
stream); known pre-existing tty failures untouched.

**Live-model shakedown (plan step 15): NOT RUN.** The dev sandbox for this
worktree denies reading `~/.config/3code/config` (the main worktree
allowlists it; this one has no policy file), so no live keys were
available. Remaining probes, from a terminal with the real config, in this
worktree:

- vision first:
  `./build/3code -m zai.glm-5.3-flash "@testdata/images/ui-mockup.png describe this UI, then rebuild it as HTML"`
  — prove pixel-level detail arrives (image_url accepted in user messages
  during tool loops; open question 1), note the prompt-token delta per
  image from the receipt.
- computer-use loop: same model, `:computer on`, then `open an xterm, look
  at it, and reproduce its geometry in a HTML file; verify` — verify the
  model prefers `shot` over raw xdotool (plan step 15's fallback-design
  trigger), that observe→act→verify actually happens, and the per-capture
  token cost from the receipt.
- repeat both on a `deepseek-v4-flash-vision-exp` hosting.

**Token-per-image measurements: PENDING** those probes; budget with the
wire size (≤190 KB b64, ~48 KB JPEG typical) until measured. JPEG q85 vs
q75 glyph readability at 1280 px (open question 2) also unmeasured; the
`screenshot(fidelity=true)` PNG path is the escape hatch.

**Platform status (phase 3)**: X11 only. macOS (`screencapture` +
`cliclick`), Wayland (`grim` + `ydotool`) and Windows (.NET SendInput) are
NOT implemented — arming fails with a named, not-implemented-here error
(compile-checked for macosx/windows via `nim check --os:…`, not
run-verified). macOS needs the stefani VM per `.agents/osx-testing.md`;
claim nothing until run there.

**Decisions recorded**: no `# Images` system-prompt sentence for computer
use — the one-time activation note is the single source (a second surface
would bust the cache twice); `shot` + state live under the temp dir (the
one path every bash sandbox policy must leave readable — the bash tool's
own scripts run from there); the capture runs in-process, outside the wall
(web_fetch's standing exemption); resume keeps the tool off (runtime-only
`Session.computerActivated`, nothing persisted auto-on).
