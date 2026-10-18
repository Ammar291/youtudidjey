module MatchSpec (spec) where

import Test.Hspec
import Yuo.Match

spec :: Spec
spec = do
  describe "paneInfo" $ do
    it "extracts the video title and the audio flag" $
      paneInfo "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster) - YouTube - Audio playing - Google Chrome"
        `shouldBe` PaneInfo (Just "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)") True
    it "reads a silent results page" $
      paneInfo "Daft Punk Get Lucky - YouTube - Google Chrome" `shouldBe` PaneInfo (Just "Daft Punk Get Lucky") False
    it "has no video title outside YouTube" $
      paneInfo "New Tab - Google Chrome" `shouldBe` PaneInfo Nothing False

  describe "songMatches" $ do
    it "matches the official upload" $
      songMatches "Daft Punk Get Lucky" "Daft Punk - Get Lucky (Official Audio) ft. Pharrell Williams, Nile Rodgers" `shouldBe` True
    it "rejects a different song" $
      songMatches "Daft Punk Get Lucky" "Rick Astley - Together Forever (Official HD Video)" `shouldBe` False
    it "ignores accents" $
      songMatches "Beyonc\233 Halo" "Beyonce - Halo (Official Video)" `shouldBe` True
    it "handles hyphenated artist names" $
      songMatches "a-ha Take On Me" "a-ha - Take On Me (Official Video) [4K]" `shouldBe` True
    it "matches Arabic titles" $
      songMatches "\1593\1605\1585\1608 \1583\1610\1575\1576" "\1593\1605\1585\1608 \1583\1610\1575\1576 - \1606\1608\1585 \1575\1604\1593\1610\1606" `shouldBe` True

  describe "playState" $
    it "reads both label styles of the play/pause button" $
      map playState ["Pause (k)", "Pause keyboard shortcut k", "Play (k)", "Play keyboard shortcut k", "Play on TV"]
        `shouldBe` [Just Playing, Just Playing, Just PausedState, Just PausedState, Nothing]

  describe "isAdMarker" $
    it "recognises ad overlay controls only" $
      map isAdMarker ["Sponsored", "My Ad Center", "Skip", "Skip navigation", "Settings"]
        `shouldBe` [True, True, True, False, False]
