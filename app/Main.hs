module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Options.Applicative (execParser)
import System.Exit (ExitCode (..), die, exitWith)
import Control.Monad (when)
import System.IO (hPutStrLn, hSetEncoding, stderr, stdout, utf8)
import Yuo.Blindly
import Yuo.Cli
import Yuo.Log
import Yuo.Explore
import Yuo.Llm (backendFor)
import Yuo.Songs (readSongs)
import Yuo.Types

main :: IO ()
main =
  execParser commandInfo >>= \case
    Proxy o -> proxy o >>= exitWith
    Explore o -> explore o
    _ -> hPutStrLn stderr "not implemented" >> exitWith (ExitFailure 2)

-- | @yuotudidjey b4 … -- ARGS@: guard, log and pass one blindly4 call through for solution.py.
proxy :: B4Opts -> IO ExitCode
proxy o = do
  stage <- maybe (die "bad --stage") pure (parseStage (T.pack (b4StageName o)))
  origin <- maybe (die "bad --origin") pure (parseOrigin (T.pack (b4OriginName o)))
  (code, out, err) <- withLogger (b4RunDir o) $ \logger -> do
    b4 <- newB4 (processBackend (b4Exe o)) Nothing logger stage
    runRawArgv b4 origin (map T.pack (b4Args o))
  BS.hPut stdout (TE.encodeUtf8 out)
  BS.hPut stderr (TE.encodeUtf8 err)
  pure (if code == 0 then ExitSuccess else ExitFailure code)

-- | Exploration stage: LLM-driven songs, then (Task 10) code generation.
explore :: ExploreOpts -> IO ()
explore o = do
  hSetEncoding stdout utf8
  songs <- readSongs (exSongs o)
  when (null songs) (die ("no songs in " <> exSongs o))
  let backend = backendFor (T.pack (exLlm o)) (T.pack (exModel o))
  dir <- runExploration (ExploreConfig songs (exMaxSongs o) backend (exMaxPlay o) (exBlindly4 o))
  putStrLn ("exploration run: " <> dir)
