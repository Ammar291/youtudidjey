module Main (main) where

import Options.Applicative (execParser)
import System.Exit (exitWith, ExitCode (..))
import System.IO (hPutStrLn, stderr)
import Yuo.Cli

main :: IO ()
main = execParser commandInfo >>= \case
  _ -> hPutStrLn stderr "not implemented" >> exitWith (ExitFailure 2)
