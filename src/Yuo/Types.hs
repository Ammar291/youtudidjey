-- | Shared vocabulary: stages, origins, events and logged blindly4 calls, with their JSON forms.
module Yuo.Types
  ( Pid (..)
  , Path (..)
  , Stage (..)
  , Origin (..)
  , EventKind (..)
  , Event (..)
  , Call (..)
  , stageText
  , originText
  , kindText
  , parseStage
  , parseOrigin
  , nowPosix
  ) where

import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Yuo.Songs (Song (..))

newtype Pid = Pid Int
  deriving (Eq, Show)

-- | Dot-separated child indexes into blindly4's live tree, e.g. @0.1.2@.
newtype Path = Path Text
  deriving (Eq, Ord, Show)

data Stage = Exploration | Exploitation
  deriving (Eq, Show)

-- | Who issued a blindly4 call or event.
data Origin = OLlm | ODriver | OObserver | OSolution
  deriving (Eq, Ord, Show, Enum, Bounded)

data EventKind
  = SongAssigned
  | PlaybackStarted
  | Paused
  | AdSeen
  | PlayObserved
  | PauseObserved
  | StepError
  | SongGaveUp
  deriving (Eq, Show, Enum, Bounded)

-- | One line of @events.jsonl@; 'evData' holds any extra fields (flattened into the line).
data Event = Event
  { evT :: Double
  , evStage :: Stage
  , evSource :: Origin
  , evKind :: EventKind
  , evSong :: Maybe Song
  , evData :: Object
  }
  deriving (Eq, Show)

-- | One line of @blindly4.jsonl@.
data Call = Call
  { callStage :: Stage
  , callOrigin :: Origin
  , callArgv :: [Text]
  , callStart :: Double
  , callMs :: Double
  , callExit :: Int
  , callStdout :: Text
  , callStderr :: Text
  }
  deriving (Eq, Show)

stageText :: Stage -> Text
stageText = \case
  Exploration -> "exploration"
  Exploitation -> "exploitation"

originText :: Origin -> Text
originText = \case
  OLlm -> "llm"
  ODriver -> "driver"
  OObserver -> "observer"
  OSolution -> "solution"

kindText :: EventKind -> Text
kindText = \case
  SongAssigned -> "song_assigned"
  PlaybackStarted -> "playback_started"
  Paused -> "paused"
  AdSeen -> "ad_seen"
  PlayObserved -> "play_observed"
  PauseObserved -> "pause_observed"
  StepError -> "step_error"
  SongGaveUp -> "song_gave_up"

inverse :: (Enum a, Bounded a) => (a -> Text) -> Text -> Maybe a
inverse render t = lookup t [(render x, x) | x <- [minBound .. maxBound]]

parseStage :: Text -> Maybe Stage
parseStage = inverse stageText

parseOrigin :: Text -> Maybe Origin
parseOrigin = inverse originText

instance Enum Stage where
  fromEnum = \case Exploration -> 0; Exploitation -> 1
  toEnum = \case 0 -> Exploration; _ -> Exploitation

instance Bounded Stage where
  minBound = Exploration
  maxBound = Exploitation

nowPosix :: IO Double
nowPosix = realToFrac <$> getPOSIXTime

textEnum :: (Enum a, Bounded a) => String -> (a -> Text) -> Value -> Result a
textEnum what render = \case
  String t | Just x <- inverse render t -> Success x
  v -> Error ("bad " <> what <> ": " <> show v)

instance ToJSON Stage where toJSON = String . stageText
instance FromJSON Stage where parseJSON v = either fail pure (resultEither (textEnum "stage" stageText v))
instance ToJSON Origin where toJSON = String . originText
instance FromJSON Origin where parseJSON v = either fail pure (resultEither (textEnum "origin" originText v))
instance ToJSON EventKind where toJSON = String . kindText
instance FromJSON EventKind where parseJSON v = either fail pure (resultEither (textEnum "kind" kindText v))

resultEither :: Result a -> Either String a
resultEither = \case
  Success a -> Right a
  Error e -> Left e

instance ToJSON Event where
  toJSON e =
    Object $
      KM.fromList
        ( [ ("t", toJSON (evT e))
          , ("stage", toJSON (evStage e))
          , ("source", toJSON (evSource e))
          , ("kind", toJSON (evKind e))
          ]
            <> maybe [] (\s -> [("song_index", toJSON (songIndex s)), ("song", toJSON (songQuery s))]) (evSong e)
        )
        <> evData e

instance FromJSON Event where
  parseJSON = withObject "event" $ \o -> do
    index <- o .:? "song_index"
    query <- o .:? "song"
    let known = ["t", "stage", "source", "kind", "song_index", "song"]
    Event
      <$> o .: "t"
      <*> o .: "stage"
      <*> o .: "source"
      <*> o .: "kind"
      <*> pure (Song <$> index <*> query)
      <*> pure (KM.filterWithKey (\k _ -> k `notElem` known) o)

instance ToJSON Call where
  toJSON c =
    object
      [ "stage" .= callStage c
      , "origin" .= callOrigin c
      , "argv" .= callArgv c
      , "t_start" .= callStart c
      , "duration_ms" .= callMs c
      , "exit_code" .= callExit c
      , "stdout" .= callStdout c
      , "stderr" .= callStderr c
      ]

instance FromJSON Call where
  parseJSON = withObject "call" $ \o ->
    Call
      <$> o .: "stage"
      <*> o .: "origin"
      <*> o .: "argv"
      <*> o .: "t_start"
      <*> o .: "duration_ms"
      <*> o .: "exit_code"
      <*> (T.copy <$> o .: "stdout")
      <*> o .: "stderr"
