# Swallowed-Error Scan

A living checklist for finding places where an error is caught and then
silently dropped, masked, or converted into a benign-looking result. This
class of bug caused the "waitforever" hang: `recvIntoHead` caught every
`CatchableError` and turned it into `chunk = ""`, which read as a clean EOF,
so a dead TLS connection masqueraded as a graceful close.

The fix closed that swallow site. This document is how to find the rest.

## The pattern

A swallow site is any `except` block (or `try` expression) that absorbs an
error and continues with a default, empty, or `nil` result **without
re-raising, logging, or recording it**. The dangerous ones look innocuous
because the surrounding code "works" in the happy path. They only bite when
an unexpected error variant arrives, at which point the caller proceeds on
bad data (an empty string, a nil node, a false bool) and the real failure is
lost.

## How to scan

Run these from the project root. They list candidate sites; each must be
read by a human to decide whether the silence is intentional.

```sh
# 1. except blocks that contain discard / empty / a bare assignment
rg -n 'except\b' src --type nim -A2 \
  | rg -B1 'discard|continue|= ""|= \[\]|= nil|= false|= 0\b' \
  | less

# 2. the broader set: every except block with its body, for manual review
rg -n 'except\b' src --type nim -A3 | less

# 3. try expressions assigned to a default that hide the error path
rg -n 'try:' src --type nim -B1 -A2 \
  | rg 'except.*discard|= ""|= nil' | less

# 4. callbacks registered as hooks — these run across thread boundaries
#    and a swallowed error there is invisible to the caller
rg -n 'proc\(.*\).*closure|Hook|hook' src --type nim -A2 \
  | rg 'except.*discard' | less
```

## What counts as a real swallow (investigate)

- `except CatchableError: discard` on a path that should propagate.
- `except ...: result = ""` / `nil` / `false` where the empty result is
  indistinguishable from a genuine empty answer (the EOF case that hid the
  TLS read failure).
- `except ...: continue` where the loop has no other exit on failure.
- A `try: x = action() except: x = default` where `default` lets the caller
  proceed as though `action` succeeded.

## What is fine (do not flag)

- `except CatchableError: discard` on a **close** / **cleanup** / **teardown**
  path where re-raising would mask the original error (e.g. closing a socket
  inside a `finally`).
- Logging the error to stderr then continuing — the failure is recorded.
- Catching a *specific* narrow exception to convert it (e.g. catching
  `StreamTimeoutError` to loop on poll) — that is intentional control flow,
  not a swallow.
- Test stubs and the `providerStub`/`httpStub` paths.

## Known sites to keep an eye on

These were reviewed during the waitforever fix and judged acceptable, but
they are the shape that drifts toward dangerous under refactors:

- `streamhttp` `close*` — swallows close errors. Correct (teardown).
- `streamhttp` `recvIntoHead` — **was** the bug; now re-raises. The
  non-timeout `except CatchableError` was converted to `raise e`. Re-check
  if a future change reverts this.
- `api.nim` `closeCachedStreamConn` — swallows `close()`. Correct (cache
  teardown; the error surfaces on the next connect).
- `api.nim` retry backoff `except CatchableError` in `verifyProfile` /
  `fetchModels` — converts to `(false, msg)` / `(@[], msg)`. Correct (the
  error is returned to the caller, not dropped).
- `fatprompt/runtime.nim` `spinnerLoop` / `barTickLoop` — `except
  CatchableError: discard` on a render thread. Acceptable: a render blip
  must not kill the spinner, and the next tick repaints. But if these ever
  swallow the *only* signal of a dead connection, promote to logging.

## When you find a new one

1. Decide if the silence is load-bearing (cleanup, benign-default) or a bug.
2. If a bug: the fix is to **re-raise** (preferred) or **record** the error,
   not to add more special cases around the empty result.
3. Add or expand a test that drives the error variant and asserts it
   surfaces. A swallow that survives is one nobody tested.
