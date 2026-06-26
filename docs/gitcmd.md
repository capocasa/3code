.. title:: 3code - bash and unix tools on Windows for coding agents

## bash + unix tools on Windows

This research note covers how a coding agent gets a real bash and the usual
unix toolset on Windows — the equivalent of 3code's
``irm https://3code.capocasa.dev/install.ps1 | iex`` formula, but for the
shell layer rather than the agent itself. Two questions answered: is there a
turnkey one-command install, and does any of this disturb WSL.

### Short answer

There is no single official ``irm ... | iex`` one-liner that drops a complete
bash+unix-tools bundle the way the 3code installer does. But there is a
de facto procedure the agent community has converged on, and the substrate
for it is a private, bundled MinGit/PortableGit. The community-built agents
that already do this well are Hermes (Nous Research) and, to a lesser
extent, mise — both pin their bash via an env var.

### The substrates

Three real options, ranked by suitability for a coding agent.

**MSYS2** — the most complete bundle: full bash, ``pacman``, ripgrep,
coreutils, git. This is the setup OpenAI's Codex Windows guide recommends
(`openai/codex#3580 <https://github.com/openai/codex/discussions/3580>`_).
Strictly better than Git Bash for agent use because the toolset is complete
and ``pacman``-upgradeable.

Not a piped one-liner, but the installer is fully scriptable. Closest
equivalent::

    # GUI installer, silent CLI mode -> C:\msys64
    .\msys2-x86_64-latest.exe in --confirm-command --accept-messages --root C:/msys64

    # Or the self-extracting archive (no GUI integration, functionally identical):
    .\msys2-base-x86_64-latest.sfx.exe -y -oC:\

Then ``pacman -Syu`` and ``pacman -S mingw-w64-ucrt-x86_64-ripgrep`` etc.
The sfx archive lives on the msys2-installer GitHub releases, so it's one
PowerShell line away from being a ``irm | iex`` — you'd just be the one
hosting it. There is no off-the-shelf equivalent to copy.

**Git for Windows / Git Bash** — one command via winget::

    winget install --id Git.Git -e --source winget

Git Bash is a stripped-down MSYS2 fork: enough bash + git + a minimal set of
coreutils to work, but intentionally lean — no ``pacman``, manual installs
for things like ripgrep via scoop/choco separately. The Codex thread also
notes Git Bash has caused load failures in some IDE agent plugins without
clear errors, where MSYS2 hasn't. For a coding agent, MSYS2 beats Git Bash.

**Private bundled MinGit** — the actual pattern mature agents use. See
below.

### The procedure agents actually use

The pattern, documented explicitly by Hermes and noted as "the same strategy
Claude Code uses": **don't install the full Git-for-Windows or MSYS2 into the
system. Bundle a trimmed PortableGit/MinGit into a private directory and pin
it with an env var.**

Hermes's ``irm | iex`` installer does this, step by step:

1. Downloads the official **MinGit** zip (~45 MB, from git-for-windows
   releases) into ``%LOCALAPPDATA%\hermes\git\PortableGit``. No admin, no
   registry, no Windows installer.
2. Sets ``HERMES_GIT_BASH_PATH`` to ``...\git\usr\bin\bash.exe`` so fresh
   shells find it deterministically.
3. Resolution order on the agent side: env var → its own bundled PortableGit
   → system Git for Windows → MSYS2/Cygwin → anything on PATH as last
   resort.

That env var is the whole trick. It sidesteps the classic footgun where
``C:\Windows\System32\bash.exe`` (the WSL launcher) wins ``bash`` resolution
and the agent ends up running inside WSL by accident.

Two gotchas the Hermes docs call out, both worth baking into a custom
``install.ps1``:

- Use the **non-busybox** MinGit (``MinGit-*-64-bit.zip``, not
  ``*-busybox*``). The busybox build ships ``ash``, not ``bash``, and
  coreutils are missing.
- In MinGit's layout, bash lives at ``usr\bin\bash.exe``, **not**
  ``bin\bash.exe``. Check both.

For the 3code formula this is the cleanest substrate: one PowerShell line,
~45 MB, self-contained, and the bash path is controlled via an env var
rather than fighting system PATH ordering. MSYS2 is more powerful (full
``pacman``, ripgrep, etc.) but heavier and has no turnkey ``irm | iex`` —
that bootstrap would have to be written by hand.

### Does it disturb WSL?

No. They coexist cleanly.

- Git for Windows / MSYS2 install into their own directories (``C:\msys64``,
  ``C:\Program Files\Git``, or a private ``%LOCALAPPDATA%\...\git``). They
  do not touch the WSL distro, the WSL VM, or ``/mnt/c`` interop. Hermes
  explicitly documents that native and WSL2 installs "coexist cleanly" with
  data in separate roots.
- No admin rights, no registry mutation for the portable variant, no PATH
  clobbering of the WSL launcher.

The one real interaction — not damage, just ambiguity — is ``bash``
resolution: ``C:\Windows\System32\bash.exe`` is the WSL launcher, and if an
agent naively calls ``bash`` it can land in WSL instead of the bundled Git
Bash. That is exactly what the ``*_GIT_BASH_PATH`` env-var pin solves. mise
documents the same problem and the same fix (``MISE_BASH_PATH``). So: install
is harmless to WSL; the only thing to get right is making sure the agent
resolves the *right* bash.

If hard isolation is ever wanted, disable WSL's PATH-interop in
``/etc/wsl.conf``::

    [interop]
    appendWindowsPath = false

That's only relevant if a tool (like mise's shim mode) actually leaks
Windows shims into WSL. For a Git Bash install, not needed.

### Sources

- `MSYS2 installer docs <https://www.msys2.org/docs/installer/>`_ — silent
  CLI install forms, sfx archive.
- `openai/codex#3580 <https://github.com/openai/codex/discussions/3580>`_ —
  the Codex Windows MSYS2 setup guide; also flags the Git Bash plugin-load
  failures and the ``System32\bash.exe`` WSL collision.
- `Hermes Windows (Native) Guide
  <https://hermes-agent.nousresearch.com/docs/user-guide/windows-native>`_ —
  the private PortableGit + env-var-pin procedure, the MinGit layout and
  busybox gotchas, the WSL coexistence statement.
- `mise troubleshooting
  <https://mise.jdx.dev/troubleshooting.html>`_ — same ``bash``-resolution
  footgun, ``MISE_BASH_PATH`` fix, the WSL interop ``appendWindowsPath``
  lever.
