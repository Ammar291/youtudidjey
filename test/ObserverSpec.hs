module ObserverSpec (spec) where

import Data.Aeson (Value (..), eitherDecodeFileStrict')
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec
import Yuo.Observer
import Yuo.Songs (Song (..))
import Yuo.Tree
import Yuo.Types (Path (..))

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
spec = describe "stepObserver" $ do
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
    [m | OutPauseMargin _ m <- o1] `shouldBe` [4]
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
