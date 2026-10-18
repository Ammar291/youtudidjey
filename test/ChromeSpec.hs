module ChromeSpec (spec) where

import System.FilePath ((</>))
import Test.Hspec
import Yuo.Chrome (profileFor)
import Yuo.Types (Stage (..))

spec :: Spec
spec = describe "profileFor" $ do
  it "uses a fresh, throwaway profile per stage run by default" $
    profileFor Nothing Exploration "20261018-230000" `shouldBe` (".chrome-profile" </> "exploration-20261018-230000", True)
  it "reuses a persistent profile when one is given, and never deletes it" $
    profileFor (Just "C:\\yuo\\signed-in") Exploitation "20261018-230000" `shouldBe` ("C:\\yuo\\signed-in", False)
