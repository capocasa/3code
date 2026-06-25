## This test exercises the non-streaming transport via the `callHttpStub`
## defined in `tests/stub/http.nim`, which is `include`d into `api.nim`
## only under `-d:httpStub`. The define is test-local (it replaces the real
## `callHttp`), so it lives here rather than in the top-level `config.nims`,
## which would otherwise build a stubbed main binary.
switch("define", "httpStub")
