module TreeSpec (spec) where

import Data.Aeson (Value, eitherDecodeFileStrict')
import Data.Maybe (isJust)
import qualified Data.Text as T
import qualified Data.Text.IO.Utf8 as TU
import Test.Hspec
import Yuo.Time (parseResultDuration)
import Yuo.Tree
import Yuo.Types (Path (..))

loadJson :: FilePath -> IO Value
loadJson f = eitherDecodeFileStrict' f >>= either fail pure

spec :: Spec
spec = do
  describe "parseMatches" $ do
    it "reads blindly4 search results" $ do
      nodes <- either (fail . T.unpack) pure . parseMatches =<< loadJson "test/fixtures/results_find.json"
      length nodes `shouldBe` 8
      map nIdent nodes `shouldBe` replicate 8 "video-title"
      map nRole nodes `shouldBe` replicate 8 "AXLink"
      map (isJust . parseResultDuration . nTitle) (take 1 nodes) `shouldBe` [True]
    it "computes element centres from position and size" $ do
      nodes <- either (fail . T.unpack) pure . parseMatches =<< loadJson "test/fixtures/player_children.json"
      map nPath (take 1 nodes) `shouldBe` [Path "0.1.0.0.1.1.0.1.0.0.1.0.0"]
      map nCenter (take 1 nodes) `shouldBe` [Just (637, 540)]
    it "rejects output without matches" $
      parseMatches "nope" `shouldSatisfy` either (const True) (const False)

  describe "capXml" $ do
    it "drops anonymous group leaves but keeps named controls" $ do
      xml <- TU.readFile "test/fixtures/player_children.xml"
      let out = capXml 10000 xml
      out `shouldSatisfy` T.isInfixOf "id=\"movie_player\""
      out `shouldSatisfy` T.isInfixOf "title=\"Pause (k)\""
      out `shouldNotSatisfy` T.isInfixOf "path=\"0.1.0.0.1.1.0.1.0.0.1.0.0.0\" "
      take 1 (T.lines out) `shouldBe` ["<matches truncated=\"false\">"]
      take 1 (reverse (T.lines out)) `shouldBe` ["</matches>"]
    it "truncates at a line boundary, says so, and closes open elements" $ do
      xml <- TU.readFile "test/fixtures/player_children.xml"
      let out = capXml 300 xml
      T.length out `shouldSatisfy` (<= 400)
      out `shouldSatisfy` T.isInfixOf "<!-- truncated"
      take 1 (reverse (T.lines out)) `shouldBe` ["</matches>"]
    it "closes nested tree elements in order" $
      capXml 60 "<tree truncated=\"false\">\n  <AXWindow path=\"0\" title=\"w\">\n    <AXButton path=\"0.0\" title=\"a\" />\n    <AXButton path=\"0.1\" title=\"b\" />\n  </AXWindow>\n</tree>"
        `shouldBe` "<tree truncated=\"false\">\n  <AXWindow path=\"0\" title=\"w\">\n<!-- truncated 2 elements -->\n</AXWindow>\n</tree>"
