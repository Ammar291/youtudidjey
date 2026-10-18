module PauseSpec (spec) where

import Test.Hspec
import Yuo.Pause (acceptResync, acceptStart)
import Yuo.Time (Progress (..))

spec :: Spec
spec = do
  describe "acceptStart (the reading taken right after playback is confirmed)" $ do
    it "takes a fresh song-length reading that agrees with the observed start" $
      acceptStart 60 249 (76, Progress 15 247) `shouldBe` Just (61, 247)
    it "ignores the slider left over from an ad" $
      acceptStart 60 249 (76, Progress 1 15) `shouldBe` Nothing
    it "ignores a reading whose position contradicts the observed start" $
      acceptStart 60 249 (76, Progress 200 247) `shouldBe` Nothing

  describe "acceptResync (the reading 15 s before the deadline)" $ do
    it "corrects a few seconds of drift" $
      acceptResync 100 247 (290, Progress 186 247) `shouldBe` Just 104
    it "rejects a stale reading that would push the pause minutes late" $
      acceptResync 60 249 (291, Progress 16 249) `shouldBe` Nothing
    it "rejects a reading of another video's length" $
      acceptResync 100 247 (290, Progress 186 15) `shouldBe` Nothing
