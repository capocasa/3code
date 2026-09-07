# macOS verification

Canonical automated configuration: `.github/workflows/osx.yml` (macos-14).
It builds and verifies the Seatbelt + wall proxy matrix, then runs the shared
CI test dispatcher. Read the workflow for current commands; do not infer macOS
support from Linux-only PTY results or blanket test exclusions.

Historical manual verification used the `stefani` VM. This checkout contains no
verified VM connection/credential provisioning instructions. Use an already
authorized VM connection if available; do not invent hostnames, install packages,
or trigger remote workflows without authorization. Record OS/architecture,
Nim version, commit/build defines, test command, duration, and artifacts.

On the Mac checkout run `nimble setup` once and plain `nim c` against local sources,
then the selected test through `tools/test_dispatch.sh`. For sandbox changes,
run the matrix documented in the workflow in a disposable directory, preserving
its allow/deny cases and network prerequisites. External network checks require
explicit authorization and are not equivalent to local mock transport tests.

For terminal fixes use the same dimensions, config, and typed/pasted input as the
report. PTY/ttty frames are a model surface only. Capture the actual terminal
window when the model cannot reproduce the failure; verify the image is nonempty
and inspect it. Follow root `AGENTS.md`, which overrides older replay-only advice.
Attach raw bytes and structured frames as diagnostics, not screenshot substitutes.
If no Mac/VM is available, state macOS unverified rather than claiming a pass.
