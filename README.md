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

Results of the measured runs: [`results/report.md`](results/report.md).

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

The blindly4 submodule points at a local branch `yuotudidjey-patches`; the same changes are in
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
`--skip-codegen`, `--from-run DIR` (generate `solution.py` from an earlier exploration run).

Both stages take over the desktop while they run (Chrome is brought to the front; the pointer is moved
over the player once per song).

## How it works

- **Only blindly4 touches the browser.** Chrome is opened with `blindly4 open --chrome-profile` (fresh,
  isolated profile per stage), read with `find`/`inspect`/`tree` (JSON for programs, XML for the LLM),
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
  playbook. Finally the LLM writes `solution.py` from the playbook and the full call trace; a lint
  (functional style + safety, Python `ast`) and a real smoke run gate it, with up to three repairs.
- **Exploitation.** `python solution.py` runs with `claude`/`codex` removed from `PATH` and API keys
  removed from its environment; it reaches blindly4 only through the proxy.

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
