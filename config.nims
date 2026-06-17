switch("path", "src")
switch("d", "ssl")

when withDir(thisDir(), system.fileExists("config.local.nims")):
  include "config.local.nims"
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
