-- | The environment solution.py runs in: blindly4 only through the logging proxy, and no LLM.
module Yuo.SolutionEnv
  ( solutionEnv
  , stripLlmPath
  , llmDirs
  ) where

import Data.Char (toLower)
import Data.List (nub)
import Data.Maybe (catMaybes)
import qualified Data.Text as T
import System.Directory (findExecutable)
import System.FilePath (dropTrailingPathSeparator, takeDirectory, (</>))
import Yuo.Log (encodeLine)
import Yuo.Types

normaliseDir :: FilePath -> String
normaliseDir = map toLower . dropTrailingPathSeparator

-- | PATH entries minus the directories holding an LLM CLI.
stripLlmPath :: [FilePath] -> [FilePath] -> [FilePath]
stripLlmPath entries dirs = filter (\e -> normaliseDir e `notElem` map normaliseDir dirs) entries

-- | Directories of the claude and codex CLIs (and their npm shims) on this machine.
llmDirs :: IO [FilePath]
llmDirs = nub . map takeDirectory . catMaybes <$> mapM findExecutable ["claude", "codex", "claude.cmd", "codex.cmd"]

splitPath :: String -> [String]
splitPath = map T.unpack . filter (not . T.null) . T.splitOn ";" . T.pack

-- | @solutionEnv stage selfExe runDir blindly4 pid llmDirs base@.
solutionEnv :: Stage -> FilePath -> FilePath -> FilePath -> Pid -> [FilePath] -> [(String, String)] -> [(String, String)]
solutionEnv stage self runDir blindly4 (Pid pid) dirs base =
  [ ("YUO_B4", T.unpack (encodeLine proxy))
  , ("YUO_EVENTS", runDir </> "solution-events.jsonl")
  , ("YUO_CHROME_PID", show pid)
  , ("PYTHONIOENCODING", "utf-8")
  , ("PATH", foldr1' (\a b -> a <> ";" <> b) (stripLlmPath (splitPath path) dirs))
  ]
    <> filter (\(k, _) -> map toLower k `notElem` dropped) base
  where
    proxy = [self, "b4", "--run-dir", runDir, "--stage", T.unpack (stageText stage), "--origin", "solution", "--blindly4", blindly4, "--"]
    path = maybe "" snd (lookupCI "path" base)
    dropped = ["path", "anthropic_api_key", "openai_api_key", "codex_api_key", "pythonioencoding", "yuo_b4", "yuo_events", "yuo_chrome_pid"]
    lookupCI k = foldr (\(a, b) acc -> if map toLower a == k then Just (a, b) else acc) Nothing
    foldr1' f xs = if null xs then "" else foldr1 f xs
