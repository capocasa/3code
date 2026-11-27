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
##   node_modules, ~/.npm, and the baseline. Java joins on macOS: the
##   JVM's non-path needs (kern.grade_cputype sysctl, opendirectoryd
##   user lookup, the dirhelper mach service behind confstr's temp-dir
##   resolution - without it java hangs before main, 3code #64) are
##   granted by the sandwall seatbelt profile itself,
##   and the JDK homes under $HOME ride readonly lines below (the
##   system ones - /Library/Java, brew's /opt, the /usr/libexec/java_home
##   shim - are already baseline-readable). Everything past that -
##   ruby, maven, gradle, scons, and friends - is a manual recipe, not
##   a default.
##
## The floor is `ask /`: everything the table does not name stays
## closed, but a closed path the agent bumps into offers the user a
## one-key grant instead of a silent denial (sandwall's ask kind; a
## headless session treats ask exactly like deny). System binaries
## ride explicit readonly lines (/usr/bin, /bin) because the
## in-process gate for the file tools sees only this table, not the
## sandwall baseline the bash fence auto-grants.
##
## What stays fenced, on purpose: token-bearing files (~/.npmrc,
## ~/.git-credentials, ~/.cargo/credentials, ~/.netrc, ~/.aws, ...)
## and ~/.ssh private keys. ~/.ssh itself is read-only - public keys,
## config, known_hosts - with every OpenSSH default private-identity
## name re-denied on top, so ssh keeps working while the keys the
## prompts answer for stay unread. A missed allow fails loud (git
## dies, the user sees it); a missed deny fails silent and forever.
## There is no published "safe dotfiles" list to defer to, so the
## default opens exactly the documented lookup paths of the tools it
## keeps alive, and no more. The user extends it the way ripgrep
## extends its types: a project file (`:sandbox allow`, like
## `--type-add`) or a user baseline file (~/.config/3code/sandbox,
## like RIPGREP_CONFIG_PATH).
##
## Windows keeps the same shape with its cache locations; VCS config
## is handled by the caller (streamexec seeds the bash child's
## redirected HOME with a copy of the real ~/.gitconfig, because the
## child runs as a separate user and git's ownership check would
## otherwise reject every repo).

when defined(windows):
  const defaultPolicyText* = """
ask /
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
readonly ~/.ssh
deny ~/.ssh/identity
deny ~/.ssh/id_dsa
deny ~/.ssh/id_ecdsa
deny ~/.ssh/id_ecdsa_sk
deny ~/.ssh/id_ed25519
deny ~/.ssh/id_ed25519_sk
deny ~/.ssh/id_rsa
deny ~/.ssh/id_xmss
allow ./
"""
elif defined(macosx):
  const defaultPolicyText* = """
ask /
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
readonly ~/Library/Java
readonly ~/.jdks
readonly ~/.sdkman/candidates
readonly ~/.gitconfig
readonly ~/.config/git
readonly ~/.hgrc
readonly ~/.config/hg
readonly /usr/bin
readonly /bin
readonly ~/.ssh
deny ~/.ssh/identity
deny ~/.ssh/id_dsa
deny ~/.ssh/id_ecdsa
deny ~/.ssh/id_ecdsa_sk
deny ~/.ssh/id_ed25519
deny ~/.ssh/id_ed25519_sk
deny ~/.ssh/id_rsa
deny ~/.ssh/id_xmss
allow *
"""
else:
  const defaultPolicyText* = """
ask /
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
readonly /usr/bin
readonly /bin
readonly ~/.ssh
deny ~/.ssh/identity
deny ~/.ssh/id_dsa
deny ~/.ssh/id_ecdsa
deny ~/.ssh/id_ecdsa_sk
deny ~/.ssh/id_ed25519
deny ~/.ssh/id_ed25519_sk
deny ~/.ssh/id_rsa
deny ~/.ssh/id_xmss
allow *
"""
