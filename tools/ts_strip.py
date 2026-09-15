#!/usr/bin/env python3
"""Strip util-linux script(1)'s leading banner from a typescript.

This host's script writes one banner line at offset 0 starting with
"Script started" and ending "]\n" before the raw stream. Anything typed
before the stream begins is not in the file, so offset 0 is safe to
inspect. A trailing "Script done ..." footer is removed too if the
wrapped command exited (it usually has not in these repros).
"""
import sys

data = open(sys.argv[1], "rb").read()
if data.startswith(b"Script started"):
    nl = data.find(b"\n")
    if nl >= 0:
        data = data[nl + 1:]
i = data.rfind(b"Script done ")
if i >= 0 and i > len(data) - 200:
    data = data[:i]
sys.stdout.buffer.write(data)
