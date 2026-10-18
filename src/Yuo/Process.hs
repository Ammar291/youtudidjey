-- | Running a child process with UTF-8 bytes in and out, whatever the console code page is.
module Yuo.Process
  ( runUtf8
  ) where

import Control.Concurrent.Async (concurrently)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import System.Directory (makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath (isPathSeparator, normalise)
import System.IO (hClose, hSetBinaryMode)
import System.Process (CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess)

-- | @runUtf8 exe args cwd stdin@ → exit code, stdout, stderr. The child is terminated if the
-- caller is interrupted (e.g. by a timeout).
runUtf8 :: FilePath -> [String] -> Maybe FilePath -> Text -> IO (Int, Text, Text)
runUtf8 exe args cwd input = do
  -- CreateProcess does not resolve a relative path written with forward slashes.
  resolved <- if any isPathSeparator exe then normalise <$> makeAbsolute exe else pure exe
  let spec = (proc resolved args) {cwd = cwd, std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
  withCreateProcess spec $ \mIn mOut mErr ph -> case (mIn, mOut, mErr) of
    (Just hin, Just hout, Just herr) -> do
      mapM_ (`hSetBinaryMode` True) [hin, hout, herr]
      (_, (out, err)) <-
        concurrently
          (BS.hPut hin (TE.encodeUtf8 input) >> hClose hin)
          (concurrently (BS.hGetContents hout) (BS.hGetContents herr))
      code <- waitForProcess ph
      let exitInt = case code of ExitSuccess -> 0; ExitFailure n -> n
      pure (exitInt, TE.decodeUtf8With lenientDecode out, TE.decodeUtf8With lenientDecode err)
    _ -> pure (1, "", "could not start " <> T.pack exe)
