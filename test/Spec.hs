module Main (main) where

import qualified ActionSpec
import qualified BlindlySpec
import qualified ExploreSpec
import qualified GuardSpec
import qualified LintSpec
import qualified LlmSpec
import qualified LogSpec
import qualified MatchSpec
import qualified MetricsSpec
import qualified ObserverSpec
import qualified SolutionEnvSpec
import qualified SongsSpec
import Test.Hspec
import qualified TimeSpec
import qualified TreeSpec

main :: IO ()
main = hspec $ do
  describe "Yuo.Time" TimeSpec.spec
  describe "Yuo.Songs" SongsSpec.spec
  describe "Yuo.Match" MatchSpec.spec
  describe "Yuo.Guard" GuardSpec.spec
  describe "Yuo.Log" LogSpec.spec
  describe "Yuo.Blindly" BlindlySpec.spec
  describe "Yuo.Tree" TreeSpec.spec
  describe "Yuo.Observer" ObserverSpec.spec
  describe "Yuo.Llm" LlmSpec.spec
  describe "Yuo.Explore.Action" ActionSpec.spec
  describe "Yuo.Explore" ExploreSpec.spec
  describe "Yuo.Codegen.Lint" LintSpec.spec
  describe "Yuo.SolutionEnv" SolutionEnvSpec.spec
  describe "Yuo.Metrics" MetricsSpec.spec
