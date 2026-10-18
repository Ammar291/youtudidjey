module BlindlySpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (forConcurrently_)
import Data.Aeson (Value (..), decodeStrict')
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Char8 as BC
import Data.Either (isLeft)
import Data.IORef
import Data.Text (Text)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Yuo.Blindly
import Yuo.Concurrent (firstJust)
import Yuo.Log
import Yuo.Types

-- | A B4 over a fake backend, logging into a temporary run directory.
withFake :: Backend -> (FilePath -> B4 -> IO a) -> IO a
withFake backend act = withSystemTempDirectory "run" $ \dir ->
  withLogger dir $ \logger -> do
    b4 <- newB4 backend (Just (Pid 7)) logger Exploration
    act dir b4

constant :: (Int, Text, Text) -> IO Backend
constant out = pure (Backend (const (pure out)))

callLines :: FilePath -> IO [Value]
callLines dir = map (maybe Null id . decodeStrict') . BC.lines <$> BC.readFile (dir </> "blindly4.jsonl")

spec :: Spec
spec = do
  describe "argv" $ do
    it "renders a find with its bounds and pid" $
      argv (Just (Pid 7)) (Find findQ {fqIdentifier = Just "movie_player"})
        `shouldBe` ["find", "--identifier", "movie_player", "--depth", "40", "--limit", "1", "--pid", "7"]
    it "renders an XML subtree listing" $
      argv (Just (Pid 7)) (Find findQ {fqTitle = Just "", fqUnder = Just (Path "0.1"), fqDepth = 3, fqLimit = 80, fqXml = True})
        `shouldBe` ["find", "--title", "", "--under", "0.1", "--depth", "3", "--limit", "80", "--format", "xml", "--pid", "7"]
    it "renders a press with its expected label" $
      argv (Just (Pid 7)) (Press (Path "0.1.2") "Pause") `shouldBe` ["press", "--path", "0.1.2", "--expect-description", "Pause", "--pid", "7"]
    it "renders a hover" $
      argv (Just (Pid 7)) (Hover 10 20) `shouldBe` ["hover", "--x", "10", "--y", "20", "--pid", "7"]
    it "renders apps without a pid" $
      argv (Just (Pid 7)) Apps `shouldBe` ["apps"]
    it "renders the isolated Chrome open" $
      argv Nothing (Open "https://www.youtube.com/" "C:\\p") `shouldBe` ["open", "--url", "https://www.youtube.com/", "--chrome-profile", "C:\\p"]

  describe "runRead" $ do
    it "throws ChromeGone when the browser window is gone" $ do
      backend <- constant (77, "{\"error\":\"No visible windows for PID 7\",\"code\":\"accessibility_error\"}", "")
      withFake backend $ \_ b4 ->
        runRead b4 ODriver Apps `shouldThrow` (\(ChromeGone m) -> m == "No visible windows for PID 7")
    it "returns other accessibility failures as Left" $ do
      backend <- constant (77, "{\"error\":\"Path 0.9 no longer exists; rediscover the target\",\"code\":\"accessibility_error\"}", "")
      withFake backend $ \_ b4 -> runRead b4 ODriver (Inspect (Path "0.9")) >>= (`shouldSatisfy` isLeft)
    it "decodes stdout JSON on success" $ do
      backend <- constant (0, "{\"apps\":[]}", "")
      withFake backend $ \_ b4 -> runRead b4 ODriver Apps >>= (`shouldBe` Right (Object (KM.singleton "apps" (Array mempty))))
    it "logs one line per call with stage, origin and argv" $ do
      backend <- constant (0, "{\"apps\":[]}", "")
      lines' <- withFake backend $ \dir b4 -> runRead b4 ODriver Apps >> flushLogger (b4Logger b4) >> callLines dir
      map (lookupKey "origin") lines' `shouldBe` [Just (String "driver")]
      map (lookupKey "stage") lines' `shouldBe` [Just (String "exploration")]
      map (lookupKey "argv") lines' `shouldBe` [Just (Array (pure (String "apps")))]

  describe "runInput" $ do
    it "refuses a guarded-out call without running it" $ do
      ran <- newIORef False
      let backend = Backend (\_ -> writeIORef ran True >> pure (0, "{}", ""))
      withFake backend $ \_ b4 -> do
        r <- withInput b4 $ \tok -> runInput b4 OLlm tok (Press (Path "0.1") "Subscribe")
        r `shouldSatisfy` isLeft
      readIORef ran `shouldReturn` False
    it "never overlaps two input calls" $ do
      active <- newIORef (0 :: Int)
      peak <- newIORef (0 :: Int)
      let backend = Backend $ \_ -> do
            n <- atomicModifyIORef' active (\a -> (a + 1, a + 1))
            atomicModifyIORef' peak (\p -> (max p n, ()))
            threadDelay 20000
            atomicModifyIORef' active (\a -> (a - 1, ()))
            pure (0, "{\"ok\":true}", "")
      withFake backend $ \_ b4 ->
        forConcurrently_ [1 .. 8 :: Int] $ \_ -> withInput b4 $ \tok -> runInput b4 OLlm tok (Press (Path "0.1") "Search")
      readIORef peak `shouldReturn` 1

  describe "firstJust" $ do
    it "returns the first Just to finish" $
      firstJust [threadDelay 50000 >> pure (Just 1), pure Nothing, threadDelay 10000 >> pure (Just (2 :: Int))] `shouldReturn` Just 2
    it "returns Nothing when every attempt fails" $
      firstJust [pure Nothing, pure (Nothing :: Maybe Int)] `shouldReturn` Nothing
  where
    lookupKey k = \case
      Object o -> KM.lookup k o
      _ -> Nothing
