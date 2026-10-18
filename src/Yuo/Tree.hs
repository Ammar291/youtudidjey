-- | Reading blindly4's output: JSON matches for programs, XML UI tree (capped) for the LLM.
module Yuo.Tree
  ( Node (..)
  , parseMatches
  , capXml
  ) where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Text (Text)
import qualified Data.Text as T
import Yuo.Types (Path (..))

data Node = Node
  { nPath :: Path
  , nRole :: Text
  , nTitle :: Text
  , nValue :: Maybe Text
  , nIdent :: Text
  , nActions :: [Text]
  , nCenter :: Maybe (Int, Int)
  }
  deriving (Eq, Show)

instance FromJSON Node where
  parseJSON = withObject "node" $ \o -> do
    position <- o .:? "position"
    size <- o .:? "size"
    centre <- case (position, size) of
      (Just p, Just s) -> do
        (x, y, w, h) <- (,,,) <$> p .: "x" <*> p .: "y" <*> s .: "width" <*> s .: "height"
        pure (Just (truncate (x + w / 2 :: Double), truncate (y + h / 2 :: Double)))
      _ -> pure Nothing
    Node
      <$> (Path <$> o .:? "path" .!= "")
      <*> o .: "role"
      <*> o .:? "title" .!= ""
      <*> o .:? "value"
      <*> o .:? "identifier" .!= ""
      <*> o .:? "actions" .!= []
      <*> pure centre

-- | The @matches@ of a blindly4 @find@.
parseMatches :: Value -> Either Text [Node]
parseMatches = either (Left . T.pack) Right . parseEither (withObject "find result" (.: "matches"))

data LineKind = Open Text | Close | SelfClosing Text | Other

lineKind :: Text -> LineKind
lineKind line
  | "</" `T.isPrefixOf` l = Close
  | "<!--" `T.isPrefixOf` l = Other
  | "<" `T.isPrefixOf` l && "/>" `T.isSuffixOf` l = SelfClosing name
  | "<" `T.isPrefixOf` l && ">" `T.isSuffixOf` l = Open name
  | otherwise = Other
  where
    l = T.strip line
    name = T.takeWhile (\c -> c /= ' ' && c /= '>' && c /= '/') (T.drop 1 l)

-- | A self-closing group with no title, value or id tells the LLM nothing.
anonymousLeaf :: Text -> Bool
anonymousLeaf line = case lineKind line of
  SelfClosing "AXGroup" -> not (any (`T.isInfixOf` line) [" title=\"", " value=\"", " id=\""])
  _ -> False

-- | Keeps whole lines (one element each) up to @maxChars@, then notes how many elements were cut
-- and closes whatever is still open, so the result stays well-formed.
capXml :: Int -> Text -> Text
capXml maxChars = T.intercalate "\n" . go 0 [] . filter (not . anonymousLeaf) . map (T.dropWhileEnd (== '\r')) . T.lines
  where
    go _ _ [] = []
    go used open (line : rest)
      | used' > maxChars = ("<!-- truncated " <> T.pack (show (elements (line : rest))) <> " elements -->") : map (\n -> "</" <> n <> ">") open
      | otherwise = line : go used' open' rest
      where
        used' = used + T.length line + 1
        open' = case lineKind line of
          Open n -> n : open
          Close -> drop 1 open
          _ -> open
    elements = length . filter (\l -> case lineKind l of Open _ -> True; SelfClosing _ -> True; _ -> False)
