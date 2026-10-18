-- | Pausing 3 s before the end without watching the song: a deadline in a TVar, one fresh reading
-- at the start and one re-sync 15 s before the end (the slider is only fresh after a hover).
module Yuo.Pause
  ( PauseResult (..)
  , waitAndPause
  , freshProgress
  , acceptStart
  , acceptResync
  , sleepUntil
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Monad (void, when)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Yuo.Blindly
import Yuo.Concurrent (firstJust)
import Yuo.Explore.Action (PausePlan (..))
import Yuo.Observer (Observer (..), PlayInfo (..))
import Yuo.Time
import Yuo.Tree
import Yuo.Types

data PauseResult = PauseResult
  { prPausedAt :: Double
  , prDuration :: Int
  , prDurationSource :: Text
  , prResynced :: Bool
  , prPressed :: Bool
  }
  deriving (Eq, Show)

nodes :: B4 -> Command 'ReadOnly -> IO [Node]
nodes b cmd = either (const []) id . (>>= either (Left . B4Unexpected 0) Right . parseMatches) <$> runRead b ODriver cmd

-- | Hover over the player so YouTube refreshes its slider, then read it: (time, progress).
freshProgress :: B4 -> Observer -> IO (Maybe (Double, Progress))
freshProgress b obs = do
  player <- atomically (obsPlayer obs)
  case player of
    Just p | Just (x, y) <- nCenter p -> do
      -- A real pointer movement across the player, then time for YouTube to repaint its controls.
      void (withInput b $ \tok -> runInput b ODriver tok Activate >> runInput b ODriver tok (Hover (x - 40) y) >> runInput b ODriver tok (Hover x y))
      threadDelay 800000
      sliders <- nodes b (Find findQ {fqRole = Just "AXSlider", fqTitle = Just "Seek slider", fqUnder = Just (nPath p), fqDepth = 6})
      t <- nowPosix
      pure ((t,) <$> (listToMaybe sliders >>= nValue >>= parseProgress))
    _ -> pure Nothing

-- | Sleeps until the deadline in the TVar, re-arming whenever it moves.
sleepUntil :: TVar Double -> IO ()
sleepUntil deadline = do
  d <- readTVarIO deadline
  now <- nowPosix
  when (d > now) $ do
    timer <- registerDelay (ceiling ((d - now) * 1e6))
    moved <-
      atomically $
        (readTVar timer >>= check >> pure False)
          `orElse` (readTVar deadline >>= \d' -> check (d' /= d) >> pure True)
    when moved (sleepUntil deadline)

-- | Hovering usually refreshes the slider text, but not always: a stale reading must never move the
-- pause. A reading is believed only when the start it implies (time − position) agrees with what is
-- already known to within 10 s.
agrees :: Double -> Double -> Bool
agrees known implied = abs (implied - known) <= 10

-- | The reading right after playback is confirmed: a song-length (not an ad's) slider consistent
-- with the observed start gives the exact start and duration.
acceptStart :: Double -> Int -> (Double, Progress) -> Maybe (Double, Int)
acceptStart observedStart planned (t, Progress pos d)
  | (d >= 60 || abs (d - planned) <= 3) && agrees observedStart implied = Just (implied, d)
  | otherwise = Nothing
  where
    implied = t - fromIntegral pos

-- | The re-sync before the deadline corrects drift (an ad or a stall of a few seconds), nothing more.
acceptResync :: Double -> Int -> (Double, Progress) -> Maybe Double
acceptResync start dur (t, Progress pos d)
  | abs (d - dur) <= 3 && agrees start implied = Just implied
  | otherwise = Nothing
  where
    implied = t - fromIntegral pos

-- | The latency of the pause call itself, subtracted from the deadline.
pauseLatency :: Double
pauseLatency = 0.6

waitAndPause :: B4 -> Observer -> PlayInfo -> PausePlan -> Maybe Int -> IO PauseResult
waitAndPause b obs info plan maxPlay = do
  first <- freshProgress b obs
  let planned = ppDurationSec plan
      (start, dur, source) = case first >>= acceptStart (piStartEst info) planned of
        Just (s, d) -> (s, d, "slider after hover")
        Nothing -> (piStartEst info, planned, "llm plan")
      deadlineFrom s =
        let full = pauseDeadline s dur 0 pauseLatency
         in maybe full (\cap -> min full (s + fromIntegral cap)) maxPlay
  deadline <- newTVarIO (deadlineFrom start)
  resyncAt <- subtract 15 <$> readTVarIO deadline
  resyncVar <- newTVarIO resyncAt
  sleepUntil resyncVar
  now <- nowPosix
  d0 <- readTVarIO deadline
  resynced <-
    if d0 - now > 5
      then
        freshProgress b obs >>= \case
          Just reading | Just s <- acceptResync start dur reading -> atomically (writeTVar deadline (deadlineFrom s)) >> pure True
          _ -> pure False
      else pure False
  sleepUntil deadline
  t0 <- nowPosix
  pressed <- pressPause b obs plan
  t1 <- nowPosix
  pure (PauseResult ((t0 + t1) / 2) dur source resynced pressed)

-- | Finds the pause control by the plan (all title variants searched at once) and presses it.
pressPause :: B4 -> Observer -> PausePlan -> IO Bool
pressPause b obs plan = do
  player <- atomically (obsPlayer obs)
  container <- case ppUnderIdentifier plan of
    Nothing -> pure Nothing
    Just ident
      | Just p <- player, nIdent p == ident -> pure (Just (nPath p))
      | otherwise -> fmap nPath . listToMaybe <$> nodes b (Find findQ {fqIdentifier = Just ident})
  let search title = listToMaybe <$> nodes b (Find findQ {fqRole = Just (ppRole plan), fqTitle = Just title, fqUnder = container, fqDepth = maybe 40 (const 6) container})
      attempt = firstJust (map search (ppTitles plan))
  found <- attempt
  case found of
    Nothing -> pure False
    Just n ->
      withInput b (\tok -> runInput b ODriver tok (Press (nPath n) (nTitle n))) >>= \case
        Right _ -> pure True
        Left _ -> attempt >>= maybe (pure False) (\m -> either (const False) (const True) <$> withInput b (\tok -> runInput b ODriver tok (Press (nPath m) (nTitle m))))
