module GuardSpec (spec) where

import Data.Either (isLeft)
import Test.Hspec
import Yuo.Guard
import Yuo.Types (Origin (..), Pid (..))

spec :: Spec
spec = describe "allowedCall" $ do
  it "allows a press with an expected label" $
    allowedCall OLlm Nothing ["press", "--path", "0.1", "--expect-description", "Search", "--pid", "7"] `shouldBe` Right ()
  it "refuses a press without an expected label" $
    allowedCall OLlm Nothing ["press", "--path", "0.1", "--pid", "7"] `shouldSatisfy` isLeft
  it "refuses a press on a public side-effect control" $
    allowedCall OLlm Nothing ["press", "--path", "0.1", "--expect-description", "Subscribe", "--pid", "7"] `shouldSatisfy` isLeft
  it "refuses typing into the comment box" $
    allowedCall OLlm Nothing ["set-value", "--path", "0.2", "--value", "hi", "--expect-description", "Add a comment", "--pid", "7"] `shouldSatisfy` isLeft
  it "allows a song whose title merely contains a denied word" $
    allowedCall OLlm Nothing ["press", "--path", "0.3", "--expect-description", "Madonna - Like A Prayer", "--pid", "7"] `shouldBe` Right ()
  it "allows dismissing an upsell with No thanks" $
    allowedCall OLlm Nothing ["press", "--path", "0.4", "--expect-description", "No thanks", "--pid", "7"] `shouldBe` Right ()
  it "refuses raw typing and clicking" $ do
    allowedCall OLlm Nothing ["type", "--text", "x", "--pid", "7"] `shouldSatisfy` isLeft
    allowedCall OLlm Nothing ["click", "--x", "1", "--y", "2", "--pid", "7"] `shouldSatisfy` isLeft
    allowedCall OLlm Nothing ["paste", "--text", "x", "--pid", "7"] `shouldSatisfy` isLeft
  it "refuses an unguarded Enter" $
    allowedCall OLlm Nothing ["key", "--key", "return", "--pid", "7"] `shouldSatisfy` isLeft
  it "allows a guarded Enter" $
    allowedCall OLlm Nothing ["key", "--key", "return", "--pid", "7", "--target-path", "0.2", "--require-value", "Toto Africa"] `shouldBe` Right ()
  it "allows escape and digit keys" $ do
    allowedCall OLlm Nothing ["key", "--key", "escape", "--pid", "7"] `shouldBe` Right ()
    allowedCall OLlm Nothing ["key", "--key", "0", "--pid", "7"] `shouldBe` Right ()
  it "allows reloading the page with F5" $
    allowedCall OLlm Nothing ["key", "--key", "f5", "--pid", "7"] `shouldBe` Right ()
  it "never opens a URL in the personal default browser" $
    allowedCall ODriver Nothing ["open", "--url", "https://www.youtube.com/"] `shouldSatisfy` isLeft
  it "refuses other keys" $
    allowedCall OLlm Nothing ["key", "--key", "ctrl+l", "--pid", "7"] `shouldSatisfy` isLeft
  it "lets only the driver open YouTube in an isolated profile" $ do
    allowedCall ODriver Nothing ["open", "--url", "https://evil.example/", "--chrome-profile", "C:\\p"] `shouldSatisfy` isLeft
    allowedCall ODriver Nothing ["open", "--url", "https://www.youtube.com/", "--chrome-profile", "C:\\p"] `shouldBe` Right ()
    allowedCall OLlm Nothing ["open", "--url", "https://www.youtube.com/", "--chrome-profile", "C:\\p"] `shouldSatisfy` isLeft
    allowedCall OSolution Nothing ["open", "--url", "https://www.youtube.com/", "--chrome-profile", "C:\\p"] `shouldSatisfy` isLeft
  it "lets only the driver close the browser" $ do
    allowedCall ODriver Nothing ["key", "--key", "alt+f4", "--pid", "7"] `shouldBe` Right ()
    allowedCall OSolution Nothing ["key", "--key", "alt+f4", "--pid", "7"] `shouldSatisfy` isLeft
    allowedCall OLlm Nothing ["key", "--key", "alt+f4", "--pid", "7"] `shouldSatisfy` isLeft
  it "allows read-only commands" $ do
    allowedCall OLlm Nothing ["find", "--title", "x"] `shouldBe` Right ()
    allowedCall OLlm Nothing ["apps"] `shouldBe` Right ()
  it "refuses an empty call and unknown commands" $ do
    allowedCall OLlm Nothing [] `shouldSatisfy` isLeft
    allowedCall OLlm Nothing ["request-permission"] `shouldSatisfy` isLeft
  describe "pinning to the session's browser" $ do
    it "refuses a solution call aimed at another process" $
      allowedCall OSolution (Just (Pid 7)) ["press", "--path", "0.1", "--expect-description", "Search", "--pid", "8"] `shouldSatisfy` isLeft
    it "refuses a solution call without --pid, which would hit the foreground window" $
      allowedCall OSolution (Just (Pid 7)) ["key", "--key", "escape"] `shouldSatisfy` isLeft
    it "allows calls aimed at the session's browser" $
      allowedCall OSolution (Just (Pid 7)) ["find", "--title", "x", "--pid", "7"] `shouldBe` Right ()
    it "allows listing apps and the schema without a pid" $ do
      allowedCall OSolution (Just (Pid 7)) ["apps"] `shouldBe` Right ()
      allowedCall OSolution (Just (Pid 7)) ["schema"] `shouldBe` Right ()
  it "refuses fragments of denied labels" $ do
    allowedCall OLlm Nothing ["press", "--path", "0.1", "--expect-description", "ubscribe", "--pid", "7"] `shouldSatisfy` isLeft
    allowedCall OLlm Nothing ["press", "--path", "0.1", "--expect-description", "ik", "--pid", "7"] `shouldSatisfy` isLeft
