## Test-only define for the aside suite.
##
## BtwReapWaitMs shrinks the retired worker's wait for a reap handshake
## that a cancelled aside never gets (it is wall-clock bounded in the
## source), so the interrupt test's reap wait stays short.
switch("define", "BtwReapWaitMs=1000")
