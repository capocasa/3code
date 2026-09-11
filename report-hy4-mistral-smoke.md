# Live smoke test: hy4 and mistral large-3/medium-3.5

Result record for the chunk-4 best-effort live check in
`impl-hy4-mistral-4.md`. The unit suite covers the reasoning level sets and
the wire builder; this run confirms the live OpenRouter endpoints accept the
shapes and round-trip a tool loop.

## Surface

- Binary: `src/threecode.out` built from this tree with `nim c
  src/threecode.nim` (Nim 2.2.12, orc, threads on). Commit d46f7a0.
- Config: isolated `XDG_CONFIG_HOME`, one `openrouter` provider only.
- Transport: a local logging TLS proxy (`/tmp/smoke/proxy.nim`) on
  `127.0.0.1:8901` forwards to `https://openrouter.ai` with the Host header
  rewritten, and logs each request body plus each response stream. This is a
  real round-trip to the live endpoint, not a mock.
- Driving pattern: one-shot `-m openrouter.<model> "<prompt>"` for the tool
  loop, and `script -qec "<bin> -i ..."` (real PTY) for `:reasoning`.
- Prompt (tool-loop runs): "read README.md and tell me just the first
  markdown heading" in a scratch cwd with a two-line README.

Note: the repo cwd was locked by a running 3code session (pid 11635), so the
live runs used a scratch cwd under `/tmp/smoke/work`; none touched the
user's session.

## Results

### hy4 (openrouter, `tencent/hy4-preview`)

- Exit 0, streamed.
- Tool call fired: `read {"path": "README.md"}`; the follow-up request
  carried the `tool` role.
- Wire: `reasoning: {"effort": "high"}` (the openrouter branch of
  `applyHy3Reasoning`); no `chat_template_kwargs`.
- `:reasoning` (live REPL) lists exactly:
  ```
    no_think
  * high
  ```

### mistral-medium-3-5 (openrouter, `mistralai/mistral-medium-3-5`)

- Exit 0, streamed.
- Tool call fired (follow-up request carried the `tool` role); no
  context loss across the tool turn, so Medium keeps `thinkBack = tbNone`.
- Wire: `reasoning: {"effort": "high"}` (the openrouter branch of
  `applyMistralReasoning`); no top-level `reasoning_effort`.
- Thinking chunks present: 14 and 18 `reasoning` / `reasoning_details`
  deltas across the two responses.
- `:reasoning` (live REPL) lists exactly:
  ```
    none
  * high
  ```

### mistral-large-2512 (openrouter, `mistralai/mistral-large-2512`)

- Exit 0, streamed, tool call fired.
- Wire: no `reasoning` and no `reasoning_effort` field at all (no knob).
- `:reasoning` (live REPL) reports `mistral: no reasoning knob`; the welcome
  banner omits the `reasoning` line.

## Not verified live

- First-party `tencent` (TokenHub) `chat_template_kwargs.reasoning_effort`
  path: no TokenHub key configured. Still unverified against the live host.
- First-party `mistral` (`api.mistral.ai`) top-level `reasoning_effort` path:
  no Mistral key configured. Only the OpenRouter normalized
  `reasoning.effort` shape is confirmed.
