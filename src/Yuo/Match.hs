-- | Pure recognisers for what the accessibility tree says about YouTube's state.
module Yuo.Match
  ( PlayState (..)
  , PaneInfo (..)
  , tokens
  , songMatches
  , paneInfo
  , playState
  , isAdMarker
  , adMarkerTitles
  , adMarkerQueries
  ) where

import Data.Char (GeneralCategory (NonSpacingMark), generalCategory, isAlphaNum)
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Normalize (NormalizationMode (NFD), normalize)

data PlayState = Playing | PausedState
  deriving (Eq, Show)

-- | What Chrome's window pane name says: the YouTube page title and whether audio is audible.
data PaneInfo = PaneInfo {paneVideoTitle :: Maybe Text, paneAudio :: Bool}
  deriving (Eq, Show)

-- | Case-folded, accent-free alphanumeric words.
tokens :: Text -> [Text]
tokens =
  filter (not . T.null)
    . T.split (not . isAlphaNum)
    . T.toCaseFold
    . T.filter ((/= NonSpacingMark) . generalCategory)
    . normalize NFD

-- | At least 60 % of the query's words appear in the title.
songMatches :: Text -> Text -> Bool
songMatches query title =
  let wanted = tokens query
      present = Set.fromList (tokens title)
      hits = length (filter (`Set.member` present) wanted)
   in not (null wanted) && fromIntegral hits >= (0.6 :: Double) * fromIntegral (length wanted)

-- | @"<video> - YouTube - Audio playing - Google Chrome"@.
paneInfo :: Text -> PaneInfo
paneInfo pane =
  let withoutBrowser = fromMaybe pane (T.stripSuffix " - Google Chrome" pane)
      (audio, page) = maybe (False, withoutBrowser) (True,) (T.stripSuffix " - Audio playing" withoutBrowser)
   in PaneInfo (T.stripSuffix " - YouTube" page) audio

-- | The player's play/pause button names the action it would take.
playState :: Text -> Maybe PlayState
playState label
  | label `elem` ["Pause (k)", "Pause keyboard shortcut k"] = Just Playing
  | label `elem` ["Play (k)", "Play keyboard shortcut k"] = Just PausedState
  | otherwise = Nothing

-- | Exact titles of controls that only exist inside the player while an ad runs.
adMarkerTitles :: [Text]
adMarkerTitles = ["Sponsored", "My Ad Center", "Skip", "Skip Ad", "Skip Ads"]

isAdMarker :: Text -> Bool
isAdMarker = (`elem` adMarkerTitles)

-- | Title searches that find every ad marker: blindly4 matches titles by substring, so a title that
-- contains another marker ("Skip Ad" contains "Skip") needs no search of its own.
adMarkerQueries :: [Text]
adMarkerQueries = [t | t <- adMarkerTitles, not (any (\o -> o /= t && o `T.isInfixOf` t) adMarkerTitles)]
