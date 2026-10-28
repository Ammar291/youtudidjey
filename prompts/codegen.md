Exploration is over. Now write `solution.py`: a Python program that does what you just did, with no LLM.
Write it to `{{solution}}` (in your working directory); you may not write anywhere else.

## What it must do

It is run as `python -X utf8 solution.py --chrome-profile DIR` by youtudidjey, which talks to it over
stdin and stdout:

1. At start: open Chrome on YouTube with `blindly4 open --url https://www.youtube.com --chrome-profile DIR`.
   If this profile's Chrome is already running, find its window with `blindly4 apps` and use that.
   When the page is ready, print `READY`.
2. Then read song queries from stdin, one per line. For each one: search for it and play it. Print
   `PLAYING` as soon as the song itself (not an ad) is playing. Pause it 3 seconds before its end
   (±0.5 s), then print `PAUSED`. Only then read the next line.
3. When stdin ends, close the Chrome window with its own Close button and exit with code 0.

Print only these words (and `SKIPPED`, below) on stdout, each on its own line and flushed immediately.
Diagnostics go to stderr.

## Constraints

- **Only blindly4 touches the browser**: call the `blindly4` executable (it is on PATH) through
  `subprocess`. No other UI automation, no network access, no LLM, and nothing outside the Python 3.13
  standard library.
- Use blindly4's JSON output (the default without `--format xml`). `find` prints
  `{"matches":[{"path","role","title","description","identifier","value","position":{"x","y"},"size":{"width","height"}}],"truncated":…}`.
  A failed call exits non-zero and prints `{"error":…,"code":…}`. `find` searches 8 levels deep
  unless given `--depth` (page content needs about 15, or use `--under`).
- Encode what you learned: the selectors that worked, how long things took, how to tell an ad from the
  song, how you recovered from failures. Don't encode paths: find elements every time.
- Be fast: the time from reading a song to printing `PLAYING` is what gets measured. Use narrow
  searches (`--identifier`, `--role`, `--under`, `--limit`), and poll briefly (about 0.3–0.5 s) instead
  of sleeping long. Read-only calls that don't depend on each other may run in parallel. Input actions
  must not.
- Be robust: bound every wait with a timeout and retry a failed step by finding its element again. If a
  song cannot be played within about 90 s, say why on stderr, print `SKIPPED` instead of `PLAYING` and
  `PAUSED`, and go on with the next one, so that the DJ never stops.
- Time the pause from a fresh slider reading, and read it again about 20 s before the end, in case an
  ad or buffering moved the end. A reading is fresh only right after the pointer **moved** over the
  player: alternate the hover between two points, never the same point twice in a row. If readings
  still don't advance, fall back to the time elapsed since the song started playing. Press Pause by query, not by path:
  `press --under PLAYER --role button --title Pause --expect-description Pause`, optionally with
  `--at T`.
- **Functional style**: a pure core (parsing outputs, choosing a result, computing deadlines) separate
  from the few functions that call blindly4. Use immutable data (`NamedTuple`, tuples, frozen
  dataclasses), no mutable globals, and `map`/`filter`/comprehensions/`functools`/`itertools` where
  they read naturally.
- Keep it short and readable: about 150–250 lines.

## Shape

```python
import json, subprocess, sys
from typing import NamedTuple

class Element(NamedTuple):
    path: str
    title: str
    identifier: str
    value: str
    x: int  # centre of the element on screen
    y: int

def b4(*args: str) -> dict:
    """Runs one blindly4 command and returns its JSON output; errors come back as {"error": …}."""
    done = subprocess.run(("blindly4", *args), capture_output=True, text=True, encoding="utf-8")
    return json.loads(done.stdout or '{"error": "no output"}')

def say(word: str) -> None:
    print(word, flush=True)

def main(profile: str) -> None:
    pid = open_youtube(profile)
    say("READY")
    for song in filter(None, map(str.strip, sys.stdin)):
        play(pid, song)              # prints PLAYING
        pause_before_end(pid)        # prints PAUSED
    close_window(pid)
```

## Test it

1. Close your own Chrome window first (its Close button), so that the profile is free.
2. Test once with the shortest song you played. Run exactly this command, with a 600000 ms timeout,
   from your working directory: no `cd`, no other path to the script, nothing chained before or after
   it (any other form is refused):
   `echo "<song>" | python -X utf8 solution.py --chrome-profile {{profile}}`
   Check that it printed `READY`, `PLAYING` and `PAUSED`, that the pause came about 3 s before the
   end, and that it exited with code 0 after closing Chrome.
3. If something is wrong, fix it and test again, at most twice.

Finish with a short summary: how `solution.py` works, what the test showed, and any known weakness.
