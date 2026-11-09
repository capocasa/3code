# 3code

**The economical coding agent.** Prompt and it keeps going.

→ [3code.capocasa.dev](https://3code.capocasa.dev)

## Install

The install script is the recommended way in:

```sh
# macOS / Linux
curl -fsSL https://3code.capocasa.dev/install | sh

# Windows (PowerShell)
irm https://3code.capocasa.dev/install.ps1 | iex
```

npm is here for those who prefer it:

```sh
npm install -g 3code
```

Both install the same release binaries. The npm package downloads the build
for your platform from the
[GitHub release](https://github.com/capocasa/3code/releases) matching its own
version during postinstall.

## Use

```
$ mkdir myprojectdir
$ cd myprojectdir
$ 3code
```

With no provider configured, the setup wizard starts by itself. Enter a
provider name or URL, paste your key, done. The
[manual](https://3code.capocasa.dev/docs) has everything else.
