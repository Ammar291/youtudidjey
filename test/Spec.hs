module Main (main) where

import qualified BlindlySpec
import qualified GuardSpec
import qualified LogSpec
import qualified MatchSpec
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
