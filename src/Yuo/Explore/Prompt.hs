-- | Prompts for the exploring LLM. Blank slate by design: the goal, the rules, the action
-- vocabulary, blindly4's own command list, live observations and the LLM's own playbook — none of
-- the facts found while building yuotudidjey.
module Yuo.Explore.Prompt
  ( StepRecord (..)
  , StepContext (..)
  , stepPrompt
  , pausePrompt
  , reflectPrompt
  , schemaDoc
  ) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Yuo.Log (encodeLine)
import Yuo.Songs (Song (..))

data StepRecord = StepRecord {stepAction :: Text, stepOk :: Bool, stepResult :: Text}
  deriving (Eq, Show)

data StepContext = StepContext
  { scSong :: Song
  , scPane :: Text
  , scSchema :: Text
  , scPlaybook :: Value
  , scHistory :: [StepRecord]
  , scRejected :: Maybe Text
  , scStep :: Int
  , scBudget :: Int
  }

-- | @blindly4 schema@ condensed to one line per command.
schemaDoc :: Value -> Text
schemaDoc = \case
  Object o | Just (Array cs) <- KM.lookup "commands" o -> T.unlines [line c | Object c <- V.toList cs]
  _ -> ""
  where
    line c = field "usage" c <> " — " <> field "summary" c <> " [" <> field "risk" c <> "]"
    field k c = case KM.lookup k c of
      Just (String t) -> t
      _ -> ""

actionDoc :: Text
actionDoc =
  T.unlines
    [ "Actions (JSON objects, field \"cmd\" plus its fields):"
    , "- {\"cmd\":\"find\", \"title\"|\"role\"|\"value\"|\"description\"|\"identifier\": text, \"under\"?: path, \"depth\"?: n, \"limit\"?: n} — search the tree (case-insensitive contains; identifier exact). Result: XML."
    , "- {\"cmd\":\"list\", \"under\": path, \"depth\"?: n, \"limit\"?: n} — every element below a path. Result: XML."
    , "- {\"cmd\":\"inspect\", \"path\": path} — one element in detail."
    , "- {\"cmd\":\"set_value\", \"path\", \"value\", \"expect\"} — replace the text of an editable field."
    , "- {\"cmd\":\"press\", \"path\", \"expect\"} — invoke a button or link."
    , "- {\"cmd\":\"focus\", \"path\", \"expect\"} — give an element keyboard focus."
    , "- {\"cmd\":\"key\", \"key\": \"escape\"|\"f5\"|\"0\"..\"9\"|\"return\", \"target_path\"?, \"require_value\"?} — return/enter only with target_path + require_value (the focused field must contain exactly that text)."
    , "- {\"cmd\":\"scroll\", \"direction\": up|down|left|right, \"amount\"?: n}"
    , "- {\"cmd\":\"hover\", \"x\", \"y\"} — move the pointer (screen coordinates; an element's frame is x,y,w,h)."
    , "- {\"cmd\":\"wait\", \"ms\": up to 5000}"
    , "- {\"cmd\":\"done\"} — you believe the song is playing."
    , "- {\"cmd\":\"give_up\", \"reason\"}"
    ]

rules :: Text
rules =
  T.unlines
    [ "Rules:"
    , "- press, set_value and focus need \"expect\": text contained in the target's accessible name or description; blindly4 checks it before acting, so a stale path fails safely."
    , "- Never touch subscribe, like, share, save, comment, sign-in, purchase or other account or social controls (they are refused)."
    , "- Do not close the browser. Keep searches narrow (role, identifier, title, under): listing the whole page is slow."
    , "- Paths are positions in the live tree; they change when the page changes. Find again before acting on a page that may have changed."
    ]

stepPrompt :: StepContext -> Text
stepPrompt c =
  T.unlines $
    [ "You operate Google Chrome on Windows through blindly4, a command-line tool that reads the accessibility (UI Automation) tree of the browser window and triggers UI events. You never run commands yourself: you reply with JSON actions, yuotudidjey runs them through blindly4 (adding the browser's --pid) and shows you the results."
    , ""
    , "Goal: make YouTube play the song \"" <> songQuery (scSong c) <> "\" — the song itself (an official video or audio, or a normal upload), from its beginning; not a mix, playlist, loop, extended, live or lyrics-only version unless nothing else exists. A separate observer confirms playback; keep acting until it does."
    , ""
    , rules
    , actionDoc
    , "blindly4 commands (for reference; you use the actions above):"
    , scSchema c
    , "Browser window title now: " <> scPane c
    , "Step " <> tshow (scStep c) <> " of " <> tshow (scBudget c) <> "."
    , "Your playbook from earlier songs: " <> encodeLine (scPlaybook c)
    , ""
    , "Recent steps (oldest first):"
    ]
      <> zipWith history [1 :: Int ..] (scHistory c)
      <> maybe [] (\e -> ["", "Your previous reply was rejected: " <> e]) (scRejected c)
      <> ["", "Reply with {\"thought\": short reasoning, \"actions\": 1 to 4 actions run in order (later ones are skipped if one fails), \"note\": anything worth remembering}."]
  where
    history i r = tshow i <> ". " <> stepAction r <> (if stepOk r then " → " else " → FAILED: ") <> stepResult r

pausePrompt :: Song -> Text -> Text -> Text
pausePrompt song pane observation =
  T.unlines
    [ "The song \"" <> songQuery song <> "\" is now playing in YouTube (window title: " <> pane <> ")."
    , "yuotudidjey will pause it 3 seconds before its end with a timer, then press the pause control."
    , "From the buttons and sliders below (XML from blindly4), say:"
    , "- which control pauses playback: its role, the accessible titles it may show while playing (all variants you can infer), and optionally the identifier of a container element it is inside;"
    , "- the full length of the video in seconds, and where you read it."
    , ""
    , observation
    ]

reflectPrompt :: Value -> Song -> [StepRecord] -> Text
reflectPrompt playbook song records =
  T.unlines $
    [ "You just got YouTube to play \"" <> songQuery song <> "\" by driving Chrome through blindly4. Update your playbook so the next song needs fewer steps, and so a program could later follow it without any reasoning."
    , "Record the concrete flow (steps), how to find each element reliably (selectors: role, title or identifier patterns, containers — never raw paths), and pitfalls with their fixes."
    , "Current playbook: " <> encodeLine playbook
    , ""
    , "What happened this time:"
    ]
      <> zipWith (\i r -> tshow i <> ". " <> stepAction r <> (if stepOk r then " → " else " → FAILED: ") <> T.take 400 (stepResult r)) [1 :: Int ..] records

tshow :: Show a => a -> Text
tshow = T.pack . show
