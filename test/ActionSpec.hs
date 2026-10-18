module ActionSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Either (isLeft)
import Test.Hspec
import Yuo.Blindly (FindQuery (..), findQ)
import Yuo.Explore.Action
import Yuo.Types (Path (..))

reply :: [Value] -> Value
reply actions = object ["thought" .= ("t" :: String), "actions" .= actions, "note" .= ("n" :: String)]

actionsOf :: Either a StepReply -> Either a [Action]
actionsOf = fmap srActions

spec :: Spec
spec = describe "decodeStep" $ do
  it "decodes a press with its expected label" $
    actionsOf (decodeStep (reply [object ["cmd" .= ("press" :: String), "path" .= ("0.1" :: String), "expect" .= ("Search" :: String)]]))
      `shouldBe` Right [APress (Path "0.1") "Search"]
  it "decodes a narrow find, always as XML" $
    actionsOf (decodeStep (reply [object ["cmd" .= ("find" :: String), "role" .= ("AXComboBox" :: String), "title" .= ("Search" :: String)]]))
      `shouldBe` Right [AFind findQ {fqRole = Just "AXComboBox", fqTitle = Just "Search", fqLimit = 10, fqXml = True}]
  it "rejects an unknown command" $
    decodeStep (reply [object ["cmd" .= ("rm -rf" :: String)]]) `shouldSatisfy` isLeft
  it "rejects more than four actions" $
    decodeStep (reply (replicate 5 (object ["cmd" .= ("done" :: String)]))) `shouldSatisfy` isLeft
  it "rejects an empty action list" $
    decodeStep (reply []) `shouldSatisfy` isLeft
  it "rejects a press without a path" $
    decodeStep (reply [object ["cmd" .= ("press" :: String), "expect" .= ("Search" :: String)]]) `shouldSatisfy` isLeft
  it "rejects a press without an expected label" $
    decodeStep (reply [object ["cmd" .= ("press" :: String), "path" .= ("0.1" :: String)]]) `shouldSatisfy` isLeft
  it "rejects a malformed path" $
    decodeStep (reply [object ["cmd" .= ("inspect" :: String), "path" .= ("0.1; rm" :: String)]]) `shouldSatisfy` isLeft
  it "clamps a long wait to five seconds" $
    actionsOf (decodeStep (reply [object ["cmd" .= ("wait" :: String), "ms" .= (60000 :: Int)]])) `shouldBe` Right [AWait 5000]
  it "rejects prose instead of JSON" $
    decodeStep (String "I think we should click") `shouldSatisfy` isLeft
  it "decodes a pause plan" $
    decodePausePlan (object ["role" .= ("AXButton" :: String), "titles" .= ["Pause (k)" :: String], "duration_seconds" .= (247 :: Int), "under_identifier" .= ("movie_player" :: String)])
      `shouldBe` Right (PausePlan (Just "movie_player") "AXButton" ["Pause (k)"] 247)
  it "rejects a pause plan without titles" $
    decodePausePlan (object ["role" .= ("AXButton" :: String), "titles" .= ([] :: [String]), "duration_seconds" .= (247 :: Int)]) `shouldSatisfy` isLeft
