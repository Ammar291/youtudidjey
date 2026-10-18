-- | Pausing 3 s before the end without watching the song: a deadline in a TVar, one fresh reading
-- at the start and one re-sync 15 s before the end (the slider is only fresh after a hover).
module Yuo.Pause
  ( PauseResult (..)
  , waitAndPause
  , freshProgress
  , acceptStart
  , acceptResync
  , plannedDuration
  , sleepUntil
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Monad (when)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Yuo.Blindly
import Yuo.Concurrent (firstJust)
import Yuo.Explore.Action (PausePlan (..))
import Yuo.Observer (Observer (..), PlayInfo (..), hoverReading)
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
freshProgress b obs = atomically (obsPlayer obs) >>= maybe (pure Nothing) (hoverReading b ODriver)

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
-- pause. The re-sync is believed only when the start it implies agrees with the start in use to 10 s.
agrees :: Double -> Double -> Bool
agrees known implied = abs (implied - known) <= 10

-- | A fresh reading after playback was seen: a song-length slider whose implied start is plausible
-- (see 'plausibleStart') gives the exact start and duration. Ad-length sliders are never believed.
acceptStart :: Double -> Int -> (Double, Progress) -> Maybe (Double, Int)
acceptStart seen _planned (t, Progress pos d)
  | d >= 60 && plausibleStart seen implied = Just (implied, d)
  | otherwise = Nothing
  where
    implied = t - fromIntegral pos

-- | The LLM's duration is only a fallback, and only when it is song-length (it may have read an
-- ad's stale slider).
plannedDuration :: Int -> Maybe Int
plannedDuration d = if d >= 60 then Just d else Nothing

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
  let reading tries = do
        r <- freshProgress b obs
        case r >>= acceptStart (piStartEst info) (ppDurationSec plan) of
          Just ok -> pure (Just ok)
          Nothing | tries > (1 :: Int) -> threadDelay 5000000 >> reading (tries - 1)
          Nothing -> pure Nothing
      -- Best source first: the observer's own fresh reading, then ours, then a song-length plan;
      -- with none of these there is no safe guess, so keep reading every 5 s.
      timing = case piDuration info of
        Just d -> pure (Just (piStartEst info, d, "observer reading"))
        Nothing ->
          reading 4 >>= \case
            Just (s, d) -> pure (Just (s, d, "slider after hover"))
            Nothing -> case plannedDuration (ppDurationSec plan) of
              Just d -> pure (Just (piStartEst info, d, "llm plan"))
              Nothing -> fmap (\(s, d) -> (s, d, "slider after hover (late)")) <$> reading 40
  timing >>= \case
    Nothing -> do
      t0 <- nowPosix
      pressed <- pressPause b obs plan
      pure (PauseResult t0 0 "no duration" False pressed)
    Just (start, dur, source) -> do
      let deadlineFrom s =
            let full = pauseDeadline s dur 0 pauseLatency
             in maybe full (\cap -> min full (s + fromIntegral cap)) maxPlay
      deadline <- newTVarIO (deadlineFrom start)
      resyncVar <- newTVarIO (deadlineFrom start - 15)
      sleepUntil resyncVar
      now <- nowPosix
      d0 <- readTVarIO deadline
      resynced <-
        if d0 - now > 5
          then
            freshProgress b obs >>= \case
              Just r | Just s <- acceptResync start dur r -> atomically (writeTVar deadline (deadlineFrom s)) >> pure True
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
