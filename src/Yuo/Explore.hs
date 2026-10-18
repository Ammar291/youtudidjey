-- | Exploration stage: the LLM decides every UI action, Haskell runs and logs it through blindly4,
-- the observer confirms playback, a timer pauses, and the LLM keeps a playbook between songs.
module Yuo.Explore
  ( ExploreConfig (..)
  , ExploreEnv (..)
  , SongOutcome (..)
  , startSong
  , finishSong
  , pauseReport
  , exploreSong
  , runExploration
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, wait)
import Control.Concurrent.STM
import Control.Exception (try)
import Control.Monad (forM_, void)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO.Utf8 as TU
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Yuo.Blindly
import Yuo.Chrome (ChromeSession (..), withChrome)
import Yuo.Explore.Action
import Yuo.Explore.Prompt
import Yuo.Llm
import Yuo.Log
import Yuo.Observer
import Yuo.Pause
import Yuo.Songs (Song (..))
import Yuo.Tree (capXml)
import Yuo.Types

data ExploreConfig = ExploreConfig
  { ecSongs :: [Song]
  , ecMaxSongs :: Int
  , ecBackend :: LlmBackend
  , ecMaxPlay :: Maybe Int
  , ecBlindly4 :: FilePath
  }

data ExploreEnv = ExploreEnv
  { eeB4 :: B4
  , eeObserver :: Observer
  , eeLlm :: LlmBackend
  , eeAsk :: AskConfig
  , eeRunDir :: FilePath
  , eePlaybook :: TVar Value
  , eeSchema :: Text
  , eeBudget :: Int
  , eeMaxPlay :: Maybe Int
  , eeConfirmSeconds :: Int
  }

data SongOutcome = Played PlayInfo | GaveUp Text
  deriving (Eq, Show)

logDriver :: ExploreEnv -> EventKind -> Song -> [(Key, Value)] -> IO ()
logDriver env kind song fields = do
  t <- nowPosix
  logEvent (b4Logger (eeB4 env)) (Event t Exploration ODriver kind (Just song) (KM.fromList fields))

-- | The driver's own read of the window title (not an LLM decision).
paneTitle :: B4 -> IO Text
paneTitle b =
  runRead b ODriver (Inspect (Path "0.1")) >>= \case
    Right (Object o) | Just (String t) <- KM.lookup "title" o -> pure t
    _ -> pure ""

-- | Runs one action; returns its record and whether to keep going with the step's other actions.
runAction :: ExploreEnv -> Action -> IO (StepRecord, Bool)
runAction env action = case toCommand action of
  Just (Left cmd) -> do
    r <- runReadText b OLlm cmd
    pure (record (fmap (capXml 6000) r))
  Just (Right cmd) -> do
    r <- withInput b (\tok -> runInput b OLlm tok cmd)
    pure (record (fmap encodeLine r))
  Nothing -> case action of
    AWait ms -> threadDelay (ms * 1000) >> pure (StepRecord (renderAction action) True "waited", True)
    _ -> pure (StepRecord (renderAction action) True "", True)
  where
    b = eeB4 env
    record = \case
      Right out -> (StepRecord (renderAction action) True out, True)
      Left e -> (StepRecord (renderAction action) False (errorText e), False)

-- | Runs actions in order, stopping at the first failure.
runActions :: ExploreEnv -> [Action] -> IO [StepRecord]
runActions env = \case
  [] -> pure []
  a : rest -> do
    (r, continue) <- runAction env a
    if continue then (r :) <$> runActions env rest else pure [r]

-- | Polls the observer for up to @seconds@.
confirmed :: ExploreEnv -> Int -> IO (Maybe PlayInfo)
confirmed env seconds = go (seconds * 2)
  where
    go n =
      atomically (obsPlayInfo (eeObserver env)) >>= \case
        Just i -> pure (Just i)
        Nothing | n > 0 -> threadDelay 500000 >> go (n - 1)
        Nothing -> pure Nothing

-- | The LLM loop that gets the song playing; the observer, not the LLM, decides success.
startSong :: ExploreEnv -> Int -> Song -> IO (SongOutcome, [StepRecord])
startSong env seqNo song = do
  t0 <- nowPosix
  logDriver env SongAssigned song ["seq" .= seqNo]
  obsAssign (eeObserver env) song t0
  loop 1 [] Nothing
  where
    loop n history rejected =
      atomically (obsPlayInfo (eeObserver env)) >>= \case
        Just info -> pure (Played info, history)
        Nothing
          | n > eeBudget env -> do
              logDriver env SongGaveUp song ["reason" .= ("step budget exhausted" :: Text), "steps" .= (n - 1)]
              pure (GaveUp "step budget exhausted", history)
          | otherwise -> do
              pane <- paneTitle (eeB4 env)
              playbook <- readTVarIO (eePlaybook env)
              let prompt = stepPrompt (StepContext song pane (eeSchema env) playbook (lastN 8 history) rejected n (eeBudget env))
              reply <- askLoggedWith (eeAsk env) (b4Logger (eeB4 env)) (eeLlm env) PStep stepSchema prompt
              case reply >>= decodeStep of
                Left e -> loop (n + 1) history (Just e)
                Right sr -> do
                  records <- runActions env (srActions sr)
                  snapshot n records
                  let history' = history <> records
                  case [r | AGiveUp r <- srActions sr] of
                    reason : _ -> do
                      logDriver env SongGaveUp song ["reason" .= reason]
                      pure (GaveUp reason, history')
                    [] -> do
                      let waitFor = if ADone `elem` srActions sr then eeConfirmSeconds env else 0
                      seen <- confirmed env waitFor
                      case seen of
                        Just info -> pure (Played info, history')
                        Nothing
                          | ADone `elem` srActions sr -> loop (n + 1) history' (Just ("the observer has not confirmed playback yet (window title: " <> pane <> ")"))
                          | otherwise -> loop (n + 1) history' Nothing
    lastN k xs = drop (length xs - k) xs
    snapshot n records = do
      let dir = eeRunDir env </> "snapshots"
      createDirectoryIfMissing True dir
      TU.writeFile (dir </> ("song" <> show seqNo <> "-step" <> show n <> ".txt")) (T.unlines [stepAction r <> "\n" <> stepResult r | r <- records])

-- | Asks how to pause, then pauses on a timer; returns the pause time and duration used.
finishSong :: ExploreEnv -> Song -> PlayInfo -> IO (Maybe PauseResult)
finishSong env song info = do
  let b = eeB4 env
      generic role limit = either errorText (capXml 5000) <$> runReadText b ODriver (Find findQ {fqRole = Just role, fqLimit = limit, fqXml = True})
  pane <- paneTitle b
  buttons <- generic "AXButton" 60
  sliders <- generic "AXSlider" 10
  plan <- askLoggedWith (eeAsk env) (b4Logger b) (eeLlm env) PPreparePause pauseSchema (pausePrompt song pane (buttons <> "\n" <> sliders))
  case plan >>= decodePausePlan of
    Left e -> do
      logDriver env StepError song ["reason" .= ("no pause plan: " <> e)]
      pure Nothing
    Right p -> do
      result <- waitAndPause b (eeObserver env) info p (eeMaxPlay env)
      let details = ["duration" .= prDuration result, "duration_source" .= prDurationSource result, "resynced" .= prResynced result]
      case pauseReport result of
        Just (t, d) -> do
          logDriver env Paused song (("paused_at" .= t) : details)
          obsPaused (eeObserver env) t (Just d)
        Nothing -> logDriver env StepError song (("reason" .= ("the pause control could not be pressed" :: Text)) : details)
      pure (Just result)

-- | A pause counts (event, observer margin) only when the control was actually pressed.
pauseReport :: PauseResult -> Maybe (Double, Int)
pauseReport r = if prPressed r then Just (prPausedAt r, prDuration r) else Nothing

-- | Updates the playbook from what happened (runs while the song plays).
reflect :: ExploreEnv -> Song -> [StepRecord] -> IO ()
reflect env song records = do
  playbook <- readTVarIO (eePlaybook env)
  r <- askLoggedWith (eeAsk env) (b4Logger (eeB4 env)) (eeLlm env) PReflect playbookSchema (reflectPrompt playbook song records)
  forM_ r $ \p -> do
    atomically (writeTVar (eePlaybook env) p)
    BL.writeFile (eeRunDir env </> "playbook.json") (encode p)

-- | One song: get it playing, reflect during playback, pause on time.
exploreSong :: ExploreEnv -> IORef (Maybe (Async ())) -> Int -> Song -> IO SongOutcome
exploreSong env pending seqNo song = do
  -- The previous song's reflection ran during its playback; its playbook is needed now.
  readIORef pending >>= mapM_ wait
  (outcome, records) <- startSong env seqNo song
  case outcome of
    Played info -> do
      writeIORef pending . Just =<< async (reflect env song records)
      void (finishSong env song info)
    GaveUp _ -> pure ()
  pure outcome

runExploration :: ExploreConfig -> IO FilePath
runExploration cfg = do
  runDir <- newRunDir Exploration
  withLogger runDir $ \logger -> do
    b0 <- newB4 (processBackend (ecBlindly4 cfg)) Nothing logger Exploration
    schema <- either (const "") schemaDoc <$> runRead b0 ODriver Schema
    result <- try $ withChrome b0 Exploration $ \session -> do
      let b = withPid (chromePid session) b0
      withObserver b Exploration $ \obs -> do
        playbook <- newTVarIO (object [])
        pending <- newIORef Nothing
        let env = ExploreEnv b obs (ecBackend cfg) defaultAsk runDir playbook schema 25 (ecMaxPlay cfg) 10
        forM_ (zip [0 ..] (take (ecMaxSongs cfg) (cycle (ecSongs cfg)))) $ \(i, song) ->
          exploreSong env pending i song
        readIORef pending >>= mapM_ wait
    case result of
      Left (ChromeGone m) -> do
        t <- nowPosix
        logEvent logger (Event t Exploration ODriver StepError Nothing (KM.fromList ["reason" .= ("browser gone: " <> m)]))
        flushLogger logger
        ioError (userError ("exploration stopped: the browser window is gone (" <> T.unpack m <> ")"))
      Right () -> pure ()
  pure runDir
