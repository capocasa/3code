import std/[unittest, atomics, locks]
import threecode/bufprompt

# Reset shared state between tests so order doesn't matter.
proc resetState() =
  clearBuffer()
  bufferLineReady.store(false, moRelaxed)

suite "bufprompt: drainBufferedLine basics":
  test "returns empty when buffer is empty":
    resetState()
    check drainBufferedLine() == ""

  test "returns empty when no newline present":
    resetState()
    feedBuffer("partial input without newline")
    check drainBufferedLine() == ""

  test "returns single line and clears it":
    resetState()
    feedBuffer("hello world\n")
    check drainBufferedLine() == "hello world"
    # Buffer should now be empty
    check drainBufferedLine() == ""

  test "returns first line, leaves remainder":
    resetState()
    feedBuffer("line one\nline two\n")
    check drainBufferedLine() == "line one"
    check drainBufferedLine() == "line two"
    check drainBufferedLine() == ""

  test "handles multiple lines with trailing content":
    resetState()
    feedBuffer("a\nb\npartial")
    check drainBufferedLine() == "a"
    check drainBufferedLine() == "b"
    check drainBufferedLine() == ""

  test "preserves UTF-8 content":
    resetState()
    feedBuffer("café résumé 🧡\n")
    check drainBufferedLine() == "café résumé 🧡"

  test "handles empty line between newlines":
    resetState()
    feedBuffer("\n\n")
    check drainBufferedLine() == ""
    check drainBufferedLine() == ""
    check drainBufferedLine() == ""

suite "bufprompt: bufferLineReady flag":
  test "starts false after reset":
    resetState()
    check bufferLineReady.load(moAcquire) == false

  test "caller can set it to true":
    resetState()
    bufferLineReady.store(true, moRelease)
    check bufferLineReady.load(moAcquire) == true

  test "drainBufferedLine clears flag when no more complete lines remain":
    resetState()
    bufferLineReady.store(true, moRelease)
    feedBuffer("only line\n")
    discard drainBufferedLine()
    check bufferLineReady.load(moAcquire) == false

  test "drainBufferedLine keeps flag true when more complete lines remain":
    resetState()
    bufferLineReady.store(true, moRelease)
    feedBuffer("first\nsecond\n")
    discard drainBufferedLine()
    check bufferLineReady.load(moAcquire) == true
    discard drainBufferedLine()
    check bufferLineReady.load(moAcquire) == false

  test "drainBufferedLine does not set flag for incomplete input":
    resetState()
    bufferLineReady.store(false, moRelaxed)
    feedBuffer("no newline here")
    check drainBufferedLine() == ""
    check bufferLineReady.load(moAcquire) == false

suite "bufprompt: clearBuffer":
  test "clears buffered content":
    resetState()
    feedBuffer("some text\nmore\n")
    bufferLineReady.store(true, moRelease)
    clearBuffer()
    check drainBufferedLine() == ""

  test "resets bufferLineReady to false":
    resetState()
    bufferLineReady.store(true, moRelease)
    clearBuffer()
    check bufferLineReady.load(moAcquire) == false

  test "is idempotent":
    resetState()
    clearBuffer()
    clearBuffer()
    check bufferLineReady.load(moAcquire) == false

# Thread-safety is documented but not unit-tested; the lock-based
# design is straightforward and would need concurrency stress tests
# to verify meaningfully.
