-- | The browser session for one stage: opened, warmed up and closed through blindly4 only.
module Yuo.Chrome
  ( ChromeSession (..)
  , withChrome
  , warmUpUrl
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (unless, void)
import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (isJust, listToMaybe)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import System.Directory (createDirectoryIfMissing, makeAbsolute, removeDirectoryRecursive)
import System.FilePath ((</>))
import Yuo.Blindly
import Yuo.Match (PlayState (..), playState)
import Yuo.Tree
import Yuo.Types

data ChromeSession = ChromeSession {chromePid :: Pid, chromeProfile :: FilePath}

-- | A short, song-independent video. YouTube only plays videos reached by in-page navigation once
-- the session's player has been initialised by a full watch-page load (see the design doc).
warmUpUrl :: Text
warmUpUrl = "https://www.youtube.com/watch?v=jNQXAC9IVRw"

-- | Fresh isolated profile per stage run; YouTube open, warmed up, paused and in front.
withChrome :: B4 -> Stage -> (ChromeSession -> IO a) -> IO a
withChrome b4 stage = bracket open close
  where
    open = do
      stamp <- formatTime defaultTimeLocale "%Y%m%d-%H%M%S" <$> getZonedTime
      profile <- makeAbsolute (".chrome-profile" </> (T.unpack (stageText stage) <> "-" <> stamp))
      createDirectoryIfMissing True profile
      reply <- withInput b4 $ \tok -> runInput b4 ODriver tok (Open warmUpUrl (T.pack profile))
      pid <- either (fail . T.unpack . ("could not open Chrome: " <>) . errorText) pure (reply >>= pidOf)
      let b = withPid pid b4
      waitFor 40 (paneHasYouTube b)
      void (withInput b $ \tok -> runInput b ODriver tok Activate)
      waitFor 30 (pauseIfPlaying b)
      threadDelay 2000000 -- let the single-page app settle before the first song
      pure (ChromeSession pid profile)
    close (ChromeSession pid profile) = do
      let b = withPid pid b4
      closeWindow b pid (3 :: Int)
      removeWhenReleased (20 :: Int) profile
    pidOf = \case
      Object o | Just (Number n) <- KM.lookup "pid" o, Just p <- toBoundedInteger n -> Right (Pid p)
      v -> Left (B4Unexpected 0 ("open returned no pid: " <> T.pack (show v)))

nodes :: B4 -> Command 'ReadOnly -> IO [Node]
nodes b cmd = either (const []) id . (>>= either (Left . B4Unexpected 0) Right . parseMatches) <$> runRead b ODriver cmd

-- | True once nothing is playing: presses the player's pause button if it shows "Pause".
pauseIfPlaying :: B4 -> IO Bool
pauseIfPlaying b = do
  player <- nodes b (Find findQ {fqIdentifier = Just "movie_player"})
  case listToMaybe player of
    Nothing -> pure False
    Just p -> do
      kids <- nodes b (Find findQ {fqTitle = Just "", fqUnder = Just (nPath p), fqDepth = 1, fqLimit = 40})
      case [k | k <- kids, nRole k == "AXButton", playState (nTitle k) == Just Playing] of
        k : _ -> withInput b (\tok -> runInput b ODriver tok (Press (nPath k) "Pause")) >> pure False
        [] -> pure (any (isJust . playState . nTitle) kids)

-- | Presses Chrome's own caption Close button (works whatever has keyboard focus); falls back
-- to Alt+F4, which a focused bubble window can swallow.
closeWindow :: B4 -> Pid -> Int -> IO ()
closeWindow b pid tries = do
  still <- listed b pid
  unless (not still || tries <= 0) $ do
    button <- nodes b (Find findQ {fqRole = Just "AXButton", fqTitle = Just "Close", fqDepth = 8})
    void (try (withInput b $ \tok -> case button of
      n : _ -> runInput b ODriver tok (Press (nPath n) "Close")
      [] -> runInput b ODriver tok Activate >> runInput b ODriver tok (Key "alt+f4" Nothing)) :: IO (Either SomeException (Either B4Error Value)))
    waitFor 10 (not <$> listed b pid)
    closeWindow b pid (tries - 1)

-- | Chrome's helper processes keep profile files open briefly after the window closes.
removeWhenReleased :: Int -> FilePath -> IO ()
removeWhenReleased tries profile =
  (try (removeDirectoryRecursive profile) :: IO (Either SomeException ())) >>= \case
    Left _ | tries > 0 -> threadDelay 500000 >> removeWhenReleased (tries - 1) profile
    _ -> pure ()

paneHasYouTube :: B4 -> IO Bool
paneHasYouTube b =
  runRead b ODriver (Inspect (Path "0.1")) >>= \case
    Right (Object o) | Just (String t) <- KM.lookup "title" o -> pure ("YouTube" `T.isInfixOf` t)
    _ -> pure False

listed :: B4 -> Pid -> IO Bool
listed b (Pid p) =
  (try (runRead b ODriver Apps) :: IO (Either SomeException (Either B4Error Value))) >>= \case
    Right (Right (Object o)) | Just (Array apps) <- KM.lookup "apps" o -> pure (any (hasPid p) apps)
    _ -> pure False
  where
    hasPid n = \case
      Object a | Just (Number m) <- KM.lookup "pid" a -> toBoundedInteger m == Just n
      _ -> False

-- | Polls every half second, at most @tries@ times.
waitFor :: Int -> IO Bool -> IO ()
waitFor tries check
  | tries <= 0 = pure ()
  | otherwise = check >>= \ok -> if ok then pure () else threadDelay 500000 >> waitFor (tries - 1) check
