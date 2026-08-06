## TLS smoke check for the Termux CI smoke job (termux.yml). Compiled and
## run inside the emulated Termux container against the freshly built
## android binary's runtime environment: the openssl wrapper dlopens
## libssl.so.3/libcrypto.so.3 at module init, which only resolves when the
## binary's DT_RUNPATH points at the Termux lib dir (see config.nims). A
## verified handshake exercises exactly the code path api.nim depends on.
import std/net, std/nativesockets

let ctx = newContext(verifyMode = CVerifyPeer)
let s = newSocket()
ctx.wrapSocket(s)
s.connect("github.com", Port(443))
echo "tls handshake ok"
s.close()
