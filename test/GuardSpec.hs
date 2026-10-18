module GuardSpec (spec) where

import Data.Either (isLeft)
import Test.Hspec
import Yuo.Guard

spec :: Spec
spec = describe "allowedCall" $ do
  it "allows a press with an expected label" $
    allowedCall ["press", "--path", "0.1", "--expect-description", "Search", "--pid", "7"] `shouldBe` Right ()
  it "refuses a press without an expected label" $
    allowedCall ["press", "--path", "0.1", "--pid", "7"] `shouldSatisfy` isLeft
  it "refuses a press on a public side-effect control" $
    allowedCall ["press", "--path", "0.1", "--expect-description", "Subscribe", "--pid", "7"] `shouldSatisfy` isLeft
  it "refuses typing into the comment box" $
    allowedCall ["set-value", "--path", "0.2", "--value", "hi", "--expect-description", "Add a comment", "--pid", "7"] `shouldSatisfy` isLeft
  it "allows a song whose title merely contains a denied word" $
    allowedCall ["press", "--path", "0.3", "--expect-description", "Madonna - Like A Prayer", "--pid", "7"] `shouldBe` Right ()
  it "allows dismissing an upsell with No thanks" $
    allowedCall ["press", "--path", "0.4", "--expect-description", "No thanks", "--pid", "7"] `shouldBe` Right ()
  it "refuses raw typing and clicking" $ do
    allowedCall ["type", "--text", "x", "--pid", "7"] `shouldSatisfy` isLeft
    allowedCall ["click", "--x", "1", "--y", "2", "--pid", "7"] `shouldSatisfy` isLeft
    allowedCall ["paste", "--text", "x", "--pid", "7"] `shouldSatisfy` isLeft
  it "refuses an unguarded Enter" $
    allowedCall ["key", "--key", "return", "--pid", "7"] `shouldSatisfy` isLeft
  it "allows a guarded Enter" $
    allowedCall ["key", "--key", "return", "--pid", "7", "--target-path", "0.2", "--require-value", "Toto Africa"] `shouldBe` Right ()
  it "allows escape and digit keys" $ do
    allowedCall ["key", "--key", "escape", "--pid", "7"] `shouldBe` Right ()
    allowedCall ["key", "--key", "0", "--pid", "7"] `shouldBe` Right ()
  it "refuses other keys" $
    allowedCall ["key", "--key", "ctrl+l", "--pid", "7"] `shouldSatisfy` isLeft
  it "opens only YouTube" $ do
    allowedCall ["open", "--url", "https://evil.example/", "--chrome-profile", "C:\\p"] `shouldSatisfy` isLeft
    allowedCall ["open", "--url", "https://www.youtube.com/", "--chrome-profile", "C:\\p"] `shouldBe` Right ()
  it "allows read-only commands" $ do
    allowedCall ["find", "--title", "x"] `shouldBe` Right ()
    allowedCall ["apps"] `shouldBe` Right ()
  it "refuses an empty call and unknown commands" $ do
    allowedCall [] `shouldSatisfy` isLeft
    allowedCall ["request-permission"] `shouldSatisfy` isLeft
