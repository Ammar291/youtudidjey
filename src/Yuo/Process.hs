-- | Running a child process with UTF-8 bytes in and out, whatever the console code page is.
module Yuo.Process
  ( runUtf8
  , runUtf8Timed
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently, withAsync)
import qualified Data.ByteString as BS
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import System.Directory (makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath (isPathSeparator, normalise)
import System.IO (hClose, hSetBinaryMode)
import System.Process (CreateProcess (..), StdStream (..), proc, terminateProcess, waitForProcess, withCreateProcess)

-- | @runUtf8 exe args cwd stdin@ → exit code, stdout, stderr.
runUtf8 :: FilePath -> [String] -> Maybe FilePath -> Text -> IO (Int, Text, Text)
runUtf8 exe args cwd input = maybe (1, "", "unreachable: no deadline") id <$> run Nothing exe args cwd input

-- | Like 'runUtf8', but the child is killed after @seconds@ and the result is 'Nothing'.
-- An async timeout cannot do this on Windows: a thread blocked reading a pipe is not
-- interruptible, so the process itself must end for the read to return.
runUtf8Timed :: Int -> FilePath -> [String] -> Maybe FilePath -> Text -> IO (Maybe (Int, Text, Text))
runUtf8Timed seconds = run (Just seconds)

run :: Maybe Int -> FilePath -> [String] -> Maybe FilePath -> Text -> IO (Maybe (Int, Text, Text))
run deadline exe args cwd input = do
  -- CreateProcess does not resolve a relative path written with forward slashes.
  resolved <- if any isPathSeparator exe then normalise <$> makeAbsolute exe else pure exe
  let spec = (proc resolved args) {cwd = cwd, std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
  withCreateProcess spec $ \mIn mOut mErr ph -> case (mIn, mOut, mErr) of
    (Just hin, Just hout, Just herr) -> do
      killed <- newIORef False
      let watchdog = mapM_ (\s -> threadDelay (s * 1000000) >> writeIORef killed True >> terminateProcess ph) deadline
      withAsync watchdog $ \_ -> do
        mapM_ (`hSetBinaryMode` True) [hin, hout, herr]
        (_, (out, err)) <-
          concurrently
            (BS.hPut hin (TE.encodeUtf8 input) >> hClose hin)
            (concurrently (BS.hGetContents hout) (BS.hGetContents herr))
        code <- waitForProcess ph
        timedOut <- readIORef killed
        let exitInt = case code of ExitSuccess -> 0; ExitFailure n -> n
        pure $
          if timedOut
            then Nothing
            else Just (exitInt, TE.decodeUtf8With lenientDecode out, TE.decodeUtf8With lenientDecode err)
    _ -> pure (Just (1, "", "could not start " <> T.pack exe))
