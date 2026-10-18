module ChromeSpec (spec) where

import Data.Either (isLeft)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO.Utf8 as TU
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Yuo.Blindly
import Yuo.Chrome (profileFor, warmUp)
import Yuo.Log (withLogger)
import Yuo.Types

-- | A page whose player is present and paused, except that the first @activateFailures@ activations
-- fail (Chrome not in front) and, when @player@ is False, the page never exposes its player.
fakePage :: Bool -> Int -> IORef Int -> IO Backend
fakePage player activateFailures activations = do
  children <- TU.readFile "test/fixtures/player_children.json"
  let paused = T.replace "\"Pause (k)\"" "\"Play (k)\"" children
      playerOnly = "{\"pid\":7,\"role\":\"AXGroup\",\"path\":\"0.1.0.0.1.1.0.1.0.0.1.0.0\",\"title\":\"YouTube Video Player\",\"identifier\":\"movie_player\"}"
  pure $ Backend $ \args -> case args of
    "activate" : _ -> do
      n <- atomicModifyIORef' activations (\k -> (k + 1, k))
      pure $ if n < activateFailures then (77, "{\"error\":\"window is not in the foreground\",\"code\":\"accessibility_error\"}", "") else (0, "{\"ok\":true}", "")
    "find" : rest
      | not player -> pure (0, "{\"matches\":[],\"truncated\":false}", "")
      | "--under" `elem` rest -> pure (0, paused, "")
      | otherwise -> pure (0, "{\"matches\":[" <> playerOnly <> "],\"truncated\":false}", "")
    _ -> pure (0, "{\"ok\":true}", "")

-- | Two polls per round and no settling delay, so a failing warm-up ends quickly.
warmWith :: Int -> Backend -> IO (Either Text ())
warmWith retries backend = withSystemTempDirectory "run" $ \dir ->
  withLogger dir $ \logger -> do
    b4 <- newB4 backend (Just (Pid 7)) logger Exploration
    warmUp retries 2 0 b4

warm :: Backend -> IO (Either Text ())
warm = warmWith 2

spec :: Spec
spec = do
  describe "profileFor" $ do
    it "uses a fresh, throwaway profile per stage run by default" $
      profileFor Nothing Exploration "20261018-230000" `shouldBe` (".chrome-profile" </> "exploration-20261018-230000", True)
    it "reuses a persistent profile when one is given, and never deletes it" $
      profileFor (Just "C:\\yuo\\signed-in") Exploitation "20261018-230000" `shouldBe` ("C:\\yuo\\signed-in", False)
  describe "warmUp" $ do
    it "is ready once Chrome is in front and the paused player is present" $ do
      activations <- newIORef 0
      warm =<< fakePage True 0 activations
      `shouldReturn` Right ()
    it "retries a failed activation instead of starting with Chrome in the background" $ do
      activations <- newIORef 0
      r <- warm =<< fakePage True 1 activations
      r `shouldBe` Right ()
      readIORef activations `shouldReturn` 2
    it "keeps retrying the activation while another window holds the foreground, up to its retries" $ do
      activations <- newIORef 0
      r <- warmWith 6 =<< fakePage True 5 activations
      r `shouldBe` Right ()
      readIORef activations `shouldReturn` 6
    it "reports the environment as not ready when the page never exposes its player" $ do
      activations <- newIORef 0
      r <- warm =<< fakePage False 0 activations
      r `shouldSatisfy` isLeft
