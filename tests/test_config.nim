import std/[os, strutils, unittest]
import threecode/[config, types, web]

suite "config: search-url":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-config.ini"

  teardown:
    removeFile(tmp)

  test "parseConfigFile returns the search-url when set":
    writeFile(tmp, "[settings]\nsearch-url = \"https://example.com/search?q=\"\n")
    let (_, searchUrl, _) = parseConfigFile(tmp)
    check searchUrl == "https://example.com/search?q="

  test "parseConfigFile returns empty string when search-url is absent":
    writeFile(tmp, "[settings]\ncurrent = \"some-provider\"\n")
    let (_, searchUrl, _) = parseConfigFile(tmp)
    check searchUrl == ""

  test "parseConfigFile accepts search_url alias":
    writeFile(tmp, "[settings]\nsearch_url = \"https://alias.example.com/?s=\"\n")
    let (_, searchUrl, _) = parseConfigFile(tmp)
    check searchUrl == "https://alias.example.com/?s="

  test "activeSearchUrl defaults to DefaultSearchUrl":
    check activeSearchUrl == DefaultSearchUrl

suite "config: streaming toggle":
  var tmp = ""

  setup:
    tmp = getTempDir() / "3code-test-streaming.ini"
    streamingEnabled = true  # reset to default between tests

  teardown:
    removeFile(tmp)
    streamingEnabled = true

  test "streamingEnabled stays on when [settings] omits the key":
    writeFile(tmp, "[settings]\ncurrent = \"p.m\"\n")
    discard parseConfigFile(tmp)
    check streamingEnabled == true

  test "parseConfigFile sets streaming off when [settings] streaming = off":
    writeFile(tmp, "[settings]\nstreaming = \"off\"\n")
    discard parseConfigFile(tmp)
    check streamingEnabled == false

  test "parseConfigFile keeps streaming on when [settings] streaming = on":
    streamingEnabled = false
    writeFile(tmp, "[settings]\nstreaming = \"on\"\n")
    discard parseConfigFile(tmp)
    check streamingEnabled == true

  test "parseConfigFile accepts boolean dialect (yes/1/false/0)":
    writeFile(tmp, "[settings]\nstreaming = \"no\"\n")
    discard parseConfigFile(tmp)
    check streamingEnabled == false
    writeFile(tmp, "[settings]\nstreaming = \"1\"\n")
    discard parseConfigFile(tmp)
    check streamingEnabled == true

  test "writeConfigFile persists streaming off and not when on":
    streamingEnabled = false
    writeConfigFile(tmp, "p.m", @[])
    let raw = readFile(tmp)
    check raw.find("streaming = \"off\"") >= 0
    streamingEnabled = true
    writeConfigFile(tmp, "p.m", @[])
    let raw2 = readFile(tmp)
    check raw2.find("streaming") < 0  # on is the default — clean config
