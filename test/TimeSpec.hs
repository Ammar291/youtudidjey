module TimeSpec (spec) where

import Test.Hspec
import Test.QuickCheck
import Yuo.Time

spec :: Spec
spec = do
  describe "parseProgress" $ do
    it "parses the seek slider text" $
      parseProgress "0 Minutes 2 Seconds of 3 Minutes 33 Seconds" `shouldBe` Just (Progress 2 213)
    it "parses singular units" $
      parseProgress "1 Minute 1 Second of 4 Minutes 7 Seconds" `shouldBe` Just (Progress 61 247)
    it "parses hours" $
      parseProgress "1 Hour 2 Minutes 3 Seconds of 2 Hours 0 Minutes 0 Seconds" `shouldBe` Just (Progress 3723 7200)
    it "rejects the precise-seeking slider text" $
      parseProgress "Seek to 0 Minutes 0 Seconds" `shouldBe` Nothing
    it "rejects the volume slider text" $
      parseProgress "100% volume" `shouldBe` Nothing
    it "round-trips renderProgress" $ property $ \(NonNegative p) (NonNegative extra) ->
      let pos = p `mod` 36000
          pr = Progress pos (pos + extra `mod` 36000)
       in parseProgress (renderProgress pr) === Just pr

  describe "parseResultDuration" $ do
    it "reads the trailing duration of a result link" $
      parseResultDuration "Daft Punk - Get Lucky (Official Audio) ft. Pharrell Williams, Nile Rodgers 4 minutes, 9 seconds"
        `shouldBe` Just 249
    it "reads a minutes-only duration" $
      parseResultDuration "Daft Punk - 'Get Lucky' (10 min loop) 10 minutes" `shouldBe` Just 600
    it "reads hours" $
      parseResultDuration "Long mix 1 hour, 2 minutes, 3 seconds" `shouldBe` Just 3723
    it "returns Nothing for a Mix without a duration" $
      parseResultDuration "Mix - Daft Punk - Get Lucky (Official Audio) ft. Pharrell Williams, Nile Rodgers" `shouldBe` Nothing

  describe "pauseDeadline" $ do
    it "is start + duration - 3 s - pause latency" $
      pauseDeadline 100 247 0 0.5 `shouldBe` 343.5
    it "pauses immediately for a video shorter than 3 s" $
      pauseDeadline 100 2 0 0.5 `shouldSatisfy` (<= 100)
    it "extends by ad time" $
      pauseDeadline 100 247 30 0.5 `shouldBe` 373.5
