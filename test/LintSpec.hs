module LintSpec (spec) where

import qualified Data.Text as T
import Test.Hspec
import Yuo.Codegen.Lint

mentions :: T.Text -> [T.Text] -> Bool
mentions word = any (T.isInfixOf word)

spec :: Spec
spec = describe "lintSolution" $ do
  it "accepts functional code that reaches blindly4 only through YUO_B4" $
    lintSolution "test/fixtures/fp_good.py" `shouldReturn` []
  it "rejects while loops" $
    lintSolution "test/fixtures/fp_bad_while.py" >>= (`shouldSatisfy` mentions "while")
  it "rejects mutation: append, augmented assignment, global" $ do
    vs <- lintSolution "test/fixtures/fp_bad_mutation.py"
    vs `shouldSatisfy` mentions "append"
    vs `shouldSatisfy` mentions "augmented"
    vs `shouldSatisfy` mentions "global"
  it "rejects calling an LLM or the network" $ do
    vs <- lintSolution "test/fixtures/fp_bad_llm.py"
    vs `shouldSatisfy` mentions "claude"
    vs `shouldSatisfy` mentions "requests"
  it "rejects going around blindly4" $ do
    vs <- lintSolution "test/fixtures/fp_bad_bypass.py"
    vs `shouldSatisfy` mentions "ctypes"
    vs `shouldSatisfy` mentions "YUO_B4"
  it "rejects every indirect way around the YUO_B4 proxy" $ do
    vs <- lintSolution "test/fixtures/fp_bad_bypass2.py"
    let flagged n = any (T.isPrefixOf ("line " <> T.pack (show (n :: Int)) <> ":")) vs
    filter (not . flagged) [1, 3, 18, 19, 20, 21, 22, 23, 24] `shouldBe` []
  it "still accepts the generated style of proxy call" $
    lintSolution "test/fixtures/fp_good.py" `shouldReturn` []
