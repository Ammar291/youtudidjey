# yuotudidjey

A YouTube "DJ" written and compiled in Haskell. It plays a list of songs in Google Chrome — each until
3 seconds before its end, then the next, looping forever — while touching the browser **only through
[blindly4](https://github.com/aleski-green/blindly4)** (the accessibility-tree CLI from sapiens4).

It runs in two stages:

| Stage | Who decides each UI action | Output |
|---|---|---|
| **Exploration** (`yuotudidjey explore`) | an LLM through a pipe-based agentic CLI (`claude -p` by default, `codex exec` optional) | logs, a playbook, and a generated `generated/solution.py` |
| **Exploitation** (`yuotudidjey exploit`) | the generated `solution.py`, with no LLM reachable | logs |

`yuotudidjey report` compares the two stages: assign-to-playback latency (mean, median, p90, …),
blindly4 call counts and sequences, LLM share, ad time and pause accuracy.

Results of the measured runs: [`results/report.md`](results/report.md); summary [below](#results).

## Prerequisites (Windows 10/11)

- Google Chrome
- .NET SDK 10 (to build blindly4)
- GHC 9.10 + cabal 3.16 (e.g. via GHCup)
- Python 3.13 on `PATH`
- `claude` CLI, signed in (the default LLM backend)

## Build

```powershell
git submodule update --init           # blindly4 (patched; see below)
powershell -File blindly4/windows/build.ps1 -Runtime win-x64
cabal build exe:yuotudidjey
cabal test                            # unit tests (no browser, no LLM)
cabal install exe:yuotudidjey --installdir=bin --install-method=copy --overwrite-policy=always
```

The blindly4 submodule points at branch `yuotudidjey-patches` of
[Ammar291/blindly4](https://github.com/Ammar291/blindly4/tree/yuotudidjey-patches), a fork of
`aleski-green/blindly4`. The same changes are in
[`patches/blindly4-yuotudidjey.patch`](patches/blindly4-yuotudidjey.patch) (apply with `git am` on
`aleski-green/blindly4@1369de4`). The patch adds: lazy `find` (≈ 4–5× faster), `find --identifier/--under`,
`hover`, `open --chrome-profile` (isolated, accessible Chrome), `--format xml`, and
`--expect-description` on `set-value`/`focus`.

## Run

```powershell
bin\yuotudidjey.exe explore --songs songs.txt --max-songs 10      # LLM stage, then writes generated\solution.py
bin\yuotudidjey.exe exploit --songs songs.txt --max-songs 10      # no-LLM stage (omit --max-songs to play forever)
bin\yuotudidjey.exe report --explore logs\exploration-… --exploit logs\exploitation-… --out results
```

Useful options: `--llm codex`, `--model <name>`, `--max-play-seconds S` (development only),
`--skip-codegen`, `--from-run DIR` (generate `solution.py` from an earlier exploration run),
`--chrome-profile DIR` (reuse one Chrome profile instead of a fresh one per stage).

Without `--chrome-profile`, every stage starts Chrome on a brand-new, signed-out profile. After many
such fresh profiles in a row, YouTube started treating the sessions as bots and refused playback
until sign-in. The measured runs therefore used one persistent profile,
`--chrome-profile .yuo-profile/signed-out`, that is never signed in to any account. Playback works
signed out; nothing in either stage signs in.

Both stages take over the desktop while they run (Chrome is brought to the front; the pointer is moved
over the player once per song).

## How it works

- **Only blindly4 touches the browser.** Chrome is opened with `blindly4 open --chrome-profile` (an
  isolated profile, fresh per stage unless `--chrome-profile` names one), read with `find`/`inspect`/`tree` (JSON for programs, XML for the LLM),
  driven with `set-value`/`press`/`hover`/`key`, and closed by pressing its own Close button.
- **One logging layer.** Every blindly4 call — yuotudidjey's own and `solution.py`'s (through the
  `yuotudidjey b4` proxy) — is a line in `blindly4.jsonl` with stage, origin, argv, timing, exit code
  and output. A safety guard refuses raw typing/clicking and account/social controls.
- **The same measuring instrument for both stages.** A read-only observer thread polls the window title
  (audio indicator), the address bar and the player (ad markers) and records when the assigned song is
  really playing; it never sends input.
- **Exploration.** For each song the LLM sees the goal, the rules, blindly4's command list, XML
  observations and its own playbook, and replies with 1–4 JSON actions; Haskell validates and runs them.
  After playback starts, the LLM names the pause control and the duration; a timer (STM deadline, one
  hover re-sync 15 s before the end) pauses 3 s before the end. During playback the LLM updates its
  playbook. Finally the LLM writes `solution.py` from the playbook, the full call trace and a
  description of how the driver recognised ads and timed the pause. That description is built from
  the driver's own constants, so it cannot drift from the code. A lint (functional style + safety,
  Python `ast`) and a real smoke run gate the result, with up to three repairs. The lint trusts the
  `YUO_B4` prefix only through a name bound nowhere else. It also rejects module aliases, reflection
  (`getattr`/`vars`/`globals`, dunders, `sys.modules`) and raw OS or input modules.
- **Exploitation.** `python solution.py` runs with `claude`/`codex` removed from `PATH` and API keys
  removed from its environment; it reaches blindly4 only through the proxy.

## Results

Measured on Windows 11 with the 10 songs in `songs.txt`, a persistent signed-out Chrome profile, and
`claude -p --model sonnet` (Claude Sonnet 5.5) as the exploration LLM. Both stages are measured by the
same independent observer. "Latency" means the time from assigning a song to the moment the song
itself starts playing, after any ads.

| | Exploration (LLM) | Exploitation (`solution.py`) |
|---|---|---|
| songs played | 10 / 10 | 10 / 10 |
| mean latency to actual playback | 62.5 s | 81.6 s |
| mean ad time before the song | 29.5 s | 62.1 s |
| **mean latency excluding ad time** | **32.9 s** | **19.6 s** (median 12.8 s) |
| LLM share of latency | 70 % | 0 % |
| blindly4 calls until playback (mean) | 13.8 (LLM 7.9, driver 5.9) | 102 |
| mean pause margin (target 3 s before the end) | 3.12 s | 2.17 s (worst −0.51 s) |

- **Removing the LLM pays off.** In exploration, 70 % of the time to playback was spent waiting for the
  LLM. Without ads, `solution.py` starts a song in 19.6 s on average, against 32.9 s for exploration.
- **Ads decide the raw numbers.** The exploitation run happened to get twice as many ads as the
  exploration run (YouTube chooses them). That is why its raw mean latency is higher.
  - Neither stage set out to skip ads: the exploration LLM pressed Skip once, and the measured
    `solution.py` never did.
  - `solution.py` makes more blindly4 calls because it keeps checking the player while ads run.
- **Pause accuracy.** Exploration's own timer averaged 3.12 s before the end.
  - The generated `solution.py` averaged 2.17 s. It searches the whole page for the pause button just
    before the deadline, and UI Automation slows down at page transitions.
  - On one song (*Take On Me*) the pause came 0.5 s after the song ended.

Artifacts in [`results/`](results/):
- **Comparison:** `report.md` (per song, command mix, first-song call sequences side by side),
  `latency.csv` and `traces/<stage>-song<n>.txt` (every blindly4 call per song).
- **Complete call logs per stage:** `exploration/` and `exploitation/` hold `blindly4.jsonl` (every
  blindly4 call: origin, argv, timing, exit code, output) and `events.jsonl`.
  - Exploration also has `llm.jsonl` (every LLM request and reply) and `playbook.json`.
  - One redaction: blindly4's `apps` command lists every window on the desktop. In these shared copies,
    only the test Chrome is kept in each `apps` reply (the rest is a count), and window lists quoted in
    LLM prompts are replaced by a placeholder.
  - Exploration's LLM-call count includes code generation over all three rounds.
- **The program:** `solution.py` is the generated program that was measured. `generated/` is
  git-ignored, so this is the committed copy.

How the measured `solution.py` came about:
1. **Code generation round 1.** That `solution.py` paused one song 46 s early in a first exploitation
   run: it took an unskippable ad's Pause button for the song. That run was stopped. The contract given
   to the LLM is now built from the driver's own constants (ad markers, start window, re-sync tolerance).
2. **Round 2.** This produced the measured `solution.py`, run over 10 songs.
3. **Review and fixes.** A review of round 2's program led to further fixes:
   - **Contract:** skip enabled ads; find the pause control early, inside the player; measure the start
     window from the last ad evidence; per-attempt time budgets; backoff after errors.
   - **Harness:** fresh smoke directories; a warm-up that checks Chrome is in front; a watchdog that
     counts the solution's own calls.

   These fixes are covered by the unit tests but have **not been measured live**.
4. **Round 3.** Generated under the fixed contract, it could not be smoke-tested: Windows does not let
   Chrome come to the front while someone is using the computer. It was not run.

   To measure it, leave the computer untouched for about 40 minutes and run
   `bin\yuotudidjey.exe explore --songs songs.txt --from-run logs\exploration-20261018-234135 --chrome-profile .yuo-profile\signed-out`,
   then `exploit` and `report` as above.

## Known limitations

- **The lint is best-effort.** It is a static check of the generated code and catches the ordinary
  ways of reaching other programs. An independent review found that deliberately evasive Python could
  still get past it (Python offers too many dynamic routes for a static check to cover).
  - The other layers do not depend on it. The proxy's guard refuses any blindly4 call aimed at another
    window, and `solution.py` runs with the LLM CLIs and API keys removed from its environment.
  - The generated `solution.py` is a file you can read, and the measured one reaches the browser only
    through the proxy.
- **YouTube decides the ads.** The number and length of ads before a song vary from run to run, so the
  report also gives latency excluding ad time.
- **The desktop must be left alone.** Both stages bring Chrome to the front and move the pointer over
  the player.
  - While someone uses the keyboard or mouse, Windows refuses to switch the foreground for about 200 s.
  - In that case the warm-up waits, and if the computer stays in use it reports "environment not ready".
- **The measured `solution.py` predates the last fixes** (see [Results](#results)). It pauses about
  0.8 s later than the 3 s target on average and does not skip ads.

## Layout

| Path | What |
|---|---|
| `app/Main.hs` | CLI dispatch |
| `src/Yuo/*.hs` | library: `Blindly` (typed commands, guard, logging), `Observer`, `Explore`, `Pause`, `Codegen`, `Exploit`, `Metrics`, `Report`, … |
| `lint/fp_lint.py` | the generated-code lint (embedded in the binary) |
| `test/` | hspec + QuickCheck suite with recorded blindly4 fixtures |
| `docs/superpowers/` | design and implementation plan |
| `logs/` | run directories (git-ignored) |
| `results/` | the measured runs' report and logs |
