module GuardSpec (spec) where

import Data.Either (isLeft)
import Test.Hspec
import Yuo.Guard
import Yuo.Types (Origin (..))

spec :: Spec
spec = describe "allowedCall" $ do
  it "allows a press with an expected label" $
    allowedCall OLlm ["press", "--path", "0.1", "--expect-description", "Search", "--pid", "7"] `shouldBe` Right ()
  it "refuses a press without an expected label" $
    allowedCall OLlm ["press", "--path", "0.1", "--pid", "7"] `shouldSatisfy` isLeft
  it "refuses a press on a public side-effect control" $
    allowedCall OLlm ["press", "--path", "0.1", "--expect-description", "Subscribe", "--pid", "7"] `shouldSatisfy` isLeft
  it "refuses typing into the comment box" $
    allowedCall OLlm ["set-value", "--path", "0.2", "--value", "hi", "--expect-description", "Add a comment", "--pid", "7"] `shouldSatisfy` isLeft
  it "allows a song whose title merely contains a denied word" $
    allowedCall OLlm ["press", "--path", "0.3", "--expect-description", "Madonna - Like A Prayer", "--pid", "7"] `shouldBe` Right ()
  it "allows dismissing an upsell with No thanks" $
    allowedCall OLlm ["press", "--path", "0.4", "--expect-description", "No thanks", "--pid", "7"] `shouldBe` Right ()
  it "refuses raw typing and clicking" $ do
    allowedCall OLlm ["type", "--text", "x", "--pid", "7"] `shouldSatisfy` isLeft
    allowedCall OLlm ["click", "--x", "1", "--y", "2", "--pid", "7"] `shouldSatisfy` isLeft
    allowedCall OLlm ["paste", "--text", "x", "--pid", "7"] `shouldSatisfy` isLeft
  it "refuses an unguarded Enter" $
    allowedCall OLlm ["key", "--key", "return", "--pid", "7"] `shouldSatisfy` isLeft
  it "allows a guarded Enter" $
    allowedCall OLlm ["key", "--key", "return", "--pid", "7", "--target-path", "0.2", "--require-value", "Toto Africa"] `shouldBe` Right ()
  it "allows escape and digit keys" $ do
    allowedCall OLlm ["key", "--key", "escape", "--pid", "7"] `shouldBe` Right ()
    allowedCall OLlm ["key", "--key", "0", "--pid", "7"] `shouldBe` Right ()
  it "allows reloading the page with F5" $
    allowedCall OLlm ["key", "--key", "f5", "--pid", "7"] `shouldBe` Right ()
  it "never opens a URL in the personal default browser" $
    allowedCall ODriver ["open", "--url", "https://www.youtube.com/"] `shouldSatisfy` isLeft
  it "refuses other keys" $
    allowedCall OLlm ["key", "--key", "ctrl+l", "--pid", "7"] `shouldSatisfy` isLeft
  it "lets only the driver open YouTube in an isolated profile" $ do
    allowedCall ODriver ["open", "--url", "https://evil.example/", "--chrome-profile", "C:\\p"] `shouldSatisfy` isLeft
    allowedCall ODriver ["open", "--url", "https://www.youtube.com/", "--chrome-profile", "C:\\p"] `shouldBe` Right ()
    allowedCall OLlm ["open", "--url", "https://www.youtube.com/", "--chrome-profile", "C:\\p"] `shouldSatisfy` isLeft
    allowedCall OSolution ["open", "--url", "https://www.youtube.com/", "--chrome-profile", "C:\\p"] `shouldSatisfy` isLeft
  it "lets only the driver close the browser" $ do
    allowedCall ODriver ["key", "--key", "alt+f4", "--pid", "7"] `shouldBe` Right ()
    allowedCall OSolution ["key", "--key", "alt+f4", "--pid", "7"] `shouldSatisfy` isLeft
    allowedCall OLlm ["key", "--key", "alt+f4", "--pid", "7"] `shouldSatisfy` isLeft
  it "allows read-only commands" $ do
    allowedCall OLlm ["find", "--title", "x"] `shouldBe` Right ()
    allowedCall OLlm ["apps"] `shouldBe` Right ()
  it "refuses an empty call and unknown commands" $ do
    allowedCall OLlm [] `shouldSatisfy` isLeft
    allowedCall OLlm ["request-permission"] `shouldSatisfy` isLeft
