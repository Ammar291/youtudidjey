module MetricsSpec (spec) where

import Data.Aeson (Value, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Test.Hspec
import Yuo.Metrics
import Yuo.Songs (Song (..))
import Yuo.Types

ev :: Double -> Origin -> EventKind -> Int -> [(KM.Key, Value)] -> Event
ev t src kind i fields = Event t Exploitation src kind (Just (Song i (names !! i))) (KM.fromList fields)
  where
    names = ["Daft Punk Get Lucky", "Toto Africa"] :: [Text]

call :: Double -> Origin -> Text -> Call
call t origin cmd = Call Exploitation origin [cmd] t 500 0 "" ""

events :: [Event]
events =
  [ ev 10 OSolution SongAssigned 0 []
  , ev 14.5 OObserver PlayObserved 0 ["start_est" .= (14 :: Double), "start_pos" .= (0 :: Int), "ad_s" .= (0 :: Double)]
  , ev 250 OSolution Paused 0 ["duration" .= (247 :: Int)]
  , ev 251 OObserver PauseObserved 0 ["remaining_s" .= (3.2 :: Double)]
  , ev 300 OSolution SongAssigned 1 []
  , ev 302 OObserver PlayObserved 1 ["start_est" .= (301.5 :: Double), "start_pos" .= (200 :: Int), "ad_s" .= (0 :: Double)]
  ]

calls :: [Call]
calls = [call 11 OLlm "find", call 12 OLlm "press", call 299 OSolution "find", call 301 OSolution "press", call 301.2 OObserver "inspect"]

spec :: Spec
spec = lateSpec >> mainSpec

mainSpec :: Spec
mainSpec = do
  describe "stats" $
    it "computes count, mean, nearest-rank median and p90, min and max" $
      stats [1, 2, 3, 4] `shouldBe` Stats 4 2.5 2 4 1 4

  describe "songMetrics" $ do
    let ms = songMetrics Exploitation events calls []
    it "measures assign-to-playback latency per song" $ do
      map smLatency ms `shouldBe` [Just 4.5, Just 2.0]
      map smLatencyEst ms `shouldBe` [Just 4.0, Just 1.5]
    it "attributes calls to songs by time window and origin, excluding the observer" $ do
      map smCallsToPlay ms `shouldBe` [M.fromList [(OLlm, 2)], M.fromList [(OSolution, 1)]]
    it "keeps the observed pause margin" $
      map smPauseMargin ms `shouldBe` [Just 3.2, Nothing]
    it "flags a song whose first call came before it was assigned" $
      map smFlags ms `shouldSatisfy` (\fs -> "assigned late" `elem` (fs !! 1) && "assigned late" `notElem` head' fs)
    it "flags a song that did not start near 0:00" $
      map smFlags ms `shouldSatisfy` (\fs -> "did not start near 0:00" `elem` (fs !! 1))

  describe "a song that never played" $ do
    let gaveUp = [ev 10 ODriver SongAssigned 0 [], ev 60 ODriver SongGaveUp 0 ["reason" .= ("budget" :: Text)], ev 61 ODriver SongAssigned 1 [], ev 65 OObserver PlayObserved 1 []]
        ms = songMetrics Exploration gaveUp [] []
    it "is marked failed and left out of the latency statistics" $ do
      map smFailed ms `shouldBe` [True, False]
      stN (latencyStats ms) `shouldBe` 1
  where
    head' xs = case xs of
      x : _ -> x
      [] -> []

lateSpec :: Spec
lateSpec = describe "after a song that never played" $
  it "does not flag the next song as assigned late because of the failed song's own calls" $ do
    let evs =
          [ ev 10 OSolution SongAssigned 0 []
          , ev 14 OObserver PlayObserved 0 []
          , ev 250 OSolution Paused 0 []
          , ev 300 OSolution SongAssigned 1 []
          , ev 390 OSolution StepError 1 []
          , ev 400 OSolution SongAssigned 0 []
          , ev 405 OObserver PlayObserved 0 []
          ]
        cs = [call 301 OSolution "find", call 350 OSolution "press"]
    map smFlags (songMetrics Exploitation evs cs []) `shouldBe` [[], [], []]
