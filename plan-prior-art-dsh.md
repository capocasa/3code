# Prior art: DeepSeek Harness ("everything is a plugin")

Status: **capture + comparison**, feeds the plugin plan. Sources: the
official repo README and `docs/architecture.md` (read directly), plus
two source-file docstrings surfaced by code search. dsh is a developer
preview that promises breaking changes; details below may churn.

## What it is

`dsh` (github.com/deepseek-ai/deepseek-harness, ~217k stars) is
DeepSeek's open-source agent harness built on **Cordis**, a JS plugin
framework (from the Koishi chatbot lineage; there is even a paper, "A
Programming Paradigm for Spatiotemporal Composability"). TypeScript,
runs from npm, ships web UI / headless / SDK / ACP profiles plus an
Electron desktop app.

## How it works

**Plugins contribute services, typed events, and reversible effects to
a shared `ctx`.** There is no privileged core: the model adapter
(`ctx.llm`), tool registry (`ctx.tools`), session log, sandbox, and the
agent loop itself are plugins, each replaceable from configuration.
Registrations unwind when their plugin unloads (live reload in dev
profiles).

**Composition is layered patches.** A *profile* (named composition in
the harness home) stacks *bundles* (config rows + code, each patchable
by layers above): bundles in order, then the profile's
`cordis.patch.yml`, then a home-level patch, then `--patch` overlays.
`dsh --profile web --dump-config` prints the tree; any row can be
replaced by a patch.

**Events are the extension points**, in three domains:

- *session events*: durable facts in the append-only log ("model-visible
  means logged" is a runtime invariant; anything a model saw must be
  reconstructable from the log),
- *agent events*: live interception of steps, streams, requests;
  several are **waterfalls** where listeners call `next()` to delegate
  (middleware chains, including rewrite and reject at `agent/pre-step`),
- *capability events*: policy and adapters on seams (`fs/*`, `tools/*`,
  `telemetry/*`).

**Capability seams** are swappable capabilities with three roles:
Service Definition (interface), Service Provider (implementation),
Consumer (usually a model-facing tool). The payoff: point the fs +
subprocess providers at a remote sandbox and Bash, PTY, and LSP all
move with it, no forks. Subagents are a seam too (providers range from
a child agent to a whole delegated turn in Claude Code or Codex).

**The extension table** (their "where new behavior goes"): new model on
`ctx.llm`; model-facing capability on `ctx.tools` (schema joins prompt
assembly); human command on `ctx.commands`, dispatched without a model
turn; background work on `ctx.jobs`; filesystem/policy on `ctx.fs`;
sandbox backends on `ctx.sandbox`; model-visible context via
`agent.inject()`; durable state by extending the session event map.

**MCP is a bridge plugin, not core**: one plugin instance per server,
registering tools as native `mcp__server__tool` names. So the schemas
join the per-request tool schema assembly, the standard (expensive)
way. The community also built the inverse (expose dsh plugins to MCP
agents as an MCP server).

**Code Mode** (`run_code`, flagged experimental): the model writes a
TypeScript program against a generated API over the tools; the program
runs in a sandboxed runtime and *only what it prints or returns enters
model history* (nested executions are logged for reconstruction).
Rationale (from their notes, echoing Cloudflare's Code Mode proposal):
models have seen millions of lines of real code and few contrived
tool-calling traces, so code composes better than schema-bound calls.

## What it validates in our design

- **Events as the extension points**, with a sync pre- veto/rewrite:
  their `tools/pre-execute` waterfall is our `tool.pre`.
- **A human command layer that dispatches without a model turn**:
  their `ctx.commands` is exactly our `registerCommand`.
- **"Model-visible means logged"**: our discipline that plugins touch
  text (skills, tool results, transcript) and never the message array
  is the same invariant, held more conservatively.
- **The plugin architecture is an adoption magnet**: `dsh-plugin` as a
  discoverability topic, 217k stars in preview. For "3code as the new
  vim", the seam set matters more than any one mechanism.

## Where we deliberately differ

1. **No privileged core vs privileged core.** dsh is the Emacs end of
   the spectrum: the loop itself is replaceable, which requires a
   composition substrate (Node + Cordis) and shows the cost: breaking
   changes promised, 16k commits of coherence work. 3code is the vim
   end: a small privileged core (conversation, editor line, event
   loop, fixed tool surface) with thin, vetted seams. Both ecosystems
   can thrive; they are different bets.
2. **Schema assembly vs zero schema.** dsh's MCP bridge pays per-call
   schema tokens and answers the cost with Code Mode. We answer it
   before it exists: capabilities are CLIs the model drives through
   bash and learns from skills, so there is nothing to assemble. The
   convergence is the interesting fact: both arrived at "the model
   composes capabilities as code, not as schema-bound calls". Our
   `mcpwrap` decision stands, now with an existence proof that the
   schema path needs a remediation layer.
3. **Message injection.** `agent.inject()` is convenient and a
   prompt-injection surface; we keep refusing it for plugins in v1.
   Their own invariant suggests the v2 shape if ever needed: injection
   as a logged, visible event.
4. **Layered patch composition.** Genuinely good, and overkill for
   3code's size. We take the ordering discipline only: plugins load in
   declared order, and hook chains run in load order.
5. **HMR/reversible effects.** A JS-runtime luxury; our crash guard
   and load markers are the honest Nim equivalents.

## What we steal outright

- **Waterfall ordering for `tool.pre`**: if multiple plugins subscribe,
  they run in load order as a chain; a veto short-circuits and names
  the plugin. (Our rev 2/3 text implied single-listener; correct it.)
- **A discoverability convention** for the ecosystem: a
  `3code-plugin` repo topic, same as `dsh-plugin`.
- **Subagents as a future seam**: calling another agent (or another
  3code) as a capability belongs in the conceived-plugins list, not in
  v1 core. Their subagent provider range (child agent to delegated
  Claude Code turn) is the design to study when we get there.
