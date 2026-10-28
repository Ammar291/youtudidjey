# youtudidjey

A YouTube "DJ". It plays a list of songs in Google Chrome, each until 3 seconds before its end, then
pauses, searches for the next one and plays it, looping over the list forever. The browser is touched
only through [blindly4](https://github.com/aleski-green/blindly4) (accessibility-tree CLI).

`youtudidjey` is a short Haskell program that **only orchestrates** the two stages and measures them:

| Stage | Who drives Chrome (through blindly4) | Result |
|---|---|---|
| `youtudidjey explore` | an LLM agent: `claude -p`, one turn per song | the agent writes `solution.py` |
| `youtudidjey exploit` | `solution.py`, with no LLM | the songs play, forever |

The playback logic exists once: in the agent's head during exploration, and in the generated
`solution.py` afterwards. Haskell never reads the page or presses anything.

## The exploration harness

Everything the LLM gets is in this repository:

- **The prompts** ([`prompts/`](prompts/)): [`explore.md`](prompts/explore.md) is the system prompt
  (task, reply protocol, tools, blindly4 commands with real example calls and outputs, YouTube facts,
  rules). Each turn's message is [`setup.md`](prompts/setup.md),
  [`song.md`](prompts/song.md) (one per song) or [`codegen.md`](prompts/codegen.md) (write and test
  `solution.py`).
- **The harness** ([`agentTurn` in `app/Main.hs`](app/Main.hs)): each turn is one `claude -p` process
  in the run directory, continuing the same conversation (`--continue`), so the agent remembers
  earlier songs:

  ```
  claude -p "<turn message>" --model sonnet --append-system-prompt-file system-prompt.md
         --tools Bash --allowedTools "Bash(blindly4 *)" "Bash(sleep *)" "Bash(date *)"
         --permission-mode dontAsk --safe-mode --strict-mcp-config
         --output-format stream-json --verbose [--continue]
  ```

- **The tools**: only Bash, and in it only `blindly4`, `date` and background `sleep` (plus harmless
  read-only commands such as `cat` and `grep`, which Claude Code always allows). Anything else is
  refused (`dontAsk`). The codegen turn adds `Read`, `Edit(solution.py)` (writing only that file) and
  `Bash(python -X utf8 solution.py *)` so the agent can test its program on one song. `--safe-mode` and
  `--strict-mcp-config` keep the user's plugins, hooks, MCP servers and CLAUDE.md out of the session.
- **The transcript**: `agent.jsonl` in the run directory has, for every turn, a header with the exact
  command line (including the message), followed by everything Claude streamed: each tool call, its
  result, and the agent's text.

## Protocol and measurement

Both actors answer with words on a line of their own: `READY` after opening Chrome, `PLAYING` once the
assigned song itself (not an ad) is playing, `PAUSED` after pausing it 3 s before its end, or `SKIPPED`
if `solution.py` could not play it. The agent writes these words in its replies; `solution.py` prints
them on stdout (and reads songs from stdin, one per line).

youtudidjey records, per song, the time it assigned the song (sent the message, or wrote the line) and
the time `PLAYING` arrived. That difference is the **latency** in `latency.csv`. Browser start-up is
excluded in both stages (it happens before `READY`). The exploration latency includes the agent's
reaction time, because that is how long the LLM-driven stage takes to know the song is playing.

## Logs

Each run gets a directory `runs/<stage>-<time>/`:

| File | What |
|---|---|
| `blindly4.jsonl` | **every blindly4 call**, written by blindly4 itself: start time, duration, arguments, exit code, output. Covers the agent's calls and `solution.py`'s alike. |
| `latency.csv` | per song: assigned, playing, done (Unix seconds), latency, song |
| `agent.jsonl`, `system-prompt.md` | exploration: the full agent transcript and the system prompt it got |
| `solution.py`, `solution.out`, `solution.err` | exploitation: the program that ran, its words with times, its diagnostics |

`youtudidjey report RUN_DIR...` prints the stages side by side: latency statistics and the number of
blindly4 calls until playback and per song.

## blindly4 patch

The `blindly4` submodule points at
[Ammar291/blindly4@youtudidjey-patches](https://github.com/Ammar291/blindly4/tree/youtudidjey-patches),
a fork of `aleski-green/blindly4` (Windows backend only; the same changes are in
[`patches/blindly4-youtudidjey.patch`](patches/blindly4-youtudidjey.patch), applied with
`git am --keep-cr` on `aleski-green/blindly4@1369de4`):

- `BLINDLY4_LOG=FILE`: every invocation appends one JSON line to FILE, so no caller can skip the log.
- `--at UNIX_SECONDS`: wait until that moment, then run the command. The agent replies in seconds, too
  slowly to pause on time itself, so it schedules the press: `press … --at T` runs within ~0.1 s of T.
- `press --under PATH --title/--role/--identifier`: press the first match below PATH, looked up when the
  press runs. YouTube renumbers its control bar, so a path found seconds earlier can point elsewhere.
- Earlier: lazy `find` (4–5× faster), `find --identifier/--under`, `hover`, `open --chrome-profile`
  (an isolated Chrome with accessibility on), `--format xml`, `--expect-description` on
  `set-value`/`focus`.

## Build and run (Windows 10/11)

Needs Google Chrome, .NET SDK 10, GHC 9.10 + cabal, Python 3.13, and the `claude` CLI signed in.

```powershell
git submodule update --init
powershell -File blindly4/windows/build.ps1 -Runtime win-x64
cabal install exe:youtudidjey --installdir=bin --install-method=copy --overwrite-policy=always

bin\youtudidjey.exe explore                    # 10 songs with the agent, then writes solution.py
bin\youtudidjey.exe exploit --max-songs 10     # without --max-songs it plays forever
bin\youtudidjey.exe report runs\explore-… runs\exploit-…
```

Options: `--songs FILE` (default `songs.txt`), `--max-songs N`, `--model MODEL` (explore; default
`sonnet`), `--solution FILE` (exploit; default `solution.py`). Chrome runs on a persistent, signed-out
profile in `.chrome-profile/` (fresh profiles every run made YouTube suspect a bot).

Both stages take over the desktop: Chrome comes to the front and the pointer moves over the player.
Leave the computer alone while they run (Windows refuses to bring Chrome to the front while someone is
typing).

## Results

Measured on Windows 11 on a sample of 3 songs per stage (the first three in `songs.txt`), with
`claude -p --model sonnet` (Claude Sonnet 5.5) exploring. [`results/report.md`](results/report.md) is the
output of `youtudidjey report`.

| | Exploration (agent) | Exploitation (`solution.py`) |
|---|---|---|
| songs played | 3 / 3 | 3 / 3 |
| time to playback, per song | 42.9, 65.5, 59.7 s | 12.1, 33.0, 27.1 s |
| **mean** (median) | **56.0 s** (59.7 s) | **24.0 s** (27.1 s) |
| of which ads (approx.) | 3.0, 12.9, 12.5 s | 5.2, 27.4, 21.2 s |
| **mean excluding ads** | **46.6 s** | **6.1 s** |
| blindly4 calls until playing (mean) | 19.7 | 129.3 |
| pause before the end (target 3 s) | 3.5, 3.6, 3.2 s | 3.6, 3.6, 3.6 s |

- **Without the LLM, a song starts 7.6× faster** once ads are taken out (6.1 s against 46.6 s). In
  exploration, blindly4 calls took only 2–3 s per song; the rest is starting `claude` and the model's
  turns.
- **`solution.py` makes many more blindly4 calls.** While an ad plays it polls the player (a hover and
  four parallel `find`s, about once a second) so that it notices the song the moment it starts. The
  agent looks every few seconds.
- **Both stages pause on time.** The agent schedules `press … --at T` from a slider reading;
  `solution.py` does the same. The margins are estimated from the last fresh slider reading in the log
  (the slider shows whole seconds, so ±1 s).
- **Ads differ between runs** (YouTube decides), so the row without ads is the fairer comparison. Ad
  time is the span between the first and the last blindly4 output before `PLAYING` that shows an ad
  (`Sponsored`, a Skip button, or a slider of another length).

### How the prompts got here

Two shorter runs before the measured one showed what the prompts were missing. Each fix is now a line in
`prompts/`:

- `find` searches 8 levels deep by default, and YouTube's content sits about 15 deep: the agent's
  searches came back empty.
- YouTube renumbers the control bar's buttons, so a pause scheduled by path found another control and
  came 20 s late. Hence blindly4's `press --under … --title Pause`, resolved when it fires.
- The player shows fresh controls only when the pointer moves. A generated `solution.py` hovered at the
  same point every time, read a stale slider and missed the end. Now it alternates two points and falls
  back to the elapsed time.
- The agent ran its test of `solution.py` by an absolute path, which its permissions refused. The prompt
  now gives the one allowed command.

In the measured run, the agent's first test of `solution.py` failed (a reload retry never fired); it
fixed the bug, and the second test passed.

Artifacts in [`results/`](results/): `report.md`; `exploration/` with `agent.jsonl` (the full
transcript), `system-prompt.md`, `blindly4.jsonl` and `latency.csv`; `exploitation/` with
`blindly4.jsonl`, `latency.csv` and `solution.out`. `solution.py` at the top of the repository is the
program that exploration wrote and exploitation ran.

## Layout

| Path | What |
|---|---|
| `app/Main.hs` | the orchestrator: explore, exploit, report |
| `prompts/` | everything the exploring LLM is told |
| `solution.py` | the program the measured exploration wrote (and exploitation ran) |
| `results/` | the measured runs: logs, transcript, report |
| `songs.txt` | the 10 songs |
| `blindly4/` | the patched blindly4 (submodule) |
