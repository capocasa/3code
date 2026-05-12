switch("path", "src")
switch("d", "ssl")

when withDir(thisDir(), system.fileExists("config.local.nims")):
  include "config.local.nims"
