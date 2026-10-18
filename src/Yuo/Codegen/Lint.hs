{-# LANGUAGE TemplateHaskell #-}

-- | The deterministic gate in front of generated code: functional style and safety rules,
-- checked by a Python @ast@ script compiled into this binary.
module Yuo.Codegen.Lint
  ( fpLintScript
  , lintSolution
  ) where

import Data.Aeson (Value (..), eitherDecodeStrict')
import qualified Data.Aeson.KeyMap as KM
import Data.FileEmbed (embedStringFile)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import Yuo.Process (runUtf8)

fpLintScript :: Text
fpLintScript = $(embedStringFile "lint/fp_lint.py")

-- | Human-readable violations; empty means the file passes.
lintSolution :: FilePath -> IO [Text]
lintSolution file = do
  (code, out, err) <- runUtf8 "python" ["-I", "-X", "utf8", "-", file] Nothing fpLintScript
  pure $ case eitherDecodeStrict' (TE.encodeUtf8 out) of
    Right (Object o) | Just (Array vs) <- KM.lookup "violations" o -> map describe (V.toList vs)
    _ -> ["lint did not run (exit " <> T.pack (show code) <> "): " <> T.take 400 (T.strip err)]
  where
    describe = \case
      Object v -> lineOf v <> textOf "rule" v
      other -> T.pack (show other)
    lineOf v = case KM.lookup "line" v of
      Just (Number n) | n > 0 -> "line " <> T.pack (show (round n :: Int)) <> ": "
      _ -> ""
    textOf k v = case KM.lookup k v of
      Just (String t) -> t
      _ -> ""
