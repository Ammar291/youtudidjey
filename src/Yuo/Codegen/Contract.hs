-- | What solution.py must be: its interface, its rules, and its functional style.
module Yuo.Codegen.Contract
  ( contractText
  , fpRulesText
  , driverTimingText
  ) where

import Data.Text (Text)
import qualified Data.Text as T

contractText :: Text
contractText =
  T.unlines
    [ "Write solution.py: a standalone Python 3.13 program (standard library only) that plays a list of YouTube songs in an already-open Google Chrome using only blindly4 — no LLM, no network access of its own."
    , ""
    , "Command line: --songs FILE (UTF-8, one search query per line; skip blank lines and lines starting with #), --max-songs N (stop after N songs; without it, play forever), --forever (explicit forever), --start-index N (first list position, default 0), --max-play-seconds S (testing only: pause S seconds after playback starts if that comes first)."
    , ""
    , "Behaviour, per song, looping over the list forever (itertools.cycle):"
    , "1. Emit song_assigned BEFORE any blindly4 call for that song."
    , "2. Search YouTube for the query and open the right video: the song itself (official video/audio or a normal upload), not a mix, playlist, Short, live stream or loop."
    , "3. Make sure it plays from its beginning; emit playback_started when you see it playing (include \"position\" if known)."
    , "4. Wait until 3 seconds before the end of the video, then pause it; emit paused with \"duration\" (video length in seconds you used) and \"remaining\" (seconds left by your computation)."
    , "5. Then the next song. If a song cannot be found or played after a few retries, emit step_error with a \"reason\" and continue with the next song."
    , "Exit with status 0 after --max-songs songs."
    , ""
    , "The browser: Chrome is already open on YouTube; its process id is in the environment variable YUO_CHROME_PID. Never open or close the browser."
    , "blindly4: call it ONLY through the command prefix in the environment variable YUO_B4 (a JSON array of strings): subprocess.run([*prefix, *args], capture_output=True) with args a blindly4 argument list that includes \"--pid\", pid. Decode stdout/stderr as UTF-8. stdout is JSON (XML with --format xml). Exit codes: 0 ok, 64 usage error or refused by the safety guard, 77 accessibility error (target gone, not foreground, ...)."
    , "Every call except apps and schema must include --pid with the YUO_CHROME_PID value; the proxy refuses calls aimed at any other window."
    , "The proxy refuses: type, click, paste; press/set-value/focus without --expect-description; labels that start with, or are fragments of, subscribe, like, dislike, share, save, join, comment, reply, report, sign in, buy, premium, download, thanks, clip, remix, notify, create, upload; keys other than escape, f5, a digit, or return/enter given with --target-path and --require-value."
    , "Keyboard and pointer input (key, hover, scroll) need Chrome in the foreground: run \"activate\" first when needed."
    , "Tree paths change whenever the page changes: find an element again right before acting on it; when reusing a remembered path, check it first and fall back to find."
    , "Read-only lookups may run concurrently (concurrent.futures; the first successful result wins); input commands must run one at a time."
    , ""
    , "Events: append one JSON object per line to the file named in the environment variable YUO_EVENTS (UTF-8; open, append, close each time):"
    , "{\"t\": time.time(), \"stage\": \"exploitation\", \"source\": \"solution\", \"kind\": KIND, \"song_index\": list position, \"song\": query, ...extra fields}"
    , "KIND is one of song_assigned, playback_started, paused, ad_seen, step_error."
    , ""
    , fpRulesText
    ]

fpRulesText :: Text
fpRulesText =
  T.unlines
    [ "Style — functional programming (checked by a linter; violations are rejected):"
    , "- Pure functions for parsing, matching and decisions; side effects (blindly4 calls, clock, sleep, event writes) confined to a small, clearly named set of effect functions."
    , "- Immutable data only: @dataclass(frozen=True), NamedTuple, tuples, frozenset. No mutable globals."
    , "- Use lambdas (at least 5), map/filter, functools.reduce, functools.partial, itertools (cycle, islice, repeat, takewhile, dropwhile, count), and a compose/pipe helper."
    , "- Forbidden: while loops (iterate lazily: e.g. next(filter(ready, map(probe, itertools.repeat(None))))), global, nonlocal, augmented assignment (+= etc.), del, item or attribute assignment, mutating methods (append, extend, insert, pop, remove, clear, update, setdefault, popitem, add, discard, sort, reverse), classes other than frozen dataclasses / NamedTuple / Enum."
    , "- Forbidden imports: anthropic, openai, requests, urllib, http, socket, httpx, aiohttp, ctypes, comtypes, pywinauto, uiautomation, win32*, selenium, playwright, webbrowser, asyncio, importlib, multiprocessing, ssl and other network modules; no __import__/eval/exec/compile; no os.system/os.popen/os.startfile/os.spawn*/os.exec*; no string mentioning claude, codex or blindly4.exe."
    , "- Every subprocess call is a direct call (not via partial or an alias) whose command is exactly [*prefix, *args] with prefix = the YUO_B4 array used whole — never index or slice it."
    ]

-- | How exploration's own (non-LLM) driver timed the pause — part of the collected data.
driverTimingText :: Text
driverTimingText =
  T.unlines
    [ "How the exploration stage's timer paused each song (its calls appear in the trace with origin \"driver\"):"
    , "- Right after playback was confirmed it hovered the pointer over the centre of the YouTube player (\"hover\" with the player element's frame centre) and then read the player's seek slider; the slider's value text (\"X Minutes Y Seconds of A Minutes B Seconds\") is only up to date right after such a hover — without it the text can be stale, even showing a finished ad."
    , "- It computed start = now − position and deadline = start + duration − 3 s − 0.6 s (the pause call's own latency), slept until 15 s before the deadline, hovered and read again to re-sync, slept until the deadline, then pressed the pause control."
    , "- Even right after a hover the text is sometimes stale, so a reading was believed only if its duration matched and the start it implied (now − position) was within 10 s of the start already known (the moment playback was first seen); otherwise the earlier estimate was kept. Hover by moving across the player (e.g. 40 px left of its centre, then the centre) and wait about 0.8 s before reading."
    ]
