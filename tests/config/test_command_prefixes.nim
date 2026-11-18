## `[settings] system-command-prefixes`: each non-whitespace character
## of the value is one command prefix, duplicates collapse, and a later
## (higher-priority) line replaces the inherited set instead of
## extending it. Missing keeps the compiled `:` default; an empty value
## is a schema error.
import std/[os, strutils, unittest]
import threecode/[config, types, util]

suite "config: normalizeCommandPrefixes":
  test "whitespace between prefixes is optional":
    check normalizeCommandPrefixes(": /") == ":/"
    check normalizeCommandPrefixes(":/") == ":/"
    check normalizeCommandPrefixes(" :  / ") == ":/"

  test "single prefix survives untouched":
    check normalizeCommandPrefixes(":") == ":"
    check normalizeCommandPrefixes("/") == "/"

  test "duplicates collapse to one occurrence":
    check normalizeCommandPrefixes("::") == ":"
    check normalizeCommandPrefixes(": : /:") == ":/"

  test "empty value normalizes to the empty set":
    check normalizeCommandPrefixes("") == ""
    check normalizeCommandPrefixes("   ") == ""

suite "config: system-command-prefixes parsing":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-cmdprefix.ini"
    commandPrefixes = ":"

  teardown:
    removeFile(tmp)
    commandPrefixes = ":"

  test "missing setting keeps the compiled ':' default":
    writeFile(tmp, "[settings]\ncurrent = \"p.m\"\n")
    discard parseConfigFile(tmp)
    check commandPrefixes == ":"

  test "single prefix parses":
    writeFile(tmp, "[settings]\nsystem-command-prefixes = \"/\"\n")
    discard parseConfigFile(tmp)
    check commandPrefixes == "/"
    check isCommandPrefix('/')
    check not isCommandPrefix(':')

  test "spaced and unspaced multiple prefixes are equivalent":
    writeFile(tmp, "[settings]\nsystem-command-prefixes = \": /\"\n")
    discard parseConfigFile(tmp)
    check commandPrefixes == ":/"
    writeFile(tmp, "[settings]\nsystem-command-prefixes = \":/\"\n")
    discard parseConfigFile(tmp)
    check commandPrefixes == ":/"

  test "duplicate prefixes are ignored":
    writeFile(tmp, "[settings]\nsystem-command-prefixes = \"/ :/\"\n")
    discard parseConfigFile(tmp)
    check commandPrefixes == "/:"

  test "underscore spelling accepted":
    writeFile(tmp, "[settings]\nsystem_command_prefixes = \":/\"\n")
    discard parseConfigFile(tmp)
    check commandPrefixes == ":/"

  test "empty value is a configuration error":
    writeFile(tmp, "[settings]\nsystem-command-prefixes = \"\"\n")
    try:
      discard parseConfigFile(tmp)
      fail()
    except ValueError as e:
      # parsecfg reports the line past the pair it just consumed
      check e.msg == tmp & ":3: empty value for 'system-command-prefixes' " &
             "in [settings]"

  test "whitespace-only value is a configuration error":
    let m = validateConfig(tmp, @[("settings", "system-command-prefixes",
                                   "  ", 3)])
    check m == tmp & ":3: empty value for 'system-command-prefixes' " &
           "in [settings]"

  test "a higher-priority line replaces the inherited set":
    # Replacement, not extension: the later line's set is the whole set,
    # so ':' from the first line does not survive alongside '/'.
    writeFile(tmp, "[settings]\nsystem-command-prefixes = \":\"\n" &
                   "system-command-prefixes = \"/\"\n")
    discard parseConfigFile(tmp)
    check commandPrefixes == "/"
    check not isCommandPrefix(':')

  test "a parse without the key inherits the prior set":
    commandPrefixes = ":/"
    writeFile(tmp, "[settings]\ncurrent = \"p.m\"\n")
    discard parseConfigFile(tmp)
    check commandPrefixes == ":/"

  test "writer persists a non-default set, omits the default":
    commandPrefixes = ":/"
    writeConfigFile(tmp, "test.model-a", @[
      ProviderRec(name: "test", url: "https://api.test.com",
                  key: "sk-test", models: @["model-a"]),
    ])
    check readFile(tmp).contains("system-command-prefixes = \":/\"\n")
    commandPrefixes = ":"
    writeConfigFile(tmp, "", @[])
    check not readFile(tmp).contains("system-command-prefixes")
