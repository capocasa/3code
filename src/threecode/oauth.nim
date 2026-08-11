## Generic OAuth 2.0 + PKCE plumbing for coding-agent login flows.
##
## Two grant types, both returning tokens as parsed JSON:
##
## - Browser flow: PKCE with a loopback redirect listener on 127.0.0.1.
##   `browserAuthUrl` builds the authorize URL, `awaitLoopbackCode` runs a
##   minimal one-shot HTTP server to catch the redirect, `exchangeCode`
##   trades the code for tokens.
## - Device flow (RFC 8628) for headless hosts: `requestDeviceCode`,
##   then `pollDeviceToken` until the user approves or the code expires.
##
## This module is deliberately dumb: it knows HTTP, PKCE, and JSON, and
## nothing about any specific provider, where tokens are stored, or how
## the user is shown a URL. Provider specifics live in `auth_xai.nim`,
## persistence in the caller, presentation in `ui.nim`.

import std/[base64, httpclient, json, nativesockets, net, random,
            strutils, times, uri]
import libsha/sha256
import util

# PKCE verifiers need entropy; seed once at module load.
randomize()

type
  OAuthEndpoints* = object
    ## Everything generic OAuth needs to know about a provider.
    authorize*, token*, deviceCode*: string  ## deviceCode "" = no device flow
    clientId*, scope*: string

  OAuthError* = object of CatchableError

  TokenSet* = object
    ## The parts of a token response worth keeping.
    accessToken*, refreshToken*, tokenType*: string
    expiresAt*: int64  ## epoch seconds; 0 when the server sent no expiry

proc randomUrlSafe(n: int): string =
  ## n random bytes, base64url-encoded without padding.
  var bytes = newSeq[byte](n)
  for b in bytes.mitems: b = byte(rand(255))
  base64.encode(bytes, safe = true).replace("=", "")

proc pkceChallenge*(verifier: string): string =
  ## S256 challenge per RFC 7636. libsha exposes the digest state as
  ## eight u32 words; serialize big-endian for the wire encoding.
  let s = newSha256().add(verifier)
  s.finish()
  var digest: array[32, byte]
  for i, w in s.values:
    digest[i*4] = byte(w shr 24)
    digest[i*4+1] = byte(w shr 16)
    digest[i*4+2] = byte(w shr 8)
    digest[i*4+3] = byte(w)
  base64.encode(digest, safe = true).replace("=", "")

proc newPkceVerifier*(): string =
  randomUrlSafe(48)

proc postForm(client: HttpClient, url: string,
              fields: openArray[(string, string)]): JsonNode =
  ## POST application/x-www-form-urlencoded, return parsed JSON body.
  ## Raises OAuthError on non-2xx with the server's error text.
  # usePlus=false: %20 for spaces, matching what OAuth servers expect
  # for form fields that may contain '+'-sensitive values.
  let body = encodeQuery(fields, usePlus = false)
  client.headers["Content-Type"] = "application/x-www-form-urlencoded"
  let resp = client.post(url, body = body)
  let j = try: parseJson(resp.body) except CatchableError: newJObject()
  if resp.code.int notin 200..299:
    let detail =
      if "error_description" in j: j["error_description"].getStr
      elif "error" in j: j["error"].getStr
      else: resp.body[0 ..< min(200, resp.body.len)]
    raise newException(OAuthError,
      "HTTP " & $resp.code.int & " — " & detail)
  j

proc toTokenSet(j: JsonNode): TokenSet =
  result.accessToken = j{"access_token"}.getStr
  result.refreshToken = j{"refresh_token"}.getStr
  result.tokenType = j{"token_type"}.getStr("Bearer")
  if result.accessToken == "":
    raise newException(OAuthError, "token response had no access_token")
  let ttl = j{"expires_in"}.getInt(0)
  if ttl > 0:
    result.expiresAt = epochTime().int64 + ttl

proc newOAuthClient(): HttpClient =
  newHttpClient(timeout = 30_000, userAgent = "3code",
                sslContext = bundledSslContext())

proc browserAuthUrl*(ep: OAuthEndpoints, redirectUri, state,
                     challenge: string; extra: openArray[(string, string)] = []): string =
  ## Build the authorize URL the user opens in a browser.
  var q = @[("response_type", "code"), ("client_id", ep.clientId),
            ("redirect_uri", redirectUri), ("scope", ep.scope),
            ("state", state), ("code_challenge", challenge),
            ("code_challenge_method", "S256")]
  for kv in extra: q.add kv
  var u = parseUri(ep.authorize)
  u.query = encodeQuery(q)
  $u

proc exchangeCode*(ep: OAuthEndpoints, code, redirectUri,
                   verifier: string): TokenSet =
  let client = newOAuthClient()
  defer: client.close()
  toTokenSet(postForm(client, ep.token, [
    ("grant_type", "authorization_code"), ("client_id", ep.clientId),
    ("code", code), ("redirect_uri", redirectUri),
    ("code_verifier", verifier)]))

proc refreshTokens*(ep: OAuthEndpoints, refreshToken: string): TokenSet =
  ## Exchange a refresh token. On servers that rotate refresh tokens the
  ## returned set carries the new one; otherwise `refreshToken` in the
  ## response is empty and the caller keeps the old one.
  let client = newOAuthClient()
  defer: client.close()
  result = toTokenSet(postForm(client, ep.token, [
    ("grant_type", "refresh_token"), ("client_id", ep.clientId),
    ("refresh_token", refreshToken)]))
  if result.refreshToken == "":
    result.refreshToken = refreshToken

proc requestDeviceCode*(ep: OAuthEndpoints): JsonNode =
  ## POST the device-authorization endpoint. Raw JSON: device_code,
  ## user_code, verification_uri(_complete), interval, expires_in.
  let client = newOAuthClient()
  defer: client.close()
  postForm(client, ep.deviceCode, [
    ("client_id", ep.clientId), ("scope", ep.scope)])

proc pollDeviceToken*(ep: OAuthEndpoints, deviceCode: string): TokenSet =
  ## One poll of the token endpoint for a pending device flow.
  ## Raises OAuthError on a hard failure; the caller repeats while the
  ## error is `authorization_pending` / `slow_down` — those come back as
  ## OAuthError too, distinguishable by `pendingError` below.
  let client = newOAuthClient()
  defer: client.close()
  toTokenSet(postForm(client, ep.token, [
    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
    ("client_id", ep.clientId), ("device_code", deviceCode)]))

proc pendingError*(e: ref OAuthError): string =
  ## Classify a poll failure: "authorization_pending" / "slow_down" mean
  ## keep waiting; anything else is terminal.
  let m = e.msg
  if "authorization_pending" in m: "authorization_pending"
  elif "slow_down" in m: "slow_down"
  else: ""

proc remainingMs(deadline: float): int =
  max(int((deadline - epochTime()) * 1000), 0)

proc awaitLoopbackCode*(listenPort: int, expectState: string,
                        timeoutSec = 300): string =
  ## One-shot blocking TCP listener on 127.0.0.1:listenPort. Reads a single
  ## HTTP request line (the OAuth redirect), replies 200, returns the code.
  ## No async: select + accept + recvLine with a hard deadline.
  let server = newSocket()  # buffered: recvLine needs the buffer
  defer: server.close()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(listenPort), "127.0.0.1")
  server.listen()
  let deadline = epochTime() + timeoutSec.float

  var client: Socket
  while client.isNil:
    let ms = remainingMs(deadline)
    if ms == 0:
      raise newException(OAuthError, "timed out waiting for browser callback")
    var fds = @[server.getFd()]
    if selectRead(fds, min(ms, 1000)) <= 0:
      continue
    var address = ""
    server.acceptAddr(client, address)
  defer: client.close()

  # Request line only: GET /callback?code=...&state=... HTTP/1.1
  # (headers/body are irrelevant for the OAuth redirect).
  let firstLine = try:
    client.recvLine(timeout = remainingMs(deadline))
  except TimeoutError:
    raise newException(OAuthError, "timed out reading browser callback")
  var path = ""
  let parts = firstLine.split(' ')
  if parts.len >= 2: path = parts[1]
  var code, state, err: string
  for (k, v) in decodeQuery(parseUri(path).query):
    case k
    of "code": code = v
    of "state": state = v
    of "error": err = v
    else: discard

  const body =
    "Authorization received. You can close this tab and return to the terminal."
  let resp = "HTTP/1.1 200 OK\r\n" &
    "Content-Type: text/plain; charset=utf-8\r\n" &
    "Content-Length: " & $body.len & "\r\n" &
    "Connection: close\r\n\r\n" & body
  try: client.send(resp)
  except CatchableError: discard

  if err != "":
    raise newException(OAuthError, "authorization failed: " & err)
  if code == "":
    raise newException(OAuthError, "timed out waiting for browser callback")
  if state != expectState:
    raise newException(OAuthError, "state mismatch in OAuth callback")
  code
