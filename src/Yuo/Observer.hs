-- | The independent measuring instrument used by both stages: it watches the page through
-- read-only blindly4 calls and reports when the assigned song really plays and how close to the
-- end it was paused. Pure state machine first, polling loop after.
module Yuo.Observer
  ( Probe (..)
  , PlayInfo (..)
  , ObsState (..)
  , ObsOut (..)
  , stepObserver
  , assign
  , pausedAt
  , refineStart
  , hoverReading
  , probeFromNodes
  , Observer (..)
  , withObserver
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent (myThreadId, threadDelay, throwTo)
import Control.Concurrent.Async (concurrently, link, mapConcurrently, withAsync)
import Control.Exception (catch)
import Control.Concurrent.STM
import Control.Monad (forM_, forever, void)
import Data.Aeson (Value (..), (.=))
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Yuo.Blindly
import Yuo.Log (logEvent)
import Yuo.Match
import Yuo.Songs (Song (..))
import Yuo.Time
import Yuo.Tree
import Yuo.Types

-- | One observation of the page.
data Probe = Probe
  { prAt :: Double
  , prPane :: PaneInfo
  , prOnWatch :: Bool
  , prPlay :: Maybe PlayState
  , prAd :: Bool
  , prProgress :: Maybe Progress
  }
  deriving (Eq, Show)

data PlayInfo = PlayInfo
  { piSong :: Song
  , piAssigned :: Double
  , piObserved :: Double
  , piStartEst :: Double
  , piStartPos :: Maybe Int
  , piDuration :: Maybe Int
  , piAdSecs :: Double
  }
  deriving (Eq, Show)

-- | @Awaiting song assignedAt adSeconds adStartedAt@.
data ObsState
  = Idle
  | Awaiting Song Double Double (Maybe Double)
  | Watching PlayInfo
  deriving (Eq, Show)

data ObsOut
  = OutPlay PlayInfo
  | OutAd Song Double Double
  | OutPauseMargin Song Double Double -- ^ song, pause time, seconds remaining
  deriving (Eq, Show)

-- | Builds a probe from the pane name, the address bar value and any player nodes read.
probeFromNodes :: Double -> Text -> Maybe Text -> [Node] -> Probe
probeFromNodes at pane address nodes =
  Probe
    { prAt = at
    , prPane = paneInfo pane
    , prOnWatch = maybe False ("/watch" `T.isInfixOf`) address
    , prPlay = listToMaybe (mapMaybe (playState . nTitle) (filter ((== "AXButton") . nRole) nodes))
    , prAd = any (isAdMarker . nTitle) nodes
    , prProgress = listToMaybe (mapMaybe sliderProgress nodes)
    }
  where
    sliderProgress n
      | nTitle n == "Seek slider" = nValue n >>= parseProgress
      | otherwise = Nothing

-- | The assigned song is audibly playing on its own watch page, with no ad on screen and the
-- player not known to be paused.
isPlaying :: Song -> Probe -> Bool
isPlaying song p =
  prOnWatch p
    && paneAudio (prPane p)
    && maybe False (songMatches (songQuery song)) (paneVideoTitle (prPane p))
    && not (prAd p)
    && prPlay p /= Just PausedState

stepObserver :: ObsState -> Probe -> (ObsState, [ObsOut])
stepObserver st p = case st of
  Awaiting song assigned ads adStart
    | prAd p -> (Awaiting song assigned ads (adStart <|> Just (prAt p)), [])
    | otherwise ->
        let adOut = [OutAd song a (prAt p) | Just a <- [adStart]]
            ads' = ads + maybe 0 (prAt p -) adStart
         in if isPlaying song p
              then let info = playInfo song assigned ads' in (Watching info, adOut <> [OutPlay info])
              else (Awaiting song assigned ads' Nothing, adOut)
  _ -> (st, [])
  where
    playInfo song assigned ads =
      -- The slider text goes stale while the controls are hidden (it can still show the ad that
      -- just ended), so only a song-length reading near the start is trusted.
      let trusted = case prProgress p of
            Just pr | durSec pr >= 60 -> Just pr
            _ -> Nothing
          startEst = case trusted of
            Just (Progress pos _) | pos <= 5 -> prAt p - fromIntegral pos
            _ -> prAt p
       in PlayInfo song assigned (prAt p) startEst (posSec <$> trusted) (durSec <$> trusted) ads

-- | A fresh reading (taken just after playback was seen) pins down when the song itself began:
-- YouTube may spend seconds loading it after an ad ends. Ad-length sliders, a song that has not
-- moved yet (position 0) and implausible starts leave the estimate unchanged.
refineStart :: PlayInfo -> (Double, Progress) -> PlayInfo
refineStart info (t, Progress pos d)
  | d >= 60 && pos >= 1 && plausibleStart (piObserved info) implied =
      info {piStartEst = implied, piStartPos = Just pos, piDuration = Just d}
  | otherwise = info
  where
    implied = t - fromIntegral pos

assign :: Song -> Double -> ObsState -> ObsState
assign song t _ = Awaiting song t 0 Nothing

-- | The stage paused at @t@ believing the video lasts @duration@ seconds. The observer cannot
-- re-read the position (that needs a pointer hover, and it never sends input), so the margin is
-- computed from its own start time: remaining = start + duration - t.
pausedAt :: Double -> Maybe Int -> ObsState -> (ObsState, [ObsOut])
pausedAt t duration = \case
  Watching info -> (Idle, [OutPauseMargin (piSong info) t (piStartEst info + fromIntegral d - t) | Just d <- [duration]])
  Awaiting {} -> (Idle, [])
  s -> (s, [])

data Observer = Observer
  { obsAssign :: Song -> Double -> IO ()
  , obsPaused :: Double -> Maybe Int -> IO ()
  , obsPlayInfo :: STM (Maybe PlayInfo)
  , obsPlayer :: STM (Maybe Node)
  }

-- | Runs the observer thread for the duration of the action; a dead browser stops the stage.
withObserver :: B4 -> Stage -> (Observer -> IO a) -> IO a
withObserver b4 stage act = do
  state <- newTVarIO Idle
  epoch <- newTVarIO (0 :: Int)
  latest <- newTVarIO Nothing
  player <- newTVarIO Nothing
  address <- newTVarIO Nothing
  let bump = modifyTVar' epoch (+ 1)
      observer =
        Observer
          { obsAssign = \s t -> atomically (modifyTVar' state (assign s t) >> writeTVar latest Nothing >> bump)
          , obsPaused = \t d -> do
              outs <- atomically $ do
                (s', outs) <- pausedAt t d <$> readTVar state
                writeTVar state s' >> bump >> pure outs
              mapM_ (logOut b4 stage) outs
          , obsPlayInfo = readTVar latest
          , obsPlayer = readTVar player
          }
      loop = forever $ do
        (st, e) <- atomically $ do
          s <- readTVar state
          case s of
            Awaiting song _ _ _ -> (song,) <$> readTVar epoch
            _ -> retry
        probe <- awaitingProbe b4 player address st
        outs <- atomically $ do
          e' <- readTVar epoch
          if e' /= e
            then pure []
            else do
              (s', outs) <- flip stepObserver probe <$> readTVar state
              writeTVar state s'
              forM_ [i | OutPlay i <- outs] (writeTVar latest . Just)
              pure outs
        mapM refined outs >>= mapM_ (logOut b4 stage)
      -- One hover reading (a pointer move, no click) right after playback is seen, so the
      -- measurement ends when the song itself started, not when the ad's markers vanished.
      refined = \case
        OutPlay i -> do
          i' <- refineWithHover b4 player i
          atomically $
            readTVar state >>= \case
              Watching x | x == i -> writeTVar state (Watching i') >> writeTVar latest (Just i')
              _ -> pure ()
          pure (OutPlay i')
        other -> pure other
  -- The observer is usually the first to see a closed browser: hand ChromeGone to the stage as is
  -- (link would wrap it in ExceptionInLinkedThread and the stage's handler would miss it).
  parent <- myThreadId
  withAsync (loop `catch` \(gone :: ChromeGone) -> throwTo parent gone) $ \a -> link a >> act observer

-- | Hover across the player so YouTube refreshes its slider text, then read it.
hoverReading :: B4 -> Origin -> Node -> IO (Maybe (Double, Progress))
hoverReading b4 origin player = case nCenter player of
  Nothing -> pure Nothing
  Just (x, y) -> do
    void (withInput b4 $ \tok -> runInput b4 origin tok Activate >> runInput b4 origin tok (Hover (x - 40) y) >> runInput b4 origin tok (Hover x y))
    threadDelay 800000
    sliders <- either (const []) id . (>>= either (Left . B4Unexpected 0) Right . parseMatches) <$> runRead b4 origin (Find findQ {fqRole = Just "AXSlider", fqTitle = Just "Seek slider", fqUnder = Just (nPath player), fqDepth = 6})
    t <- nowPosix
    pure ((t,) <$> (listToMaybe sliders >>= nValue >>= parseProgress))

-- | Up to three readings, two seconds apart, until one refines the start.
refineWithHover :: B4 -> TVar (Maybe Node) -> PlayInfo -> IO PlayInfo
refineWithHover b4 player = go (3 :: Int)
  where
    go n info = do
      threadDelay 2000000
      reading <- readTVarIO player >>= maybe (pure Nothing) (hoverReading b4 OObserver)
      let info' = maybe info (refineStart info) reading
      if info' /= info || n <= 1 then pure info' else go (n - 1) info

obs :: B4 -> Command 'ReadOnly -> IO [Node]
obs b4 cmd = either (const []) id . (>>= either (Left . B4Unexpected 0) Right . parseMatches) <$> runRead b4 OObserver cmd

paneTitle :: B4 -> IO Text
paneTitle b4 =
  runRead b4 OObserver (Inspect (Path "0.1")) >>= \case
    Right (Object o) | Just (String t) <- KM.lookup "title" o -> pure t
    _ -> pure ""

-- | The address bar value, rediscovering its path when the cached one no longer names it.
addressValue :: B4 -> TVar (Maybe Path) -> IO (Maybe Text)
addressValue b4 cache = do
  cached <- readTVarIO cache
  let label = "Address and search bar"
      valid = \case
        Right (Object o) | Just (String t) <- KM.lookup "title" o, t == label -> case KM.lookup "value" o of
          Just (String v) -> Just v
          _ -> Nothing
        _ -> Nothing
  hit <- maybe (pure Nothing) (fmap valid . runRead b4 OObserver . Inspect) cached
  case hit of
    Just v -> pure (Just v)
    Nothing -> do
      found <- obs b4 (Find findQ {fqRole = Just "AXTextField", fqTitle = Just label, fqDepth = 12})
      atomically (writeTVar cache (nPath <$> listToMaybe found))
      pure (listToMaybe found >>= nValue)

-- | Direct children of the player; the first match is the player itself, which validates the path.
controls :: B4 -> TVar (Maybe Node) -> IO (Maybe (Path, [Node]))
controls b4 player = do
  cached <- readTVarIO player
  let children p = obs b4 (Find findQ {fqTitle = Just "", fqUnder = Just p, fqDepth = 1, fqLimit = 40})
      isPlayer ns = case ns of
        n : _ | nIdent n == "movie_player" -> True
        _ -> False
  first <- maybe (pure []) (children . nPath) cached
  if isPlayer first
    then remember first
    else do
      found <- obs b4 (Find findQ {fqIdentifier = Just "movie_player"})
      case found of
        p : _ -> children (nPath p) >>= \ns -> if isPlayer ns then remember ns else pure Nothing
        [] -> pure Nothing
  where
    remember ns = case ns of
      p : _ -> atomically (writeTVar player (Just p)) >> pure (Just (nPath p, ns))
      [] -> pure Nothing

-- | Cheap pane read first; the full confirmation only when the pane already looks right.
awaitingProbe :: B4 -> TVar (Maybe Node) -> TVar (Maybe Path) -> Song -> IO Probe
awaitingProbe b4 player cache song = do
  pane <- paneTitle b4
  t <- nowPosix
  let info = paneInfo pane
  if paneAudio info && maybe False (songMatches (songQuery song)) (paneVideoTitle info)
    then do
      (addr, ctl) <- concurrently (addressValue b4 cache) (controls b4 player)
      case ctl of
        Nothing -> pure (probeFromNodes t pane Nothing [])
        Just (mp, ns) -> do
          -- The next ad of a pod shows "My Ad Center" or "Skip" before its "Sponsored" label renders.
          (ads, sliders) <-
            concurrently
              (concat <$> mapConcurrently (\marker -> obs b4 (Find findQ {fqTitle = Just marker, fqUnder = Just mp, fqDepth = 5})) ["Sponsored", "My Ad Center", "Skip"])
              (obs b4 (Find findQ {fqRole = Just "AXSlider", fqTitle = Just "Seek slider", fqUnder = Just mp, fqDepth = 6}))
          pure (probeFromNodes t pane addr (ns <> ads <> sliders))
    else pure (probeFromNodes t pane Nothing [])

logOut :: B4 -> Stage -> ObsOut -> IO ()
logOut b4 stage = \case
  OutPlay i ->
    emit (piObserved i) PlayObserved (piSong i)
      [ "assigned" .= piAssigned i
      , "observed" .= piObserved i
      , "latency_s" .= (piObserved i - piAssigned i)
      , "start_est" .= piStartEst i
      , "latency_est_s" .= (piStartEst i - piAssigned i)
      , "start_pos" .= piStartPos i
      , "duration" .= piDuration i
      , "ad_s" .= piAdSecs i
      ]
  OutAd song a b -> emit b AdSeen song ["ad_start" .= a, "ad_end" .= b, "ad_s" .= (b - a)]
  OutPauseMargin song t m -> emit t PauseObserved song ["remaining_s" .= m]
  where
    emit t kind song fields = logEvent (b4Logger b4) (Event t stage OObserver kind (Just song) (KM.fromList fields))
