module ProcessSpec (spec) where

import GHC.Clock (getMonotonicTime)
import Test.Hspec
import Yuo.Process

spec :: Spec
spec = describe "runUtf8Timed" $ do
  it "kills a child that outlives its deadline and returns promptly" $ do
    t0 <- getMonotonicTime
    r <- runUtf8Timed 1 "python" ["-I", "-c", "import time; time.sleep(30)"] Nothing ""
    t1 <- getMonotonicTime
    r `shouldBe` Nothing
    (t1 - t0) `shouldSatisfy` (< 10)
  it "returns the output of a child that finishes in time" $
    runUtf8Timed 10 "python" ["-I", "-X", "utf8", "-c", "import sys; print(sys.stdin.read().upper())"] Nothing "caf\233"
      `shouldReturn` Just (0, "CAF\201\r\n", "")
