-- | End of exploration: turn the playbook and the recorded traces into solution.py, then gate it
-- with the lint and a real smoke run, repairing up to three times.
module Yuo.Codegen
  ( CodegenEnv (..)
  , generateSolution
  , liveSmoke
  , condensedTraces
  , codeSchema
  ) where

import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Char8 as BC
import Data.List (sortOn)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO.Utf8 as TU
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import Yuo.Codegen.Contract
import Yuo.Codegen.Lint (lintSolution)
import Yuo.Exploit (SolutionRun (..), runSolution)
import Yuo.Llm
import Yuo.Log
import Yuo.Songs (Song (..))
import Yuo.Types

data CodegenEnv = CodegenEnv
  { cgLogger :: Logger
  , cgLlm :: LlmBackend
  , cgRunDir :: FilePath
  , cgSongs :: FilePath
  , cgBlindly4 :: FilePath
  , cgOut :: FilePath
  , cgSchema :: Text
  , cgSmoke :: Int -> FilePath -> IO (Either Text ()) -- ^ attempt number, candidate file
  }

-- | Writing a whole program takes minutes, not seconds.
codegenAsk :: AskConfig
codegenAsk = AskConfig 600 [5, 10]

codeSchema :: Value
codeSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object ["code" .= object ["type" .= ("string" :: Text)]]
    , "required" .= ["code" :: Text]
    ]

jsonLines :: FromJSON a => FilePath -> IO [a]
jsonLines file = do
  exists <- doesFileExist file
  if exists then mapMaybe decodeStrict' . BC.lines <$> BC.readFile file else pure []

-- | Per song (in assignment order): every blindly4 call the LLM or the driver made, with its result.
condensedTraces :: FilePath -> IO Text
condensedTraces runDir = do
  events <- jsonLines (runDir </> "events.jsonl")
  calls <- jsonLines (runDir </> "blindly4.jsonl")
  let starts = [(evT e, maybe "" (\s -> T.pack (show (songIndex s)) <> ": " <> songQuery s) (evSong e)) | e <- events, evKind e == SongAssigned]
      relevant = sortOn callStart [c | c <- calls, callOrigin c `elem` [OLlm, ODriver]]
      section (t0, title) next =
        ("### song " <> title)
          : [render c | c <- relevant, callStart c >= t0, maybe True (callStart c <) next]
      bounds = zip starts (map (Just . fst) (drop 1 starts) <> [Nothing])
      render c =
        "[" <> originText (callOrigin c) <> "] " <> T.unwords (map quote (callArgv c)) <> " → exit " <> T.pack (show (callExit c)) <> ": "
          <> T.replace "\n" " " (T.take 300 (T.strip (callStdout c)))
      quote a = if T.any (== ' ') a || T.null a then "\"" <> a <> "\"" else a
  pure (T.unlines (concat [section s n | (s, n) <- bounds]))

codegenPrompt :: Text -> Value -> Text -> Text
codegenPrompt schema playbook traces =
  T.unlines
    [ contractText
    , driverTimingText
    , "blindly4 commands available through YUO_B4:"
    , schema
    , "The exploration stage's playbook (written by the LLM that drove the browser):"
    , encodeLine playbook
    , ""
    , "Trace of the exploration stage (blindly4 calls with results, per song):"
    , traces
    , ""
    , "Write the complete solution.py. Reply with {\"code\": \"<the whole file>\"}."
    ]

repairPrompt :: Text -> Value -> Text -> Text -> Text -> Text
repairPrompt schema playbook traces code problems =
  T.unlines
    [ codegenPrompt schema playbook traces
    , "Your previous solution.py was rejected:"
    , problems
    , ""
    , "Previous file:"
    , code
    , ""
    , "Fix the causes (not the symptoms) and reply with the complete corrected file as {\"code\": \"...\"}."
    ]

codeOf :: Value -> Either Text Text
codeOf = \case
  Object o | Just (String c) <- KM.lookup "code" o, not (T.null (T.strip c)) -> Right c
  _ -> Left "reply has no code"

-- | Passes when the candidate exits 0, reports song 0 playing and paused, and the observer agrees.
-- @liveSmoke runDir songs blindly4 attempt candidate@ plays song 0 for 20 s with the candidate.
liveSmoke :: FilePath -> FilePath -> FilePath -> Int -> FilePath -> IO (Either Text ())
liveSmoke runDir songs blindly4 n candidate = do
  let dir = runDir </> ("smoke-" <> show n)
  (code, stderrTail) <- runSolution (SolutionRun Exploration dir candidate songs ["--max-songs", "1", "--max-play-seconds", "20"] blindly4 240)
  events <- jsonLines (dir </> "events.jsonl") :: IO [Event]
  calls <- jsonLines (dir </> "blindly4.jsonl") :: IO [Call]
  let kinds src = [evKind e | e <- events, evSource e == src]
      missing =
        [ "solution.py exited " <> T.pack (show code) | code /= 0 ]
          <> [ "no " <> kindText k <> " event from solution.py" | k <- [SongAssigned, PlaybackStarted, Paused], k `notElem` kinds OSolution ]
          <> [ "the independent observer never confirmed playback of the assigned song" | PlayObserved `notElem` kinds OObserver ]
      renderCall c = T.unwords (callArgv c) <> " → exit " <> T.pack (show (callExit c)) <> ": " <> T.take 300 (T.replace "\n" " " (callStdout c))
      failing = T.unlines [renderCall c | c <- solutionCalls, callExit c /= 0]
      lastCalls = T.unlines (map renderCall (drop (length solutionCalls - 25) solutionCalls))
      solutionCalls = [c | c <- calls, callOrigin c == OSolution]
      eventLines = T.unlines [encodeLine e | e <- events]
  pure $
    if null missing
      then Right ()
      else Left (T.unlines (missing <> ["failing blindly4 calls by solution.py:", failing, "stderr (tail):", stderrTail, "last blindly4 calls by solution.py:", lastCalls, "events:", eventLines]))

-- | Writes cgOut; Right path once it passes lint and smoke, Left after three failed repairs.
generateSolution :: CodegenEnv -> IO (Either Text FilePath)
generateSolution env = do
  playbook <- maybe (object []) id . decodeStrict' <$> readOr "{}" (cgRunDir env </> "playbook.json")
  traces <- condensedTraces (cgRunDir env)
  let ask purpose = askLoggedWith codegenAsk (cgLogger env) (cgLlm env) purpose codeSchema
      attempt n previous reply = case reply >>= codeOf of
        Left e -> retry n previous ("the reply carried no code: " <> e)
        Right code -> do
          -- Candidates live in the run directory; only a validated one replaces cgOut.
          let candidate = cgRunDir env </> ("solution-attempt-" <> show n <> ".py")
          TU.writeFile candidate code
          violations <- lintSolution candidate
          if not (null violations)
            then retry n code (T.unlines ("lint violations:" : violations))
            else
              cgSmoke env n candidate >>= \case
                Right () -> do
                  createDirectoryIfMissing True (takeDirectory (cgOut env))
                  copyFile candidate (cgOut env)
                  pure (Right (cgOut env))
                Left problems -> retry n code (T.unlines ["smoke run failed:", problems])
      retry n code problems
        | n >= (3 :: Int) = pure (Left problems)
        | otherwise = do
            t <- nowPosix
            logEvent (cgLogger env) (Event t Exploration ODriver StepError Nothing (KM.fromList [("reason", String ("codegen attempt " <> T.pack (show n) <> " rejected")), ("problems", String (T.take 4000 problems))]))
            ask PRepair (repairPrompt (cgSchema env) playbook traces code problems) >>= attempt (n + 1) code
  ask PCodegen (codegenPrompt (cgSchema env) playbook traces) >>= attempt 0 ""
  where
    readOr d f = doesFileExist f >>= \e -> if e then BC.readFile f else pure d
