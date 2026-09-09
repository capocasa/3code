# Evaluation: pi's 5000 plugins, monoliths, and the Linux driver lesson

Status: **evaluation**, feeds `plan-plugin-system.md`. Sources: pi.dev
extension docs and README (read directly), the pi package registry, one
press piece for the "5000+" count (single source; the registry itself
is real, the exact number is reported, not counted).

## What pi's system actually is

From the primary docs: TypeScript modules loaded in-process (via jiti,
hot-reloadable), auto-discovered from `~/.pi/agent/extensions/` and
`.pi/extensions/`, distributed as npm packages. The `ExtensionAPI` is
*full-surface*: `registerTool` (model-facing tools with schemas),
`registerCommand`, `registerShortcut`, `registerProvider` (OAuth
vendors), system-prompt modification hooks, custom compaction, custom
editors and TUI components (their examples include a modal vim editor,
overlays, snake, Doom), message/entry renderers, `sendUserMessage`
(context injection), tool-call blocking, input transforms. Plan mode,
subagents, SSH execution, and sandboxing all ship as example extensions
or packages, not core. The pitch line is "pi can create extensions.
Ask it to build one for your use case."

So: pi is the Emacs model executed well, with npm as the distribution
gravity and LLMs as the authoring pipeline.

## Is 5000 plugins a good thing?

**For pi, mostly yes, and it is not an accident; it is the product.**
The core is deliberately minimal (no plan mode, no subagents in core),
so the ecosystem is not an appendage, it is the feature surface. The
number proves the API is fertile, publishing is frictionless, and the
"ask pi to build one" loop works. The long tail is genuinely valuable
at the individual level: a personal extension that knows your deploy
script would never be a product feature anywhere. And a big registry
is a moat and a marketing engine, the same way dsh's 217k stars is.

**As an emulation target, no, for four structural reasons:**

1. **The median plugin is the expensive kind.** `registerTool` is the
   headline API: model-facing tools whose schemas ride every request.
   The ecosystem's own top-10 article warns that plugins "eat into
   context window". For the token-economy agent, a registry whose
   primary plugin class is schema-per-call is a denial-of-wallet
   reservoir. (dsh has the same shape; our CLI+skills tier is the
   structural fix.)
2. **In-process full-trust npm packages at 5000 scale is a supply-chain
   surface nobody audits**: typosquats, prompt-installed extensions,
   LLM-generated code with confident bugs. pi's own docs lean on
   trust prompts and a `project_trust` event, which is the right
   instinct but does not scale to the registry's tail.
3. **API freeze by install base.** A full-surface in-process API
   (editors, renderers, compaction, prompts) becomes load-bearing the
   moment 5000 packages reach through it. That is the Emacs burden:
   rich seams, decades of compat shims. It works while the API is
   young and churning; it is a mortgage, not a gift.
4. **Power law and fragmentation.** 5000 means perhaps 50 excellent,
   500 usable, thousands abandoned or duplicated; every user reassembles
   a different product. The registry count is a vanity metric; what
   users experience is the top 50 and the friction of finding them.

## The Linux driver analogy, properly drawn

The analogy is sharper than it looks, because Linux is not the
"monolith vs plugins" answer; it is the *tiered* answer:

| Linux tier | mechanism | quality model |
|---|---|---|
| in-tree drivers (the overwhelming majority) | one repo, one build, **no stable internal ABI** (`Documentation/process/stable-api-nonsense.rst`: upstream your driver or it breaks) | code comes to maintainers; review and testing happen at merge; internal APIs churn freely |
| out-of-tree binary drivers (`.ko` binaries, vendor) | tolerated, unsupported, famously painful (NVIDIA for two decades, and even it capitulated to open kernel modules) | vendor owns quality; kernel team refuses the compat burden |
| user-space drivers (FUSE, libusb) | slow paths, untrusted authors | isolation instead of review |

The kernel's core move: **plugins socially (thousands of authors),
monolithic technically (one build, unstable internals)**. The result is
that hardware support, the most unbounded variance an OS faces, became
Linux's moat. The pole Linux refused is the stable rich ABI for
out-of-tree code, which is exactly what Windows carries (WHQL
certification, vendor binaries, BSOD blame diffusion). The pole the
microkernels took (drivers as out-of-core services, Hurd's eternity)
buys fault isolation at coordination cost; it works where partitioning
is the requirement (QNX, seL4), and it lost the mainstream desktop.

Mapped to agents:

- pi = out-of-tree source against a rich internal API (the model Linux
  refuses), plus npm distribution, plus LLM authorship.
- dsh = the microkernel bet (no privileged core, Cordis composition).
- vim/Linux = privileged core + narrow seams + in-tree source tree.
- 3code's rev 3 plan = privileged core + narrow vetted seams (seven
  host services, not forty API methods) + a text long tail. Missing
  piece: the in-tree tier.

## Verdict and the one plan change

**Neither pole wins; tiers do.** The monolith is right for everything
high-integration and model-visible (our frozen tool surface, the goal
loop, compaction, prompts). Plugins are right for genuine unbounded
variance (vendors, policy, personal workflow). The failure modes to
avoid are pi's (in-process full-trust long tail, schema-per-call
economy) and the Hurd's (so much substrate the product never ships).

Concretely, fold into the plan:

1. **Promote the first-party in-tree plugin tier** from "deferred" to
   part of the core deliverable: `plugins/` in the 3code repo, Nim
   source compiled with the binary, *no* ABI stability promised
   internally, full test-suite coverage, `lintgate`/`goalkeeper`/
   `tokenmeter` live there. In-tree drivers: the highest-value
   plugins evolve with the core instead of against it.
2. **The `.so` C-ABI tier stays the exception**, not the ecosystem:
   for vendors (auth) and things that cannot upstream. Small surface,
   versioned, crash-guarded, disabled by default. Out-of-tree `.ko`:
   tolerated, never romanticized.
3. **The 5000-plugin phenomenon is welcome, in the text tier.** The
   mass of personal, LLM-authored quirks should land as skills and
   CLIs (the FUSE tier): free, sandboxed by `.sandbox`, zero ABI, no
   context cost until loaded. We want pi's long tail without pi's
   trust and token bill.
4. **Do not chase the registry number.** Success metric is the quality
   of the first-party tree plus a `3code-plugin` topic; a curated list
   beats a 5000-package swamp, and Windows teaches that certification
   is the tax you pay for a binary tier at scale.
