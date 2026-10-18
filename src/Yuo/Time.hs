-- | Pure time arithmetic: YouTube's spoken durations and the pause deadline.
module Yuo.Time
  ( Progress (..)
  , parseProgress
  , renderProgress
  , parseResultDuration
  , pauseDeadline
  , plausibleStart
  ) where

import Data.Char (isDigit)
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

-- | Position and duration in whole seconds, as the seek slider reports them.
data Progress = Progress {posSec :: Int, durSec :: Int}
  deriving (Eq, Show)

unitSeconds :: Text -> Maybe Int
unitSeconds w = lookup (T.toLower (T.dropWhileEnd (== ',') w)) units
  where
    units = [("hour", 3600), ("hours", 3600), ("minute", 60), ("minutes", 60), ("second", 1), ("seconds", 1)]

readNat :: Text -> Maybe Int
readNat t
  | not (T.null t) && T.all isDigit t = readMaybe (T.unpack t)
  | otherwise = Nothing

-- | A span is nothing but "<n> <unit>" pairs, e.g. @1 Hour 2 Minutes 3 Seconds@.
parseSpan :: [Text] -> Maybe Int
parseSpan [] = Nothing
parseSpan ws = go ws
  where
    go [] = Just 0
    go (n : u : rest) = (+) <$> ((*) <$> readNat n <*> unitSeconds u) <*> go rest
    go _ = Nothing

-- | Seek slider text: @"0 Minutes 2 Seconds of 3 Minutes 33 Seconds"@.
parseProgress :: Text -> Maybe Progress
parseProgress t = case T.splitOn " of " t of
  [a, b] -> Progress <$> parseSpan (T.words a) <*> parseSpan (T.words b)
  _ -> Nothing

renderProgress :: Progress -> Text
renderProgress (Progress p d) = render p <> " of " <> render d
  where
    render s =
      let (h, r) = s `divMod` 3600
          (m, sec) = r `divMod` 60
          tshow = T.pack . show
       in T.unwords ([tshow h <> " Hours" | h > 0] <> [tshow m, "Minutes", tshow sec, "Seconds"])

-- | Trailing @"4 minutes, 9 seconds"@ of a search-result link name, in seconds.
parseResultDuration :: Text -> Maybe Int
parseResultDuration t = case trailing (reverse (T.words t)) of
  [] -> Nothing
  secs -> Just (sum secs)
  where
    trailing (u : n : rest)
      | Just s <- unitSeconds u, Just k <- readNat n = k * s : trailing rest
    trailing _ = []

-- | Where a song's own start (time − position of a fresh reading) may fall relative to the moment
-- playback was first seen: slightly before (detection lag) or well after — YouTube can spend many
-- seconds loading the song after an ad ends, and unlabeled bumper ads can follow, with the audio
-- indicator on throughout.
plausibleStart :: Double -> Double -> Bool
plausibleStart seen implied = implied >= seen - 10 && implied <= seen + 60

-- | When to press pause: 3 s before the end, minus the pause call's own latency, plus ad time.
pauseDeadline :: Double -> Int -> Double -> Double -> Double
pauseDeadline start dur adSecs pauseLatency = start + fromIntegral dur - 3 - pauseLatency + adSecs
