# yuotudidjey Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A compiled Haskell program `yuotudidjey` that plays a 10-song list on YouTube through blindly4 only, first with an LLM exploring and generating `solution.py`, then by running `solution.py` with no LLM, and reports both stages' latency and blindly4 call traces.

**Architecture:** Pure core (time parsing, matching, XML pruning, observer state machine, metrics) with an effectful shell (blindly4 process calls with one logging layer, Chrome lifecycle, LLM CLI adapter, exploration loop, codegen with lints, exploitation supervisor, report). One independent observer thread measures both stages. Input commands are type-tagged `Mutating` and serialized by one lock; read-only probes run concurrently.

**Tech Stack:** GHC 9.10.3, cabal 3.16.1; aeson, text, bytestring, containers, process, async, stm, time, directory, filepath, optparse-applicative, unicode-transforms; hspec + QuickCheck. Patched blindly4 (C#/.NET 10). Python 3.13. `claude` CLI (default), `codex` CLI (adapter).

**Spec:** `docs/superpowers/specs/2026-10-18-yuotudidjey-design.md` — read it before any task.

## Global Constraints

- Every shell command in this plan runs in Git Bash from the repo root `C:/Users/muham/Desktop/My_workspace/yuotudidjey` with `export PATH="/c/Users/muham/ghcup/bin:$PATH"`.
- blindly4 executable: `blindly4/.build/windows/blindly4.exe` (patched; rebuild with `powershell -File blindly4/windows/build.ps1 -Runtime win-x64`).
- Chrome is opened only by `blindly4 open --url https://www.youtube.com/ --chrome-profile <abs dir>` (Task 0) and closed only by `blindly4 key --key alt+f4 --pid <pid>`.
- Fresh Chrome profile per stage run: `.chrome-profile/<stage>-<stamp>/`.
- LLM observations are blindly4's own XML (`--format xml`); programmatic reads use JSON.
- Safety guard (`Yuo.Guard.allowedCall`) applies to every exploration action and every `b4` proxy call: `press`/`set-value`/`focus` need `--expect-description` not matching the denylist `subscribe like dislike share save join comment reply report sign in buy premium download thanks clip remix notify bell`; `type`, `click`, `paste` refused; `key` only `escape`, digits, or `return`/`enter` with `--target-path` + `--require-value`; `open` only `https://www.youtube.com/…`.
- Python always runs as `python -I -X utf8`.
- Default LLM: `claude -p --model sonnet --tools "" --output-format json --json-schema <schema> --no-session-persistence`, prompt on stdin.
- All text I/O is UTF-8 (`hSetEncoding … utf8` on every handle Haskell reads or writes).
- Cross-process timestamps are wall-clock POSIX seconds as `Double` (`getPOSIXTime`; Python `time.time()`); in-process durations use `GHC.Clock.getMonotonicTime`.
- Run directory: `logs/<stage>-<YYYYmmdd-HHMMSS>/` containing `blindly4.jsonl`, `events.jsonl`, `llm.jsonl` (exploration), `snapshots/`, `playbook.json` (exploration), `smoke-<n>/` (exploration).
- `stage` JSON values: `"exploration"`, `"exploitation"`. `origin` JSON values: `"llm"`, `"driver"`, `"observer"`, `"solution"`.
- Event `kind` JSON values: `song_assigned`, `playback_started`, `paused`, `ad_seen`, `play_observed`, `pause_observed`, `step_error`, `song_gave_up`.
- Never prefetch song *i+1* while song *i* plays; only song-independent warm-up is allowed.
- Exploration and codegen prompts get no spike facts (blank slate): goal, `blindly4 schema`, action schema, observations, playbook only.
- LLM step budget: ≤ 25 steps per song, ≤ 4 actions per step, `wait` ≤ 5000 ms.
- `solution.py` FP rules (enforced by lint): no `while`, `global`, `nonlocal`, augmented assignment, `del`, subscript/attribute assignment, mutating method calls (`append extend insert pop remove clear update setdefault popitem add discard sort reverse`); classes only frozen dataclasses / `NamedTuple` / `Enum`; ≥ 5 lambdas; must import `functools` and `itertools`; must call `map(` or `filter(` and `reduce(`.
- `solution.py` safety rules (enforced by lint): no imports of `anthropic openai requests urllib http socket httpx aiohttp ctypes comtypes pywinauto uiautomation win32api win32gui win32con selenium playwright webbrowser`; no `os.system`; no string constant containing `claude`, `codex` or `blindly4.exe` (case-insensitive); every `subprocess` call's command must start with the `YUO_B4` prefix (lint: the first argument expression references the name bound from `os.environ["YUO_B4"]`).
- Commits are local only; never push.
- **Nothing bypasses blindly4** (user rule): browser open, reads, input, close and video metadata only via blindly4 commands; Chrome is closed with `key --key alt+f4 --pid <pid>`; no YouTube API / yt-dlp / HTTP fetches / `taskkill`.
- During playback there are no reads (timer only) except one `hover` + slider re-sync at deadline − 15 s.

## Review Focus

1. Song with no matching video (only Shorts/Mixes/sponsored, or nonsense query) → exploration gives up after 25 steps, logs `song_gave_up`, continues with the next song; never hangs. Test in Task 9.
2. Durations with hours or singular units (`1 Hour 2 Minutes 3 Seconds`, `1 Minute 1 Second`) and videos shorter than 3 s → parsed correctly; deadline never in the past by more than "pause now". Tests in Task 2.
3. `songs.txt` with a UTF-8 BOM, blank lines, `#` comments, accented/Arabic titles → BOM stripped, blanks and comments ignored, matching folds diacritics. Tests in Tasks 2–3.
4. Chrome closed mid-run (blindly4 exit 77 "No visible windows for PID") → stage stops with an `step_error` event and non-zero exit instead of looping. Test in Task 4.
5. LLM returns malformed JSON, an unknown `cmd`, > 4 actions, or a mutating action without a path → rejected as `Left`, fed back to the LLM, counts toward the budget. Test in Task 9.

---

### Task 0: blindly4 additions — isolated `open`, XML output, label guards

**Files:**
- Modify: `blindly4/windows/CLI/Registry.cs`, `blindly4/windows/Accessibility/Desktop.cs`, `blindly4/windows/Input/Native.cs` (or a new `blindly4/windows/Input/Launch.cs`), `blindly4/windows/CLI/SelfTest.cs`
- Create: `blindly4/windows/Support/Xml.cs`

**Interfaces:**
- Produces: `blindly4 open --url URL --chrome-profile DIR` → launches Chrome (path from `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe`, fallback `C:\Program Files\Google\Chrome\Application\chrome.exe`) with the flags in the spec, waits ≤ 15 s for a visible window of that process, prints `{"url","pid","ok":true}`. `DIR` must be absolute and contain no `"`; URL still passes `Guards.Url`. Without `--chrome-profile` the old ShellExecute behaviour is unchanged.
- Produces: `--format json|xml` on `tree` and `find` (default `json`). XML: element name = role; attributes `path`, `title`, `value`, `id` (identifier), `description` (only when ≠ title), `actions` (space-joined), `frame="x,y,w,h"`, `enabled="false"` / `focused="true"` only when notable; `find` wraps matches in `<matches truncated="…">`, `tree` nests children inside `<tree truncated="…">`. One element per line.
- Produces: `--expect-description TEXT` on `set-value` and `focus` (same contains-check as `press`).

- [ ] **Step 1: Write failing self-tests** in `SelfTest.cs`: `Registry.Get("open").Options` contains `chrome-profile`; `Registry.Get("tree").Options` and `find` contain `format`; `set-value`/`focus` options contain `expect-description`; `Xml.Element(new Dictionary<string, object?>{["role"]="AXButton",["path"]="0.1",["title"]="Pause (k)",["actions"]=new[]{"AXPress"}})` renders `<AXButton path="0.1" title="Pause (k)" actions="AXPress" />`; a title containing `<&"` is escaped; `open` rejects `--chrome-profile relative\dir` (exit 64).
- [ ] **Step 2:** `powershell -File blindly4/windows/build.ps1 -Runtime win-x64; blindly4/.build/windows/blindly4.exe --self-test` → fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Rebuild; `--self-test` → `"ok":true`. Live: `blindly4 open --url https://www.youtube.com/ --chrome-profile <abs scratch dir>` → prints a pid; `blindly4 find --pid <pid> --role AXComboBox --title Search --depth 40 --format xml` → one `<AXComboBox … title="Search" …/>` line; `blindly4 key --key alt+f4 --pid <pid>` closes it.
- [ ] **Step 5:** Commit inside `blindly4/` on branch `yuotudidjey-patches` (Task 1 step 2 then exports the patch).

### Task 1: Repository, blindly4 submodule, cabal skeleton

**Files:**
- Create: `.gitignore`, `yuotudidjey.cabal`, `cabal.project`, `app/Main.hs`, `test/Spec.hs`, `songs.txt`, `patches/blindly4-yuotudidjey.patch`
- Modify: `blindly4/` (commit existing patch on branch `yuotudidjey-patches`)

**Interfaces:**
- Produces: library `yuotudidjey` (hs-source-dirs `src`), executable `yuotudidjey` (`app/Main.hs`), test-suite `spec` (`test/`, hspec-discover not used — `test/Spec.hs` imports each `*Spec` module explicitly). `ghc-options: -Wall -threaded -rtsopts "-with-rtsopts=-N"` on exe and tests. Default extensions: `OverloadedStrings`, `DataKinds`, `GADTs`, `KindSignatures`, `LambdaCase`, `StrictData`.
- Produces: `app/Main.hs` with optparse-applicative subcommands `explore`, `exploit`, `b4`, `report`, each printing `not implemented` and exiting 2 until its task wires it.

- [ ] **Step 1:** `git init`; set repo-local `user.email mhammar029@gmail.com`, `user.name muham`. `.gitignore`: `dist-newstyle/ .chrome-profile/ logs/ tools/ bin/ generated/__pycache__/`.
- [ ] **Step 2:** In `blindly4/`: `git checkout -b yuotudidjey-patches`, commit the working changes as `windows: lazy find, --identifier, --under, hover, ReadyToRun`; then `git -C blindly4 format-patch origin/main --stdout > patches/blindly4-yuotudidjey.patch`. In root: `git submodule add https://github.com/aleski-green/blindly4.git blindly4` (registers the existing clone).
- [ ] **Step 3:** `songs.txt` — one query per line, `#` comments allowed:
  ```
  Daft Punk Get Lucky
  Rick Astley Never Gonna Give You Up
  Queen Bohemian Rhapsody
  a-ha Take On Me
  Toto Africa
  Michael Jackson Billie Jean
  Pharrell Williams Happy
  Mark Ronson Uptown Funk
  Beyoncé Halo
  Coldplay Viva La Vida
  ```
- [ ] **Step 4:** Write `test/Spec.hs` with one placeholder `it "builds" True`; run `cabal build all && cabal test` → `1 example, 0 failures`.
- [ ] **Step 5:** Run `cabal run yuotudidjey -- --help` → lists the four subcommands.
- [ ] **Step 6:** Commit `chore: scaffold yuotudidjey, add patched blindly4 submodule`.

### Task 2: `Yuo.Time` and `Yuo.Songs` (pure)

**Files:**
- Create: `src/Yuo/Time.hs`, `src/Yuo/Songs.hs`, `test/TimeSpec.hs`, `test/SongsSpec.hs`

**Interfaces:**
- Produces: `data Progress = Progress { posSec :: Int, durSec :: Int } deriving (Eq, Show)`
- Produces: `parseProgress :: Text -> Maybe Progress` — slider text `"<span> of <span>"`, span = sequence of `<n> Hour(s)|Minute(s)|Second(s)`.
- Produces: `renderProgress :: Progress -> Text` (inverse, plural units always, hours only when > 0).
- Produces: `parseResultDuration :: Text -> Maybe Int` — trailing `"<n> hour(s), <n> minute(s), <n> second(s)"` phrase (any subset, comma-separated) at the end of a result-link name.
- Produces: `pauseDeadline :: Double -> Int -> Double -> Double -> Double` — `pauseDeadline start dur adSecs pauseLatency = start + fromIntegral dur - 3 - pauseLatency + adSecs`.
- Produces: `data Song = Song { songIndex :: Int, songQuery :: Text } deriving (Eq, Show)` (in `Yuo.Songs`) and `parseSongs :: Text -> [Song]`.

- [ ] **Step 1: Write failing tests** (`TimeSpec`, `SongsSpec`):
  ```haskell
  parseProgress "0 Minutes 2 Seconds of 3 Minutes 33 Seconds" `shouldBe` Just (Progress 2 213)
  parseProgress "1 Minute 1 Second of 4 Minutes 7 Seconds" `shouldBe` Just (Progress 61 247)
  parseProgress "1 Hour 2 Minutes 3 Seconds of 2 Hours 0 Minutes 0 Seconds" `shouldBe` Just (Progress 3723 7200)
  parseProgress "Seek to 0 Minutes 0 Seconds" `shouldBe` Nothing
  parseProgress "100% volume" `shouldBe` Nothing
  property $ \(NonNegative p) (NonNegative extra) -> let pr = Progress (p `mod` 36000) (p `mod` 36000 + extra `mod` 36000) in parseProgress (renderProgress pr) == Just pr
  parseResultDuration "Daft Punk - Get Lucky (Official Audio) ft. Pharrell Williams, Nile Rodgers 4 minutes, 9 seconds" `shouldBe` Just 249
  parseResultDuration "Daft Punk - 'Get Lucky' (10 min loop) 10 minutes" `shouldBe` Just 600
  parseResultDuration "Long mix 1 hour, 2 minutes, 3 seconds" `shouldBe` Just 3723
  parseResultDuration "Mix - Daft Punk - Get Lucky (Official Audio) ft. Pharrell Williams, Nile Rodgers" `shouldBe` Nothing
  pauseDeadline 100 247 0 0.5 `shouldBe` 343.5
  pauseDeadline 100 2 0 0.5 `shouldSatisfy` (<= 100)        -- shorter than 3 s → pause immediately
  pauseDeadline 100 247 30 0.5 `shouldBe` 373.5
  parseSongs "\xFEFFDaft Punk Get Lucky\n\n# comment\n  Beyoncé Halo  \r\n" `shouldBe` [Song 0 "Daft Punk Get Lucky", Song 1 "Beyoncé Halo"]
  ```
- [ ] **Step 2:** `cabal test` → fails (modules missing).
- [ ] **Step 3:** Implement both modules (hand-written `Text` tokenizer; no regex dependency).
- [ ] **Step 4:** `cabal test` → all pass.
- [ ] **Step 5:** Commit `feat: time parsing, pause deadline, songs file`.

### Task 3: `Yuo.Match` (pure)

**Files:**
- Create: `src/Yuo/Match.hs`, `test/MatchSpec.hs`

**Interfaces:**
- Produces: `data PlayState = Playing | PausedState deriving (Eq, Show)`
- Produces: `data PaneInfo = PaneInfo { paneVideoTitle :: Maybe Text, paneAudio :: Bool } deriving (Eq, Show)`
- Produces: `tokens :: Text -> [Text]` — NFD (unicode-transforms), drop non-spacing marks, `toCaseFold`, split on non-alphanumerics, drop empty.
- Produces: `songMatches :: Text -> Text -> Bool` — `songMatches query title`: ≥ 60 % of the query's tokens occur in the title's tokens.
- Produces: `paneInfo :: Text -> PaneInfo` — strips `" - Google Chrome"`, detects and strips `" - Audio playing"`, strips trailing `" - YouTube"`.
- Produces: `playState :: Text -> Maybe PlayState` — exact titles `Pause (k)`, `Pause keyboard shortcut k` → `Playing`; `Play (k)`, `Play keyboard shortcut k` → `PausedState`.
- Produces: `isAdMarker :: Text -> Bool` — title ∈ {`Sponsored`, `My Ad Center`, `Skip`, `Skip Ad`, `Skip Ads`}.

- [ ] **Step 1: Write failing tests:**
  ```haskell
  paneInfo "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster) - YouTube - Audio playing - Google Chrome"
    `shouldBe` PaneInfo (Just "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)") True
  paneInfo "Daft Punk Get Lucky - YouTube - Google Chrome" `shouldBe` PaneInfo (Just "Daft Punk Get Lucky") False
  paneInfo "New Tab - Google Chrome" `shouldBe` PaneInfo Nothing False
  songMatches "Daft Punk Get Lucky" "Daft Punk - Get Lucky (Official Audio) ft. Pharrell Williams, Nile Rodgers" `shouldBe` True
  songMatches "Daft Punk Get Lucky" "Rick Astley - Together Forever (Official HD Video)" `shouldBe` False
  songMatches "Beyoncé Halo" "Beyonce - Halo (Official Video)" `shouldBe` True
  songMatches "a-ha Take On Me" "a-ha - Take On Me (Official Video) [4K]" `shouldBe` True
  map playState ["Pause (k)", "Pause keyboard shortcut k", "Play (k)", "Play keyboard shortcut k", "Play on TV"]
    `shouldBe` [Just Playing, Just Playing, Just PausedState, Just PausedState, Nothing]
  map isAdMarker ["Sponsored", "My Ad Center", "Skip", "Skip navigation", "Settings"] `shouldBe` [True, True, True, False, False]
  ```
- [ ] **Step 2:** `cabal test` → fails.
- [ ] **Step 3:** Implement `Yuo.Match`.
- [ ] **Step 4:** `cabal test` → passes.
- [ ] **Step 5:** Commit `feat: title matching, pane parsing, play state, ad markers`.

### Task 4: `Yuo.Types`, `Yuo.Log`, `Yuo.Blindly`, `b4` proxy

**Files:**
- Create: `src/Yuo/Types.hs`, `src/Yuo/Log.hs`, `src/Yuo/Blindly.hs`, `src/Yuo/Concurrent.hs`, `src/Yuo/Guard.hs`, `test/BlindlySpec.hs`, `test/LogSpec.hs`, `test/GuardSpec.hs`
- Modify: `app/Main.hs` (wire `b4`)

**Interfaces:**
- Produces (`Yuo.Types`): `newtype Pid = Pid Int`; `newtype Path = Path Text` (dot-separated indexes); `data Stage = Exploration | Exploitation`; `data Origin = OLlm | ODriver | OObserver | OSolution`; `data EventKind = SongAssigned | PlaybackStarted | Paused | AdSeen | PlayObserved | PauseObserved | StepError | SongGaveUp`; `data Event = Event { evT :: Double, evStage :: Stage, evSource :: Origin, evKind :: EventKind, evSong :: Maybe Song, evData :: Value }`; `data Call = Call { callStage :: Stage, callOrigin :: Origin, callArgv :: [Text], callStart :: Double, callMs :: Double, callExit :: Int, callStdout :: Text, callStderr :: Text }`. JSON instances use the snake_case names and string values from Global Constraints (`evT` → `"t"`, `callStart` → `"t_start"`, `callMs` → `"duration_ms"`).
- Produces (`Yuo.Blindly`):
  ```haskell
  data Risk = ReadOnly | Mutating
  data FindQuery = FindQuery { fqTitle, fqRole, fqValue, fqDescription, fqIdentifier :: Maybe Text, fqUnder :: Maybe Path, fqDepth :: Int, fqLimit :: Int }
  findQ :: FindQuery   -- all Nothing, depth 40, limit 1
  data Command (r :: Risk) where
    Apps :: Command 'ReadOnly; Find :: FindQuery -> Command 'ReadOnly; Inspect :: Path -> Command 'ReadOnly; Schema :: Command 'ReadOnly
    SetValue :: Path -> Text -> Command 'Mutating; Press :: Path -> Maybe Text -> Command 'Mutating; Focus :: Path -> Command 'Mutating
    Key :: Text -> Maybe (Path, Text) -> Command 'Mutating; Paste :: Text -> Maybe Path -> Command 'Mutating
    Scroll :: Text -> Int -> Command 'Mutating; Hover :: Int -> Int -> Command 'Mutating
  argv :: Maybe Pid -> Command r -> [Text]            -- pure; adds --pid when given (not for Apps/Schema)
  newtype Backend = Backend { invoke :: [Text] -> IO (Int, Text, Text) }   -- exit, stdout, stderr
  processBackend :: FilePath -> Backend
  data B4 = B4 { b4Backend :: Backend, b4Pid :: Maybe Pid, b4Lock :: MVar (), b4Logger :: Logger, b4Stage :: Stage }
  newtype InputToken = InputToken ()                  -- only obtainable inside withInput
  withInput :: B4 -> (InputToken -> IO a) -> IO a     -- takes b4Lock
  runRead  :: B4 -> Origin -> Command 'ReadOnly -> IO (Either B4Error Value)
  runInput :: B4 -> Origin -> InputToken -> Command 'Mutating -> IO (Either B4Error Value)
  runRawArgv :: B4 -> Origin -> [Text] -> IO (Int, Text, Text)   -- proxy; logs, no parsing
  data B4Error = B4Usage Text | B4Access Text | B4Gone Text | B4Unexpected Int Text   -- 64 / 77 / 77 with "No visible windows" / other
  ```
- Produces (`Yuo.Log`): `data Logger`; `newRunDir :: Stage -> IO FilePath`; `withLogger :: FilePath -> (Logger -> IO a) -> IO a` (writer thread on a `TBQueue`, flushes on exit); `logCall :: Logger -> Call -> IO ()`; `logEvent :: Logger -> Event -> IO ()`; `logLlm :: Logger -> Value -> IO ()`; `appendLineShared :: FilePath -> Text -> IO ()` (open-append-close, retry on `IOException` up to 200× with 5 ms back-off — used by proxy processes).
- Produces (CLI): `yuotudidjey b4 --run-dir DIR --stage STAGE --origin ORIGIN --blindly4 EXE -- ARGS…` → passes stdout/exit code through, appends one `Call` line to `DIR/blindly4.jsonl` via `appendLineShared`.
- Produces (`Yuo.Concurrent`, file `src/Yuo/Concurrent.hs`): `firstJust :: [IO (Maybe a)] -> IO (Maybe a)` — runs all with `async`, returns the first `Just` to finish (cancelling the rest), `Nothing` only when all return `Nothing`; used for fallback lookups (cached path vs. `find`).
- Produces: `data ChromeGone = ChromeGone Text` (`Exception`); `runRead`/`runInput` throw it on `B4Gone`, so every stage stops instead of looping.
- Produces (`Yuo.Guard`, file `src/Yuo/Guard.hs`): `allowedCall :: [Text] -> Either Text ()` implementing the Global Constraints safety guard on a blindly4 argv; `Yuo.Blindly.runInput` and the `b4` proxy call it first and refuse (proxy: exit 64 with `{"error":…,"code":"guard_refused"}`, logged).
- `Command` gains `Open Text Text :: Command 'Mutating` (url, profile dir) and `Find` gains `fqXml :: Bool` (`--format xml`); `SetValue`/`Focus` gain a `Text` expected description.

- [ ] **Step 1: Write failing tests:**
  ```haskell
  argv (Just (Pid 7)) (Find findQ { fqIdentifier = Just "movie_player" })
    `shouldBe` ["find","--identifier","movie_player","--depth","40","--limit","1","--pid","7"]
  argv (Just (Pid 7)) (Press (Path "0.1.2") (Just "Pause")) `shouldBe` ["press","--path","0.1.2","--expect-description","Pause","--pid","7"]
  argv (Just (Pid 7)) (Hover 10 20) `shouldBe` ["hover","--x","10","--y","20","--pid","7"]
  argv (Just (Pid 7)) Apps `shouldBe` ["apps"]
  -- fake Backend returning (77, "{\"error\":\"No visible windows for PID 7\",\"code\":\"accessibility_error\"}", "")
  runRead b4 ODriver Apps `shouldThrow` (\(ChromeGone m) -> m == "No visible windows for PID 7")
  firstJust [threadDelay 50000 >> pure (Just 1), pure Nothing, threadDelay 10000 >> pure (Just 2)] `shouldReturn` Just (2 :: Int)
  firstJust [pure Nothing, pure (Nothing :: Maybe Int)] `shouldReturn` Nothing
  allowedCall ["press","--path","0.1","--expect-description","Search","--pid","7"] `shouldBe` Right ()
  allowedCall ["press","--path","0.1","--pid","7"] `shouldSatisfy` isLeft                                   -- no expected label
  allowedCall ["press","--path","0.1","--expect-description","Subscribe","--pid","7"] `shouldSatisfy` isLeft
  allowedCall ["set-value","--path","0.2","--value","hi","--expect-description","Add a comment","--pid","7"] `shouldSatisfy` isLeft
  allowedCall ["type","--text","x","--pid","7"] `shouldSatisfy` isLeft
  allowedCall ["key","--key","return","--pid","7"] `shouldSatisfy` isLeft
  allowedCall ["key","--key","return","--pid","7","--target-path","0.2","--require-value","Toto Africa"] `shouldBe` Right ()
  allowedCall ["open","--url","https://evil.example/","--chrome-profile","C:\\p"] `shouldSatisfy` isLeft
  allowedCall ["find","--title","x"] `shouldBe` Right ()
  -- logging: after runRead with a fake backend, blindly4.jsonl has exactly 1 line whose "origin" == "driver" and "argv" == ["apps"]
  -- appendLineShared: 8 concurrent writers × 50 lines → file has 400 lines, each valid JSON
  ```
- [ ] **Step 2:** `cabal test` → fails.
- [ ] **Step 3:** Implement `Yuo.Types`, `Yuo.Log`, `Yuo.Blindly`; wire `b4` in `app/Main.hs`.
- [ ] **Step 4:** `cabal test` → passes. Then live, read-only: `cabal run yuotudidjey -- b4 --run-dir logs/tmp --stage exploration --origin driver --blindly4 blindly4/.build/windows/blindly4.exe -- schema` → prints schema JSON containing `"hover"`; `logs/tmp/blindly4.jsonl` has 1 line.
- [ ] **Step 5:** Commit `feat: typed blindly4 commands, input lock, call/event logging, b4 proxy`.

### Task 5: `Yuo.Tree` (pure) with recorded fixtures

**Files:**
- Create: `src/Yuo/Tree.hs`, `test/TreeSpec.hs`, `test/fixtures/results_find.json`, `test/fixtures/player_children.json`, `test/fixtures/player_ad.json`

**Interfaces:**
- Produces: `data Node = Node { nPath :: Text, nRole :: Text, nTitle :: Text, nValue :: Maybe Text, nIdent :: Text, nActions :: [Text], nCenter :: Maybe (Int, Int) }`; `instance FromJSON Node` (from a blindly4 `matches[]` entry; center from position+size).
- Produces: `parseMatches :: Value -> Either Text [Node]`.
- Produces: `capXml :: Int -> Text -> Text` — `capXml maxChars xml`: keeps whole lines (blindly4 emits one element per line) up to `maxChars`, then closes open elements and appends `<!-- truncated N lines -->`; drops lines for nameless, valueless, actionless `AXGroup` leaves to save space.

- [ ] **Step 1: Capture fixtures** (live, read-only, Chrome on a YouTube results page and a watch page): `blindly4 find --pid <chrome> --identifier video-title --role AXLink --depth 40 --limit 8` → `results_find.json`; `blindly4 find --pid <chrome> --under <movie_player> --title "" --depth 3 --limit 80` during a song → `player_children.json`, during an ad → `player_ad.json`; the same player query with `--format xml` → `player_children.xml` (`xmlFixture`).
- [ ] **Step 2: Write failing tests:**
  ```haskell
  -- results_find.json: 8 nodes, first nTitle ends with "4 minutes, 9 seconds", nIdent == "video-title"
  capXml 10000 xmlFixture `shouldBe` xmlFixture without its empty-AXGroup leaf lines
  T.length (capXml 300 xmlFixture) `shouldSatisfy` (<= 400)              -- cap plus closing tags and comment
  capXml 300 xmlFixture `shouldSatisfy` T.isInfixOf "<!-- truncated"
  -- every line of capXml output that opens an element is either self-closing or matched by a closing line
  ```
- [ ] **Step 3:** `cabal test` → fails. **Step 4:** Implement. **Step 5:** `cabal test` → passes.
- [ ] **Step 6:** Commit `feat: blindly4 match parsing and pruned XML rendering`.

### Task 6: `Yuo.Chrome`

**Files:**
- Create: `src/Yuo/Chrome.hs`

**Interfaces:**
- Consumes: `Yuo.Blindly` (`runRead`, `Apps`).
- Produces: `data ChromeSession = ChromeSession { chromePid :: Pid, chromeProfile :: FilePath }`; `withChrome :: B4 -> Stage -> (ChromeSession -> IO a) -> IO a` — creates `.chrome-profile/<stage>-<stamp>/` (absolute), runs `blindly4 open --url https://www.youtube.com/ --chrome-profile <dir>` (origin `driver`) and takes `pid` from its JSON, waits (≤ 20 s, `inspect --path 0.1`) until the pane title contains `YouTube`; `bracket` release: `blindly4 key --key alt+f4 --pid <pid>`, wait ≤ 10 s until `apps` no longer lists the pid, then delete the profile directory (filesystem only).

- [ ] **Step 1:** Implement.
- [ ] **Step 2: Live check:** a temporary `cabal repl` call `withChrome b4 Exploration (\s -> print (chromePid s) >> threadDelay 3000000)` → prints a PID different from any pre-existing Chrome; window appears and closes; profile dir removed.
- [ ] **Step 3:** Commit `feat: isolated Chrome session lifecycle`.

### Task 7: `Yuo.Observer` (pure core + concurrent probe loop)

**Files:**
- Create: `src/Yuo/Observer.hs`, `test/ObserverSpec.hs`

**Interfaces:**
- Consumes: `Yuo.Match`, `Yuo.Time`, `Yuo.Tree`, `Yuo.Blindly`.
- Produces:
  ```haskell
  data Probe = Probe { prAt :: Double, prPane :: PaneInfo, prOnWatch :: Bool, prPlay :: Maybe PlayState, prAd :: Bool, prProgress :: Maybe Progress }
  data PlayInfo = PlayInfo { piSong :: Song, piAssigned :: Double, piObserved :: Double, piStartEst :: Double, piDuration :: Maybe Int, piAdSecs :: Double }
  data ObsState = Idle | Awaiting Song Double (Maybe Double) | Watching PlayInfo (Maybe Double) | AwaitPause PlayInfo Double
  data ObsOut = OutPlay PlayInfo | OutAd Song Double Double | OutPauseMargin Song Double
  stepObserver :: ObsState -> Probe -> (ObsState, [ObsOut])
  assign :: Song -> Double -> ObsState -> ObsState          -- song_assigned at time t
  pausedAt :: Double -> ObsState -> ObsState                -- paused event at time t
  probeFromNodes :: Double -> Text -> Maybe Text -> [Node] -> Probe   -- pane title, address-bar value, player subtree
  data Observer = Observer { obsAssign :: Song -> Double -> IO (), obsPaused :: Double -> IO (), obsPlayInfo :: STM (Maybe PlayInfo), obsPlayer :: STM (Maybe Node) }   -- obsPlayer: latest movie_player node (path + centre)
  withObserver :: B4 -> Stage -> (Observer -> IO a) -> IO a
  ```
- Rules (`stepObserver`): in `Awaiting s tA _`, a probe with `prOnWatch && paneAudio && songMatches query title && prPlay == Just Playing && not prAd` → `Watching`, emit `OutPlay` with `piObserved = prAt`, `piStartEst = prAt - posSec` when `prProgress` has `posSec <= 5` else `prAt`, `piDuration = durSec`. While `Awaiting`, ad probes record the ad start (the `Maybe Double`); the first non-ad probe after one emits `OutAd song start end` and adds `end - start` to the pre-roll ad time that becomes `piAdSecs` in `OutPlay`. `AwaitPause pi tP`: first probe with `prAt >= tP + 1.5` and `prProgress` → `OutPauseMargin song (dur - pos)` → `Idle`.
- Probe loop: 3 read-only calls run with `concurrently` — `inspect --path 0.1` (pane), `inspect` cached address-bar path (rediscovered with `find --role AXTextField --title "Address and search bar" --depth 12` when its title no longer matches), `find --under <movie_player> --title "" --depth 3 --limit 80` (player path cached; rediscovered with `find --identifier movie_player` when `inspect` no longer shows that identifier). Poll back-to-back while `Awaiting`, never while `Watching` (the song runs on a timer), every 0.5 s while `AwaitPause`. All calls logged with origin `observer`; `OutPlay`/`OutAd`/`OutPauseMargin` logged as `play_observed`/`ad_seen`/`pause_observed` events.

- [ ] **Step 1: Write failing tests** (probes built with `probeFromNodes` from Task 5 fixtures):
  ```haskell
  -- ad probe then song probe for "Daft Punk Get Lucky": no OutPlay on the ad probe; OutPlay on the song probe
  -- results page (address "youtube.com/results?search_query=…", pane "Daft Punk Get Lucky - YouTube - Audio playing - Google Chrome") → no OutPlay
  -- song probe with Progress 2 247 at t=50 after assign at t=40 → piObserved 50, piStartEst 48, piDuration Just 247
  -- Awaiting, probes: ad at t=100, ad at t=110, song at t=125 → OutAd _ 100 125, then OutPlay with piAdSecs == 25
  -- AwaitPause pi 300, probe at 301 (ignored), probe at 302 with Progress 244 247 → OutPauseMargin _ 3.0, state Idle
  ```
- [ ] **Step 2:** `cabal test` → fails. **Step 3:** Implement. **Step 4:** `cabal test` → passes.
- [ ] **Step 5: Live check:** with Chrome on a playing watch page, run the probe once from `cabal repl` → `Probe` shows `prOnWatch = True`, `paneAudio = True`, `prPlay = Just Playing`.
- [ ] **Step 6:** Commit `feat: independent playback observer`.

### Task 8: `Yuo.Llm`

**Files:**
- Create: `src/Yuo/Llm.hs`, `test/LlmSpec.hs`

**Interfaces:**
- Produces:
  ```haskell
  data Purpose = PStep | PPreparePause | PReflect | PCodegen | PRepair
  data LlmBackend = LlmBackend { llmName :: Text, llmAsk :: Value -> Text -> IO (Either Text Value) }  -- schema, prompt
  claudeBackend :: Text -> LlmBackend          -- model, e.g. "sonnet"
  codexBackend :: Maybe Text -> LlmBackend
  askLogged :: Logger -> LlmBackend -> Purpose -> Value -> Text -> IO (Either Text Value)   -- logs {t, purpose, backend, prompt, response, ms, ok} to llm.jsonl
  extractClaude :: Value -> Either Text Value   -- from `claude --output-format json` stdout
  ```
- `claudeBackend`: `claude -p --model <m> --tools "" --output-format json --json-schema <schema> --no-session-persistence`, prompt on stdin, cwd = a scratch dir under the run dir. `extractClaude` returns `structured_output` when present, else parses the `result` string as JSON; `is_error: true` → `Left`.
- `codexBackend`: `codex exec --sandbox read-only --ephemeral --skip-git-repo-check --output-schema <tmp schema file> -o <tmp out file> -`, prompt on stdin; reads the out file as JSON.
- `askLogged` enforces a 120 s timeout per attempt (`System.Timeout.timeout`, child process terminated on expiry) and retries twice with 2 s / 5 s back-off; the final failure is `Left "llm timeout"` / the last error.

- [ ] **Step 1: Probe the real shape once:** `echo 'Return {"n": 1}.' | claude -p --model sonnet --tools "" --output-format json --json-schema '{"type":"object","properties":{"n":{"type":"integer"}},"required":["n"]}' --no-session-persistence > test/fixtures/claude_structured.json`.
- [ ] **Step 2: Write failing tests:** `extractClaude` on `claude_structured.json` → `Right (object ["n" .= 1])`; on `{"is_error":true,"result":"boom"}` → `Left "boom"`; on `{"result":"{\"n\":2}"}` → `Right (object ["n" .= 2])`; `askLogged` with a fake backend that sleeps forever and a 1 s test timeout → `Left "llm timeout"` after 3 attempts and 3 `llm.jsonl` lines with `"ok":false`.
- [ ] **Step 3:** `cabal test` → fails. **Step 4:** Implement. **Step 5:** `cabal test` → passes.
- [ ] **Step 6:** Commit `feat: LLM CLI adapters with structured output and logging`.

### Task 9: `Yuo.Explore` (exploration loop, mechanical pause, playbook)

**Files:**
- Create: `src/Yuo/Explore/Action.hs`, `src/Yuo/Explore/Prompt.hs`, `src/Yuo/Explore.hs`, `src/Yuo/Pause.hs`, `test/ActionSpec.hs`, `test/ExploreSpec.hs`
- Modify: `app/Main.hs` (wire `explore`)

**Interfaces:**
- Consumes: Tasks 2–8.
- Produces (`Yuo.Explore.Action`):
  ```haskell
  data Action = AFind FindQuery | AInspect Path | AList Path Int Int | ASetValue Path Text Text | APress Path Text
              | AFocus Path Text | AKey Text (Maybe (Path, Text)) | AScroll Text Int
              | AHover Int Int | AWait Int | ADone | AGiveUp Text
  data StepReply = StepReply { srThought :: Text, srActions :: [Action], srNote :: Text }
  decodeStep :: Value -> Either Text StepReply      -- enforces 1..4 actions, wait clamp 0..5000, known cmds only
  stepSchema :: Value                               -- JSON Schema passed to the LLM
  data PausePlan = PausePlan { ppUnderIdentifier :: Maybe Text, ppRole :: Text, ppTitles :: [Text], ppDurationSec :: Int }
  decodePausePlan :: Value -> Either Text PausePlan
  ```
  JSON action shape: `{"cmd":"find","title":…,"role":…,"value":…,"description":…,"identifier":…,"under":…,"depth":…,"limit":…}`, `{"cmd":"inspect","path"}`, `{"cmd":"list","under","depth","limit"}` (→ `find --under P --title "" …`), `{"cmd":"set_value","path","value","expect"}`, `{"cmd":"press","path","expect"}`, `{"cmd":"focus","path","expect"}`, `{"cmd":"key","key","target_path"?,"require_value"?}`, `{"cmd":"scroll","direction","amount"?}`, `{"cmd":"hover","x","y"}`, `{"cmd":"wait","ms"}`, `{"cmd":"done"}`, `{"cmd":"give_up","reason"}`. (`APaste` is dropped from `Action`; `APress`/`ASetValue`/`AFocus` carry a required `Text` expect.)
- Produces (`Yuo.Explore.Prompt`): `stepPrompt :: StepContext -> Text`, `pausePrompt :: Song -> Text -> Text`, `reflectPrompt :: Value -> [StepRecord] -> Text` — blank slate (goal, song, `blindly4 schema` text, action schema, safety guard rules, last 8 step records, playbook, current pane title). Goal text: play the song itself from its beginning (not loops/extended/live/lyrics versions), skip unavailable/age-restricted/live results, dismiss pop-ups and "Continue watching?" prompts, never touch comments/subscribe/like/share/sign-in/purchase controls.
- Action → argv always adds `--pid`, `--format xml` on `find`/`list`, and the action's `expect` as `--expect-description`; every action passes `allowedCall` before running (refusals are fed back like decode errors).
- Produces (`Yuo.Pause`): `waitAndPause :: B4 -> Observer -> PlayInfo -> PausePlan -> Maybe Int -> IO Double` — deadline in a `TVar` from `pauseDeadline` (duration = slider duration, else plan duration; `Maybe Int` = `--max-play-seconds` cap → deadline `min` (start + cap)); STM wait via `registerDelay` on the deadline `TVar`; at deadline − 15 s: `hover` the player centre + read the slider → re-sync start; at deadline: resolve the pause control by `PausePlan`, `press --expect-description Pause`; return pause wall time.
- Produces (`Yuo.Explore`): `data ExploreConfig = ExploreConfig { ecSongs :: [Song], ecMaxSongs :: Int, ecBackend :: LlmBackend, ecMaxPlay :: Maybe Int, ecBlindly4 :: FilePath }`; `exploreSong :: ExploreEnv -> Song -> IO SongOutcome` (`data SongOutcome = Played PlayInfo | GaveUp Text`); `runExploration :: ExploreConfig -> IO FilePath`.
- Songs are iterated as `take ecMaxSongs (cycle songs)`. Pause-control resolution uses `firstJust` (validate cached path via `inspect` ‖ `find` by `PausePlan`).
- Loop per song: emit `song_assigned` (driver) + `obsAssign`; repeat ≤ 25 steps { stop when `obsPlayInfo` is `Just`; ask `PStep`; decode (on `Left` feed the error into the next prompt); run actions (reads `runRead`, mutations inside `withInput`, origin `llm`), record results as XML snapshots in `snapshots/song<i>-step<n>.xml` }; then `PPreparePause` → `PausePlan`; fork `PReflect` with `async` (updates `playbook.json`, joined before the next song's first step); `waitAndPause`; emit `paused` + `obsPaused`. 25 steps without playback → `song_gave_up`, continue.
- After `ecMaxSongs` songs: hand off to Task 10 `generateSolution`.

- [ ] **Step 1: Write failing tests** (`ActionSpec`, `ExploreSpec` with fake `Backend` + fake `LlmBackend` + fake `Observer`):
  ```haskell
  decodeStep (obj [cmd "press" & path "0.1" & expect "Search"]) `shouldBe` Right (StepReply _ [APress (Path "0.1") "Search"] _)
  decodeStep with {"cmd":"rm -rf"} `shouldSatisfy` isLeft
  decodeStep with 5 actions `shouldSatisfy` isLeft
  decodeStep with {"cmd":"press"} (no path) `shouldSatisfy` isLeft
  decodeStep with {"cmd":"wait","ms":60000} → AWait 5000
  decodeStep on the non-JSON string "I think we should click" `shouldSatisfy` isLeft
  -- fake LLM always answers find; observer never plays → exploreSong returns GaveUp after exactly 25 LLM step calls
  -- fake LLM answers malformed twice then valid; observer plays after the valid step → Played, and the 2nd prompt contains the decode error text
  -- every APress/ASetValue in a run is logged with origin "llm" and never overlaps another input call (lock)
  -- backend always answers exit 77 "No visible windows for PID 7" → exploreSong throws ChromeGone; runExploration logs step_error and exits non-zero
  ```
- [ ] **Step 2:** `cabal test` → fails. **Step 3:** Implement. **Step 4:** `cabal test` → passes.
- [ ] **Step 5: Live dev run** (desktop in use ~5 min): `cabal run yuotudidjey -- explore --songs songs.txt --max-songs 2 --max-play-seconds 20 --skip-codegen` → both songs `play_observed`, `pause_observed`; inspect `logs/exploration-*/` files.
- [ ] **Step 6:** Commit `feat: LLM exploration loop, mechanical pause, playbook reflection`.

### Task 10: `Yuo.Codegen` (generation, lints, smoke, repair)

**Files:**
- Create: `src/Yuo/Codegen.hs`, `src/Yuo/Codegen/Lint.hs`, `src/Yuo/Codegen/Contract.hs`, `test/LintSpec.hs`, `test/fixtures/fp_good.py`, `test/fixtures/fp_bad_while.py`, `test/fixtures/fp_bad_mutation.py`, `test/fixtures/fp_bad_llm.py`, `test/fixtures/fp_bad_bypass.py`

**Interfaces:**
- Produces (`Lint`): `fpLintScript :: Text` (Python `ast` checker implementing the FP + safety rules in Global Constraints; prints `{"ok": bool, "violations": [{"line": n, "rule": "…"}]}`); `lintSolution :: FilePath -> IO [Text]` — runs `python -I -X utf8 -m py_compile <file>`, then `python -I -X utf8 - <file>` with the script on stdin; returns human-readable violations.
- Produces (`Contract`): `contractText :: Text` — the solution.py contract from the spec (CLI flags `--songs --max-songs --forever --max-play-seconds --start-index`; env `YUO_B4` = JSON array command prefix, `YUO_EVENTS` = events path, `YUO_CHROME_PID`; event JSON lines `{"t","stage":"exploitation","source":"solution","kind","song_index","song",…}` with kinds `song_assigned playback_started paused ad_seen step_error`; `song_assigned` written before the song's first blindly4 call; Chrome is already open (PID in `YUO_CHROME_PID`), never launched or closed by the solution; every `press`/`set-value`/`focus` passes `--expect-description` (the proxy refuses otherwise); safety guard rules verbatim; rediscover-before-mutate; serialize input; race read-only fallbacks with `concurrent.futures`; FP rules verbatim; stdlib only).
- Produces (`Codegen`): `generateSolution :: CodegenEnv -> IO (Either Text FilePath)` — prompt (`PCodegen`) = contract + `playbook.json` + condensed traces (per song: ordered `argv` + exit + first 200 chars of stdout of `llm`/`driver` calls) + `blindly4 schema`; schema `{"code": string}`; writes `generated/solution.py`; lint → smoke (`--max-songs 1 --max-play-seconds 20`, 240 s timeout, run under `withChrome` + `withObserver`, success = exit 0 and observer `play_observed` + `pause_observed` for song 0) → on failure `PRepair` with violations or smoke tail (stderr, last 20 calls, events), ≤ 3 rounds.

- [ ] **Step 1: Write fixtures and failing tests:**
  ```haskell
  lintSolution "test/fixtures/fp_good.py" `shouldReturn` []
  lintSolution "test/fixtures/fp_bad_while.py" >>= (`shouldSatisfy` any ("while" `T.isInfixOf`))
  lintSolution "test/fixtures/fp_bad_mutation.py" >>= (`shouldSatisfy` any ("append" `T.isInfixOf`))   -- also has `x += 1`, `global`
  lintSolution "test/fixtures/fp_bad_llm.py" >>= (`shouldSatisfy` any ("claude" `T.isInfixOf`))       -- subprocess.run(["claude","-p"]) and `import requests`
  lintSolution "test/fixtures/fp_bad_bypass.py" >>= (`shouldSatisfy` any ("ctypes" `T.isInfixOf`))    -- import ctypes; subprocess.run(["chrome.exe"]) not built from YUO_B4
  ```
  `fp_good.py`: frozen dataclass, ≥ 5 lambdas, `functools.reduce`, `itertools.cycle/islice`, `map`/`filter`, no mutation.
- [ ] **Step 2:** `cabal test` → fails. **Step 3:** Implement. **Step 4:** `cabal test` → passes.
- [ ] **Step 5:** Commit `feat: solution.py codegen with FP/safety lint, smoke test and repair loop`.

### Task 11: `Yuo.Exploit`

**Files:**
- Create: `src/Yuo/Exploit.hs`, `test/ExploitSpec.hs`
- Modify: `app/Main.hs` (wire `exploit`)

**Interfaces:**
- Produces: `stripLlmPath :: [FilePath] -> [FilePath] -> [FilePath]` (`stripLlmPath pathEntries llmDirs`, case-insensitive, trailing-separator-insensitive); `llmDirs :: IO [FilePath]` (directories of `claude`/`codex` found via `findExecutable`); `solutionEnv :: FilePath -> FilePath -> FilePath -> Pid -> [(String, String)] -> [(String, String)]` (`solutionEnv selfExe runDir blindly4Exe pid baseEnv` → sets `YUO_B4`, `YUO_EVENTS`, `YUO_CHROME_PID`, `PYTHONIOENCODING=utf-8`, stripped `PATH`, removes `ANTHROPIC_API_KEY`/`OPENAI_API_KEY`); `runExploitation :: ExploitConfig -> IO FilePath` — `withChrome`, `withObserver`, tails `events.jsonl` every 100 ms feeding `song_assigned`/`paused` into the observer, runs `python -I -X utf8 generated/solution.py --songs … [--max-songs N | --forever]`, propagates its exit code. Watchdog: when no new event line arrives within `watchdogSeconds` (default: longest `play_observed` duration seen so far + 120, initially 600), terminate the child, log `step_error` `{"reason":"watchdog"}`, exit 3. In `--forever` mode the supervisor starts a fresh run directory after every `length songs` `paused` events (`YUO_EVENTS`/`YUO_B4` are re-pointed by restarting the child with `--start-index`).

- [ ] **Step 1: Write failing tests:**
  ```haskell
  stripLlmPath ["C:\\a", "C:\\Users\\muham\\AppData\\Roaming\\npm\\", "C:\\b"] ["c:\\users\\muham\\appdata\\roaming\\npm"] `shouldBe` ["C:\\a", "C:\\b"]
  lookup "YUO_CHROME_PID" (solutionEnv "y.exe" "logs/x" "b.exe" (Pid 42) []) `shouldBe` Just "42"
  (decode . encodeUtf8 . T.pack <$> lookup "YUO_B4" env) `shouldBe` Just (Just ["y.exe","b4","--run-dir","logs/x","--stage","exploitation","--origin","solution","--blindly4","b.exe","--"])
  lookup "ANTHROPIC_API_KEY" (solutionEnv … [("ANTHROPIC_API_KEY","k")]) `shouldBe` Nothing
  ```
- [ ] **Step 2:** `cabal test` → fails. **Step 3:** Implement. **Step 4:** `cabal test` → passes.
- [ ] **Step 5:** Commit `feat: exploitation supervisor with no-LLM environment`.

### Task 12: `Yuo.Metrics` (pure) and `Yuo.Report`

**Files:**
- Create: `src/Yuo/Metrics.hs`, `src/Yuo/Report.hs`, `test/MetricsSpec.hs`
- Modify: `app/Main.hs` (wire `report`)

**Interfaces:**
- Produces:
  ```haskell
  data SongMetric = SongMetric { smStage :: Stage, smIndex :: Int, smSong :: Text, smAssigned :: Double, smLatency :: Double, smLatencyEst :: Double, smAdSecs :: Double, smCalls :: Map Origin Int, smB4Ms :: Double, smLlmMs :: Double, smLlmCalls :: Int, smPauseMargin :: Maybe Double }
  songMetrics :: Stage -> [Event] -> [Call] -> [Value] -> [SongMetric]   -- events, calls, llm records; calls/LLM attributed to song i by t ∈ [assigned_i, assigned_{i+1})
  data Stats = Stats { stN :: Int, stMean, stMedian, stP90, stMin, stMax :: Double }
  stats :: [Double] -> Stats                                             -- single strict foldl' for n/sum/min/max; nearest-rank median and p90
  renderReport :: [SongMetric] -> [SongMetric] -> Text                   -- markdown
  renderCsv :: [SongMetric] -> Text
  writeReport :: FilePath -> FilePath -> FilePath -> IO ()               -- exploreDir exploitDir outDir → report.md, latency.csv, traces/<stage>-song<i>.txt
  ```
- `report.md` sections: per-stage summary table (mean/median/p90/min/max latency, mean est. latency, mean ad seconds, mean blindly4 calls per song by origin, total LLM calls and LLM share of latency, mean pause margin); per-song table for both stages; command mix (count by `argv[0]`) per stage; side-by-side call sequence of song 0 in both stages.

- [ ] **Step 1: Write failing tests:**
  ```haskell
  stats [1,2,3,4] `shouldBe` Stats 4 2.5 2 4 1 4
  -- events: song_assigned(0)@10, play_observed(0)@14.5 (start_est 14), song_assigned(1)@300, play_observed(1)@302; calls at t=11,12,301
  --   → latencies [4.5, 2.0], est [4.0, …], smCalls of song 0 == fromList [(OLlm,2)], song 1 == fromList [(OSolution,1)]
  -- a song with song_gave_up and no play_observed is excluded from latency stats and listed as failed
  -- a call for song 1 at t=299 (before song_assigned(1)@300 but after paused(0)) → song 1 flagged "assigned late"
  -- play_observed(0) with start position 200 s → song 0 flagged "did not start near 0:00"
  ```
- [ ] **Step 2:** `cabal test` → fails. **Step 3:** Implement. **Step 4:** `cabal test` → passes.
- [ ] **Step 5:** Commit `feat: metrics fold and comparison report`.

### Task 13: Measured runs, README, final review

**Files:**
- Create: `README.md`, `results/` (copied `report.md`, `latency.csv`, `traces/`, both run dirs' `blindly4.jsonl` + `events.jsonl` + `llm.jsonl`, `generated/solution.py`)

- [ ] **Step 1:** `cabal install exe:yuotudidjey --installdir=bin --install-method=copy --overwrite-policy=always`.
- [ ] **Step 2: (user-scheduled, desktop unusable ≈ 50 min)** `bin/yuotudidjey.exe explore --songs songs.txt --max-songs 10` → `generated/solution.py` passes lint and smoke; exploration run dir has 10 `song_assigned`.
- [ ] **Step 3: (user-scheduled, ≈ 40 min)** `bin/yuotudidjey.exe exploit --songs songs.txt --max-songs 10` → 10 `play_observed`, 10 `pause_observed`; `llm.jsonl` absent/empty in the exploitation run dir.
- [ ] **Step 4:** `bin/yuotudidjey.exe report --explore logs/exploration-… --exploit logs/exploitation-… --out results/` → `results/report.md` shows both stages' mean latency.
- [ ] **Step 5:** `README.md`: prerequisites, build (`blindly4` patch, cabal), commands, how stages work, where artifacts are, headline numbers from `results/report.md`.
- [ ] **Step 6:** Commit `docs: results of measured runs and README`.
