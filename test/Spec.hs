module Main (main) where

import Test.Hspec

main :: IO ()
main = hspec $
  describe "scaffold" $
    it "builds" True
