-- | Pure metrics over a run's logs: one strict fold for statistics, time windows for attribution.
module Yuo.Metrics
  ( Stats (..)
  , stats
  , SongMetric (..)
  , songMetrics
  , latencyStats
  ) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KM
import Data.List (sort, sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Yuo.Songs (Song (..))
import Yuo.Types

data Stats = Stats {stN :: Int, stMean :: Double, stMedian :: Double, stP90 :: Double, stMin :: Double, stMax :: Double}
  deriving (Eq, Show)

-- | Count, sum, min and max in one strict pass; nearest-rank median and p90.
stats :: [Double] -> Stats
stats [] = Stats 0 0 0 0 0 0
stats xs@(x0 : _) =
  let (n, total, lo, hi) = foldl' (\(!c, !s, !l, !h) x -> (c + 1, s + x, min l x, max h x)) (0 :: Int, 0, x0, x0) xs
      sorted = sort xs
      rank :: Double -> Double
      rank p = sorted !! max 0 (ceiling (p * fromIntegral n) - 1)
   in Stats n (total / fromIntegral n) (rank 0.5) (rank 0.9) lo hi

data SongMetric = SongMetric
  { smStage :: Stage
  , smSeq :: Int
  , smIndex :: Int
  , smSong :: Text
  , smAssigned :: Double
  , smLatency :: Maybe Double
  , smLatencyEst :: Maybe Double
  , smAdSecs :: Double
  , smCallsToPlay :: M.Map Origin Int
  , smCallsTotal :: M.Map Origin Int
  , smB4MsToPlay :: Double
  , smLlmMsToPlay :: Double
  , smLlmCalls :: Int
  , smPauseMargin :: Maybe Double
  , smFailed :: Bool
  , smFlags :: [Text]
  }
  deriving (Eq, Show)

num :: KM.Key -> Event -> Maybe Double
num k e = case KM.lookup k (evData e) of
  Just (Number n) -> Just (realToFrac n)
  _ -> Nothing

llmTime :: Value -> Maybe (Double, Double)
llmTime = \case
  Object o | Just (Number t) <- KM.lookup "t" o, Just (Number ms) <- KM.lookup "ms" o -> Just (realToFrac t, realToFrac ms)
  _ -> Nothing

-- | One metric per song_assigned, in order. Calls, LLM time and observer events belong to a song
-- when they fall in [its assignment, the next assignment).
songMetrics :: Stage -> [Event] -> [Call] -> [Value] -> [SongMetric]
songMetrics stage events calls llm = zipWith3 metric [0 ..] assigned windowsEnd
  where
    ordered = sortOn evT events
    assigned = [e | e <- ordered, evKind e == SongAssigned]
    windowsEnd = map (Just . evT) (drop 1 assigned) <> [Nothing]
    endTimes = [evT e | e <- ordered, evKind e `elem` [Paused, StepError, SongGaveUp]]
    inWindow t0 end t = t >= t0 && maybe True (t <) end
    metric i a end =
      let t0 = evT a
          song = evSong a
          mine = [e | e <- ordered, inWindow t0 end (evT e)]
          played = listToMaybe [e | e <- mine, evKind e == PlayObserved]
          tPlay = evT <$> played
          upTo t = maybe (inWindow t0 end t) (\tp -> t >= t0 && t <= tp) tPlay
          acting = [c | c <- calls, callOrigin c /= OObserver]
          countBy cs = M.fromListWith (+) [(callOrigin c, 1 :: Int) | c <- cs]
          toPlay = [c | c <- acting, upTo (callStart c)]
          llmToPlay = [ms | (t, ms) <- mapMaybe llmTime llm, upTo t]
          -- Calls after the previous song ended (paused, failed or given up) and before this
          -- assignment belong to nobody: they mean the assignment was emitted late.
          previousStart = if i > 0 then evT <$> listToMaybe (drop (i - 1) assigned) else Nothing
          previousEnd = previousStart >>= \ps -> listToMaybe (reverse [t | t <- endTimes, t >= ps, t < t0])
          early = [c | c <- acting, callOrigin c `elem` [OLlm, OSolution], Just p <- [previousEnd], callStart c > p, callStart c < t0]
          startPos = played >>= num "start_pos"
          flags =
            ["assigned late" | not (null early)]
              <> ["did not start near 0:00" | maybe False (> 5) startPos]
       in SongMetric
            { smStage = stage
            , smSeq = i
            , smIndex = maybe 0 songIndex song
            , smSong = maybe "" songQuery song
            , smAssigned = t0
            , smLatency = (subtract t0) <$> tPlay
            , smLatencyEst = (subtract t0) <$> (played >>= num "start_est")
            , smAdSecs = maybe 0 id (played >>= num "ad_s")
            , smCallsToPlay = countBy toPlay
            , smCallsTotal = countBy [c | c <- acting, inWindow t0 end (callStart c)]
            , smB4MsToPlay = sum (map callMs toPlay)
            , smLlmMsToPlay = sum llmToPlay
            , smLlmCalls = length llmToPlay
            , smPauseMargin = listToMaybe (mapMaybe (num "remaining_s") [e | e <- mine, evKind e == PauseObserved])
            , smFailed = tPlay == Nothing
            , smFlags = flags
            }

latencyStats :: [SongMetric] -> Stats
latencyStats = stats . mapMaybe smLatency
