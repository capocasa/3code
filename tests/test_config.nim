import std/[os, unittest]
import threecode/[config, web]

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
