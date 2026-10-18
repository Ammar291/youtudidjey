module ObserverSpec (spec) where

import Data.Aeson (Value (..), eitherDecodeFileStrict')
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import System.IO.Temp (withSystemTempDirectory)
import Yuo.Blindly (Backend (..), ChromeGone (..), newB4)
import Yuo.Log (withLogger)
import Yuo.Observer
import Yuo.Songs (Song (..))
import Yuo.Tree
import Yuo.Types (Path (..), Pid (..), Stage (..))

json :: FilePath -> IO Value
json f = eitherDecodeFileStrict' ("test/fixtures/" <> f) >>= either fail pure

nodesOf :: FilePath -> IO [Node]
nodesOf f = json f >>= either (fail . T.unpack) pure . parseMatches

titleOf :: FilePath -> IO Text
titleOf f =
  json f >>= \case
    Object o | Just (String t) <- KM.lookup "title" o -> pure t
    _ -> fail "no title"

lucky :: Song
lucky = Song 0 "Daft Punk Get Lucky"

watchUrl :: Maybe Text
watchUrl = Just "youtube.com/watch?v=5NV6Rdv1a3I&list=RD5NV6Rdv1a3I&start_radio=1"

slider :: Text -> Node
slider v = Node (Path "0.1.5") "AXSlider" "Seek slider" (Just v) "" [] Nothing

pauseButton :: Node
pauseButton = Node (Path "0.1.6") "AXButton" "Pause (k)" Nothing "" ["AXPress"] Nothing

plays :: [ObsOut] -> [PlayInfo]
plays outs = [p | OutPlay p <- outs]

spec :: Spec
spec = observerLoopSpec >> adMarkerSpec >> stepSpec

stepSpec :: Spec
stepSpec = describe "stepObserver" $ do
  it "does not count an ad as the song, then counts the song after the ad" $ do
    adProbe <- probeFromNodes 100 <$> titleOf "pane_ad.json" <*> pure watchUrl <*> nodesOf "player_ad_full.json"
    songProbe <- probeFromNodes 105 <$> titleOf "pane_playing.json" <*> pure watchUrl <*> nodesOf "player_children.json"
    let (s1, o1) = stepObserver (assign lucky 90 Idle) adProbe
        (_, o2) = stepObserver s1 songProbe
    plays o1 `shouldBe` []
    map piObserved (plays o2) `shouldBe` [105]
    map piAdSecs (plays o2) `shouldBe` [5]
    [(a, b) | OutAd _ a b <- o2] `shouldBe` [(100, 105)]

  it "ignores the results page even though its title matches the query" $ do
    let probe = probeFromNodes 50 "Daft Punk Get Lucky - YouTube - Audio playing - Google Chrome" (Just "youtube.com/results?search_query=Daft+Punk+Get+Lucky") [pauseButton]
    plays (snd (stepObserver (assign lucky 40 Idle) probe)) `shouldBe` []

  it "estimates the true start from a fresh slider reading" $ do
    let probe = probeFromNodes 50 "Daft Punk - Get Lucky (Official Audio) - YouTube - Audio playing - Google Chrome" watchUrl [pauseButton, slider "0 Minutes 2 Seconds of 4 Minutes 7 Seconds"]
        found = plays (snd (stepObserver (assign lucky 40 Idle) probe))
    map piObserved found `shouldBe` [50]
    map piStartEst found `shouldBe` [48]
    map piDuration found `shouldBe` [Just 247]

  it "accumulates a multi-probe ad before playback" $ do
    adProbe <- probeFromNodes 0 <$> titleOf "pane_ad.json" <*> pure watchUrl <*> nodesOf "player_ad_full.json"
    songProbe <- probeFromNodes 125 <$> titleOf "pane_playing.json" <*> pure watchUrl <*> nodesOf "player_children.json"
    let s0 = assign lucky 90 Idle
        (s1, _) = stepObserver s0 adProbe {prAt = 100}
        (s2, _) = stepObserver s1 adProbe {prAt = 110}
        (_, o3) = stepObserver s2 songProbe
    [(a, b) | OutAd _ a b <- o3] `shouldBe` [(100, 125)]
    map piAdSecs (plays o3) `shouldBe` [25]

  it "computes the pause margin from the observed start and the stage's duration" $ do
    let watching = fst (stepObserver (assign lucky 40 Idle) (probeFromNodes 50 "Daft Punk - Get Lucky - YouTube - Audio playing - Google Chrome" watchUrl [pauseButton]))
        (s1, o1) = pausedAt 293 (Just 247) watching
    [(t, m) | OutPauseMargin _ t m <- o1] `shouldBe` [(293, 4)]
    s1 `shouldBe` Idle

  it "reports no margin when the duration is unknown" $ do
    let watching = fst (stepObserver (assign lucky 40 Idle) (probeFromNodes 50 "Daft Punk - Get Lucky - YouTube - Audio playing - Google Chrome" watchUrl [pauseButton]))
    snd (pausedAt 293 Nothing watching) `shouldBe` []

  it "does not trust an ad-length slider duration" $ do
    let probe = probeFromNodes 50 "Daft Punk - Get Lucky - YouTube - Audio playing - Google Chrome" watchUrl [pauseButton, slider "0 Minutes 2 Seconds of 0 Minutes 15 Seconds"]
        found = plays (snd (stepObserver (assign lucky 40 Idle) probe))
    map piDuration found `shouldBe` [Nothing]
    map piStartEst found `shouldBe` [50]

  it "stops waiting for a song that is paused before it ever played" $
    pausedAt 60 (Just 247) (assign lucky 40 Idle) `shouldBe` (Idle, [])

-- | The observer is usually first to notice a closed browser; the stage must see ChromeGone itself.
observerLoopSpec :: Spec
observerLoopSpec = describe "withObserver" $
  it "rethrows ChromeGone to the stage unwrapped" $
    withSystemTempDirectory "obs" $ \dir -> withLogger dir $ \lg -> do
      let gone = Backend (const (pure (77, "{\"error\":\"No visible windows for PID 7\",\"code\":\"accessibility_error\"}", "")))
      b <- newB4 gone (Just (Pid 7)) lg Exploration
      withObserver b Exploration (\o -> obsAssign o lucky 0 >> threadDelay 3000000) `shouldThrow` (\(ChromeGone _) -> True)

-- | A watch page with audio, the song's title and a Pause button, plus whatever ad markers given.
fakeWatchPage :: [Text] -> Backend
fakeWatchPage markers = Backend $ \args -> pure (0, reply args, "")
  where
    has flag value args = any (== [flag, value]) (pairs args)
    pairs xs = zipWith (\a b -> [a, b]) xs (drop 1 xs)
    node path role title ident = "{\"role\":\"" <> role <> "\",\"path\":\"" <> path <> "\",\"title\":\"" <> title <> "\",\"identifier\":\"" <> ident <> "\"}"
    matches ns = "{\"matches\":[" <> T.intercalate "," ns <> "],\"truncated\":false}"
    reply args
      | take 1 args == ["inspect"] && has "--path" "0.1" args = "{\"title\":\"Daft Punk - Get Lucky (Official Audio) - YouTube - Audio playing - Google Chrome\"}"
      | take 1 args == ["inspect"] = "{\"title\":\"Address and search bar\",\"value\":\"youtube.com/watch?v=5NV6Rdv1a3I\"}"
      | has "--title" "Address and search bar" args = matches ["{\"role\":\"AXTextField\",\"path\":\"0.9\",\"title\":\"Address and search bar\",\"value\":\"youtube.com/watch?v=5NV6Rdv1a3I\"}"]
      | has "--identifier" "movie_player" args = matches [node "0.5" "AXGroup" "YouTube Video Player" "movie_player"]
      | has "--title" "" args && has "--depth" "1" args = matches [node "0.5" "AXGroup" "YouTube Video Player" "movie_player", node "0.5.1" "AXButton" "Pause (k)" ""]
      | otherwise = matches [node "0.5.2" "AXButton" m "" | m <- markers, any (\t -> has "--title" t args && t `T.isInfixOf` m) ["Sponsored", "My Ad Center", "Skip"]]

adMarkerSpec :: Spec
adMarkerSpec = describe "withObserver ad detection" $ do
  it "does not count a pod's next ad that only shows My Ad Center as the song" $
    withSystemTempDirectory "obs" $ \dir -> withLogger dir $ \lg -> do
      b <- newB4 (fakeWatchPage ["My Ad Center"]) (Just (Pid 7)) lg Exploration
      seen <- withObserver b Exploration $ \o -> obsAssign o lucky 0 >> threadDelay 2500000 >> atomically (obsPlayInfo o)
      seen `shouldBe` Nothing
  it "confirms the song once no ad marker is on screen" $
    withSystemTempDirectory "obs" $ \dir -> withLogger dir $ \lg -> do
      b <- newB4 (fakeWatchPage []) (Just (Pid 7)) lg Exploration
      seen <- withObserver b Exploration $ \o -> obsAssign o lucky 0 >> threadDelay 2500000 >> atomically (obsPlayInfo o)
      fmap (songQuery . piSong) seen `shouldBe` Just "Daft Punk Get Lucky"
