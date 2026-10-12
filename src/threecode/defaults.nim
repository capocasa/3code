## 3code's built-in sandbox default, one literal block per OS.
##
## This is the product's curated table (ripgrep's `default_types.rs`
## shape): the sandbox engine in sandwall ships zero opinions about
## what a developer needs; this table is where 3code says. It holds
## only what was actually verified under the sandbox on real
## hardware, each entry the tool's own documented home - popular
## stacks only; the rest are recipes in the manual ("Sandbox
## settings collection"), and improvements to this list are ordinary
## commits: keep the lines sorted within their tier, keep every
## entry backed by a real run.
##
## Shape:
## * temp dirs and the project dir are writable;
## * the dependency and build caches the covered toolchains keep
##   under $HOME are writable, because those homes are disposable by
##   specification or construction (~/.cache is defined by the XDG
##   Base Directory spec as non-essential data; ~/.npm and ~/go hold
##   package caches and fetched modules; ~/.cargo/registry|git hold
##   downloaded dependencies);
## * the toolchain shims are read-only+execute (~/.cargo/bin,
##   ~/.rustup, ~/.choosenim) - code, not data, exactly like the
##   system /usr the sandwall baseline already grants;
## * the version-control user config is readable, because the tools
##   are *fatal* without it: git aborts every invocation when
##   ~/.gitconfig exists but is unreadable (it treats EACCES unlike
##   ENOENT), cargo dies the same way on ~/.cargo/config.toml. Those
##   lines mirror git's and mercurial's own documented config search
##   paths, of which the system tier (/etc) is already covered by the
##   sandwall baseline;
## * the languages covered out of the box: C, Zig, Go, Nim, Python,
##   Rust - command-line builds only. C and Zig ride the project dir,
##   the read-only system baseline, and ~/.cache (Zig's global cache;
##   on Windows ~/AppData/Local/zig). Node rides the project's
##   node_modules, ~/.npm, and the baseline. Everything past that -
##   ruby, java, gradle, scons, and friends - is a manual recipe, not
##   a default.
##
## What stays fenced, on purpose: token-bearing files (~/.npmrc,
## ~/.git-credentials, ~/.cargo/credentials, ~/.netrc, ~/.ssh,
## ~/.aws, ...). A missed allow fails loud (git dies, the user sees
## it); a missed deny fails silent and forever. There is no published
## "safe dotfiles" list to defer to, so the default opens exactly the
## documented lookup paths of the tools it keeps alive, and no more.
## The user extends it the way ripgrep extends its types: a project
## file (`:sandbox allow`, like `--type-add`) or a user baseline file
## (~/.config/3code/sandbox, like RIPGREP_CONFIG_PATH).
##
## Windows keeps the same shape with its cache locations; VCS config
## is handled by the caller (streamexec seeds the bash child's
## redirected HOME with a copy of the real ~/.gitconfig, because the
## child runs as a separate user and git's ownership check would
## otherwise reject every repo).

when defined(windows):
  const defaultPolicyText* = """
deny /
allow ~/AppData/Local/Temp
allow ~/AppData/Local/npm-cache
allow ~/AppData/Local/pip/cache
allow ~/AppData/Local/zig
allow ~/go
allow ~/.npm
allow ~/.cargo/registry
allow ~/.cargo/git
readonly ~/.cargo/bin
readonly ~/.cargo/config.toml
readonly ~/.rustup
allow ~/.nimble
readonly ~/.choosenim
allow ./
"""
elif defined(macosx):
  const defaultPolicyText* = """
deny /
allow /tmp
allow /var/tmp
allow ./
allow ~/go
allow ~/.cache
allow ~/Library/Caches
allow ~/.npm
allow ~/.cargo/registry
allow ~/.cargo/git
readonly ~/.cargo/bin
readonly ~/.cargo/config.toml
readonly ~/.rustup
allow ~/.nimble
readonly ~/.choosenim
readonly ~/.local/share/uv
readonly ~/.gitconfig
readonly ~/.config/git
readonly ~/.hgrc
readonly ~/.config/hg
allow *
"""
else:
  const defaultPolicyText* = """
deny /
allow /tmp
allow /var/tmp
allow ./
allow ~/go
allow ~/.cache
allow ~/.npm
allow ~/.cargo/registry
allow ~/.cargo/git
readonly ~/.cargo/bin
readonly ~/.cargo/config.toml
readonly ~/.rustup
allow ~/.nimble
readonly ~/.choosenim
readonly ~/.local/share/uv
readonly ~/.gitconfig
readonly ~/.config/git
readonly ~/.hgrc
readonly ~/.config/hg
allow *
"""
