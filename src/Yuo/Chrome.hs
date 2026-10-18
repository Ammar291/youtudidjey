-- | The browser session for one stage: opened, warmed up and closed through blindly4 only.
module Yuo.Chrome
  ( ChromeSession (..)
  , EnvironmentNotReady (..)
  , withChrome
  , warmUp
  , warmUpUrl
  , profileFor
  , persistentProfileVar
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception, SomeException, bracket, throwIO, try)
import Control.Monad (unless, void, when)
import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KM
import Data.Either (isRight)
import Data.Maybe (isJust, listToMaybe)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import System.Directory (createDirectoryIfMissing, makeAbsolute, removeDirectoryRecursive)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Yuo.Blindly
import Yuo.Match (PlayState (..), playState)
import Yuo.Tree
import Yuo.Types

data ChromeSession = ChromeSession {chromePid :: Pid, chromeProfile :: FilePath, chromeThrowaway :: Bool}

-- | Environment variable naming a persistent profile (e.g. one signed in to YouTube), set by
-- @--chrome-profile@ so that every stage and smoke run of the process uses it.
persistentProfileVar :: String
persistentProfileVar = "YUO_CHROME_PROFILE"

-- | Profile directory for a stage run and whether to delete it afterwards: a fresh throwaway one by
-- default, or the given persistent one (never deleted).
profileFor :: Maybe FilePath -> Stage -> String -> (FilePath, Bool)
profileFor persistent stage stamp = case persistent of
  Just dir -> (dir, False)
  Nothing -> (".chrome-profile" </> (T.unpack (stageText stage) <> "-" <> stamp), True)

-- | A short, song-independent video. YouTube only plays videos reached by in-page navigation once
-- the session's player has been initialised by a full watch-page load (see the design doc).
warmUpUrl :: Text
warmUpUrl = "https://www.youtube.com/watch?v=jNQXAC9IVRw"

-- | The browser never reached a usable state (not in front, or the page exposes no player): a fault
-- of the environment, not of whatever was about to run in it.
newtype EnvironmentNotReady = EnvironmentNotReady Text
  deriving (Show)

instance Exception EnvironmentNotReady

-- | Fresh isolated profile per stage run; YouTube open, warmed up, paused and in front.
withChrome :: B4 -> Stage -> (ChromeSession -> IO a) -> IO a
withChrome b4 stage = bracket open close
  where
    open = do
      stamp <- formatTime defaultTimeLocale "%Y%m%d-%H%M%S" <$> getZonedTime
      persistent <- lookupEnv persistentProfileVar
      let (dir, throwaway) = profileFor persistent stage stamp
      profile <- makeAbsolute dir
      createDirectoryIfMissing True profile
      reply <- withInput b4 $ \tok -> runInput b4 ODriver tok (Open warmUpUrl (T.pack profile))
      pid <- either (fail . T.unpack . ("could not open Chrome: " <>) . errorText) pure (reply >>= pidOf)
      let b = withPid pid b4
          session = ChromeSession pid profile throwaway
      void (waitFor 40 (paneHasYouTube b))
      warmUp 30 3000000 b >>= \case
        Left why -> close session >> throwIO (EnvironmentNotReady why)
        Right () -> threadDelay 2000000 -- let the single-page app settle before the first song
      pure session
    close (ChromeSession pid profile throwaway) = do
      let b = withPid pid b4
      closeWindow b pid (3 :: Int)
      when throwaway (removeWhenReleased (20 :: Int) profile)
    pidOf = \case
      Object o | Just (Number n) <- KM.lookup "pid" o, Just p <- toBoundedInteger n -> Right (Pid p)
      v -> Left (B4Unexpected 0 ("open returned no pid: " <> T.pack (show v)))

-- | Brings Chrome to the front and waits (up to @tries@ half-second polls) for the paused player.
-- A background window exposes no page tree, so a failed activation is retried after @settleUs@; a
-- missing player gets a reload (F5) and @settleUs@ to load. At most two retries.
warmUp :: Int -> Int -> B4 -> IO (Either Text ())
warmUp tries settleUs b = attempt (2 :: Int)
  where
    attempt retries = do
      activated <- isRight <$> withInput b (\tok -> runInput b ODriver tok Activate)
      ready <- if activated then waitFor tries (pauseIfPlaying b) else pure False
      case (activated, ready) of
        (True, True) -> pure (Right ())
        _ | retries <= 0 -> pure (Left (if activated then "the YouTube player never appeared in the accessibility tree" else "Chrome could not be brought to the front"))
        (True, False) -> do
          void (withInput b (\tok -> runInput b ODriver tok (Key "f5" Nothing)))
          threadDelay settleUs
          attempt (retries - 1)
        (False, _) -> threadDelay settleUs >> attempt (retries - 1)

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
    void (waitFor 10 (not <$> listed b pid))
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

-- | Polls every half second, at most @tries@ times; whether the check passed.
waitFor :: Int -> IO Bool -> IO Bool
waitFor tries check
  | tries <= 0 = pure False
  | otherwise = check >>= \ok -> if ok then pure True else threadDelay 500000 >> waitFor (tries - 1) check
