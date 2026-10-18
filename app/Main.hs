module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Options.Applicative (execParser)
import System.Exit (ExitCode (..), die, exitWith)
import Control.Monad (unless, when)
import System.Directory (doesFileExist, makeAbsolute)
import System.FilePath ((</>))
import System.IO (hSetEncoding, stderr, stdout, utf8)
import Yuo.Blindly
import Yuo.Cli
import Yuo.Log
import System.Environment (setEnv)
import Yuo.Chrome (persistentProfileVar)
import Yuo.Codegen (CodegenEnv (..), generateSolution, liveSmoke)
import Yuo.Codegen.Lint (lintSolution)
import Yuo.Exploit (ExploitConfig (..), runExploitation)
import Yuo.Report (writeReport)
import Yuo.Explore
import Yuo.Explore.Prompt (schemaDoc)
import Yuo.Llm (backendFor)
import Yuo.Songs (readSongs)
import Yuo.Types

main :: IO ()
main = do
  hSetEncoding stderr utf8
  execParser commandInfo >>= \case
    Proxy o -> proxy o >>= exitWith
    Explore o -> explore o
    Exploit o -> exploit o
    Report o -> report o

-- | @yuotudidjey b4 … -- ARGS@: guard, log and pass one blindly4 call through for solution.py.
proxy :: B4Opts -> IO ExitCode
proxy o = do
  stage <- maybe (die "bad --stage") pure (parseStage (T.pack (b4StageName o)))
  origin <- maybe (die "bad --origin") pure (parseOrigin (T.pack (b4OriginName o)))
  (code, out, err) <- withLogger (b4RunDir o) $ \logger -> do
    b4 <- newB4 (processBackend (b4Exe o)) (Pid <$> b4SessionPid o) logger stage
    runRawArgv b4 origin (map T.pack (b4Args o))
  BS.hPut stdout (TE.encodeUtf8 out)
  BS.hPut stderr (TE.encodeUtf8 err)
  pure (if code == 0 then ExitSuccess else ExitFailure code)

-- | Exploration stage: LLM-driven songs, then (Task 10) code generation.
explore :: ExploreOpts -> IO ()
explore o = do
  hSetEncoding stdout utf8
  usePersistentProfile (exProfile o)
  songs <- readSongs (exSongs o)
  when (null songs) (die ("no songs in " <> exSongs o))
  let backend = backendFor (T.pack (exLlm o)) (T.pack (exModel o))
  dir <- maybe (runExploration (ExploreConfig songs (exMaxSongs o) backend (exMaxPlay o) (exBlindly4 o))) makeAbsolute (exFromRun o)
  putStrLn ("exploration run: " <> dir)
  unless (exSkipCodegen o) $ withLogger dir $ \logger -> do
    b <- newB4 (processBackend (exBlindly4 o)) Nothing logger Exploration
    schema <- either (const "") schemaDoc <$> runRead b ODriver Schema
    let writer = backendFor (T.pack (exLlm o)) (T.pack (exCodegenModel o))
    generated <- generateSolution (CodegenEnv logger writer dir (exSongs o) (exBlindly4 o) "generated/solution.py" schema (liveSmoke dir (exSongs o) (exBlindly4 o)))
    either (\e -> die ("no solution.py was installed:\n" <> T.unpack e)) (\p -> putStrLn ("solution.py: " <> p)) generated

-- | Exploitation stage: the generated solution.py alone, with no LLM reachable.
exploit :: ExploitOpts -> IO ()
exploit o = do
  hSetEncoding stdout utf8
  usePersistentProfile (xpProfile o)
  exists <- doesFileExist (xpSolution o)
  unless exists (die (xpSolution o <> " does not exist: run explore first"))
  violations <- lintSolution (xpSolution o)
  unless (null violations) (die ("refusing to run a solution.py that fails the lint:\n" <> T.unpack (T.unlines violations)))
  (dir, code) <- runExploitation (ExploitConfig (xpSongs o) (xpMaxSongs o) (xpSolution o) (xpBlindly4 o) (xpMaxPlay o))
  putStrLn ("exploitation run: " <> dir)
  exitWith (if code == 0 then ExitSuccess else ExitFailure code)

report :: ReportOpts -> IO ()
report o = do
  writeReport (rpExplore o) (rpExploit o) (rpOut o)
  putStrLn ("report: " <> (rpOut o </> "report.md"))

-- | Every browser session of this process (stages and smoke runs) reuses the given profile.
usePersistentProfile :: Maybe FilePath -> IO ()
usePersistentProfile = mapM_ (\dir -> makeAbsolute dir >>= setEnv persistentProfileVar)
