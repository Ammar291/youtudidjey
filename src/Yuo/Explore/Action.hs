-- | The vocabulary the exploring LLM may use, decoded defensively: anything outside it is a
-- 'Left' that goes back into the next prompt, never a command.
module Yuo.Explore.Action
  ( Action (..)
  , StepReply (..)
  , decodeStep
  , stepSchema
  , PausePlan (..)
  , decodePausePlan
  , pauseSchema
  , playbookSchema
  , toCommand
  , renderAction
  ) where

import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Char (isDigit)
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Yuo.Blindly
import Yuo.Types (Path (..))

data Action
  = AFind FindQuery
  | AInspect Path
  | AList Path Int Int
  | ASetValue Path Text Text
  | APress Path Text
  | AFocus Path Text
  | AKey Text (Maybe (Path, Text))
  | AScroll Text Int
  | AHover Int Int
  | AWait Int
  | ADone
  | AGiveUp Text
  deriving (Eq, Show)

data StepReply = StepReply {srThought :: Text, srActions :: [Action], srNote :: Text}
  deriving (Eq, Show)

-- | How the step was asked to look: a pure check of the LLM's JSON.
decodeStep :: Value -> Either Text StepReply
decodeStep = \case
  Object o -> do
    actions <- case KM.lookup "actions" o of
      Just (Array a) | not (V.null a) && V.length a <= 4 -> traverse decodeAction (V.toList a)
      Just (Array _) -> Left "actions must hold 1 to 4 actions"
      _ -> Left "reply has no actions array"
    pure (StepReply (str "thought" o) actions (str "note" o))
  _ -> Left "reply is not a JSON object"
  where
    str k o = case KM.lookup k o of
      Just (String t) -> t
      _ -> ""

clamp :: Int -> Int -> Int -> Int
clamp lo hi = max lo . min hi

decodeAction :: Value -> Either Text Action
decodeAction = \case
  Object o -> case text "cmd" of
    Just "find"
      | all isNothing [text "title", text "role", text "value", text "description", text "identifier"] ->
          Left "find needs at least one of title, role, value, description, identifier"
      | otherwise -> do
          under <- traverse path (text "under")
          pure . AFind $
            findQ
              { fqTitle = text "title"
              , fqRole = text "role"
              , fqValue = text "value"
              , fqDescription = text "description"
              , fqIdentifier = text "identifier"
              , fqUnder = under
              , fqDepth = clamp 1 60 (int 40 "depth")
              , fqLimit = clamp 1 50 (int 10 "limit")
              , fqXml = True
              }
    Just "inspect" -> AInspect <$> need "inspect needs path" (text "path" >>= ok . path)
    Just "list" -> (\p -> AList p (clamp 1 8 (int 3 "depth")) (clamp 1 150 (int 60 "limit"))) <$> need "list needs under" (text "under" >>= ok . path)
    Just "set_value" -> labelled "set_value" (\p e -> (\v -> ASetValue p v e) <$> need "set_value needs value" (text "value"))
    Just "press" -> labelled "press" (\p e -> Right (APress p e))
    Just "focus" -> labelled "focus" (\p e -> Right (AFocus p e))
    Just "key" -> do
      k <- need "key needs key" (text "key")
      guarded <- case (text "target_path", text "require_value") of
        (Just p, Just v) -> (\pp -> Just (pp, v)) <$> path p
        (Nothing, Nothing) -> Right Nothing
        _ -> Left "key needs target_path and require_value together"
      pure (AKey k guarded)
    Just "scroll" -> case text "direction" of
      Just d | d `elem` ["up", "down", "left", "right"] -> Right (AScroll d (clamp 1 15 (int 3 "amount")))
      _ -> Left "scroll needs direction up, down, left or right"
    Just "hover" -> case (KM.lookup "x" o, KM.lookup "y" o) of
      (Just (Number _), Just (Number _)) -> Right (AHover (int 0 "x") (int 0 "y"))
      _ -> Left "hover needs x and y"
    Just "wait" -> Right (AWait (clamp 0 5000 (int 1000 "ms")))
    Just "done" -> Right ADone
    Just "give_up" -> Right (AGiveUp (maybe "" id (text "reason")))
    Just other -> Left ("unknown cmd: " <> other)
    Nothing -> Left "action has no cmd"
    where
      text k = case KM.lookup (K.fromText k) o of
        Just (String t) -> Just t
        _ -> Nothing
      int d k = case KM.lookup (K.fromText k) o of
        Just (Number n) -> round n
        _ -> d
      need msg = maybe (Left msg) Right
      ok = either (const Nothing) Just
      labelled name k = do
        p <- need (name <> " needs path") (text "path" >>= ok . path)
        e <- need (name <> " needs expect: text the target's accessible name contains") (T.strip <$> text "expect")
        if T.null e then Left (name <> " needs a non-empty expect") else k p e
  _ -> Left "action is not an object"

path :: Text -> Either Text Path
path t
  | not (T.null t) && all (\p -> not (T.null p) && T.all isDigit p) (T.splitOn "." t) = Right (Path t)
  | otherwise = Left ("not a tree path: " <> t)

-- | JSON Schema handed to the CLI so the reply is structured.
stepSchema :: Value
stepSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties"
        .= object
          [ "thought" .= strT
          , "actions"
              .= object
                [ "type" .= ("array" :: Text)
                , "minItems" .= (1 :: Int)
                , "maxItems" .= (4 :: Int)
                , "items"
                    .= object
                      [ "type" .= ("object" :: Text)
                      , "properties"
                          .= object
                            ( ("cmd" .= object ["type" .= ("string" :: Text), "enum" .= cmds])
                                : [K.fromText k .= strT | k <- strings]
                                  <> [K.fromText k .= intT | k <- ints]
                            )
                      , "required" .= ["cmd" :: Text]
                      ]
                ]
          , "note" .= strT
          ]
    , "required" .= ["thought", "actions", "note" :: Text]
    ]
  where
    cmds = ["find", "inspect", "list", "set_value", "press", "focus", "key", "scroll", "hover", "wait", "done", "give_up" :: Text]
    strings = ["title", "role", "value", "description", "identifier", "under", "path", "expect", "key", "target_path", "require_value", "direction", "reason"]
    ints = ["depth", "limit", "amount", "x", "y", "ms"]

strT, intT :: Value
strT = object ["type" .= ("string" :: Text)]
intT = object ["type" .= ("integer" :: Text)]

-- | How to pause, and how long the video is, as the LLM understands it.
data PausePlan = PausePlan
  { ppUnderIdentifier :: Maybe Text
  , ppRole :: Text
  , ppTitles :: [Text]
  , ppDurationSec :: Int
  }
  deriving (Eq, Show)

decodePausePlan :: Value -> Either Text PausePlan
decodePausePlan = \case
  Object o -> do
    role <- maybe (Left "pause plan needs role") Right (str "role" o)
    titles <- case KM.lookup "titles" o of
      Just (Array a) | ts@(_ : _) <- [t | String t <- V.toList a, not (T.null t)] -> Right ts
      _ -> Left "pause plan needs at least one title"
    dur <- case KM.lookup "duration_seconds" o of
      Just (Number n) | n > 0 -> Right (round n)
      _ -> Left "pause plan needs duration_seconds"
    pure (PausePlan (str "under_identifier" o) role titles dur)
  _ -> Left "pause plan is not a JSON object"
  where
    str k o = case KM.lookup k o of
      Just (String t) | not (T.null t) -> Just t
      _ -> Nothing

pauseSchema :: Value
pauseSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties"
        .= object
          [ "under_identifier" .= strT
          , "role" .= strT
          , "titles" .= object ["type" .= ("array" :: Text), "items" .= strT, "minItems" .= (1 :: Int)]
          , "duration_seconds" .= intT
          , "duration_source" .= strT
          ]
    , "required" .= ["role", "titles", "duration_seconds", "duration_source" :: Text]
    ]

playbookSchema :: Value
playbookSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties"
        .= object
          [ "steps" .= listOf strT
          , "selectors" .= listOf (object ["type" .= ("object" :: Text), "properties" .= object ["name" .= strT, "how" .= strT], "required" .= ["name", "how" :: Text]])
          , "pitfalls" .= listOf strT
          ]
    , "required" .= ["steps", "selectors", "pitfalls" :: Text]
    ]
  where
    listOf t = object ["type" .= ("array" :: Text), "items" .= t]

-- | Wait, done and give-up are handled by the loop; everything else is a blindly4 command.
toCommand :: Action -> Maybe (Either (Command 'ReadOnly) (Command 'Mutating))
toCommand = \case
  AFind q -> Just (Left (Find q))
  AInspect p -> Just (Left (Inspect p))
  AList p d l -> Just (Left (Find findQ {fqTitle = Just "", fqUnder = Just p, fqDepth = d, fqLimit = l, fqXml = True}))
  ASetValue p v e -> Just (Right (SetValue p v e))
  APress p e -> Just (Right (Press p e))
  AFocus p e -> Just (Right (Focus p e))
  AKey k g -> Just (Right (Key k g))
  AScroll d n -> Just (Right (Scroll d n))
  AHover x y -> Just (Right (Hover x y))
  AWait _ -> Nothing
  ADone -> Nothing
  AGiveUp _ -> Nothing

-- | A short human-readable form for prompts and logs.
renderAction :: Action -> Text
renderAction = \case
  AWait ms -> "wait " <> tshow ms <> " ms"
  ADone -> "done"
  AGiveUp r -> "give_up: " <> r
  a -> maybe "?" (T.unwords . either (argv Nothing) (argv Nothing)) (toCommand a)
  where
    tshow = T.pack . show
