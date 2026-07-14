## Shrink `VerifyTimeoutMs` so the "silent-after-accept" verifyProfile
## regression returns in ~3s instead of the production 30s. The production
## value (an intdefine) is overridden here only for this test binary.
switch("define", "VerifyTimeoutMs=3000")
