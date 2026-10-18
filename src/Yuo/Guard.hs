-- | The one safety rule for every blindly4 call that yuotudidjey or solution.py makes.
module Yuo.Guard
  ( allowedCall
  , deniedLabels
  ) where

import Data.Char (isDigit)
import Data.List (find)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T

-- | Labels of controls with public or account side effects, matched as a case-insensitive prefix
-- so that a song merely containing a word ("Madonna - Like A Prayer") is still playable.
deniedLabels :: [Text]
deniedLabels =
  [ "subscribe", "unsubscribe", "like", "dislike", "share", "save", "join", "add a comment", "comment"
  , "reply", "report", "sign in", "buy", "premium", "get youtube premium", "download", "thanks"
  , "super thanks", "clip", "remix", "notify", "turn on notifications", "create", "upload"
  ]

readOnlyOrHarmless :: [Text]
readOnlyOrHarmless =
  ["apps", "schema", "tree", "show", "find", "focused", "inspect", "actions", "activate", "scroll", "hover", "scroll-to", "show-menu"]

-- | @--flag value@ pairs; a flag directly followed by another flag has an empty value.
options :: [Text] -> [(Text, Text)]
options = \case
  k : rest@(v : _) | "--" `T.isPrefixOf` v, "--" `T.isPrefixOf` k -> (k, "") : options rest
  k : v : rest | "--" `T.isPrefixOf` k -> (k, v) : options rest
  _ : rest -> options rest
  [] -> []

allowedCall :: [Text] -> Either Text ()
allowedCall [] = Left "empty blindly4 call"
allowedCall (cmd : args)
  | cmd `elem` readOnlyOrHarmless = Right ()
  | cmd == "open" =
      if maybe False ("https://www.youtube.com/" `T.isPrefixOf`) (opt "url") && isJust (opt "chrome-profile")
        then Right ()
        else Left "open is limited to https://www.youtube.com/ in an isolated --chrome-profile"
  | cmd `elem` ["press", "set-value", "focus"] = labelled
  | cmd == "key" = key
  | cmd `elem` ["type", "click", "paste", "set-selected-text"] =
      Left (cmd <> " is not allowed: use set-value or press with --expect-description")
  | otherwise = Left ("blindly4 command not allowed: " <> cmd)
  where
    opt name = lookup ("--" <> name) (options args)
    labelled = case T.strip <$> opt "expect-description" of
      Nothing -> Left (cmd <> " needs --expect-description so blindly4 verifies its target")
      Just "" -> Left (cmd <> " needs a non-empty --expect-description")
      Just label -> case find (`T.isPrefixOf` T.toCaseFold label) deniedLabels of
        Just word -> Left ("refused: '" <> label <> "' is a public side-effect control (" <> word <> ")")
        Nothing -> Right ()
    key = case T.toLower <$> opt "key" of
      Just k
        | k `elem` ["escape", "esc", "f5"] || (T.length k == 1 && T.all isDigit k) -> Right ()
        | k `elem` ["return", "enter"] && isJust (opt "target-path") && isJust (opt "require-value") -> Right ()
      _ -> Left "key allows escape, f5, a digit, or return/enter guarded by --target-path and --require-value"
