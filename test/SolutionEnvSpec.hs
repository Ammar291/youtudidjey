module SolutionEnvSpec (spec) where

import Data.Aeson (decode)
import qualified Data.ByteString.Lazy.Char8 as BLC
import Test.Hspec
import Yuo.SolutionEnv
import Yuo.Types

env :: [(String, String)]
env =
  solutionEnv Exploitation "y.exe" "logs/x" "b.exe" (Pid 42) ["c:\\users\\muham\\appdata\\roaming\\npm"]
    [("ANTHROPIC_API_KEY", "k"), ("Path", "C:\\a;C:\\Users\\muham\\AppData\\Roaming\\npm\\;C:\\b"), ("HOME", "h")]

spec :: Spec
spec = do
  describe "stripLlmPath" $
    it "removes the LLM CLI directories, ignoring case and trailing separators" $
      stripLlmPath ["C:\\a", "C:\\Users\\muham\\AppData\\Roaming\\npm\\", "C:\\b"] ["c:\\users\\muham\\appdata\\roaming\\npm"]
        `shouldBe` ["C:\\a", "C:\\b"]
  describe "solutionEnv" $ do
    it "points solution.py at its browser" $
      lookup "YUO_CHROME_PID" env `shouldBe` Just "42"
    it "gives solution.py the logging proxy as its only way to blindly4" $
      (lookup "YUO_B4" env >>= decode . BLC.pack)
        `shouldBe` Just ["y.exe", "b4", "--run-dir", "logs/x", "--stage", "exploitation", "--origin", "solution", "--blindly4", "b.exe", "--session-pid", "42", "--" :: String]
    it "writes solution events to their own file" $
      lookup "YUO_EVENTS" env `shouldBe` Just "logs/x\\solution-events.jsonl"
    it "removes LLM credentials and LLM CLIs from the environment" $ do
      lookup "ANTHROPIC_API_KEY" env `shouldBe` Nothing
      lookup "PATH" env `shouldBe` Just "C:\\a;C:\\b"
      lookup "Path" env `shouldBe` Nothing
    it "keeps unrelated variables and forces UTF-8" $ do
      lookup "HOME" env `shouldBe` Just "h"
      lookup "PYTHONIOENCODING" env `shouldBe` Just "utf-8"
