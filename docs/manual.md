.. title:: 3code - the economical coding agent

## Introduction

3code grew out of my frustration with AI studios not optimizing at all to conserve
AI tokens. While I totally get that it's a good thing to take a "what if we had
endless resources" approach in a rearch lab, in my world, I'm paying- and it looks
to me like the AI companies are scaling the research lab up, free token fiction and all,
instead of adapting their research to what my needs are today. So it seems clear our
priorities are not aligned.

I find that open models- particularly GLM- are more than adequate to meet all my programming needs.
But I also found the other open agents seem to have either taken a page out of the AI companies
themselves- not optimizing very much for token use- or take a hyper-minimalistic 'the model will do
what it does' approach. 3code does neither- it makes every decision based on the idea "what will
bring better results with the least brainpower, tokens and computer resources used", and nothing else.
That's why it's the economical coding agent.

By being futurists and not having a proper product development vision based on today, the AI labs
have left a real gap. The open AI companies have filled most of it- 3code is here to make the
most of these.

## Quickstart

The first thing you need to do is get a provider where you can buy inference via an API, or set up
your computer with an open model so you can be your own provider.

Note: Being your own provider is just barely workable in terms of the quality you can get.

### Get a provider

There are lots and lots of providers to choose from.

#### Free providers

The best way to get to know 3code is with a free provider.

There are 2 notable ones I am aware of: `nvidia <https://build.nvidia.com>`_ has free deepseek v4 pro which is quite remarkable, and `novita.ai <novita.ai>`_ has tencent hy3 which is my favorite 'small' model. Both are usable- the rate limits don't make it impossible to work.

#### The z.ai coding plan

To do proper work, nothing beats GLM 5.2, in my experience. I think it's in the same league as the more well known models- it can work a bit slower but the results are right there. 3code makes sure to be very agentic keep everything hands off- so that tradeoff usually really doesn't matter much!

The best way to use 3code is the `z.ai coding plan <https://z.ai/subscribe>`_ ! This is the combination that really replaced Claude Code for me.

Note: While z.ai coding plan doesn't publically list 3code as a supported agent yet because it's in alpha, its use is officially permitted by z.ai- many thanks!

#### EU jurisdiction

I work with sensitive data that sometimes that I like to keep within EU jurisdiction- I like `tensorx <https://tensorx.ai>` a lot for this.

#### Low cost providers

There are 3 notable low cost providers supported by 3code- deepinfra, opencode and nano-gpt.com. They work by serving quantized versions of the open weights models and I find they work remarkably well.

#### More interesting models and providers 

I tried them all!

**Deepseek V4 Pro** is also very capable and inexpensive. I found it much more prone to create bugs than GLM but if you can keep it on track, when it does workit works very well. Available directly from `deepseek <https://deepseek.com>`_.

**LongCat** is interesting- I find it very similar to deepseek and it seemed more focused. Available from openrouter and `longcat <https://longcat.chat>_` directly (alipay app needed).

**Minimax M3** is very interesting- it has great general wide knowledge including of programming and comes up with pretty good approachs but it can be a bit hit or miss and doesn't stay focused very well for programming. It's might runner-up 'light'model. Super inexpensive plans are available directly from Minimax `<https://minimax.io>_`.

**Tencent Hy3** is available for free at the moment- the openrouter free version is rather limited but it's also on a provider called `novita <https://novita.ai>` and I haven't run into a limit yet. It's a lot like GLM but you can't give it as tough jobs. My favorite light model. We'll have to see where it goes with the pricing. 

**Kimi K2.7-code** worked just fine but I found it more expensive and especially much, much more verbose than GLM- so it costs more per task, so I haven't used it very much. Kimi K3 has been met with much enthusiasm but I was unable to test as of yet!

#### Finding even more providers

You can sign up at `openrouter <https://openrouter.com>`_ and `eurouter <https://www.eurouter.ai/>`, or you can do what I like to do and look at their models pages and sign up directly with the provider just to have one entity less in the loop.

### Install

```
# macOS / Linux
curl -fsSL https://3code.capocasa.dev/install | sh

# Windows (PowerShell)
irm https://3code.capocasa.dev/install.ps1 | iex
```

### Termux (Android arm64)

The CI ships a prebuilt Termux binary (`3code-termux-arm64.tar.gz`), or
build from source inside Termux:

```
pkg install nim git openssl
nimble install https://github.com/capocasa/3code
```

The binary needs Termux's OpenSSL for TLS (`pkg install openssl`).
Notes: the Landlock sandbox and desktop notifications are not available
on Android; both degrade gracefully (in-process path checks still
apply, notifications no-op). Auto-update is disabled — update with
`nimble install` again or re-download the tarball.

### Enter your API key

Navigate to your project directory and run `3code`. On first launch with no
config it walks you through setup:

```
  ╶──╮
  ╶──┤    3code v0.3.4   the economical coding agent
  ╶──╯

  no provider configured. let's add one. (ctrl+d to quit)
  supported: deepinfra, ovh, nvidia, nebius, fireworks

  api key              : ************************
  provider name or url : nvidia
  verifying... ok
  saved to ~/.config/3code/config
```

### Run your first prompt

```
❯ Build me a Hello World program in Nim
```

## Picking a provider

There are two categories of provider that are interesting to use with 3code:
the nvidia free tier and Chinese flat-rate providers. Other providers work but
will most likely be too expensive except to test-drive different models.

`nvidia <https://build.nvidia.com>`_ - Free tier. You get gpt-oss-120b, which
is good enough for a lot of cases. You will notice when it starts to get
limiting. MiniMax M2.7 is a very modern option on nvidia but it is pretty slow,
something you want to use in the background.

`MiniMax <https://platform.minimax.io>`_ - First-party API for the MiniMax
M-series: M3 frontier (1M context) and M2.7. The first-party endpoint is the
cheapest way to run M3 and the only one that exposes the Anthropic-style
`thinking.type` knob; the OpenAI-compatible surface (api.minimax.io/v1) is
what 3code talks to and uses the vLLM-style `chat_template_kwargs` knob
under the hood. M2.7 is also available on nvidia, fireworks, together,
sambanova, and deepinfra as a hosted alternative.

`z.ai <https://z.ai/>`_ - GLM 5.2 on the z.ai coding plan what I use to develop 3code! The effectiveness is absolutely top notch, you can throw hard problems at it, and it the tokens stack up considerably slower than on any other model I've tried.

`nebius <https://tokenfactory.nebius.com/>`_ - The EU-resident runner up. Only has GLM 5.1, not 5.2, but still a great choice if if tensorx isn't available.

`xAI <https://console.x.ai>`_ - First-party API for the Grok family (grok-4.5,
grok-4.3, grok-4.20, grok-build-0.1). Keys start with `xai-`, which the setup
wizard recognizes. The API is OpenAI-compatible and exposes a graded
`reasoning_effort` knob: low/medium/high on all models, with 4.20 also
accepting off. Prompt caching is server-side; 3code benefits automatically on
repeat turns.

Two ways to authenticate: paste an `xai-` API key in the provider wizard, or
type `xai` at the key prompt to sign in with your SuperGrok / X Premium+
subscription (browser OAuth, or device code on headless hosts). Subscription
tokens live in `$XDG_DATA_HOME/3code/auth/xai.json` (mode 0600) and refresh
automatically; the provider is saved with `auth = "oauth"` and no key.

Add a provider inside the REPL:

```
:provider add
```

Or switch between configured providers:

```
:provider use nvidia
:provider use zai.glm-5.1
```

Have a look at the `full list of providers <#known-good>`_.

## Starting programming

Use the `:model` command (tab-complete it), then press Tab again to rotate
through all the models configured for the current provider.

Then tell the model what you want.

I like to keep a `3CODE.md` in the project root that inlines my main project
style file with a `@../3CODE.md` reference. `AGENTS.md` also works; I prefer
agent-specific filenames.

## Usage monitoring

Every response shows a token receipt on its own line:

```
  ○12%  ↑4.2k  ↻18k  ↓1.1k  8s
```

The fields:

| glyph | meaning |
|-------|---------|
| `○N%` | context window used (percentage) |
| `↑`   | fresh input tokens (not cached) |
| `↻`   | cached input tokens |
| `↓`   | output tokens generated |
| `Xs`  | wall-clock seconds for this response |

During streaming, the same line updates live so you can watch the numbers tick
up in real time. If a glyph is absent it just means the provider did not stream
that information.

## Patient retry

Many providers enforce a rolling usage window, often five hours, after which
they return `429` until the window slides forward. Hitting one mid-task used to
mean dropping back to the prompt and re-submitting by hand once the window
reset. Patient retry removes that.

When patient retry is on (the default), any retryable failure, a `429` usage
limit, a `5xx`, or a network dropout, keeps retrying instead of surfacing. The
backoff is one shared exponential curve (power-of-2 off the category's own
level) capped at 2048 seconds, so the loop re-probes roughly every 34 minutes
at worst rather than napping for hours. After the initial ramp-up (~1 minute)
the attempt counter and the real error message keep scrolling by as transcript
lines, e.g.:

```
Usage limit reached for the past 5 hours. (code 429). retry 42/64 in 2048s
```

So you can glance over, see the underlying reason, and know the session is
holding. A network dropout on a train ride recovers the moment the cell comes
back, without you at the keyboard.

Turn it off if you would rather failures surface quickly:

```
:retry off
```

With it off, the initial ramp-up still runs (~1 minute, 7 attempts) before the
error reaches the prompt, so transient blips still self-heal. The toggle is
persisted in `[settings]` as `patient_retry` (written only when off, since on
is the default):

```
[settings]
patient_retry = "off"
```

You can cancel a running patient-retry hold at any time with Ctrl-C.

## Thinking

When a model reasons before replying, its thinking is shown as a one-line
ticker above the spinner. This gives you a quick sense of what the model is
working through without flooding the screen.

To toggle it:

```
:think off
:think on
```

The ticker has no effect if the provider does not emit reasoning content.

## Known good models

3code has a list of models and providers that have been tested to work- each provider usually needs a bit of handholding because there can be difference in the details of how the API is called. You can get the current list by running

```
3code --good
```

At the time of writing that's these

| Provider | Models |
| --- | --- |
| baseten | GLM-5 GLM-4.7 GLM-5.2 GLM-5.1 gpt-oss-120b DeepSeek-V4-Pro Kimi-K2.6 Kimi-K2.5 |
| cerebras | zai-glm-4.7 gpt-oss-120b |
| fireworks | glm-5p1 glm-5 gpt-oss-120b deepseek-v4-pro minimax-m2p7 kimi-k2p6 |
| nebius | GLM-5.1 GLM-5 GLM-5.2 gpt-oss-120b gpt-oss-120b-fast DeepSeek-V3.2 DeepSeek-V3.2-fast DeepSeek-V4-Pro Kimi-K2.5 Kimi-K2.5-fast MiniMax-M2.5 MiniMax-M2.5-fast MiniMax-M3 Kimi-K2.6 |
| nvidia | glm4.7 glm-5.2 gpt-oss-120b gpt-oss-20b deepseek-v4-pro deepseek-v4-flash minimax-m2.5 minimax-m2.7 minimax-m3 kimi-k2.6 |
| together | GLM-5.1 GLM-5 GLM-4.7 GLM-5.2 gpt-oss-20b gpt-oss-120b DeepSeek-V4-Pro MiniMax-M2.7 MiniMax-M3 Kimi-K2.5 Kimi-K2.6 |
| zai | glm-4.7 glm-4.7-flash glm-5 glm-5-turbo glm-5.1 glm-5.2 |
| deepinfra | GLM-5.1 GLM-5 GLM-4.7 GLM-4.7-Flash GLM-5.2 gpt-oss-120b gpt-oss-20b DeepSeek-V4-Pro DeepSeek-V4-Flash DeepSeek-V3.2 MiniMax-M2.5 MiniMax-M2.7 MiniMax-M3 Kimi-K2.6 Kimi-K2.5 Hy3 |
| novita | glm-4.7 glm-4.7-flash glm-5 glm-5-turbo glm-5.1 glm-5.2 gpt-oss-20b gpt-oss-120b deepseek-v3.2 deepseek-v4-flash deepseek-v4-pro minimax-m2.5 minimax-m2.7 minimax-m2.7-highspeed minimax-m3 kimi-k2.5 kimi-k2.6 hy3 |
| openrouter | glm-4.7 glm-4.7-flash glm-5 glm-5-turbo glm-5.1 glm-5.2 gpt-oss-120b gpt-oss-20b deepseek-chat deepseek-v3.2 deepseek-v4-flash deepseek-v4-pro minimax-m2.5 minimax-m2.7 minimax-m3 kimi-k2.5 kimi-k2.6 hy3:free hy3 grok-4.5 grok-4.5-latest grok-4.3 grok-4.20 grok-4.20-reasoning grok-4.20-multi-agent grok-build-0.1 |
| groq | gpt-oss-120b gpt-oss-20b |
| ovh | gpt-oss-120b gpt-oss-20b |
| sambanova | gpt-oss-120b DeepSeek-V3.2 MiniMax-M2.7 MiniMax-M2.5 |
| deepseek | deepseek-chat deepseek-reasoner deepseek-v4-flash deepseek-v4-pro |
| minimax | MiniMax-M3 MiniMax-M2.7 MiniMax-M2.7-highspeed MiniMax-M2.5 |
| longcat | LongCat-2.0 |
| xai | grok-4.5 grok-4.5-latest grok-4.3 grok-4.3-latest grok-build-0.1 grok-4.20 grok-4.20-reasoning grok-4.20-multi-agent |

## Sessions

List recent sessions for the current directory (newest first, up to 20):

```
3code --list
# or
3code -l
```

Listing is scoped to the current directory by design. To see every saved
session, run 3code from the sessions directory itself (e.g.
`~/.local/share/3code/sessions`).

Resume a specific session by ID:

```
3code -r:abc123
```

Note: different providers expire their prompt cache at different rates. Resuming
an old session still works but you will not get cache savings on stale context.

## Context clear

Inside the REPL, `:clear` wipes the accumulated context and starts a fresh
conversation with the same provider and model. Useful when a task is done and
you want to start something new without the old context bleeding in.

```
:clear
```

## Chunked mode

For larger tasks, have the model create a plan first and divide the work into
natural chunks - each saved to a file. Each chunk file should end by calling
the `context_clear` tool with the next file as the parameter. This produces
a series of implementing steps with context resets in between.

Example prompt to kick off a chunked task:

```
Divide the following task into 4-6 chunks, each in its own impl-N.md file.
End each file by calling context_clear with instructions to read the next file.
Then execute chunk 1.

Task: add comprehensive test coverage to the parser module.
```

Chunked mode is well-suited to busywork that does not require human interaction,
such as adding basic test coverage across a large codebase. A capable model is
needed; GLM 5.1 works well.

Calling `context_clear` at the end of each chunk with the next file as the
target also serves as a cheap capability test: if the model loses track enough
to forget to call the next file, the task was probably too hard for this mode.

## Cybernetic mode

Cybernetic mode is the go-to way to do a long-running coding session with 3code- agentic use.

How it works is you get yourself a chunk of work in a worktree, and ask our model to use the built-in cybernetic skill to complete it.

Here's what the skill does:

- It makes a plan for your work and writes it to a plan file as a todo list
- Has instructions in the file to pick one of the todo items, implement it, and update the plan file informed by the learnings of implementation
- Clears the context, with instructions for the next session to load the file
- Rinse and repeat
- When all items are completed, the last session performs a review

This allows for long-running task completion of large chunks of work while preserving only the context that is actually needed. This is different from summarizing, where all context is kept at a lower resolution, regardless of whether it is relevant.

## No sub-agents

Sub-agents are not supported because both research and user feedback says they are very expensive and bring unclear or negative benefits, so I consider it a feature that 3code doesn't have them. Use Cybernetic mode with worktrees instead.

## Sandbox

3code confines every tool call to a filesystem sandbox you define. The
sandbox is a plain text policy living in exactly one file at a time:

1. **repo** - `.sandboxrc` in your project directory, when it exists.
2. **user** - `~/.config/3code/sandboxrc`, next to your config,
   otherwise.

There is no cascade and no merging: the repo file wins outright, the
user file is the fallback. The user file is created from the built-in
default on first run, so the sandbox is always on and you can change
what every project without its own `.sandboxrc` gets by editing that
one file. Yolo mode (everything writable) is fine but you have to ask
for it explicitly.

The sandbox is enforced two ways. Bash commands run through `3code box`,
the built-in sandwall sandbox (Landlock on Linux, Seatbelt on macOS), which
3code re-execs itself as; the box process loads the policy file itself,
so every command launches on the freshest policy. The in-process
read/write/patch tools check paths against the same policy (reloaded when
the file changes) in the 3code process. Both layers run the same sandwall
parser and rule model, so the rules you write apply uniformly.

Host rules additionally drive the network wall: the first host rule in
the effective policy switches on egress fencing for bash commands, which
then reach the network only through a per-run allowlist proxy (``3code
wall proxy``). Linux fences with a kernel network namespace (the proxy is
reached through a unix-socket bridge), macOS with Seatbelt loopback-only
rules; a fenced command sees ``http_proxy``/``HTTPS_PROXY``/``ALL_PROXY``
pointed at the proxy and a ``GIT_SSH_COMMAND`` ProxyCommand unless you set
one yourself. Denied connections fail with a proxy 403. On Windows the
fence is keyed on a dedicated ``sandwall`` user and needs a one-time
elevated ``3code wall setup-windows``; without it, host-rule policies
print a warning and run unfenced (silence with
``[settings] sandbox_wall_warn = off``).

### The sandbox file

Each line is an access word, arbitrary whitespace, and a target. Lines run
top to bottom; each line supersedes the ones above it for the target it
names. Later rules win, so you can open a broad path then narrow parts of
it.

==========  ==============================================
Word        Meaning
==========  ==============================================
``deny``    deny: no read, no write, no connect
``readonly``  read-only: read and execute (paths only)
``allow``   writable path / connectable host
==========  ==============================================

A word only counts as an access word when it stands alone (whitespace
or end of line after it); a line starting with anything else is treated
as a host rule, so hostnames like ``deny.corp.internal`` still parse.

The target's first character decides what it names:

==========  ==============================================
Start       Target
==========  ==============================================
``/``       absolute path (``C:\`` drive roots on Windows)
``~``       home-dir path
``.``       path relative to the project dir
letter/digit  host rule: hostname, IPv4, or IPv6, optional ``:port``
==========  ==============================================

A bare word with no target means the project dir itself (``allow`` =
writable project). Host rules (``allow api.example.com``,
``allow 1.2.3.4:8080``, ``allow *`` for no network restrictions) fence
the network egress of sandboxed bash commands through the wall proxy.

On first run, 3code initializes `~/.config/3code/sandboxrc` with this
default:

```
deny /
allow /tmp
allow
```

The root is denied, the system temp dir and the project directory are
writable. This is the safe default: the agent can read and write your
project and scratch files, nothing else.

### Yolo mode

If you want the agent to have free rein over the whole filesystem, replace
the file with one line:

```
allow /
```

This is the explicit opt-in the spec requires. 3code never writes yolo for
you; you type it.

### Nesting and overrides

Because each line supersedes the ones above, you can layer rules. This
makes the working directory writable, opens ``/var`` read-only, then locks
down a secrets directory inside the project:

```
deny /
allow
readonly /var
deny ./secrets
```

The last matching rule for a path wins. ``./secrets`` is covered by the
root deny, the working-directory writable, and its own deny line - in that
order - so the deny wins. Read the file bottom-up for the effective policy
on any given path.

### Editing the sandbox

The sandbox file is yours. Edit it directly in your editor, or use the
REPL commands which append a rule and reload immediately:

```
:sandbox show
:sandbox allow /opt
:sandbox readonly /var
:sandbox deny ./secrets
:sandbox on
:sandbox off
```

The first `allow`/`readonly`/`deny` in a project creates the `.sandboxrc`
file by copying your user file, then appends the rule, so project rules
start from your baseline and you have something concrete to version and
share. `:sandbox off` disables
enforcement entirely for the session (bash runs unconfined, in-process
checks pass through); it persists in `[settings]` as `sandbox = off`. This
is the only way to run without a sandbox short of editing the file.

The agent never writes the sandbox file. If the model proposes a policy
change, it edits a copy and you move it into place. This keeps the trust
boundary entirely on your side: the sandbox is defined at prompt time, by
you, and the agent cannot weaken it. Gather mode (below) is the one
exception, and you switch it on explicitly.

### Gather mode

`:sandbox gather on` flips the sandbox into record mode: every would-be
denial is allowed instead, and the path is appended live as an ``allow``
rule to `.sandboxrc`. Run a normal working session, then
`:sandbox gather off` - the policy file now covers everything the agent
actually needed. While gather mode is on, bash commands run unconfined
(the kernel backends cannot observe-and-allow) and the working directory
of each bash call is recorded. Denials are appended verbatim and
un-deduped; review the file after a gather session. The toggle is
in-memory: it resets when 3code exits.

When enforcement is on and a sandboxed bash command fails with
``Permission denied``, 3code appends a hint to the tool output pointing
at the policy files, so the agent knows the sandbox (not the OS) denied
it and asks you instead of retrying blindly.

### What gets sandboxed

Bash commands, file reads, writes, and patches all consult the sandbox.
Bash gets full kernel enforcement: the sandbox backend is compiled into
3code (the `box` subcommand), so every bash command is re-execed as
`3code box restrict ...` and a write outside the allowed paths fails with
``Permission denied`` at the syscall level. No child process can escape.
The read/write/patch tools also check paths in-process, so the
higher-risk operations (mutating your files directly) stay guarded.

### Platform behavior and fallback

The bash backend is OS-native: **Landlock** on Linux, **Seatbelt** on
macOS, and a restricted-token **ACL** scheme on Windows. At startup 3code
probes whether the backend can actually restrict on this host, then
applies it. The probe can fail on a kernel built without Landlock, or in
a container/CI runner whose seccomp filter blocks the syscall.

When the probe fails, bash degrades gracefully: commands run unconfined
(via the plain `setsid`+`sh` path) instead of failing outright. The
in-process read/write/patch path checks stay in force regardless, so the
highest-risk operations (directly mutating your files through the
write/patch tools) remain guarded even when the kernel backend is
unavailable. There is no way for the agent to bypass this layer.

## Developments

3code will keep up with the "works right now" approach as agentic coding
develops.

We will continue to support more models and providers as they come out.

## Contributing

Developer documentation (module graph, proc docs, type definitions) is in
`docs/dev/threecode.html`. Build it with `nimble devdocs`.

Pull requests welcome:

- known-good provider/model pairs with test results
- bug fixes with a clear reproduction case

Bug reports welcome, but make sure you give enough specific information to
reproduce the issue. If you are not sure what that means, please find out before
reporting - if in doubt, ask your own 3code how to do that.

## Prior art

3code is heavily influenced by Claude Code, goose, pi, and codex. While I like
the particular tradeoffs better, imitation is the sincerest form of flattery and
3code should be looked at as heavily inspired by them. As a European, I still
think using Claude Code feels like driving a turbocharged Ford F-150 to buy a
pack of gum, but I still love you.

Having said that, 3code deliberately chose to forgo some features they have,
just to focus on the task of writing software as effectively, reliably, and
consuming as few resources as possible.
