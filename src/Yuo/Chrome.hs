-- | The browser session for one stage: opened, brought forward and closed through blindly4 only.
module Yuo.Chrome
  ( ChromeSession (..)
  , withChrome
  , startUrl
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (void)
import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KM
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import System.Directory (createDirectoryIfMissing, makeAbsolute, removeDirectoryRecursive)
import System.FilePath ((</>))
import Yuo.Blindly
import Yuo.Types

data ChromeSession = ChromeSession {chromePid :: Pid, chromeProfile :: FilePath}

startUrl :: Text
startUrl = "https://www.youtube.com/"

-- | Fresh isolated profile per stage run; YouTube open and in front before the action runs.
withChrome :: B4 -> Stage -> (ChromeSession -> IO a) -> IO a
withChrome b4 stage = bracket open close
  where
    open = do
      stamp <- formatTime defaultTimeLocale "%Y%m%d-%H%M%S" <$> getZonedTime
      profile <- makeAbsolute (".chrome-profile" </> (T.unpack (stageText stage) <> "-" <> stamp))
      createDirectoryIfMissing True profile
      reply <- withInput b4 $ \tok -> runInput b4 ODriver tok (Open startUrl (T.pack profile))
      pid <- either (fail . T.unpack . ("could not open Chrome: " <>) . errorText) pure (reply >>= pidOf)
      let b = withPid pid b4
      waitFor 40 (paneHasYouTube b)
      void (withInput b $ \tok -> runInput b ODriver tok Activate)
      threadDelay 2000000 -- let the single-page app finish building before the first song
      pure (ChromeSession pid profile)
    close (ChromeSession pid profile) = do
      let b = withPid pid b4
      void (try (withInput b $ \tok -> runInput b ODriver tok (Key "alt+f4" Nothing)) :: IO (Either SomeException (Either B4Error Value)))
      waitFor 20 (not <$> listed b pid)
      removeWhenReleased (20 :: Int) profile
    pidOf = \case
      Object o | Just (Number n) <- KM.lookup "pid" o, Just p <- toBoundedInteger n -> Right (Pid p)
      v -> Left (B4Unexpected 0 ("open returned no pid: " <> T.pack (show v)))

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
  runRead b ODriver Apps >>= \case
    Right (Object o) | Just (Array apps) <- KM.lookup "apps" o -> pure (any (hasPid p) apps)
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
