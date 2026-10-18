module ContractSpec (spec) where

import qualified Data.Text as T
import Test.Hspec
import Yuo.Codegen.Contract (contractText, driverTimingText)
import Yuo.Match (adMarkerTitles)
import Yuo.Time (resyncTolerance, silenceLimit, startWindow)

secs :: Double -> T.Text
secs x = T.pack (show (round x :: Int)) <> " s"

says :: T.Text -> Expectation
says phrase = (contractText <> driverTimingText) `shouldSatisfy` T.isInfixOf phrase

spec :: Spec
spec = do
  describe "driverTimingText" $ do
    it "names every ad marker the observer recognises, quoted exactly" $
      mapM_ (\m -> driverTimingText `shouldSatisfy` T.isInfixOf ("\"" <> m <> "\"")) adMarkerTitles
    it "warns that a Pause button alone does not mean the song itself is playing" $
      driverTimingText `shouldSatisfy` T.isInfixOf "Pause (k) button alone"
    it "states the start window and the re-sync tolerance the driver uses" $ do
      let (early, late) = startWindow
      mapM_ (\w -> driverTimingText `shouldSatisfy` T.isInfixOf w)
        [secs early <> " before", secs late <> " after", "within " <> secs resyncTolerance]
    it "only claims trace origins the codegen trace contains" $
      driverTimingText `shouldNotSatisfy` T.isInfixOf "\"observer\""
    it "describes the driver's retries as they are: every 5 s, up to 40" $ do
      says "every 5 s"
      says "up to 40"
  describe "solution.py's obligations" $ do
    it "anchors the start window to the last ad evidence, not the first ad-free moment" $
      says "last time an ad marker or an ad-length reading was seen"
    it "finds the pause control early, inside the player, with --limit 1, and presses the remembered path" $ do
      says "--limit 1"
      says "remembered path"
    it "presses an enabled ad Skip button" $
      says "skip-button"
    it "states the silence watchdog and bounds each attempt well under it" $ do
      says (secs (fromIntegral silenceLimit) <> " without any event")
      says "120 s"
    it "backs off after a step_error" $
      says "back off"
