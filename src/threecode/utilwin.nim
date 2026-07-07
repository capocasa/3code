## Windows-only helpers for the color palette.
##
## Stdlib caveat: `std/winlean` exports `DWORD`, `WINBOOL`, `Handle`,
## `STD_OUTPUT_HANDLE`, and `getStdHandle`, but `std/terminal` does NOT
## re-export them (they sit inside `std/terminal`'s `when defined(windows):`
## block). Symbols in such blocks are private to the module — `import
## std/terminal` does not surface them. Same goes for `COORD` /
## `SMALL_RECT`, which are only defined (not exported) inside
## `std/terminal`. We pull what we need from `std/winlean` and declare
## the tiny struct types (`COORD`, `SMALL_RECT`) we use, matching the
## Windows SDK layout.

when defined(windows):
  import std/winlean
  export winlean.DWORD, winlean.WINBOOL, winlean.Handle
  export winlean.STD_OUTPUT_HANDLE, winlean.getStdHandle

  type
    COORD = object
      x, y: int16
    SMALL_RECT = object
      Left, Top, Right, Bottom: int16
    CONSOLE_SCREEN_BUFFER_INFOEX = object
      cbSize: DWORD
      dwSize: COORD
      dwCursorPosition: COORD
      wAttributes: int16
      srWindow: SMALL_RECT
      dwMaximumWindowSize: COORD
      wPopupAttributes: int16
      bFullscreenSupported: WINBOOL
      ColorTable: array[16, DWORD]

  proc getConsoleScreenBufferInfoEx(hConsoleOutput: Handle,
      lpConsoleScreenBufferInfo: ptr CONSOLE_SCREEN_BUFFER_INFOEX): WINBOOL{.
      stdcall, dynlib: "kernel32", importc: "GetConsoleScreenBufferInfoEx".}
  proc setConsoleScreenBufferInfoEx(hConsoleOutput: Handle,
      lpConsoleScreenBufferInfo: ptr CONSOLE_SCREEN_BUFFER_INFOEX): WINBOOL{.
      stdcall, dynlib: "kernel32", importc: "SetConsoleScreenBufferInfoEx".}

  var winPaletteSaved = false
  var winPaletteOriginal: array[16, DWORD]

  proc saveAndModWindowsPalette*() =
    ## On Windows Terminal, the Campbell palette has index 6 (cyan) as light
    ## blue #3A96DD and index 14 (bright cyan) as true cyan #61D6D6. We swap
    ## them so \e[36m renders as cyan and \e[96m as bright cyan. Saves the
    ## original values for restore.
    var hOut = getStdHandle(STD_OUTPUT_HANDLE)
    var info: CONSOLE_SCREEN_BUFFER_INFOEX
    info.cbSize = sizeof(info).DWORD
    if getConsoleScreenBufferInfoEx(hOut, addr info) == 0: return
    winPaletteOriginal = info.ColorTable
    winPaletteSaved = true
    info.ColorTable[6] = 0x00D6D636  # rgb:36/D6/D6 (true cyan)
    info.ColorTable[14] = 0x00DD963A  # rgb:3A/96/DD (light blue)
    discard setConsoleScreenBufferInfoEx(hOut, addr info)

  proc restoreWindowsPalette*() =
    ## Restore the original Windows Terminal palette.
    if not winPaletteSaved: return
    var hOut = getStdHandle(STD_OUTPUT_HANDLE)
    var info: CONSOLE_SCREEN_BUFFER_INFOEX
    info.cbSize = sizeof(info).DWORD
    if getConsoleScreenBufferInfoEx(hOut, addr info) == 0: return
    info.ColorTable = winPaletteOriginal
    discard setConsoleScreenBufferInfoEx(hOut, addr info)
    winPaletteSaved = false

else:
  # Stubs so non-Windows builds don't need `when defined(windows)` at the
  # call sites. The procs are no-ops outside Windows because nothing
  # changes the console palette there.
  proc saveAndModWindowsPalette*() = discard
  proc restoreWindowsPalette*() = discard
