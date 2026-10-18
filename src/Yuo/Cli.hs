-- | Command-line interface: one parser per subcommand, pure and separate from dispatch.
module Yuo.Cli
  ( CliCommand (..)
  , ExploreOpts (..)
  , ExploitOpts (..)
  , B4Opts (..)
  , ReportOpts (..)
  , parseCommand
  , commandInfo
  ) where

import Options.Applicative

data ExploreOpts = ExploreOpts
  { exSongs :: FilePath
  , exMaxSongs :: Int
  , exLlm :: String
  , exModel :: String
  , exMaxPlay :: Maybe Int
  , exSkipCodegen :: Bool
  , exBlindly4 :: FilePath
  }
  deriving (Eq, Show)

data ExploitOpts = ExploitOpts
  { xpSongs :: FilePath
  , xpMaxSongs :: Maybe Int -- ^ Nothing = play forever
  , xpSolution :: FilePath
  , xpBlindly4 :: FilePath
  }
  deriving (Eq, Show)

data B4Opts = B4Opts
  { b4RunDir :: FilePath
  , b4StageName :: String
  , b4OriginName :: String
  , b4Exe :: FilePath
  , b4Args :: [String]
  }
  deriving (Eq, Show)

data ReportOpts = ReportOpts
  { rpExplore :: FilePath
  , rpExploit :: FilePath
  , rpOut :: FilePath
  }
  deriving (Eq, Show)

data CliCommand
  = Explore ExploreOpts
  | Exploit ExploitOpts
  | Proxy B4Opts
  | Report ReportOpts
  deriving (Eq, Show)

defaultBlindly4 :: FilePath
defaultBlindly4 = "blindly4/.build/windows/blindly4.exe"

blindly4Opt :: Parser FilePath
blindly4Opt = strOption (long "blindly4" <> metavar "EXE" <> value defaultBlindly4 <> showDefault <> help "patched blindly4 executable")

songsOpt :: Parser FilePath
songsOpt = strOption (long "songs" <> metavar "FILE" <> value "songs.txt" <> showDefault <> help "one song query per line")

exploreP :: Parser ExploreOpts
exploreP =
  ExploreOpts
    <$> songsOpt
    <*> option auto (long "max-songs" <> metavar "N" <> value 10 <> showDefault)
    <*> strOption (long "llm" <> metavar "claude|codex" <> value "claude" <> showDefault)
    <*> strOption (long "model" <> metavar "MODEL" <> value "sonnet" <> showDefault)
    <*> optional (option auto (long "max-play-seconds" <> metavar "S" <> help "development only: pause after S seconds"))
    <*> switch (long "skip-codegen" <> help "stop after the songs; do not generate solution.py")
    <*> blindly4Opt

exploitP :: Parser ExploitOpts
exploitP =
  ExploitOpts
    <$> songsOpt
    <*> optional (option auto (long "max-songs" <> metavar "N" <> help "stop after N songs (default: forever)"))
    <*> strOption (long "solution" <> metavar "FILE" <> value "generated/solution.py" <> showDefault)
    <*> blindly4Opt

b4P :: Parser B4Opts
b4P =
  B4Opts
    <$> strOption (long "run-dir" <> metavar "DIR")
    <*> strOption (long "stage" <> metavar "exploration|exploitation")
    <*> strOption (long "origin" <> metavar "ORIGIN")
    <*> blindly4Opt
    <*> many (strArgument (metavar "-- ARGS..."))

reportP :: Parser ReportOpts
reportP =
  ReportOpts
    <$> strOption (long "explore" <> metavar "DIR")
    <*> strOption (long "exploit" <> metavar "DIR")
    <*> strOption (long "out" <> metavar "DIR" <> value "results" <> showDefault)

commandP :: Parser CliCommand
commandP =
  hsubparser $
    command "explore" (info (Explore <$> exploreP) (progDesc "LLM exploration stage; generates solution.py"))
      <> command "exploit" (info (Exploit <$> exploitP) (progDesc "run solution.py with no LLM"))
      <> command "b4" (info (Proxy <$> b4P) (progDesc "logging proxy for blindly4 (used by solution.py)"))
      <> command "report" (info (Report <$> reportP) (progDesc "compare both stages"))

commandInfo :: ParserInfo CliCommand
commandInfo = info (commandP <**> helper) (fullDesc <> progDesc "YouTube DJ driven through blindly4")

parseCommand :: [String] -> Either String CliCommand
parseCommand args = case execParserPure defaultPrefs commandInfo args of
  Success c -> Right c
  Failure f -> Left (fst (renderFailure f "yuotudidjey"))
  CompletionInvoked _ -> Left "completion"
