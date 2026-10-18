module LlmSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as A
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Yuo.Llm
import qualified Data.Text as T
import Yuo.Log

decodeFile :: FilePath -> IO Value
decodeFile f = BL.readFile f >>= either fail pure . A.eitherDecode

spec :: Spec
spec = do
  describe "extractClaude" $ do
    it "takes structured_output from the CLI's JSON envelope" $ do
      envelope <- decodeFile "test/fixtures/claude_structured.json"
      extractClaude envelope `shouldBe` Right (object ["n" .= (1 :: Int)])
    it "reports an error envelope" $
      extractClaude (object ["is_error" .= True, "result" .= ("boom" :: String)]) `shouldBe` Left "boom"
    it "falls back to parsing the result text" $
      extractClaude (object ["is_error" .= False, "result" .= ("{\"n\":2}" :: String)]) `shouldBe` Right (object ["n" .= (2 :: Int)])

  describe "askLoggedWith" $ do
    it "turns a crashing backend into a failed attempt instead of aborting the stage" $
      withSystemTempDirectory "run" $ \dir -> do
        let crash = LlmBackend "crash" (\_ _ _ -> ioError (userError "broken pipe"))
        r <- withLogger dir $ \logger -> askLoggedWith (AskConfig 5 []) logger crash PStep (object []) "prompt"
        r `shouldSatisfy` either (T.isInfixOf "broken pipe") (const False)
    it "times out, retries twice, and logs every attempt" $
      withSystemTempDirectory "run" $ \dir -> do
        let hung = LlmBackend "hung" (\_ _ _ -> forever (threadDelay 1000000))
        r <- withLogger dir $ \logger -> askLoggedWith (AskConfig 1 [0, 0]) logger hung PStep (object []) "prompt"
        r `shouldBe` Left "llm timeout"
        ls <- BC.lines <$> BC.readFile (dir </> "llm.jsonl")
        length ls `shouldBe` 3
        map (fmap okField . A.decodeStrict') ls `shouldBe` replicate 3 (Just (Bool False))
  where
    okField = \case
      Object o -> maybe Null id (lookupOk o)
      _ -> Null
    lookupOk o = case A.fromJSON (Object o) of
      A.Success (OkOnly b) -> Just (Bool b)
      _ -> Nothing

newtype OkOnly = OkOnly Bool

instance A.FromJSON OkOnly where
  parseJSON = A.withObject "llm line" (\o -> OkOnly <$> o A..: "ok")
