# The vim lesson: what makes vim plugins great, and what 3code takes

Status: **analysis feeding plan-plugin-system.md rev 3**. Trigger: the
question "should we scratch the plugin system and ship configurability
instead?" The vim answer is that this is a false split, and working
through why also tells us which primitives the plugin ABI is still
missing. Scripting language is out of scope: it will be Nim.

## The premise check: config vs plugins is a false split

Vim has no meaningful "settings-only" mode. The reason a vimrc feels
like configuration is that vimscript *is* the plugin mechanism and a
vimrc *is* a script; settings, mappings, and plugins are one continuum.
The knobs that read as settings (`'makeprg'`, `'formatprg'`,
`'grepprg'`, `'keywordprg'`) are all the same shape: a core feature
parameterized by an external command. Behavior beyond that is script.

Translation for 3code: keep shipping settings, but only of the
"parameterize one core feature with an external command" kind, and make
every setting the degenerate case of a plugin primitive. Then core stops
growing bespoke knobs and the question dissolves:

| 3code today | plugin primitive it degenerates from |
|---|---|
| `[shortcuts]` key remaps | keymap registration (same table, writable at plugin load) |
| `notify = off` | `turn.end` hook |
| `[search] engine` | capability plugin (CLI + skill, or mcpwrap) |
| `[provider]` sections | auth plugin |
| (missing) `formatter = "nixfmt"` | `tool.pre` hook (`lintgate`) |
| sandbox policy | stays core: security boundaries are not delegated |

After the primitives land, a new user wish is either a one-line setting
(parameter) or a plugin (behavior). That is the vim equilibrium.

## The ten mechanisms that make vim plugins great

Each: what vim does, the 3code translation, and whether rev 2 has it.

**1. One universal medium: everything is a buffer.** netrw, fugitive
blame, a terminal, a file picker: all render as text in a buffer, so
every editor verb (motions, search, yank, folds) works on plugin output
for free. Plugins never build UIs; they fill the medium.
*3code*: the medium is the transcript item (human side) and the
conversation itself (model side). Skills and tool results already make
model-facing extensibility pure text. The human side is missing a
primitive: **`emitTranscript`, append a committed scrollback block**.
Anything a plugin wants to show becomes a receipt, styled and
scrollable by the existing engine, respecting the append-only contract
in `.agents/design.md`.

**2. Input as a composable language.** Plugins add verbs and objects
(`surround`'s `ds(``/`cs"'`), users rebind everything; mappings are the
user-facing API. *3code*: `[shortcuts]` is the config tier; plugins
need write access to the same table at load. The model-side verbs
(tools) stay frozen on purpose: models are trained on the fixed
surface, and capabilities are commands (rev 2 layer 1). Plugin
richness goes to the human side.

**3. Autocommands, including Pre variants that transform or deny.**
`BufWritePre` formatters, `FileType` settings, `CursorHold` lint.
*3code*: the event set, with `tool.pre` as the sync veto/rewrite.
Have it.

**4. The ex command layer.** `:command -nargs=* -complete=customlist`
gave plugins a uniform, discoverable, completable namespace; fugitive
lives there. This is vim's most *used* extension surface and rev 2
lacks it entirely. *3code*: **plugins register `:` commands** with a
completion spec**;** `:usage`, `:session pick`, `:plugin stats`.

**5. UI as data, not draw calls.** statusline is `%{fn%}` evaluated
strings; `vim.ui.select`/`input` are provider patterns where the plugin
asks and the UI answers. *3code*: `setBarText` (have) and `askUser`
(have; it *is* `vim.ui.select`). Plugins never draw.

**6. Standard interchange objects: quickfix + errorformat.** Any
tool's output becomes a navigable position list; linting plugins
compose instead of each building a UI. *3code*: adopt a textual
convention, not an API: plugin-issued issues are emitted as
`path:line:col: message` lines. Today that is just readable; tomorrow
`:next`-style navigation and `:transcript grep` work across all
plugins for free.

**7. Tool-parameter settings.** `'makeprg'`, `'grepprg'`,
`'formatprg'`, `'shellpipe'`: core features, external commands, user
config. The bridge between config and plugins. *3code*: add
`formatter` (the `lintgate` 90% case), and treat future wishes in this
shape first.

**8. Drop-in distribution, conventions over manifests.** A plugin is
files in a directory (`plugin/`, `ftplugin/`, `after/`); package
managers only automate git pulls. *3code*: skills already work exactly
this way (dir scan, first-wins precedence). Harness plugin = one dir
(`plugin.toml` + `.so` + optional `skills/`), `3code plugin add
<path|git-url>` compiles once, cache keyed on source mtime.

**9. The editor owns the interaction; plugins supply data.** Completion
sources, LSP (client in neovim core), statusline functions: plugins
feed, core renders and handles keys. *3code*: core owns the
conversation, the editor line, and the event loop, full stop. Plugins
emit text, answer questions, veto calls.

**10. Deep, read-only state access.** Registers, marks, jumplist, the
undotree: plugins build undotree, mundo, session managers on real
first-class state. *3code*: read-only host queries: last tool result,
running usage totals, session list, transcript tail. Cheap to expose,
generative, no write risk.

## Neovim's five upgrades, translated

1. **Built-in LSP client.** Neovim absorbed the protocol churn once;
   plugins became thin UX over it. *3code*: core (and auth plugins)
   absorb provider/OAuth churn; `mcpwrap` absorbs MCP churn into a
   CLI. Principle: **core absorbs protocols, plugins own UX**. This is
   the strongest independent confirmation of rev 2's "no MCP in 3code".
2. **Treesitter.** Structural primitives exposed once, structural
   plugins everywhere. *3code*: no analog needed; our shared substrate
   is bash + filesystem + skills, which is the point of layer 1.
3. **Async jobs, timers, libuv.** The end of blocking-script jank.
   *3code*: **`host.post(event, json)` from plugin threads + a timer
   service**; only `tool.pre` and `askUser` stay synchronous. Rev 2
   hand-waved this ("plugins keep their own thread"); make it real.
4. **msgpack-rPC, remote plugins, ext-UI.** Out-of-core plugins that
   look native; the UI as a separate process. *3code*: we chose
   in-process, and refuse ext-UI for now, but keep the API shape
   lesson: what made remote plugins work was calling *into* core and
   being called back with data, not where the code ran. And because
   everything a plugin shows is transcript text (mechanism 1), a
   future UI split stays possible without an ABI break.
5. **Provider patterns (`vim.ui.select`).** Any plugin can ask, any UI
   can answer. *3code*: `askUser` now; letting plugins *override* the
   ask renderer is a v2 nicety, not a v1 need.

## The conceived-plugins list, revisited through the lens

| plugin | vim/neovim lineage | validates |
|---|---|---|
| `github` via mcpwrap | **fugitive**: wrap the CLI, don't speak the protocol in the editor; fugitive shells out to git and renders buffers | layer 1, no-MCP |
| `lintgate` | autoformat via `BufWritePre` + `'formatprg'` | `tool.pre`; also argues for the `formatter` setting |
| `approve` | `:confirm` dialogs + `vim.ui.select` | sync `askUser` |
| `tokenmeter` | airline/lualine statusline lineage | `setBarText` + async post |
| `testwise` | vim-test + shada (cross-session state) | plugin-owned state + bundled skill |
| `dbguard` | local-vimrc / securemodelines policy plugins | `tool.pre` on bash |
| `secretkeeper` | autocommand output scrubbers | `tool.post` |
| vendor auth | neovim absorbing LSP into core | auth plugins as protocol absorption |

Nothing on the list loses its justification under the vim lens; each
gains a lineage. And the lens generates new ones almost by itself:

- **`:session pick`**: our saved sessions plus the command layer and
  an editor-line list (session-vim lineage).
- **`:transcript grep <pat>`**: quickfix analog; renders matching
  receipts as transcript views. Core command first, plugin-extensible
  later.
- **Quote-last-result key**: a binding that inserts the previous tool
  receipt into the prompt (registers/jumplist lineage); needs a read
  service, mechanism 10.
- **Per-project skill injection on `session.start`**: filetype
  detection analog; a hook that notices the tree is a nimble/nix/docker
  project and drops the matching skill.

## What we refuse, in the spirit of vim

- **Widget toolkits, splits, ext-UI in v1.** Vim's constraint (there
  is only text in buffers) bred the ecosystem; our constraint (there is
  only text in the transcript and conversation) is the same bet.
- **Synchronous everything.** Vim's decade of jank; only `tool.pre` and
  `askUser` block.
- **Plugin-owned interaction loops.** The editor line, the event pump,
  and the conversation remain core-owned.

## Recommendation

Do not scratch. Rev 2 was already ~60% of the vim lesson by accident;
folding in four additions completes it:

1. `:command` registration with completion (mechanism 4),
2. `emitTranscript` (mechanism 1),
3. `host.post` + timers (neovim lesson 3),
4. read services + keymap registration through the existing table
   (mechanisms 10 and 2),

plus the `'formatprg'`-style settings discipline for configurability.
Then the framing sentence for the README writes itself: 3code is a
language for directing an agent; plugins extend the language (keys,
commands, events, skills), they do not bolt apps onto it.
