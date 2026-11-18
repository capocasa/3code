## The `-c` / `-C` layer stack: pure argv scan, read-path resolution,
## and the write target. These are unit-level (no binary spawn); the
## binary-level contract lives in tests/core/test_cli_args.nim.

discard """
  targets: "c"
  matrix: ""
"""

import std/[os, unittest]
import threecode/[config, util]

suite "config: flag scan":
  test "no flags means no layers and no clear":
    let s = scanConfigFlags(@["hello", "world"])
    check s.layers.len == 0
    check not s.cleared

  test "-c and --config, space and attached forms":
    let s = scanConfigFlags(@["-c", "a", "--config", "b", "--config=c",
                              "-cd", "-c=e", "-c:f"])
    check s.layers == @["a", "b", "c", "d", "e", "f"]
    check not s.cleared

  test "bare -C clears without an operand":
    let s = scanConfigFlags(@["-C"])
    check s.cleared
    check s.layers.len == 0

  test "-C consumes a following non-flag operand":
    check scanConfigFlags(@["-C", "a"]).layers == @["a"]
    check scanConfigFlags(@["--config-clear", "a"]).layers == @["a"]
    check scanConfigFlags(@["-C", "-x"]).layers.len == 0
    check scanConfigFlags(@["-C"]).layers.len == 0
    # Each clear resets: the last one owns the stack.
    check scanConfigFlags(@["--config-clear=a", "-Cb", "-C=c"]).layers ==
      @["c"]
    check scanConfigFlags(@["-C", "a", "-C", "b"]).layers == @["b"]

  test "-c a -C b resets to just b":
    let s = scanConfigFlags(@["-c", "a", "-C", "b"])
    check s.cleared
    check s.layers == @["b"]

  test "-C a -c b keeps both":
    let s = scanConfigFlags(@["-C", "a", "-c", "b"])
    check s.cleared
    check s.layers == @["a", "b"]

  test "-- ends the scan":
    let s = scanConfigFlags(@["--", "-c", "a"])
    check s.layers.len == 0
    check not s.cleared

  test "a value-taking letter before c owns the cluster":
    # -mc v sets a model; the c is the model value, not a config flag.
    let s = scanConfigFlags(@["-mc", "v"])
    check s.layers.len == 0
    # -xc v: booleans pass through, the c takes the next token.
    check scanConfigFlags(@["-xc", "v"]).layers == @["v"]

suite "config: read stack and write target":
  setup:
    let savedLayers = configLayers
    let savedCleared = configCleared
    let savedProject = projectLayer

  teardown:
    configLayers = savedLayers
    configCleared = savedCleared
    projectLayer = savedProject

  test "empty stack reads the user global":
    applyConfigFlags(@[])
    check configReadPaths() == @[userConfigRoot() / "config"]
    check configPath() == userConfigRoot() / "config"

  test "explicit layers replace the user global on read":
    applyConfigFlags(@["-c", "a", "-c", "b"])
    check configReadPaths() == @["a", "b"]
    check configPath() == "b"

  test "the project layer reads last":
    applyConfigFlags(@[])
    projectLayer = "proj"
    check configReadPaths() == @[userConfigRoot() / "config", "proj"]
    applyConfigFlags(@["-c", "a"])
    check configReadPaths() == @["a", "proj"]
    # The write target is the last explicit layer, never the project.
    check configPath() == "a"

  test "-C drops the implicit layers entirely":
    projectLayer = "proj"
    applyConfigFlags(@["-C"])
    check configReadPaths().len == 0
    # Empty stack still writes the user global (write target rule).
    check configPath() == userConfigRoot() / "config"
    applyConfigFlags(@["-C", "a", "-c", "b"])
    check configReadPaths() == @["a", "b"]
    check configPath() == "b"

  test "applyConfigFlags is idempotent":
    applyConfigFlags(@["-c", "a", "-c", "b"])
    applyConfigFlags(@["-c", "a", "-c", "b"])
    check configLayers == @["a", "b"]

  test "addConfigLayer appends, clearConfigLayers resets":
    applyConfigFlags(@["-c", "a"])
    addConfigLayer("b")
    check configReadPaths() == @["a", "b"]
    clearConfigLayers("z")
    check configReadPaths() == @["z"]
    clearConfigLayers("")
    check configReadPaths().len == 0
