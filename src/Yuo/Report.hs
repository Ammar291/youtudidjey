-- | The comparison artifact: report.md, latency.csv and per-song call traces for both stages.
module Yuo.Report
  ( StageData (..)
  , loadStage
  , renderReport
  , renderCsv
  , writeReport
  ) where

import Data.Aeson (FromJSON, Value, decodeStrict')
import qualified Data.ByteString.Char8 as BC
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO.Utf8 as TU
import Numeric (showFFloat)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import Yuo.Metrics
import Yuo.Types

data StageData = StageData
  { sdStage :: Stage
  , sdDir :: FilePath
  , sdEvents :: [Event]
  , sdCalls :: [Call]
  , sdLlm :: [Value]
  , sdMetrics :: [SongMetric]
  }

jsonLines :: FromJSON a => FilePath -> IO [a]
jsonLines file = do
  exists <- doesFileExist file
  if exists then mapMaybe decodeStrict' . BC.lines <$> BC.readFile file else pure []

loadStage :: Stage -> FilePath -> IO StageData
loadStage stage dir = do
  events <- jsonLines (dir </> "events.jsonl")
  calls <- jsonLines (dir </> "blindly4.jsonl")
  llm <- jsonLines (dir </> "llm.jsonl")
  pure (StageData stage dir events calls llm (songMetrics stage events calls llm))

fmt :: Double -> Text
fmt x = T.pack (showFFloat (Just 2) x "")

mean :: [Double] -> Maybe Double
mean [] = Nothing
mean xs = Just (sum xs / fromIntegral (length xs))

orDash :: Maybe Double -> Text
orDash = maybe "–" fmt

originsText :: M.Map Origin Double -> Text
originsText m
  | M.null m = "0"
  | otherwise = T.intercalate ", " [originText o <> " " <> fmt n | (o, n) <- M.toList m]

meanCalls :: (SongMetric -> M.Map Origin Int) -> [SongMetric] -> M.Map Origin Double
meanCalls f ms
  | null ms = M.empty
  | otherwise = M.map (\n -> fromIntegral n / fromIntegral (length ms)) (M.unionsWith (+) (map f ms))

row :: [Text] -> Text
row cells = "| " <> T.intercalate " | " cells <> " |"

renderReport :: StageData -> StageData -> Text
renderReport ex xp =
  T.unlines $
    [ "# yuotudidjey — exploration vs exploitation"
    , ""
    , "- Exploration run: `" <> T.pack (sdDir ex) <> "`"
    , "- Exploitation run: `" <> T.pack (sdDir xp) <> "`"
    , ""
    , "**Latency** = time from a song being assigned to the independent, read-only observer confirming that song itself audibly playing (no ad on screen). The same observer measured both stages. *Estimated* latency subtracts the position read from a fresh song-length slider value, when one was available."
    , ""
    , "## Summary"
    , ""
    , row ["", "Exploration (LLM)", "Exploitation (solution.py)"]
    , row ["---", "---", "---"]
    , both "songs assigned" (T.pack . show . length . sdMetrics)
    , both "played / failed" (\s -> let ms = sdMetrics s in T.pack (show (length (filter (not . smFailed) ms))) <> " / " <> T.pack (show (length (filter smFailed ms))))
    , both "**mean latency (s)**" (\s -> "**" <> statOr stMean s <> "**")
    , both "median / p90 latency (s)" (\s -> statOr stMedian s <> " / " <> statOr stP90 s)
    , both "min / max latency (s)" (\s -> statOr stMin s <> " / " <> statOr stMax s)
    , both "mean estimated latency (s)" (orDash . mean . mapMaybe smLatencyEst . played)
    , both "mean ad time before the song (s)" (orDash . mean . map smAdSecs . played)
    , both "mean blindly4 calls until playback" (originsText . meanCalls smCallsToPlay . played)
    , both "mean blindly4 time until playback (s)" (orDash . mean . map ((/ 1000) . smB4MsToPlay) . played)
    , both "mean LLM calls until playback" (orDash . mean . map (fromIntegral . smLlmCalls) . played)
    , both "LLM share of latency" (\s -> maybe "–" (\v -> fmt (100 * v) <> " %") (mean [smLlmMsToPlay m / 1000 / l | m <- played s, Just l <- [smLatency m], l > 0]))
    , both "mean pause margin (s, target 3)" (orDash . mean . mapMaybe smPauseMargin . sdMetrics)
    , both "mean blindly4 calls per song (all, by origin)" (originsText . meanCalls smCallsTotal . sdMetrics)
    , both "LLM calls in the whole stage" (T.pack . show . length . sdLlm)
    , ""
    , "## Per song"
    , ""
    , row ["stage", "#", "song", "latency s", "est. s", "ad s", "calls until playback", "LLM s", "pause margin s", "flags"]
    , row (replicate 10 "---")
    ]
      <> map songRow (sdMetrics ex <> sdMetrics xp)
      <> [ ""
         , "## Command mix (all blindly4 calls)"
         , ""
         , row ["origin · command", "exploration", "exploitation"]
         , row ["---", "---", "---"]
         ]
      <> mixRows
      <> [ ""
         , "## First song: calls until playback, side by side"
         , ""
         , "### Exploration"
         , "```"
         ]
      <> firstSongCalls ex
      <> ["```", "", "### Exploitation", "```"]
      <> firstSongCalls xp
      <> ["```"]
  where
    played s = filter (not . smFailed) (sdMetrics s)
    statOr f s = let st = latencyStats (sdMetrics s) in if stN st == 0 then "–" else fmt (f st)
    both label f = row [label, f ex, f xp]
    songRow m =
      row
        [ stageText (smStage m)
        , T.pack (show (smSeq m + 1))
        , smSong m
        , orDash (smLatency m)
        , orDash (smLatencyEst m)
        , fmt (smAdSecs m)
        , originsText (M.map fromIntegral (smCallsToPlay m))
        , fmt (smLlmMsToPlay m / 1000)
        , orDash (smPauseMargin m)
        , T.intercalate "; " (["FAILED" | smFailed m] <> smFlags m)
        ]
    mix s = M.fromListWith (+) [((originText (callOrigin c), command c), 1 :: Int) | c <- sdCalls s]
    command c = case callArgv c of
      x : _ -> x
      [] -> ""
    mixRows =
      let a = mix ex
          b = mix xp
          keys = M.keys (M.union a b)
       in [row [o <> " · " <> c, count (M.lookup k a), count (M.lookup k b)] | k@(o, c) <- keys]
    count = maybe "0" (T.pack . show)
    firstSongCalls s = case sdMetrics s of
      m : _ ->
        let end = (+ smAssigned m) <$> smLatency m
            inside c = callStart c >= smAssigned m && maybe True (callStart c <=) end && callOrigin c /= OObserver
         in [ fmt (callStart c - smAssigned m) <> "s [" <> originText (callOrigin c) <> "] " <> T.unwords (callArgv c) <> " → " <> T.pack (show (callExit c))
            | c <- sortOn callStart (sdCalls s)
            , inside c
            ]
      [] -> ["(no songs)"]

renderCsv :: [SongMetric] -> Text
renderCsv ms =
  T.unlines $
    "stage,seq,song,assigned,latency_s,latency_est_s,ad_s,calls_until_playback,llm_s_until_playback,pause_margin_s,failed,flags"
      : [ T.intercalate
            ","
            [ stageText (smStage m)
            , T.pack (show (smSeq m + 1))
            , quote (smSong m)
            , fmt (smAssigned m)
            , maybe "" fmt (smLatency m)
            , maybe "" fmt (smLatencyEst m)
            , fmt (smAdSecs m)
            , T.pack (show (sum (M.elems (smCallsToPlay m))))
            , fmt (smLlmMsToPlay m / 1000)
            , maybe "" fmt (smPauseMargin m)
            , if smFailed m then "true" else "false"
            , quote (T.intercalate "; " (smFlags m))
            ]
        | m <- ms
        ]
  where
    quote t = "\"" <> T.replace "\"" "\"\"" t <> "\""

-- | Writes report.md, latency.csv and traces/<stage>-song<n>.txt into @out@.
writeReport :: FilePath -> FilePath -> FilePath -> IO ()
writeReport exploreDir exploitDir out = do
  ex <- loadStage Exploration exploreDir
  xp <- loadStage Exploitation exploitDir
  createDirectoryIfMissing True (out </> "traces")
  TU.writeFile (out </> "report.md") (renderReport ex xp)
  TU.writeFile (out </> "latency.csv") (renderCsv (sdMetrics ex <> sdMetrics xp))
  mapM_ (writeTraces out) [ex, xp]

writeTraces :: FilePath -> StageData -> IO ()
writeTraces out s = mapM_ one (zip (sdMetrics s) (map (Just . smAssigned) (drop 1 (sdMetrics s)) <> [Nothing]))
  where
    one (m, next) =
      TU.writeFile (out </> "traces" </> (T.unpack (stageText (sdStage s)) <> "-song" <> show (smSeq m + 1) <> ".txt")) $
        T.unlines
          [ fmt (callStart c - smAssigned m) <> "s [" <> originText (callOrigin c) <> "] " <> T.unwords (callArgv c) <> " → exit " <> T.pack (show (callExit c)) <> " (" <> fmt (callMs c) <> " ms): " <> T.replace "\n" " " (T.take 240 (T.strip (callStdout c)))
          | c <- sortOn callStart (sdCalls s)
          , callStart c >= smAssigned m
          , maybe True (callStart c <) next
          ]
