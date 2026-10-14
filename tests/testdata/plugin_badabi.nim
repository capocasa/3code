#[ Deliberately incompatible fixture: wrong ABI version, no hooks.
   The host must refuse it, note why, and keep serving the good lib. ]##

proc tc_abi_version*(): cint {.exportc, dynlib, cdecl.} = 4242.cint
