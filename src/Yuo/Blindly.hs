-- | Every browser action goes through here: typed blindly4 commands, one logging layer,
-- one input lock, and the safety guard.
module Yuo.Blindly
  ( Risk (..)
  , FindQuery (..)
  , findQ
  , Command (..)
  , argv
  , Backend (..)
  , processBackend
  , processBackendWith
  , B4 (..)
  , newB4
  , withPid
  , InputToken
  , withInput
  , B4Error (..)
  , ChromeGone (..)
  , runRead
  , runReadText
  , runInput
  , runRawArgv
  , errorText
  ) where

import Control.Concurrent.MVar
import Control.Exception (Exception, throwIO)
import Data.Aeson (Value (..), eitherDecodeStrict')
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Clock (getMonotonicTime)
import Yuo.Guard (allowedCall)
import Yuo.Log
import Yuo.Process (runUtf8Timed)
import Yuo.Types

data Risk = ReadOnly | Mutating

data FindQuery = FindQuery
  { fqTitle :: Maybe Text
  , fqRole :: Maybe Text
  , fqValue :: Maybe Text
  , fqDescription :: Maybe Text
  , fqIdentifier :: Maybe Text
  , fqUnder :: Maybe Path
  , fqDepth :: Int
  , fqLimit :: Int
  , fqXml :: Bool
  }
  deriving (Eq, Show)

findQ :: FindQuery
findQ = FindQuery Nothing Nothing Nothing Nothing Nothing Nothing 40 1 False

-- | A blindly4 command, tagged with whether it can change the desktop.
data Command (r :: Risk) where
  Apps :: Command 'ReadOnly
  Schema :: Command 'ReadOnly
  Find :: FindQuery -> Command 'ReadOnly
  Inspect :: Path -> Command 'ReadOnly
  Open :: Text -> Text -> Command 'Mutating
  Activate :: Command 'Mutating
  SetValue :: Path -> Text -> Text -> Command 'Mutating
  Press :: Path -> Text -> Command 'Mutating
  Focus :: Path -> Text -> Command 'Mutating
  Key :: Text -> Maybe (Path, Text) -> Command 'Mutating
  Scroll :: Text -> Int -> Command 'Mutating
  Hover :: Int -> Int -> Command 'Mutating

-- | The command line, with @--pid@ appended where the command targets an application.
argv :: Maybe Pid -> Command r -> [Text]
argv pid = \case
  Apps -> ["apps"]
  Schema -> ["schema"]
  Open url profile -> ["open", "--url", url, "--chrome-profile", profile]
  Find q -> "find" : findArgs q <> withPidArg
  Inspect p -> ["inspect", "--path", unPath p] <> withPidArg
  Activate -> "activate" : withPidArg
  SetValue p v e -> ["set-value", "--path", unPath p, "--value", v, "--expect-description", e] <> withPidArg
  Press p e -> ["press", "--path", unPath p, "--expect-description", e] <> withPidArg
  Focus p e -> ["focus", "--path", unPath p, "--expect-description", e] <> withPidArg
  Key k guardArgs -> ["key", "--key", k] <> withPidArg <> maybe [] (\(p, v) -> ["--target-path", unPath p, "--require-value", v]) guardArgs
  Scroll d n -> ["scroll", "--direction", d, "--amount", tshow n] <> withPidArg
  Hover x y -> ["hover", "--x", tshow x, "--y", tshow y] <> withPidArg
  where
    withPidArg = maybe [] (\(Pid n) -> ["--pid", tshow n]) pid
    unPath (Path p) = p
    findArgs q =
      concat
        ( catMaybes
            [ (\v -> ["--title", v]) <$> fqTitle q
            , (\v -> ["--role", v]) <$> fqRole q
            , (\v -> ["--value", v]) <$> fqValue q
            , (\v -> ["--description", v]) <$> fqDescription q
            , (\v -> ["--identifier", v]) <$> fqIdentifier q
            , (\(Path p) -> ["--under", p]) <$> fqUnder q
            ]
        )
        <> ["--depth", tshow (fqDepth q), "--limit", tshow (fqLimit q)]
        <> ["--format" | fqXml q]
        <> ["xml" | fqXml q]

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | How a blindly4 command line is executed: exit code, stdout, stderr.
newtype Backend = Backend {invoke :: [Text] -> IO (Int, Text, Text)}

-- | Runs the real executable, reading its output as UTF-8 bytes (never the console code page).
processBackend :: FilePath -> Backend
processBackend = processBackendWith 60

-- | A call that runs past @seconds@ is killed and reported as exit 124, so a hung accessibility
-- read cannot hang a stage.
processBackendWith :: Int -> FilePath -> Backend
processBackendWith seconds exe = Backend $ \args ->
  maybe (124, "", "blindly4 timed out after " <> T.pack (show seconds) <> " s") id
    <$> runUtf8Timed seconds exe (map T.unpack args) Nothing ""

data B4 = B4
  { b4Backend :: Backend
  , b4Pid :: Maybe Pid
  , b4Lock :: MVar ()
  , b4Logger :: Logger
  , b4Stage :: Stage
  }

newB4 :: Backend -> Maybe Pid -> Logger -> Stage -> IO B4
newB4 backend pid logger stage = (\lock -> B4 backend pid lock logger stage) <$> newMVar ()

withPid :: Pid -> B4 -> B4
withPid pid b4 = b4 {b4Pid = Just pid}

-- | Proof that the caller holds the desktop input lock.
newtype InputToken = InputToken ()

-- | Keyboard, pointer, focus and clipboard are shared: input commands run one at a time.
withInput :: B4 -> (InputToken -> IO a) -> IO a
withInput b4 act = withMVar (b4Lock b4) (\() -> act (InputToken ()))

data B4Error
  = B4Usage Text
  | B4Access Text
  | B4Unexpected Int Text
  | B4Refused Text
  deriving (Eq, Show)

-- | The browser window no longer exists: no stage can continue.
newtype ChromeGone = ChromeGone Text
  deriving (Show)

instance Exception ChromeGone

errorText :: B4Error -> Text
errorText = \case
  B4Usage m -> m
  B4Access m -> m
  B4Unexpected n m -> "exit " <> tshow n <> ": " <> m
  B4Refused m -> m

-- | Guard, time, run and log one call. Refused calls are logged with exit 64 and never run.
call :: B4 -> Origin -> [Text] -> IO (Int, Text, Text)
call b4 origin args = do
  start <- nowPosix
  t0 <- getMonotonicTime
  result <- case allowedCall origin (b4Pid b4) args of
    Left reason -> pure (64, "{\"error\":" <> jsonString reason <> ",\"code\":\"guard_refused\"}", "")
    Right () -> invoke (b4Backend b4) args
  t1 <- getMonotonicTime
  let (code, out, err) = result
  logCall (b4Logger b4) (Call (b4Stage b4) origin args start ((t1 - t0) * 1000) code out err)
  pure result
  where
    jsonString = encodeLine

classify :: (Int, Text, Text) -> IO (Either B4Error Text)
classify (code, out, err) = case code of
  0 -> pure (Right out)
  64
    | "\"guard_refused\"" `T.isInfixOf` out -> pure (Left (B4Refused message))
    | otherwise -> pure (Left (B4Usage message))
  77
    | "No visible windows" `T.isPrefixOf` message -> throwIO (ChromeGone message)
    | otherwise -> pure (Left (B4Access message))
  n -> pure (Left (B4Unexpected n message))
  where
    message = case eitherDecodeStrict' (TE.encodeUtf8 out) of
      Right (Object o) | Just (String m) <- KM.lookup "error" o -> m
      _ -> if T.null (T.strip err) then T.strip out else T.strip err

decodeOut :: Either B4Error Text -> Either B4Error Value
decodeOut r = r >>= \out -> either (Left . B4Unexpected 0 . T.pack) Right (eitherDecodeStrict' (TE.encodeUtf8 out))

runReadText :: B4 -> Origin -> Command 'ReadOnly -> IO (Either B4Error Text)
runReadText b4 origin cmd = call b4 origin (argv (b4Pid b4) cmd) >>= classify

runRead :: B4 -> Origin -> Command 'ReadOnly -> IO (Either B4Error Value)
runRead b4 origin cmd = decodeOut <$> runReadText b4 origin cmd

runInput :: B4 -> Origin -> InputToken -> Command 'Mutating -> IO (Either B4Error Value)
runInput b4 origin (InputToken ()) cmd = decodeOut <$> (call b4 origin (argv (b4Pid b4) cmd) >>= classify)

-- | For the @b4@ proxy: the caller's own argv, guarded and logged, output passed through.
runRawArgv :: B4 -> Origin -> [Text] -> IO (Int, Text, Text)
runRawArgv = call
