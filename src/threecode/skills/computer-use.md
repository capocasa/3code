# task: computer-use

For driving the user's desktop: reading the screen and acting on it with
the mouse and keyboard. Load when the task is "click this", "open that
app", "reproduce this UI", or anything where the answer is on screen
rather than in a file.

## The loop

Observe → act → verify. `screenshot()` to see the screen, ONE action
through the `shot` script, then `screenshot()` again to check what the
action actually did. Screenshots cost image tokens; acting on stale
assumptions costs more.

## Coordinates

Every coordinate you read off a screenshot is in the delivered raster's
pixels (≤1280 on the long edge), NOT the native screen. The `shot`
script takes delivered-raster coordinates and maps them itself:

    shot click 640 360
    shot doubleclick 200 150        (also rightclick, middleclick)
    shot drag 100 100 400 400
    shot type "hello world"
    shot key ctrl+s                 (also enter, alt+Tab, ctrl+shift+t)
    shot scroll up 3                (or scroll down 5)
    shot title                      (active window + geometry)

Never do the scale math yourself, and never feed screenshot coordinates
to raw xdotool — always go through `shot`. The activation note in the
conversation carries the absolute path.

## Rules learned the hard way

- **Never replay a sent action.** Once you emit a `shot` call it may
  already have run, even if the turn was interrupted. Re-observe
  (screenshot) before acting again after any uncertainty.
- **Stale frame = stop.** `shot: stale frame ... call screenshot()`
  means the screen geometry changed since your last capture. Take a
  fresh screenshot; your coordinates are meaningless against it.
- **Screenshots show pixels, not correctness.** A green window proves
  rendering, not that the program is right; verify real work from
  artifacts (files, exit codes, tests).
- **You are on the user's desktop.** No sandbox stands between `shot`
  and their session; the user sees every action. Esc/Ctrl-C is the
  panic button. Stop driving the desktop the moment the task stops
  needing it.
- **Do not spam captures.** Three screenshots in a row without an
  action in between means you are avoiding the task, not observing.
