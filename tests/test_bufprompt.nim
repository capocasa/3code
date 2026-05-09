import std/[unittest, atomics, locks]
import threecode/bufprompt

# Reset shared state between tests so order doesn't matter.
proc resetState() =
  clearBuffer()
  bufferLineReady.store(false, moRelaxed)
  # Re-seed with empty under lock for a clean slate.
  acquire(bufLock)
  bufferedInput = ""
  release(bufLock)

suite "bufprompt: drainBufferedLine basics":
  test "returns empty when buffer is empty":
    resetState()
    check drainBufferedLine() == ""

  test "returns empty when no newline present":
    resetState()
    acquire(bufLock)
    bufferedInput = "partial input without newline"
    release(bufLock)
    check drainBufferedLine() == ""

  test "returns single line and clears it":
    resetState()
    acquire(bufLock)
    bufferedInput = "hello world\n"
    release(bufLock)
    check drainBufferedLine() == "hello world"
    # Buffer should now be empty
    check drainBufferedLine() == ""

  test "returns first line, leaves remainder":
    resetState()
    acquire(bufLock)
    bufferedInput = "line one\nline two\n"
    release(bufLock)
    check drainBufferedLine() == "line one"
    check drainBufferedLine() == "line two"
    check drainBufferedLine() == ""

  test "handles multiple lines with trailing content":
    resetState()
    acquire(bufLock)
    bufferedInput = "a\nb\npartial"
    release(bufLock)
    check drainBufferedLine() == "a"
    check drainBufferedLine() == "b"
    check drainBufferedLine() == ""

  test "preserves UTF-8 content":
    resetState()
    acquire(bufLock)
    bufferedInput = "café résumé 🧡\n"
    release(bufLock)
    check drainBufferedLine() == "café résumé 🧡"

  test "handles empty line between newlines":
    resetState()
    acquire(bufLock)
    bufferedInput = "\n\n"
    release(bufLock)
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
    acquire(bufLock)
    bufferedInput = "only line\n"
    release(bufLock)
    discard drainBufferedLine()
    check bufferLineReady.load(moAcquire) == false

  test "drainBufferedLine keeps flag true when more complete lines remain":
    resetState()
    bufferLineReady.store(true, moRelease)
    acquire(bufLock)
    bufferedInput = "first\nsecond\n"
    release(bufLock)
    discard drainBufferedLine()
    check bufferLineReady.load(moAcquire) == true
    discard drainBufferedLine()
    check bufferLineReady.load(moAcquire) == false

  test "drainBufferedLine does not set flag for incomplete input":
    resetState()
    bufferLineReady.store(false, moRelaxed)
    acquire(bufLock)
    bufferedInput = "no newline here"
    release(bufLock)
    check drainBufferedLine() == ""
    check bufferLineReady.load(moAcquire) == false

suite "bufprompt: clearBuffer":
  test "clears buffered content":
    resetState()
    acquire(bufLock)
    bufferedInput = "some text\nmore\n"
    release(bufLock)
    bufferLineReady.store(true, moRelease)
    clearBuffer()
    acquire(bufLock)
    check bufferedInput == ""
    release(bufLock)
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
    acquire(bufLock)
    check bufferedInput == ""
    release(bufLock)
    check bufferLineReady.load(moAcquire) == false

# Thread-safety is documented but not unit-tested; the lock-based
# design is straightforward and would need concurrency stress tests
# to verify meaningfully.
