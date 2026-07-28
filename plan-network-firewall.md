# Network plan (future): the "wall" half of sandwall

Status: **research captured, plan deliberately unrefined. Do not implement.**
The full research lives in `~/p/procbox/firewall-research.md`; this file is
the decision record. Filesystem work happens first (see
`cybernetic-plan.md`); when it lands, this plan gets refined into its own
cybernetic plan and the procbox repo is renamed sandwall at that point.

## Locked decisions (from the user)

- **Q1 rename**: procbox -> sandwall happens *with* the network milestone,
  inside the repo (keep history). Final layout: `src/sandwall/sand.nim`
  (filesystem), `src/sandwall/wall.nim` (network), shared modules at
  `src/sandwall/<m>.nim`, clearly separate network internals under
  `src/sandwall/wall/`. sand and wall must be independently usable.
- **Q2 scope**: Full monty (option A). Kernel fence to loopback + a
  `sandwall proxy` process (HTTP CONNECT + SOCKS5) enforcing hostname
  allowlists per request. No TLS termination. This is the srt/Codex
  architecture; see firewall-research.md for why there is no kernel-native
  hostname filtering on any OS.
- **Q3 old kernels**: on Linux < 6.7 (Landlock ABI < 4), a policy with
  host rules: run unfenced, skip the net rules, warn. Never hard-fail.
- **Q6 defaults**: default policy has no host rules and no network
  fencing. Network is untouched until the user adds a host rule (any
  `+host` / `-host` / `+1.2.3.4`) or an explicit fence. Adding the first
  host rule switches fencing on.
- **Q7 ports**: `+host:port` and `+ip:port` allowed; a bare host/IP means
  **all ports** (not 443+80). `+localhost` is meaningful. Wildcards:
  only `*.example.com` suffix form (TBD at refinement).
- **Q8 Windows**: do it properly eventually: dedicated local user
  (sandwall-sandbox), DPAPI-stored credentials, persistent WFP filters
  keyed on the user SID (ALE_USER_ID), loopback permit to the proxy port
  range, block everything else. One-time elevated setup helper, idempotent
  (Codex/srt shape). Large parts of this are explicitly **unplanned**;
  mark them so when refining.
- **Q9 3code's own traffic**: 3code itself stays unsandboxed forever. Its
  web tools do not consult host rules. It just never exposes its network
  privilege to the model via sandboxed tools.
- **Q10 compat**: none. Dev branch, hard cutovers are fine.

## Architecture sketch (to refine later)

- `wall.nim` public API: something like
  `wallRestrict(rules: seq[Rule], proxyPort: int)` confining the current
  thread to loopback-only egress, plus `sandwall proxy --policy <file>`
  as a standalone binary/subcommand.
- Per-platform fence:
  - Linux: Landlock ABI v4 port rules alone cannot express
    loopback-only. Options to evaluate at refinement: (a) netns via
    bwrap-style unshare + socat bridge (srt approach, heavy), (b)
    Landlock deny-all connect + proxy on a Unix socket bind-mounted in
    (proxy speaks over the unix socket, srt's Linux mode does exactly
    this), (c) accept port-only fencing as a degraded Linux mode.
    Decision deferred; (b) looks most in-spirit.
  - macOS: Seatbelt: `(allow network-outbound (remote ip "localhost:*"))`
    + deny the rest, mDNSResponder literal only if policy non-empty.
    Native, full fidelity via proxy. Straightforward extension of
    seatbelt.nim.
  - Windows: Q8 above (unplanned parts marked).
- Proxy: single Nim process, CONNECT + SOCKS5 on 127.0.0.1 ephemeral
  ports. Allowlist checked per CONNECT host: exact, `*.` suffix wildcard,
  IP literal. Proxy rereads the policy file on mtime change itself (the
  kernel fence never changes, so live reload only touches the proxy).
  Sandboxed env gets HTTP_PROXY/HTTPS_PROXY/ALL_PROXY +
  NO_PROXY=localhost + GIT_SSH_COMMAND through the SOCKS proxy (TBD).
- DNS: fenced processes cannot resolve; the proxy resolves. Kills the
  DNS-exfil channel too.
- Domain fronting is an accepted residual risk (same as srt/Codex).

## Open questions for refinement day

- Exact CLI surface: `sandwall wall ... -- CMD` vs folding net rules into
  the existing `restrict` invocation via the policy file. Leaning: the
  policy file drives everything, CLI stays `restrict`.
- Proxy lifecycle when multiple 3code sessions run: one proxy per box
  launch (simplest) vs per-session shared.
- Whether `+*` (unsandboxed) also disables the fs sandbox (per original
  user spec: "matches all networks and host names so this is
  unsandboxed", networks only, fs unaffected).
- IPv6 loopback coverage, SOCKS5 auth (none, loopback only), UDP posture
  (deny, TCP-only proxy).

## Windows unplanned sub-parts (mark explicitly when refining)

- Elevated setup helper binary (create user, DPAPI credentials, install
  WFP provider/sublayer/filters).
- CreateProcessAsUser launch path in acl.nim/process.nim.
- Loopback port-range permit + proxy binding coordination.
- Uninstall/verify commands.
