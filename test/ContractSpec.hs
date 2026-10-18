module ContractSpec (spec) where

import qualified Data.Text as T
import Test.Hspec
import Yuo.Codegen.Contract (driverTimingText)
import Yuo.Match (adMarkerTitles)
import Yuo.Time (resyncTolerance, startWindow)

secs :: Double -> T.Text
secs x = T.pack (show (round x :: Int)) <> " s"

spec :: Spec
spec = describe "driverTimingText" $ do
  it "names every ad marker the observer recognises, quoted exactly" $
    mapM_ (\m -> driverTimingText `shouldSatisfy` T.isInfixOf ("\"" <> m <> "\"")) adMarkerTitles
  it "warns that a Pause button alone does not mean the song itself is playing" $
    driverTimingText `shouldSatisfy` T.isInfixOf "Pause (k) button alone"
  it "states the start window and the re-sync tolerance the driver uses" $ do
    let (early, late) = startWindow
    mapM_ (\w -> driverTimingText `shouldSatisfy` T.isInfixOf w)
      [secs early <> " before", secs late <> " after", "within " <> secs resyncTolerance]
