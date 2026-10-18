module Main (main) where

import qualified MatchSpec
import qualified SongsSpec
import Test.Hspec
import qualified TimeSpec

main :: IO ()
main = hspec $ do
  describe "Yuo.Time" TimeSpec.spec
  describe "Yuo.Songs" SongsSpec.spec
  describe "Yuo.Match" MatchSpec.spec
