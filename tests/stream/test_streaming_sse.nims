## Shrink `VerifyTimeoutMs` so the "silent-after-accept" verifyProfile
## regression returns in ~3s instead of the production 30s. The production
## value (an intdefine) is overridden here only for this test binary.
switch("define", "VerifyTimeoutMs=3000")
# Shrink the non-streaming black-hole ceiling so the "black-holed request
# dies at the cap" test runs in ~5s instead of the production 30min. The
# production value (an intdefine) is overridden here only for this test
# binary; the suite's other slow-wait tests stay well under it.
switch("define", "NonStreamTooLongMs=5000")
