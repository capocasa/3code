switch("path", "src")
switch("d", "ssl")
switch("d", "testPlainHttp")

when withDir(thisDir(), system.fileExists("config.local.nims")):
  include "config.local.nims"

