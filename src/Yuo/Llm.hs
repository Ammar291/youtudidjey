-- | LLM reasoning through an agentic CLI used as a pipe: prompt on stdin, JSON matching a schema out.
module Yuo.Llm
  ( Purpose (..)
  , purposeText
  , LlmBackend (..)
  , claudeBackend
  , codexBackend
  , backendFor
  , AskConfig (..)
  , defaultAsk
  , askLogged
  , askLoggedWith
  , extractClaude
  ) where

import Control.Concurrent (threadDelay)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO.Utf8 as TU
import GHC.Clock (getMonotonicTime)
import System.Directory (createDirectoryIfMissing, doesFileExist, findExecutable, getTemporaryDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Yuo.Log (Logger, encodeLine, logLlm)
import Yuo.Process (runUtf8)
import Yuo.Types (nowPosix)

data Purpose = PStep | PPreparePause | PReflect | PCodegen | PRepair
  deriving (Eq, Show)

purposeText :: Purpose -> Text
purposeText = \case
  PStep -> "step"
  PPreparePause -> "prepare_pause"
  PReflect -> "reflect"
  PCodegen -> "codegen"
  PRepair -> "repair"

-- | A schema and a prompt in, a JSON value (or an error) out.
data LlmBackend = LlmBackend {llmName :: Text, llmAsk :: Value -> Text -> IO (Either Text Value)}

-- | npm installs only .cmd shims on Windows; resolve the real program behind them.
npmModule :: FilePath -> IO (Maybe FilePath)
npmModule rel =
  lookupEnv "APPDATA" >>= \case
    Nothing -> pure Nothing
    Just appData -> do
      let path = appData </> "npm" </> "node_modules" </> rel
      exists <- doesFileExist path
      pure (if exists then Just path else Nothing)

scratchDir :: IO FilePath
scratchDir = do
  dir <- (</> "yuotudidjey-llm") <$> getTemporaryDirectory
  createDirectoryIfMissing True dir
  pure dir

-- | @claude -p@ with tools disabled and hooks off: it can only answer, never act.
claudeBackend :: Text -> LlmBackend
claudeBackend model = LlmBackend ("claude:" <> model) $ \schema prompt -> do
  exe <- findExecutable "claude" >>= maybe (npmModule ("@anthropic-ai" </> "claude-code" </> "bin" </> "claude.exe")) (pure . Just)
  case exe of
    Nothing -> pure (Left "claude CLI not found")
    Just path -> do
      cwd <- scratchDir
      let args =
            [ "-p", "--model", T.unpack model, "--tools", "", "--output-format", "json"
            , "--json-schema", T.unpack (encodeLine schema), "--no-session-persistence"
            , "--settings", "{\"disableAllHooks\":true}"
            ]
      (code, out, err) <- runUtf8 path args (Just cwd) prompt
      pure $ case eitherDecodeStrict' (TE.encodeUtf8 out) of
        Right envelope -> extractClaude envelope
        Left _ -> Left ("claude exited " <> T.pack (show code) <> ": " <> T.take 400 (if T.null (T.strip err) then out else err))

-- | @codex exec@ in a read-only sandbox. Best effort: codex keeps a shell, so its log tightness is
-- weaker than claude's (see the design doc).
codexBackend :: Maybe Text -> LlmBackend
codexBackend model = LlmBackend ("codex" <> maybe "" (":" <>) model) $ \schema prompt -> do
  script <- npmModule ("@openai" </> "codex" </> "bin" </> "codex.js")
  node <- findExecutable "node"
  case (node, script) of
    (Just n, Just s) -> do
      cwd <- scratchDir
      stamp <- show . (round :: Double -> Integer) . (* 1000) <$> getMonotonicTime
      let schemaFile = cwd </> ("schema-" <> stamp <> ".json")
          outFile = cwd </> ("out-" <> stamp <> ".json")
      BL.writeFile schemaFile (encode schema)
      let args =
            [s, "exec", "--sandbox", "read-only", "--ephemeral", "--skip-git-repo-check", "--output-schema", schemaFile, "-o", outFile]
              <> maybe [] (\m -> ["-m", T.unpack m]) model
              <> ["-"]
      (code, _, err) <- runUtf8 n args (Just cwd) prompt
      exists <- doesFileExist outFile
      if not exists
        then pure (Left ("codex exited " <> T.pack (show code) <> ": " <> T.take 400 err))
        else either (Left . T.pack) Right . eitherDecodeStrict' . TE.encodeUtf8 <$> TU.readFile outFile
    _ -> pure (Left "codex CLI not found")

backendFor :: Text -> Text -> LlmBackend
backendFor name model
  | name == "codex" = codexBackend (if T.null model || model == "sonnet" then Nothing else Just model)
  | otherwise = claudeBackend model

-- | The structured output of @claude --output-format json --json-schema@.
extractClaude :: Value -> Either Text Value
extractClaude = \case
  Object o
    | Just (Bool True) <- KM.lookup "is_error" o -> Left (textField "result" o)
    | Just so <- KM.lookup "structured_output" o, so /= Null -> Right so
    | Just (String r) <- KM.lookup "result" o -> either (Left . T.pack) Right (eitherDecodeStrict' (TE.encodeUtf8 (unfence r)))
  _ -> Left "unexpected claude output"
  where
    textField k o = case KM.lookup k o of
      Just (String t) -> t
      _ -> "claude reported an error"
    -- Tolerate a fenced ```json block.
    unfence t =
      let s = T.strip t
       in if "```" `T.isPrefixOf` s then T.strip (T.dropWhileEnd (== '`') (T.dropWhile (/= '\n') s)) else s

data AskConfig = AskConfig {acTimeoutSec :: Int, acBackoffs :: [Int]}

-- | 120 s per attempt, then two retries after 2 s and 5 s.
defaultAsk :: AskConfig
defaultAsk = AskConfig 120 [2, 5]

askLogged :: Logger -> LlmBackend -> Purpose -> Value -> Text -> IO (Either Text Value)
askLogged = askLoggedWith defaultAsk

-- | One logged line per attempt in @llm.jsonl@; a timed-out child is terminated.
askLoggedWith :: AskConfig -> Logger -> LlmBackend -> Purpose -> Value -> Text -> IO (Either Text Value)
askLoggedWith cfg logger backend purpose schema prompt = go (1 :: Int) (0 : acBackoffs cfg)
  where
    go _ [] = pure (Left "no attempts")
    go attempt (delay : rest) = do
      threadDelay (delay * 1000000)
      start <- nowPosix
      t0 <- getMonotonicTime
      result <- maybe (Left "llm timeout") id <$> timeout (acTimeoutSec cfg * 1000000) (llmAsk backend schema prompt)
      t1 <- getMonotonicTime
      logLlm logger $
        object
          [ "t" .= start
          , "purpose" .= purposeText purpose
          , "backend" .= llmName backend
          , "attempt" .= attempt
          , "ms" .= ((t1 - t0) * 1000)
          , "ok" .= either (const False) (const True) result
          , "prompt" .= prompt
          , "response" .= either String id result
          ]
      case result of
        Left _ | not (null rest) -> go (attempt + 1) rest
        _ -> pure result
