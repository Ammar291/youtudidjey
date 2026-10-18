-- | Append-only JSON-lines logs for one run directory, written off the caller's thread.
module Yuo.Log
  ( Logger
  , loggerDir
  , withLogger
  , flushLogger
  , logCall
  , logEvent
  , logLlm
  , newRunDir
  , appendLineShared
  , encodeLine
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (IOException, SomeException, bracket, finally, throwIO, try)
import Control.Monad (forever, void)
import Data.Aeson (ToJSON, Value, encode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Unsafe as BU
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import System.Directory (createDirectoryIfMissing, makeAbsolute)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Win32.File
  ( closeHandle
  , createFile
  , fILE_APPEND_DATA
  , fILE_ATTRIBUTE_NORMAL
  , oPEN_ALWAYS
  , win32_WriteFile
  )
import Yuo.Types

data Item = Line FilePath Text | Barrier (MVar ())

data Logger = Logger {loggerDir :: FilePath, lgQueue :: TBQueue Item}

-- | Runs the action with a background writer; everything logged is on disk when it returns.
withLogger :: FilePath -> (Logger -> IO a) -> IO a
withLogger dir act = do
  createDirectoryIfMissing True dir
  queue <- newTBQueueIO 4096
  let logger = Logger dir queue
  withAsync (writer queue) $ \_ -> act logger `finally` flushLogger logger
  where
    writer queue = forever $
      atomically (readTBQueue queue) >>= \case
        Barrier done -> putMVar done ()
        Line file text ->
          try (appendLineShared file text) >>= \case
            Left (e :: SomeException) -> hPutStrLn stderr ("yuotudidjey: log write failed: " <> show e)
            Right () -> pure ()

-- | Blocks until every line logged before this call is written.
flushLogger :: Logger -> IO ()
flushLogger logger = do
  done <- newEmptyMVar
  atomically (writeTBQueue (lgQueue logger) (Barrier done))
  takeMVar done

enqueue :: Logger -> FilePath -> Text -> IO ()
enqueue logger name text = atomically (writeTBQueue (lgQueue logger) (Line (loggerDir logger </> name) text))

encodeLine :: ToJSON a => a -> Text
encodeLine = TE.decodeUtf8 . BL.toStrict . encode

logCall :: Logger -> Call -> IO ()
logCall logger = enqueue logger "blindly4.jsonl" . encodeLine

logEvent :: Logger -> Event -> IO ()
logEvent logger = enqueue logger "events.jsonl" . encodeLine

logLlm :: Logger -> Value -> IO ()
logLlm logger = enqueue logger "llm.jsonl" . encodeLine

-- | @logs/<stage>-<YYYYmmdd-HHMMSS>@, created, absolute.
newRunDir :: Stage -> IO FilePath
newRunDir stage = do
  stamp <- formatTime defaultTimeLocale "%Y%m%d-%H%M%S" <$> getZonedTime
  dir <- makeAbsolute ("logs" </> (T.unpack (stageText stage) <> "-" <> stamp))
  createDirectoryIfMissing True dir
  pure dir

-- | Appends one line while holding the file exclusively (share mode 0), so concurrent threads and
-- concurrent processes (the @b4@ proxy) never interleave. Retries while another writer holds it.
appendLineShared :: FilePath -> Text -> IO ()
appendLineShared file text = attempt (200 :: Int)
  where
    bytes = TE.encodeUtf8 (text <> "\n")
    attempt n =
      try write >>= \case
        Right () -> pure ()
        Left (e :: IOException)
          | n > 0 -> threadDelay 5000 >> attempt (n - 1)
          | otherwise -> throwIO e
    write =
      bracket (createFile file fILE_APPEND_DATA 0 Nothing oPEN_ALWAYS fILE_ATTRIBUTE_NORMAL Nothing) closeHandle $ \h ->
        BU.unsafeUseAsCStringLen bytes $ \(ptr, len) -> void (win32_WriteFile h ptr (fromIntegral len) Nothing)
