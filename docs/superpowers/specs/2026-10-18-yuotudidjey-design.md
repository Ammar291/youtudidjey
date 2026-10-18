# yuotudidjey — design

Date: 2026-10-18 · Status: approved in conversation ("solution looks good", "go ahead")

## Intent

A YouTube "DJ" crawler that proves a two-stage pattern: an **exploration** stage where an LLM, driving
the browser only through blindly4, discovers how to search/play/pause songs and writes `solution.py`;
and an **exploitation** stage where `solution.py` does the same job with no LLM. The value is the
comparison: latency and blindly4 call traces of both stages, measured with the same instrument.

## Goals

- `yuotudidjey` — a compiled Haskell program — plays a 10-song list from `songs.txt` on YouTube in
  Chrome, sequentially, each until 3 s before its end, pausing before searching for the next one,
  looping forever.
- All browser access goes through blindly4 (UI Automation tree, JSON) — no CDP, Selenium, or JS.
  **User rule: nothing bypasses blindly4** — opening, reading, input, closing the browser, and video
  metadata (duration) all come from blindly4 commands. No YouTube API, yt-dlp, HTTP page fetches, direct
  `chrome.exe` launch or `taskkill`. Missing capabilities are added to blindly4 instead.
- Exploration: LLM reasoning via a pipe-based agentic CLI (`claude -p` default, `codex exec` swappable).
- Exploitation: `python solution.py` with no LLM reachable.
- Artifacts: per-stage mean (plus median/p90/min/max) of *song assigned → playback started*, and the
  complete blindly4 call log for up to 10 songs per stage, plus a comparison report.

## Non-goals / anti-goals

- Not a general web agent; YouTube in Chrome on Windows only.
- No ad blockers, no YouTube API, no direct `open --url` results-page shortcut for search.
- Anti-goal: prefetching song *i+1* while song *i* plays — violates "pause → search → play" ordering
  and games the latency metric. Only song-independent warm-up (e.g. locating the search box) is allowed.
- Anti-goal: `solution.py` that secretly calls an LLM, or logs that the generated code could skip.

## Environment (verified 2026-10-18)

Windows 11, Chrome (`C:\Program Files\Google\Chrome\Application\chrome.exe`), .NET SDK 10.0.401,
Python 3.13, `claude` 2.1.293, `codex` 0.160.0, GHC + cabal via GHCup (`C:\Users\muham\ghcup\bin`).

## Feasibility spike — facts the design rests on

Measured against a live YouTube watch page with Chrome launched with `--force-renderer-accessibility`:

| Fact | Evidence |
|---|---|
| Web content is in the UIA tree | `find` returns player, buttons, comments, search box |
| Position/duration readable as text | Seek slider (`AXSlider`, title `Seek slider`) value: `"0 Minutes 2 Seconds of 3 Minutes 33 Seconds"` |
| Play state readable | Button title `Pause (k)` (playing) / `Play (k)` (paused); during ads `Play keyboard shortcut k` |
| Audio state is cheap to read | Window title from `apps` contains `- Audio playing -` while audio plays (no tree walk) |
| Stable anchor | Player has identifier `movie_player` (HTML id → UIA AutomationId) |
| Search box | `AXComboBox` title `Search` |
| Ads are real and visible | Pre-roll: slider shows ad time (`4 s of 5 s`); player subtree has `Sponsored`, `Skip` button, `My Ad Center` |
| Paths are unstable | After ad/caption changes the same path pointed at caption text → always validate before use |
| Autoplay advances | After the video ended YouTube autoplayed the next one → pausing at −3 s is load-bearing |
| `press` works | `press --expect-description Pause` paused the video |
| **Slider text is stale while controls are hidden** | value stuck at `0:02` for >4 s while audio played; fresh at video start (`0:00 of 4:07`) |
| Focus does not refresh it | `focus` on the slider → "did not receive keyboard focus" |
| "Audio playing" lives in UIA, not Win32 | `apps` window titles never show it; `inspect --path 0.1` (window pane) name does |
| Search without stealing focus | `set-value` on `AXComboBox "Search"` + `press` `AXButton "Search"` → results in ~2 s |
| Results carry identity + duration | video links: identifier `video-title`, name `"… 4 minutes, 9 seconds"`; Mixes have no identifier |
| Result → playing | link `press` → watch page ≈ 3.3 s; pre-roll ad pod (5 s + 30 s) before the song |
| LLM CLI | `claude -p --model sonnet --tools "" --output-format json` ≈ 6.7 s for a trivial prompt; `--json-schema` available |
| **`hover` makes the slider fresh** | playing from 2:13: no hover → `2:16` twice 3 s apart (stale); hover → `2:23`, `2:26` (correct); paused + 1.5 s → `2:27` |
| Play/pause label varies | `Pause (k)` / `Play (k)` *or* `Pause keyboard shortcut k` / `Play keyboard shortcut k` |
| Time display duplicate | a button under the player is titled `"2 Minutes 13 Seconds of 4 Minutes 8 Seconds"` (may differ by 1 s from slider) |
| Unicode in tree | captions contain `♪`; Python must run with `-X utf8` |

Per-call cost, stock vs patched blindly4:

| Operation | Stock | Patched |
|---|---|---|
| process start (`schema`) | ~314 ms | ~280 ms |
| `find` over whole YouTube page | 1.7–2.7 s | ~0.5 s |
| `inspect --path` | ~0.55–0.8 s | ~0.5 s |

## blindly4 patch (local clone `blindly4/`, Windows backend only)

Backward compatible; stateless invariant and safety guards untouched; self-test 54 → 64 checks.

1. `find` evaluates filters lazily, cheapest UIA property first (identifier, role, title, description,
   value) and builds the full ~12-property `Detail` only for matches. (Main speedup.)
2. `find --identifier ID` — exact, case-sensitive AutomationId match.
3. `find --under PATH` — traverse only that subtree; returned paths stay absolute.
4. Publish with ReadyToRun.
5. `hover --x X --y Y --pid PID` — pointer move only (no click), same foreground/pointer-target guards
   as `click`; used to make YouTube reveal its controls so the slider text becomes fresh.
6. `open --url URL --chrome-profile DIR` — blindly4 itself launches an isolated Chrome
   (`--user-data-dir=DIR --force-renderer-accessibility --autoplay-policy=no-user-gesture-required
   --no-first-run --no-default-browser-check --window-size=1400,1000 --new-window URL`), waits for its
   window and returns its `pid`. This is how yuotudidjey accesses the browser (challenge wording).
7. `tree` / `find --format xml` — blindly4 emits the XML UI tree directly (element name = role,
   attributes path/title/value/identifier/description/actions/frame). LLM observations are this XML.
8. `--expect-description TEXT` also on `set-value` and `focus` (same check `press` already has).

## Safety guard (one pure function, used by the exploration executor and the `b4` proxy)

- `press`, `set-value`, `focus` must carry `--expect-description`; refused when it matches the denylist
  (case-insensitive substrings: subscribe, like, dislike, share, save, join, comment, reply, report,
  sign in, buy, premium, download, thanks, clip, remix, notify, bell).
- `type`, `click`, unguarded `paste` are refused; `key` allows `escape` and digit keys freely, and
  `return`/`enter` only in blindly4's guarded form (`--target-path --require-value`).
- `open` only for `https://www.youtube.com/…`.

Pushing a fork to GitHub is the user's call; the patch lives in the local clone.

## Timing model (from the spike)

The slider text is only trustworthy at playback start, right after a `hover`, and while paused.
So the pause deadline is computed, not polled:

- `duration` = exact seconds from the slider at start (`… of 4 Minutes 7 Seconds`), cross-checked with
  the result label.
- `start` = monotonic time of the first fresh reading of the song (not an ad), minus its position.
- `deadline = start + duration − 3 s − pauseCallLatency`, extended by any detected ad time
  (mid-roll: ad markers under `movie_player`).
- No reads while the song plays (pure timer); the only mid-song check is one re-sync at ≈ deadline − 15 s
  via `hover` over the player + slider read, which also absorbs any mid-roll ad or buffering stall.
- Duration sources disagree (same video: result label 4:09, player time display 4:08, slider 4:07);
  use the player's values, never the result label, for the deadline.
- After pausing (controls visible, value fresh) read the position → recorded pause margin.

## Architecture

One Haskell executable, `yuotudidjey`:

```
yuotudidjey explore --songs songs.txt [--llm claude|codex] [--max-songs 10] [--max-play-seconds S]
yuotudidjey exploit --songs songs.txt [--max-songs N | --forever]
yuotudidjey b4 --origin ORIGIN -- <blindly4 args>   # logging proxy used by solution.py
yuotudidjey report [--explore DIR] [--exploit DIR]
```

### Modules (pure core / effectful shell)

| Module | Pure? | Responsibility |
|---|---|---|
| `Yuo.Types` | pure | `Song`, `Stage`, `Origin`, `Event`, `Phase`, `Action`, `Command (r :: Risk)` |
| `Yuo.Time` | pure | parse `"X Minutes Y Seconds of A Minutes B Seconds"` (incl. hours), pause deadline math |
| `Yuo.Match` | pure | song ↔ title fuzzy matching (token overlap), ad-marker detection |
| `Yuo.Tree` | pure | blindly4 JSON → pruned compact XML for prompts |
| `Yuo.Metrics` | pure | strict fold over event log → per-stage stats |
| `Yuo.Log` | shell | async JSONL writer thread (TBQueue); run directory layout |
| `Yuo.Blindly` | shell | typed command → argv, run process, time it, log it; input lock |
| `Yuo.Chrome` | shell | launch isolated Chrome (`bracket`), resolve PID |
| `Yuo.Observer` | shell | independent playback observer thread (same instrument in both stages) |
| `Yuo.Llm` | shell | backend adapter (`claude -p` / `codex exec`), JSON action decoding |
| `Yuo.Explore` | shell | observe → think → act loop, phases, playbook, mechanical wait+pause |
| `Yuo.Codegen` | shell | build prompt, write `solution.py`, FP lint + safety lint, smoke test, repair |
| `Yuo.Exploit` | shell | run `solution.py` with LLM CLIs stripped from PATH |
| `Yuo.Report` | shell | write `report.md` + `latency.csv` from logs |

### Logging (one layer, both stages)

Every blindly4 invocation — Haskell's own (exploration, observer) and `solution.py`'s (through
`yuotudidjey b4`) — goes through `Yuo.Blindly.run`, which appends one JSON line to
`logs/<stage>-<stamp>/blindly4.jsonl`:

`{seq, stage, origin, song_index, song, argv, t_wall, t_mono_ms, duration_ms, exit_code, stdout, stderr}`

Other files in the run directory: `events.jsonl` (song_assigned, playback_started, paused, ad_seen,
error, …), `llm.jsonl` (exploration: prompt, response, duration), `snapshots/` (XML observations),
`playbook.json`. `solution.py` cannot bypass logging because it never sees the real blindly4 path.

### Browser session

`yuotudidjey` opens the browser with `blindly4 open --url https://www.youtube.com/ --chrome-profile
.chrome-profile/<stage>-<stamp>` (fresh profile per stage run) and closes it with
`blindly4 key --key alt+f4 --pid <pid>`. Every browser interaction is a blindly4 command.

## Exploration stage

Per song, phases: `Search → Select → ConfirmPlaying → PreparePause → Waiting → Paused`.

- **Observe**: blindly4 `find`/`tree` scoped by PID (and `--under` when anchored), pruned to named /
  actionable / valued nodes, serialized as XML (`<AXLink path="…" title="…"/>`), capped in size.
- **Think**: one LLM call per step. Prompt = goal, phase, song, XML observation, last N action results,
  playbook so far, allowed-action schema. Reply must be one JSON object:
  `{"thought": "...", "action": {"cmd": "...", "args": {...}}, "note": "..."}`.
  Allowed `cmd`: `find`, `inspect`, `tree`, `focus`, `set-value`, `paste`, `press`, `key`, `scroll`,
  `wait`, `phase_done`, `give_up`. The LLM CLI runs with tools disabled, so every UI action is
  Haskell's and is logged.
- **Act**: Haskell validates (whitelist, adds `--pid`, bounded depth/limit) then runs it.
- **Waiting is mechanical**: in `PreparePause` the LLM names the pause control selector and the time
  source; Haskell computes the deadline and pauses (an LLM call takes seconds — far too slow for −3 s).
- **Playbook**: after each song an async LLM "reflection" call (runs during playback, off the
  latency path) updates `playbook.json`: selectors as (role, title/identifier pattern, anchor),
  sequences that worked, pitfalls (ads, Shorts, Mixes, sponsored results), timings. Later songs get it
  in the prompt, so exploration speeds up but remains LLM-decided.

## Code generation (end of exploration)

One LLM call receives the playbook, condensed successful traces, `blindly4 schema`, and this contract:

- Python 3.13 stdlib only. CLI: `--songs`, `--max-songs N`, `--forever`, `--max-play-seconds S` (smoke
  tests only).
- Every blindly4 call via the command prefix in env `YUO_B4` (→ `yuotudidjey b4 --origin solution --`).
- Emits JSON-line events to the path in env `YUO_EVENTS`: `song_assigned`, `playback_started`
  (with position read), `paused` (with remaining seconds), `ad_seen`, `error`.
- Re-validates any remembered path before use; falls back to `find`; races fallback lookups with
  `concurrent.futures` (`wait(FIRST_COMPLETED)`); serializes all input commands.
- **Functional style (user requirement)**:
  - pure functions for parsing, matching, decisions; side effects confined to a small, named effects
    section (blindly4 calls, clock, sleep, event emission);
  - immutable data only: `@dataclass(frozen=True)`, `NamedTuple`, tuples, `frozenset`; no mutable
    globals, no `global`/`nonlocal`;
  - lambdas, `map`/`filter`/`functools.reduce`, `itertools` (`cycle`, `islice`, `repeat`,
    `takewhile`/`dropwhile`), `functools.partial`, a `compose`/`pipe` helper, higher-order fallback
    combinators;
  - no `while` loops (lazy iterators instead — e.g. `cycle` over songs, `repeat`+`filter` for polling);
    no in-place mutation (`.append`, `.extend`, `.pop`, `.update`, `+=`, `del`, …).

Validation, all enforced by `yuotudidjey` (deterministic, no LLM):

1. `python -m py_compile`.
2. **FP lint** (Python `ast` checker embedded in the Haskell binary, run with `python -I -`): rejects
   `while`, `global`, `nonlocal`, mutating method calls, augmented assignment, `del`, non-frozen
   classes; requires ≥ 5 lambdas and use of `functools` and `itertools`.
3. **Safety lint**: rejects imports of `anthropic`, `openai`, `requests`, `urllib`, `http`, `socket`,
   and any mention of `claude`/`codex` executables.
4. **Smoke test**: `solution.py --max-songs 1 --max-play-seconds 20`.

On failure the error and trace go back to the LLM (≤ 3 repair rounds). All of it counts as exploration.

## Exploitation stage

`yuotudidjey exploit` launches Chrome, then runs `python -I solution.py …` with a PATH from which the
`claude`/`codex` directories are removed (hard no-LLM guarantee), `YUO_B4` and `YUO_EVENTS` set. It
supervises, collects logs, and stops after `--max-songs` (measurement) or runs `--forever`.

## Measurement

Both stages are measured by the **same Haskell observer** (`origin = observer` in the call log):

- `t_assign`: monotonic time at which song *i* is taken from the list (emitted by the driver —
  Haskell in exploration, `solution.py` in exploitation).
- `t_play`: first observer poll where all hold: window title fuzzy-matches the song and contains
  `Audio playing`; no ad markers under `movie_player`; seek-slider position > 0 and advancing.
  Also `t_play_est = t_poll − position` to remove polling quantization.
- latency = `t_play − t_assign`; ad time is included (it delays the song) and reported separately.
- Also reported: pause margin (target 3 s), blindly4 calls per song by origin, command mix,
  LLM share of time, failures/retries.

## Concurrency model

- Input commands are serialized: they require a token from a single `MVar` desktop lock
  (type-enforced: `Command 'Mutating` needs the token; `Command 'ReadOnly` does not).
- Read-only probes run concurrently (`concurrently`/`mapConcurrently`); fallback lookups use `race`.
- Pause scheduling: deadline in a `TVar`, re-synced by the observer; a timer thread waits on
  `registerDelay`/STM and fires the pause.
- Logging: dedicated writer thread fed by a `TBQueue`.
- Exploration reflection LLM call and codegen drafting run during playback.
- Note: Chrome serves UIA on one thread, so concurrent reads may contend; measured, not assumed.

## Functional programming in yuotudidjey

Pure core (time parsing, matching, XML pruning, phase transitions `step :: Phase -> Observation ->
(Phase, [Action])`, metrics as strict `foldl'`), ADTs that make illegal states unrepresentable,
`Either`-typed LLM decoding, effects behind records of functions (`Backend`, `LlmBackend`,
`Observer` — the handle pattern) so tests swap in fakes and recorded replays, `<|>`/`firstJust` fallbacks, `cycle songs` for the endless playlist, `bracket` for
Chrome/process cleanup, strict state for constant memory in the endless loop.

## Builder-check resolutions (Claude's calls)

- **Live desktop**: development uses short live tests plus recorded-fixture replay tests; the final
  measured runs (≈ 40+ min per stage, desktop unusable) are scheduled with the user.
- **Blank-slate exploration**: the exploration and codegen prompts get only the goal, `blindly4 schema`,
  the action schema and observations — no spike facts. YouTube knowledge in Haskell (`movie_player`,
  slider format, ad markers, `Audio playing`) is the *measurement instrument* (observer) and the
  mechanical timer, not the strategy. The LLM must discover selectors, flow, ad handling, duration source.
- **Skipping ads is allowed in both stages** (identical rules → fair comparison); ad time still reported.
- **Fresh Chrome profile per stage run** (deleted and recreated) → no inherited consent, history or cache;
  both stages start from the same state.
- **LLM backends**: `claude -p --model sonnet --tools "" --json-schema …` is primary and verified.
  `codex exec` is a pluggable adapter (`--sandbox read-only --ephemeral --output-schema`) marked
  best-effort: codex keeps a shell, so the prompt forbids running blindly4 and its log tightness is
  weaker. Step budget: ≤ 25 LLM steps per song; a call may return a short action list (≤ 4) to cut
  calls. Expected ≈ 60–100 calls per exploration run.
- `yuotudidjey b4` proxy records go to the same `blindly4.jsonl` via an append-only file with a
  per-run lock file; `seq` comes from the monotonic timestamp + origin, sorted at report time.

## Calls made by Claude (user may override)

- Search by typing in YouTube's search box, not by a results URL.
- `claude -p` default LLM; `codex exec` via `--llm codex`.
- Ad time counts toward latency and is broken out separately.
- One independent observer measures both stages.
- `--max-play-seconds` exists for smoke/dev only; measured runs play full songs.
- `songs.txt`: 10 well-known songs, editable.

## Edge-case handling added after review

- Goal text for the LLM: play the song itself from the beginning (not loops/extended/live/lyrics
  versions), skip unavailable/age-restricted/live results, dismiss pop-ups and "Continue watching?".
- Observer records the start position; the report flags songs that did not start near 0:00.
- LLM calls: 120 s timeout, 2 retries with back-off, then the step counts as failed.
- Exploitation watchdog: kill `solution.py` when no event arrives within (longest song + 120 s).
- Report flags any song whose first blindly4 call precedes its `song_assigned` event.
- `--forever` rolls the run directory every full pass over the list.
- Lint also bans `ctypes comtypes pywinauto uiautomation win32api win32gui win32con selenium playwright
  webbrowser` and `os.system`, and any `subprocess` call whose command is not built from `YUO_B4`.

## Risks

| Risk | Mitigation |
|---|---|
| ~0.5 s per blindly4 call floor (≈0.28 s is process start) | minimize calls on the critical path; anchor with `--under`; concurrent reads |
| Path drift (ads, captions, SPA navigation) | validate every remembered path (title/role) before use; fall back to `find` |
| Ads (pre/mid-roll), Shorts/Mix/sponsored results | ad markers in player; result filtering learned in exploration + matching rule |
| Desktop contention | runs need the desktop untouched; input is PID-guarded by blindly4 |
| LLM non-determinism | strict JSON action schema, validation, playbook, lint + smoke + repair loop |
| Long runs (≈ 10 × 3.5 min per stage) | `--max-play-seconds` during development only |
