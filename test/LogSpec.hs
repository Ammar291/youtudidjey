module LogSpec (spec) where

import Control.Concurrent.Async (forConcurrently_)
import Control.Monad (forM_)
import Data.Aeson (Value, decodeStrict')
import qualified Data.ByteString.Char8 as BC
import Data.Maybe (isJust)
import qualified Data.Text as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Yuo.Log

spec :: Spec
spec = describe "appendLineShared" $
  it "keeps every line intact under concurrent writers" $
    withSystemTempDirectory "log" $ \dir -> do
      let file = dir </> "blindly4.jsonl"
      forConcurrently_ [1 .. 8 :: Int] $ \w ->
        forM_ [1 .. 50 :: Int] $ \i ->
          appendLineShared file (T.pack ("{\"w\":" <> show w <> ",\"i\":" <> show i <> ",\"pad\":\"" <> replicate 300 'x' <> "\"}"))
      ls <- BC.lines <$> BC.readFile file
      length ls `shouldBe` 400
      all (isJust . (decodeStrict' :: BC.ByteString -> Maybe Value)) ls `shouldBe` True
