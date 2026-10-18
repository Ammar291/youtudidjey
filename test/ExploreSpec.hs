module ExploreSpec (spec) where

import Control.Concurrent.STM
import Data.Aeson (Value (..), decodeStrict', object, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Char8 as BC
import Data.IORef
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Yuo.Blindly
import Yuo.Explore
import Yuo.Llm
import Yuo.Log
import Yuo.Observer
import Yuo.Songs (Song (..))
import Yuo.Types

lucky :: Song
lucky = Song 0 "Daft Punk Get Lucky"

-- | A page where every find comes back empty and a press starts the song.
fakePage :: TVar (Maybe PlayInfo) -> Backend
fakePage playing = Backend $ \case
  "inspect" : _ -> pure (0, "{\"title\":\"YouTube - Google Chrome\"}", "")
  "find" : _ -> pure (0, "<matches truncated=\"false\">\n</matches>", "")
  "press" : _ -> do
    atomically (writeTVar playing (Just (PlayInfo lucky 0 1 1 Nothing Nothing 0)))
    pure (0, "{\"ok\":true}", "")
  _ -> pure (0, "{\"ok\":true}", "")

-- | Answers from a script (the last answer repeats) and records every prompt.
scripted :: [Value] -> IO (LlmBackend, IORef [Text])
scripted answers = do
  queue <- newIORef answers
  prompts <- newIORef []
  let ask _ _ prompt = do
        modifyIORef' prompts (<> [prompt])
        atomicModifyIORef' queue $ \case
          [a] -> ([a], Right a)
          a : rest -> (rest, Right a)
          [] -> ([], Left "no answer")
  pure (LlmBackend "scripted" ask, prompts)

step :: [Value] -> Value
step actions = object ["thought" .= ("t" :: String), "actions" .= actions, "note" .= ("" :: String)]

findAction, pressAction :: Value
findAction = object ["cmd" .= ("find" :: String), "role" .= ("AXComboBox" :: String)]
pressAction = object ["cmd" .= ("press" :: String), "path" .= ("0.1" :: String), "expect" .= ("Search" :: String)]

withEnv :: Backend -> LlmBackend -> STM (Maybe PlayInfo) -> (FilePath -> ExploreEnv -> IO a) -> IO a
withEnv backend llm playInfo act = withSystemTempDirectory "explore" $ \dir ->
  withLogger dir $ \logger -> do
    b4 <- newB4 backend (Just (Pid 7)) logger Exploration
    playbook <- newTVarIO (object [])
    let observer = Observer (\_ _ -> pure ()) (\_ _ -> pure ()) playInfo (pure Nothing)
    act dir (ExploreEnv b4 observer llm (AskConfig 5 []) dir playbook "schema" 25 Nothing 0)

isGaveUp :: SongOutcome -> Bool
isGaveUp = \case
  GaveUp _ -> True
  _ -> False

spec :: Spec
spec = describe "startSong" $ do
  it "gives up after exactly 25 LLM steps when the song never plays" $ do
    playing <- newTVarIO Nothing
    (llm, prompts) <- scripted [step [findAction]]
    outcome <- withEnv (fakePage playing) llm (readTVar playing) $ \_ env -> fst <$> startSong env 0 lucky
    outcome `shouldSatisfy` isGaveUp
    length <$> readIORef prompts `shouldReturn` 25

  it "feeds a rejected reply back and continues until the observer confirms playback" $ do
    playing <- newTVarIO Nothing
    (llm, prompts) <- scripted [String "I think we should click", step [object ["cmd" .= ("dance" :: String)]], step [pressAction]]
    (outcome, calls) <- withEnv (fakePage playing) llm (readTVar playing) $ \dir env -> do
      o <- fst <$> startSong env 0 lucky
      flushLogger (b4Logger (eeB4 env))
      ls <- mapMaybe decodeStrict' . BC.lines <$> BC.readFile (dir </> "blindly4.jsonl")
      pure (o, ls :: [Value])
    outcome `shouldSatisfy` (not . isGaveUp)
    ps <- readIORef prompts
    length ps `shouldBe` 3
    (ps !! 1) `shouldSatisfy` T.isInfixOf "rejected"
    (ps !! 2) `shouldSatisfy` T.isInfixOf "unknown cmd: dance"
    [o | Object c <- calls, Just (Array a) <- [KM.lookup "argv" c], take 1 (foldr (:) [] a) == [String "press"], Just o <- [KM.lookup "origin" c]]
      `shouldBe` [String "llm"]

  it "stops the stage when the browser window is gone" $ do
    playing <- newTVarIO Nothing
    (llm, _) <- scripted [step [findAction]]
    let gone = Backend (const (pure (77, "{\"error\":\"No visible windows for PID 7\",\"code\":\"accessibility_error\"}", "")))
    withEnv gone llm (readTVar playing) (\_ env -> startSong env 0 lucky) `shouldThrow` (\(ChromeGone m) -> "No visible windows" `T.isPrefixOf` m)
