-- | youtudidjey orchestrates the two stages of a YouTube DJ and measures them. It never touches the
-- browser itself:
--
-- * @explore@: an agent (@claude -p@) drives Chrome through blindly4, one turn per song, then writes
--   @solution.py@. Its prompts are the files in @prompts/@; its tools are the flags in 'agentTurn'.
-- * @exploit@: @solution.py@ does the same job with no LLM, cycling through the songs forever.
--
-- Both actors answer with the words READY, PLAYING, PAUSED (or SKIPPED). youtudidjey times each song
-- from assigning it to PLAYING. blindly4 logs every call it serves to the run's @blindly4.jsonl@.
module Main (main) where

import Control.Applicative ((<|>))
import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, threadDelay, tryReadMVar)
import Control.Exception (bracket)
import Control.Monad (forM_, guard, unless, void)
import Data.Aeson (Value (..), decodeStrict, encode, object, withObject, (.:), (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Char8 qualified as B
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Char (toUpper)
import Data.List (intercalate, partition, sort)
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, diffUTCTime, formatTime, getCurrentTime, getZonedTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import GHC.IO.Encoding (setLocaleEncoding)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, findExecutable, getCurrentDirectory)
import System.Environment (getArgs, getEnvironment)
import System.Exit (die)
import System.FilePath (searchPathSeparator, takeFileName, (</>))
import System.IO
import System.Process
import Text.Printf (printf)
import Text.Read (readMaybe)

main :: IO ()
main = do
  setLocaleEncoding utf8
  hSetBuffering stdout LineBuffering
  getArgs >>= \case
    "explore" : opts -> explore opts
    "exploit" : opts -> exploit opts
    "report" : dirs@(_ : _) -> report dirs
    _ -> die usage

usage :: String
usage =
  "usage: youtudidjey explore [--songs FILE] [--max-songs N] [--model MODEL] [--sandbox]\n\
  \       youtudidjey exploit [--songs FILE] [--max-songs N] [--solution FILE] [--sandbox]\n\
  \       youtudidjey report RUN_DIR..."

-- | The value after @--name@, if given.
option :: String -> [String] -> Maybe String
option name = \case
  k : v : rest -> if k == "--" <> name then Just v else option name (v : rest)
  _ -> Nothing

-- | Whether the bare @--name@ is given.
flag :: String -> [String] -> Bool
flag name = elem ("--" <> name)

readSongs :: [String] -> IO [String]
readSongs opts = filter (not . null) . map trim . lines <$> readFile (fromMaybe "songs.txt" (option "songs" opts))

maxSongs :: [String] -> Maybe Int
maxSongs opts = option "max-songs" opts >>= readMaybe

trim :: String -> String
trim = T.unpack . T.strip . T.filter (/= '\xFEFF') . T.pack

-- * Runs

-- | A run's directory, and the environment every actor gets: blindly4 on PATH, logging into the run, and
-- with @--sandbox@ blindly4's sandbox mode (Chrome off screen and muted, no real pointer or keyboard).
data Run = Run {folder :: FilePath, vars :: [(String, String)], chromeProfile :: FilePath}

newRun :: String -> [String] -> IO Run
newRun stage opts = do
  root <- getCurrentDirectory
  stamp <- formatTime defaultTimeLocale "%Y%m%d-%H%M%S" <$> getZonedTime
  let runDir = root </> "runs" </> (stage <> "-" <> stamp)
  createDirectoryIfMissing True runDir
  writeFile (runDir </> "latency.csv") "n,assigned,playing,done,latency_s,song\n"
  (paths, rest) <- partition ((== "PATH") . map toUpper . fst) <$> getEnvironment
  let path = intercalate [searchPathSeparator] ((root </> "blindly4" </> ".build" </> "windows") : map snd paths)
      logging = [("BLINDLY4_LOG", runDir </> "blindly4.jsonl"), ("BLINDLY4_LOG_TAG", stage)] <> [("BLINDLY4_SANDBOX", "1") | flag "sandbox" opts]
  putStrLn ("run: " <> runDir)
  -- Forward slashes: the agent's shell (Git Bash) would eat backslashes.
  pure (Run runDir (("PATH", path) : logging <> rest) (map (\c -> if c == '\\' then '/' else c) (root </> ".chrome-profile")))

-- | Appends a song to latency.csv (times in Unix seconds) and prints it.
record :: Run -> Int -> String -> UTCTime -> Maybe UTCTime -> UTCTime -> IO ()
record run n song assigned playing done = do
  let secs t = printf "%.3f" (realToFrac (utcTimeToPOSIXSeconds t) :: Double)
      latency = maybe "" (printf "%.3f" . since assigned) playing
  appendFile (folder run </> "latency.csv") (intercalate "," [show n, secs assigned, maybe "" secs playing, secs done, latency, song] <> "\n")
  putStrLn (printf "%d. %s: " n song <> maybe "not played" (printf "playing after %.1f s" . since assigned) playing)

since :: UTCTime -> UTCTime -> Double
since t0 t1 = realToFrac (diffUTCTime t1 t0)

-- | Seconds an agent turn may take before youtudidjey terminates claude.
turnDeadline :: Int
turnDeadline = 40 * 60

-- | Seconds solution.py may take to print its next word before youtudidjey terminates it.
silenceDeadline :: Int
silenceDeadline = 20 * 60

-- | Runs an action that reads a child's output, terminating the child if the action takes more than
-- @secs@ seconds; says whether it did. A 'System.Timeout.timeout' cannot interrupt a pipe read on
-- Windows, but the read returns at end of file once the child is gone.
withDeadline :: Int -> ProcessHandle -> IO a -> IO (a, Bool)
withDeadline secs process action = do
  fired <- newEmptyMVar
  let watchdog = threadDelay (secs * 1000000) >> putMVar fired () >> terminateProcess process
  result <- bracket (forkIO watchdog) killThread (const action)
  (result,) . isJust <$> tryReadMVar fired

-- * Exploration: the agent plays the songs, then writes solution.py

explore :: [String] -> IO ()
explore opts = do
  run <- newRun "explore" opts
  songs <- take (fromMaybe 10 (maxSongs opts)) <$> readSongs opts
  copyFile ("prompts" </> "explore.md") (folder run </> "system-prompt.md")
  [setup, song, codegen] <- mapM (readFile . ("prompts" </>)) ["setup.md", "song.md", "codegen.md"]
  let fill = substitute [("profile", chromeProfile run), ("solution", folder run </> "solution.py"), ("total", show (length songs))]
      turn = agentTurn run (fromMaybe "sonnet" (option "model" opts))
  void (turn "setup" False False (fill setup))
  forM_ (zip [1 :: Int ..] songs) $ \(n, query) -> do
    assigned <- getCurrentTime
    playing <- turn ("song " <> show n) True False (substitute [("n", show n), ("song", query)] (fill song))
    record run n query assigned playing =<< getCurrentTime
  void (turn "codegen" True True (fill codegen))
  generated <- doesFileExist (folder run </> "solution.py")
  unless generated (die "the agent did not write solution.py")
  copyFile (folder run </> "solution.py") "solution.py"
  putStrLn ("wrote solution.py; logs in " <> folder run)

-- | Replaces each @{{key}}@ in a prompt template.
substitute :: [(String, String)] -> String -> String
substitute pairs template = T.unpack (foldr (\(k, v) -> T.replace (T.pack ("{{" <> k <> "}}")) (T.pack v)) (T.pack template) pairs)

-- | One turn of the run's conversation with @claude -p@, in the run directory. In Bash the agent can
-- run only blindly4, sleep and date; in the codegen turn it may also write and test solution.py. Every
-- line it streams goes to agent.jsonl, after a header with the exact command line. Returns when the
-- agent said PLAYING, if it did.
agentTurn :: Run -> String -> String -> Bool -> Bool -> String -> IO (Maybe UTCTime)
agentTurn run model name continue codegen prompt = do
  claude <- claudeExe
  let tools = if codegen then "Bash,Read,Edit,Write" else "Bash"
      allowed =
        ["Bash(blindly4 *)", "Bash(sleep *)", "Bash(date *)"]
          <> if codegen then ["Read", "Edit(solution.py)", "Bash(python -X utf8 solution.py *)"] else []
      args =
        ["-p", prompt, "--model", model, "--append-system-prompt-file", "system-prompt.md"]
          <> ["--tools", tools, "--allowedTools"] <> allowed <> ["--permission-mode", "dontAsk"]
          <> ["--safe-mode", "--strict-mcp-config", "--output-format", "stream-json", "--verbose"]
          <> ["--continue" | continue]
      environment
        | codegen = ("BLINDLY4_LOG_TAG", "codegen") : filter ((/= "BLINDLY4_LOG_TAG") . fst) (vars run)
        | otherwise = vars run
  putStrLn ("agent: " <> name)
  withFile (folder run </> "agent.jsonl") AppendMode $ \transcript -> do
    hSetBuffering transcript LineBuffering
    BL.hPutStrLn transcript (encode (object ["youtudidjey" .= object ["turn" .= name, "argv" .= (claude : args)]]))
    let spec = (proc claude args) {cwd = Just (folder run), env = Just environment, std_in = NoStream, std_out = CreatePipe}
    (playing, timedOut) <- withCreateProcess spec $ \_ out _ process ->
      withDeadline turnDeadline process $ do
        seen <- stream (fromMaybe (error "no stdout") out) transcript (says "PLAYING") Nothing
        void (waitForProcess process)
        pure seen
    if timedOut then Nothing <$ putStrLn ("agent turn timed out: " <> name) else pure playing

-- | Copies the agent's stream to the transcript; returns when the first marked line arrived.
stream :: Handle -> Handle -> (B.ByteString -> Bool) -> Maybe UTCTime -> IO (Maybe UTCTime)
stream out transcript marked seen =
  hIsEOF out >>= \case
    True -> pure seen
    False -> do
      line <- B.hGetLine out
      now <- getCurrentTime
      B.hPutStrLn transcript line
      stream out transcript marked (seen <|> (now <$ guard (marked line)))

-- | Whether a stream-json line is an assistant message with the word alone on a line of its text.
says :: T.Text -> B.ByteString -> Bool
says word line = fromMaybe False $ do
  Object message <- decodeStrict line
  guard (KM.lookup "type" message == Just "assistant")
  Object body <- KM.lookup "message" message
  Array content <- KM.lookup "content" body
  pure (any (\case Object c | Just (String t) <- KM.lookup "text" c -> word `elem` map T.strip (T.lines t); _ -> False) content)

-- | npm puts only a .cmd shim on PATH; a process needs the executable behind it.
claudeExe :: IO FilePath
claudeExe =
  findExecutable "claude" >>= \case
    Just exe -> pure exe
    Nothing -> do
      appData <- fromMaybe "" . lookup "APPDATA" <$> getEnvironment
      pure (appData </> "npm" </> "node_modules" </> "@anthropic-ai" </> "claude-code" </> "bin" </> "claude.exe")

-- * Exploitation: solution.py plays the songs, with no LLM

exploit :: [String] -> IO ()
exploit opts = do
  run <- newRun "exploit" opts
  songs <- readSongs opts
  copyFile (fromMaybe "solution.py" (option "solution" opts)) (folder run </> "solution.py")
  let queue = maybe id take (maxSongs opts) (zip [1 :: Int ..] (cycle songs))
      spec diagnostics =
        (proc "python" ["-X", "utf8", folder run </> "solution.py", "--chrome-profile", chromeProfile run])
          {env = Just (vars run), std_in = CreatePipe, std_out = CreatePipe, std_err = UseHandle diagnostics}
  withFile (folder run </> "solution.out") AppendMode $ \transcript ->
    withFile (folder run </> "solution.err") AppendMode $ \diagnostics ->
    withCreateProcess (spec diagnostics) $ \input output _ process -> do
      let toSolution = fromMaybe (error "no stdin") input
          next = answer process (fromMaybe (error "no stdout") output) transcript
      mapM_ (`hSetBuffering` LineBuffering) [toSolution, transcript]
      expect "READY" =<< next
      forM_ queue $ \(n, query) -> do
        assigned <- getCurrentTime
        hPutStrLn toSolution query
        (word, at) <- next
        playing <- case word of
          "PLAYING" -> Just at <$ (expect "PAUSED" =<< next)
          _ -> Nothing <$ expect "SKIPPED" (word, at)
        record run n query assigned playing =<< getCurrentTime
      hClose toSolution
      void (waitForProcess process)
  putStrLn ("logs in " <> folder run)

-- | The next word solution.py prints, with the time it arrived. After 'silenceDeadline' seconds of
-- silence it terminates solution.py and gives up.
answer :: ProcessHandle -> Handle -> Handle -> IO (String, UTCTime)
answer process out transcript = do
  (line, silent) <- withDeadline silenceDeadline process readWord
  now <- getCurrentTime
  case line of
    Just word | not silent -> do
      hPutStrLn transcript (formatTime defaultTimeLocale "%FT%T%3QZ " now <> trim word)
      pure (trim word, now)
    _ -> die (if silent then "solution.py stopped answering" else "solution.py exited")
  where
    readWord = hIsEOF out >>= \eof -> if eof then pure Nothing else Just <$> hGetLine out

expect :: String -> (String, UTCTime) -> IO ()
expect wanted (word, _) = unless (word == wanted) (die ("solution.py said " <> show word <> ", expected " <> wanted))

-- * Report: the stages side by side

report :: [FilePath] -> IO ()
report dirs = do
  putStrLn "| run | songs | played | mean latency | median | min | max | blindly4 calls until PLAYING | per song |"
  putStrLn "|---|---|---|---|---|---|---|---|---|"
  forM_ dirs $ \runDir -> do
    rows <- mapMaybe row . lines <$> readFile (runDir </> "latency.csv")
    calls <- mapMaybe callTime . B.lines <$> B.readFile (runDir </> "blindly4.jsonl")
    let latencies = sort [p - a | (a, Just p, _) <- rows]
        between a b = fromIntegral (length (filter (\t -> a <= t && t < b) calls))
        cells =
          [takeFileName runDir, show (length rows), show (length latencies)]
            <> stats latencies
            <> map (printf "%.1f" . average) [[between a p | (a, Just p, _) <- rows], [between a d | (a, _, d) <- rows]]
    putStrLn ("| " <> intercalate " | " cells <> " |")
  where
    row line = case splitOn ',' line of
      _ : a : p : d : _ -> (,readMaybe p,) <$> readMaybe a <*> readMaybe d
      _ -> Nothing :: Maybe (Double, Maybe Double, Double)
    callTime line = realToFrac . utcTimeToPOSIXSeconds <$> (decodeStrict line >>= parseMaybe (withObject "call" (.: "ts"))) :: Maybe Double
    average xs = if null xs then 0 else sum xs / fromIntegral (length xs) :: Double

-- | Mean, median, min and max of sorted numbers, in seconds.
stats :: [Double] -> [String]
stats [] = replicate 4 "–"
stats xs = map (printf "%.1f s") [sum xs / n, (xs !! (len `div` 2) + xs !! ((len - 1) `div` 2)) / 2, minimum xs, maximum xs]
  where
    len = length xs
    n = fromIntegral len

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (field, _ : rest) -> field : splitOn c rest
  (field, []) -> [field]
