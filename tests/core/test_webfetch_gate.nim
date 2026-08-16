discard """
  # web_fetch runs in the 3code parent process, outside the network
  # fence that walls bash children through the proxy. When the sandbox
  # is active and the policy carries host rules (wallProxyNeeded), the
  # URL's host[:port] must pass the same wall matcher the proxy
  # applies, or a "fenced" session could still reach internal hosts
  # with the native tool. web_search stays ungated: it only ever talks
  # to the fixed, user-configured search endpoints.
  #
  # The gate reloads the policy from getCurrentDir(), so each test
  # chdirs into a fixture project dir owning its own .sandbox, like
  # tests/core/test_sandbox_traversal.nim does.
"""
import std/[unittest, os, strutils]
import threecode/[actions, sandbox, types]

proc newFixture(name: string; policyText: string): tuple[home, proj: string] =
  let base = getTempDir() / ("3code_wfgate_" & name & "_" & $getCurrentProcessId())
  if dirExists(base): removeDir(base)
  result = (base / "xdg", base / "proj")
  createDir(result.home)
  createDir(result.proj)
  putEnv("XDG_CONFIG_HOME", result.home)
  writeFile(result.proj / ".sandbox", policyText)

template withPolicy(name, policyText: string, body: untyped) =
  block:
    let (h, p) = newFixture(name, policyText)
    let prevCwd = getCurrentDir()
    defer:
      putEnv("XDG_CONFIG_HOME", "")
      setCurrentDir(prevCwd)
      removeDir(h.parentDir)
    putEnv("XDG_CONFIG_HOME", "")
    setCurrentDir(p)
    let wasActive = sandbox.active
    let saved = sandbox.current
    sandbox.active = true
    sandbox.current = sandbox.loadPolicy(p)
    defer:
      sandbox.active = wasActive
      sandbox.current = saved
    body

suite "web_fetch network gate":
  test "deny-all hosts: fetch to a non-allowed host errors with code 1":
    withPolicy("denyall", "deny /\nallow ./\ndeny *\n"):
      let act = Action(kind: akWebFetch, body: "http://192.0.2.1/secret")
      let (outp, code, _) = runAction(act)
      check code == 1
      check "sandbox" in outp
      check "denied" in outp
      check "192.0.2.1" in outp

  test "no host rules: unchanged behavior (no gate engaged)":
    withPolicy("nohosts", "deny /\nallow ./\n"):
      # No gate: the fetch itself runs and fails on network grounds
      # (192.0.2.x is TEST-NET, nothing listens there), but crucially
      # NOT with a sandbox-deny message.
      let act = Action(kind: akWebFetch, body: "http://192.0.2.1/")
      let (outp, code, _) = runAction(act)
      check code == 1
      check "sandbox" notin outp

  test "allowed host passes the gate":
    withPolicy("allowone", "deny /\nallow ./\ndeny *\nallow 192.0.2.1\n"):
      # Gate passes; the fetch then fails on network grounds without a
      # sandbox-deny message.
      let act = Action(kind: akWebFetch, body: "http://192.0.2.1/")
      let (outp, code, _) = runAction(act)
      check code == 1
      check "sandbox" notin outp
