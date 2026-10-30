## Compiled with `-d:httpStub` so `callHttp` is stubbed while the whole
## `callModel` body-building path runs for real (see
## tests/testdata/stub/http.nim). test_vision_wire.nim asserts image
## content blocks reach the endpoint on the deepseek wire surface.
switch("define", "httpStub")
