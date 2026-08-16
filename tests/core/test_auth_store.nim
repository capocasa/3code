## Token-store behavior shared by the subscription auth providers:
## atomic writes (no truncated store after a crash-mid-write) and a zero
## TokenSet on a corrupt store (re-login is the recovery).

import std/[json, os, times, unittest]
import threecode/oauth
import threecode/auth_openai as openai
import threecode/auth_xai as xai

template withTempStore(body: untyped) =
  ## Point both providers' stores into a scratch data root via
  ## XDG_DATA_HOME, restore afterwards. Same pattern as the session
  ## save/index e2e suite.
  let before = getEnv("XDG_DATA_HOME")
  let tmp = getTempDir() / ("3code-test-auth-" & $epochTime().int64 &
    "-" & $getCurrentProcessId())
  putEnv("XDG_DATA_HOME", tmp)
  try:
    body
  finally:
    if before.len > 0: putEnv("XDG_DATA_HOME", before)
    else: putEnv("XDG_DATA_HOME", "")
    removeDir(tmp)

template checkStoreRoundTrip(store, load: untyped, path: string) =
  let ts = TokenSet(accessToken: "at", refreshToken: "rt",
                    tokenType: "Bearer", expiresAt: 123)
  store(ts)
  check fileExists(path)
  check not fileExists(path & ".tmp")  # atomic: no temp left behind
  when defined(posix):
    check getFilePermissions(path) == {fpUserRead, fpUserWrite}
  let back = load()
  check back.accessToken == "at"
  check back.refreshToken == "rt"
  check back.tokenType == "Bearer"
  check back.expiresAt == 123

template checkCorruptStoreIsZero(load: untyped, path: string) =
  createDir(parentDir(path))
  writeFile(path, "{\"access_token\": \"at\"" & "\n")  # truncated JSON
  let ts = load()
  check ts.accessToken == ""
  check ts.refreshToken == ""

suite "auth token store":
  test "openai store/load round-trips atomically at 0600":
    withTempStore:
      checkStoreRoundTrip(openai.storeTokens, openai.loadTokens,
                          openai.tokenPath())

  test "xai store/load round-trips atomically at 0600":
    withTempStore:
      checkStoreRoundTrip(xai.storeTokens, xai.loadTokens, xai.tokenPath())

  test "openai corrupt store reads as logged out, not a crash":
    withTempStore:
      checkCorruptStoreIsZero(openai.loadTokens, openai.tokenPath())

  test "xai corrupt store reads as logged out, not a crash":
    withTempStore:
      checkCorruptStoreIsZero(xai.loadTokens, xai.tokenPath())
