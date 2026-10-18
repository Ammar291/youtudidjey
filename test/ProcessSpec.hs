module ProcessSpec (spec) where

import GHC.Clock (getMonotonicTime)
import Test.Hspec
import qualified Data.Text as T
import Yuo.Blindly (Backend (..), processBackendWith)
import Yuo.Process

spec :: Spec
spec = blindlyTimeoutSpec >> timedSpec

timedSpec :: Spec
timedSpec = describe "runUtf8Timed" $ do
  it "kills a child that outlives its deadline and returns promptly" $ do
    t0 <- getMonotonicTime
    r <- runUtf8Timed 1 "python" ["-I", "-c", "import time; time.sleep(30)"] Nothing ""
    t1 <- getMonotonicTime
    r `shouldBe` Nothing
    (t1 - t0) `shouldSatisfy` (< 10)
  it "returns the output of a child that finishes in time" $
    runUtf8Timed 10 "python" ["-I", "-X", "utf8", "-c", "import sys; print(sys.stdin.read().upper())"] Nothing "caf\233"
      `shouldReturn` Just (0, "CAF\201\r\n", "")

blindlyTimeoutSpec :: Spec
blindlyTimeoutSpec = describe "processBackendWith" $
  it "turns a hung blindly4 call into a failed call instead of hanging the stage" $ do
    t0 <- getMonotonicTime
    (code, _, err) <- invoke (processBackendWith 1 "python") ["-I", "-c", "import time; time.sleep(30)"]
    t1 <- getMonotonicTime
    code `shouldBe` 124
    err `shouldSatisfy` T.isInfixOf "timed out"
    (t1 - t0) `shouldSatisfy` (< 10)
